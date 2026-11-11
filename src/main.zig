const std = @import("std");
const engine = @import("engine.zig");
const init_mod = @import("init.zig");
const platform = @import("platform.zig");
const model = @import("model.zig");
const store_mod = @import("store.zig");
const mcp = @import("mcp.zig");

const builtin = @import("builtin");
const build_options = @import("build_options");
pub const version = build_options.version;
pub const format = 1;

const Ctx = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    json: bool = false,
    command: []const u8 = "",
    root_env: ?[]const u8 = null,
};

const TaskView = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    list: []const u8,
    file: []const u8,
    line: usize,
    fields: []const model.Field,
};

const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
};

const ErrOut = struct {
    ok: bool = false,
    command: []const u8,
    @"error": ErrorBody,
};

const CaptureData = struct { created: []TaskView };
const ListData = struct { tasks: []TaskView };
const ShowData = struct { task: TaskView };
const MoveData = struct {
    task: TaskView,
    from: []const u8,
    to: []const u8,
    dry_run: bool,
};
const PlanData = struct {
    date: []const u8,
    context: []const u8,
    tasks: []TaskView,
};
const CheckData = struct {
    errors: []const []const u8,
    warnings: []const []const u8,
};
const RecoverData = struct { recovered: bool };

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    var ctx = Ctx{ .io = init.io, .alloc = alloc, .root_env = init.environ_map.get("ZTD_ROOT") };
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--json")) ctx.json = true;
    }

    const code = run(&ctx, argv[1..]) catch |err| {
        try fail(&ctx, err);
        std.process.exit(1);
    };
    if (code != 0) std.process.exit(code);
}

fn run(ctx: *Ctx, args: []const [:0]const u8) !u8 {
    var root: ?[]const u8 = ctx.root_env;
    var today_arg: ?[]const u8 = null;
    var dry_run = false;
    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(ctx.alloc);

    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            for (args[i + 1 ..]) |rest| try filtered.append(ctx.alloc, rest);
            break;
        }
        if (std.mem.eql(u8, a, "--root")) {
            if (i + 1 >= args.len) return usage(ctx, "--root needs a path");
            root = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--today")) {
            if (i + 1 >= args.len) return usage(ctx, "--today needs YYYY-MM-DD");
            today_arg = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--json")) {
            ctx.json = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--version")) {
            ctx.command = "version";
            if (ctx.json) {
                try writeJson(ctx, .{ .ok = true, .command = "version", .data = .{ .version = version, .format = format, .target = targetName() } });
            } else {
                try stdout(ctx, "ztd ");
                try stdout(ctx, version);
                try stdout(ctx, " ");
                try stdout(ctx, targetName());
                try stdout(ctx, " format 1\n");
            }
            return 0;
        }
        try filtered.append(ctx.alloc, a);
        i += 1;
    }

    if (filtered.items.len == 0) return usage(ctx, "missing command");
    const cmd = filtered.items[0];
    ctx.command = cmd;
    const rest = filtered.items[1..];

    if (std.mem.eql(u8, cmd, "version")) {
        if (ctx.json) {
            try writeJson(ctx, .{ .ok = true, .command = "version", .data = .{ .version = version, .format = format, .target = targetName() } });
        } else {
            try stdout(ctx, "ztd ");
            try stdout(ctx, version);
            try stdout(ctx, " ");
            try stdout(ctx, targetName());
            try stdout(ctx, " format 1\n");
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp(ctx);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        const target = if (rest.len > 0) rest[0] else ".";
        const res = try init_mod.initWorkspace(ctx.io, ctx.alloc, target, dry_run);
        if (ctx.json) {
            try success(ctx, "init", .{ .dry_run = dry_run, .root = res.root, .created = res.created });
        } else {
            if (dry_run) try stdout(ctx, "would initialize ");
            try stdout(ctx, res.root);
            try stdout(ctx, "\n");
            for (res.created) |p| {
                try stdout(ctx, "  + ");
                try stdout(ctx, p);
                try stdout(ctx, "\n");
            }
        }
        return 0;
    }

    const today = if (today_arg) |t| platform.parseDate(t) catch return usage(ctx, "--today must be YYYY-MM-DD") else platform.today(ctx.io);
    if (std.mem.eql(u8, cmd, "mcp")) {
        try mcp.serve(ctx.io, ctx.alloc, rest, root, today);
        return 0;
    }
    const root_path = try store_mod.resolveRoot(ctx.io, ctx.alloc, root);
    const mutating = !dry_run and (std.mem.eql(u8, cmd, "capture") or std.mem.eql(u8, cmd, "move") or std.mem.eql(u8, cmd, "recover"));
    var eng = try engine.Engine.init(ctx.io, ctx.alloc, root_path, today, mutating);
    defer eng.deinit();

    if (std.mem.eql(u8, cmd, "capture")) return cmdCapture(ctx, &eng, rest, dry_run);
    if (std.mem.eql(u8, cmd, "list")) return cmdList(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "show")) return cmdShow(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "move")) return cmdMove(ctx, &eng, rest, dry_run);
    if (std.mem.eql(u8, cmd, "plan")) return cmdPlan(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "check")) return cmdCheck(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "recover")) return cmdRecover(ctx, &eng, rest);

    return usage(ctx, "unknown command");
}

fn cmdCapture(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8, dry_run: bool) !u8 {
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(ctx.alloc);
    var use_stdin = false;

    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--stdin") or std.mem.eql(u8, a, "-")) {
            use_stdin = true;
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) return usage(ctx, "unknown capture option");
        try texts.append(ctx.alloc, a);
        i += 1;
    }

    if (use_stdin) {
        const data = try readStdin(ctx);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len > 0) try texts.append(ctx.alloc, try ctx.alloc.dupe(u8, t));
        }
    }
    if (texts.items.len == 0) return usage(ctx, "capture needs at least one task");

    const created = try eng.capture(texts.items, dry_run);
    if (ctx.json) {
        try success(ctx, "capture", CaptureData{ .created = try viewsLoaded(ctx.alloc, created) });
    } else {
        for (created) |lt| {
            try stdout(ctx, "created ");
            try stdout(ctx, lt.task.id);
            try stdout(ctx, "\n");
        }
    }
    return 0;
}

fn cmdList(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8) !u8 {
    var context: ?[]const u8 = null;
    var client: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var only: ?engine.List = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--context") or std.mem.eql(u8, a, "--client") or std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "--list")) {
            if (i + 1 >= args.len) return usage(ctx, "option needs a value");
            const v = args[i + 1];
            if (std.mem.eql(u8, a, "--context")) {
                context = v;
            } else if (std.mem.eql(u8, a, "--client")) {
                client = v;
            } else if (std.mem.eql(u8, a, "--project")) {
                project = v;
            } else {
                only = engine.List.parse(v) orelse return usage(ctx, "unknown list");
            }
            i += 1;
            continue;
        }
        return usage(ctx, "unknown list option");
    }
    if (client != null and context == null) return usage(ctx, "--client needs --context");
    if (project != null and context == null) return usage(ctx, "--project needs --context");

    const tasks = try eng.listTasks(context, client, project, only);
    if (ctx.json) {
        try success(ctx, "list", ListData{ .tasks = try viewsLoaded(ctx.alloc, tasks) });
    } else {
        for (tasks) |lt| try printTask(ctx, lt);
    }
    return 0;
}

fn cmdShow(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8) !u8 {
    if (args.len != 1) return usage(ctx, "show needs exactly one id");
    const all = try eng.loadAll();
    const lt = try eng.find(args[0], all);
    if (ctx.json) {
        try success(ctx, "show", ShowData{ .task = view(lt) });
    } else {
        try printTask(ctx, lt);
    }
    return 0;
}

fn cmdMove(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8, dry_run: bool) !u8 {
    var id: ?[]const u8 = null;
    var dest: ?engine.List = null;
    var text: ?[]const u8 = null;
    var set_fields: std.ArrayList([2][]const u8) = .empty;
    defer set_fields.deinit(ctx.alloc);
    var unset_fields: std.ArrayList([]const u8) = .empty;
    defer unset_fields.deinit(ctx.alloc);
    var expect_line: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--text")) {
            if (i + 1 >= args.len) return usage(ctx, "--text needs a value");
            text = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--field")) {
            if (i + 1 >= args.len) return usage(ctx, "--field needs key:value");
            const kv = args[i + 1];
            const c = std.mem.indexOfScalar(u8, kv, ':') orelse return usage(ctx, "--field needs key:value");
            try set_fields.append(ctx.alloc, .{ std.mem.trim(u8, kv[0..c], " "), std.mem.trim(u8, kv[c + 1 ..], " ") });
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--unset")) {
            if (i + 1 >= args.len) return usage(ctx, "--unset needs a key");
            try unset_fields.append(ctx.alloc, args[i + 1]);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--expect-line")) {
            if (i + 1 >= args.len) return usage(ctx, "--expect-line needs a number");
            expect_line = std.fmt.parseInt(usize, args[i + 1], 10) catch return usage(ctx, "--expect-line needs a number");
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) return usage(ctx, "unknown move option");
        if (id == null) {
            id = a;
        } else if (dest == null) {
            dest = engine.List.parse(a) orelse return usage(ctx, "unknown destination list");
        } else {
            return usage(ctx, "move takes an id and a destination");
        }
    }
    if (id == null or dest == null) return usage(ctx, "move takes an id and a destination");

    const moved = try eng.move(id.?, dest.?, text, set_fields.items, unset_fields.items, expect_line, dry_run);
    if (ctx.json) {
        try success(ctx, "move", MoveData{
            .task = view(moved),
            .from = if (moved.previous) |p| p.name() else "",
            .to = moved.list.name(),
            .dry_run = dry_run,
        });
    } else {
        try stdout(ctx, if (dry_run) "would move " else "moved ");
        try stdout(ctx, moved.task.id);
        try stdout(ctx, " -> ");
        try stdout(ctx, moved.list.name());
        try stdout(ctx, "\n");
    }
    return 0;
}

fn cmdPlan(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8) !u8 {
    var context: ?[]const u8 = null;
    var client: ?[]const u8 = null;
    var date = eng.today;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--context") or std.mem.eql(u8, a, "--client") or std.mem.eql(u8, a, "--date")) {
            if (i + 1 >= args.len) return usage(ctx, "option needs a value");
            const v = args[i + 1];
            if (std.mem.eql(u8, a, "--context")) {
                context = v;
            } else if (std.mem.eql(u8, a, "--client")) {
                client = v;
            } else {
                date = platform.parseDate(v) catch return usage(ctx, "--date must be YYYY-MM-DD");
            }
            i += 1;
            continue;
        }
        return usage(ctx, "unknown plan option");
    }
    if (context == null) return usage(ctx, "plan needs --context");

    const tasks = try eng.planTasks(date, context.?, client);
    var dbuf: [10]u8 = undefined;
    const ds = date.format(&dbuf);
    if (ctx.json) {
        try success(ctx, "plan", PlanData{
            .date = ds,
            .context = context.?,
            .tasks = try viewsLoaded(ctx.alloc, tasks),
        });
    } else {
        for (tasks) |lt| try printTask(ctx, lt);
    }
    return 0;
}

fn cmdCheck(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8) !u8 {
    var strict = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else {
            return usage(ctx, "unknown check option");
        }
    }
    const result = try eng.check(strict);
    if (ctx.json) {
        try writeJson(ctx, .{
            .ok = result.errors.len == 0,
            .command = "check",
            .data = CheckData{ .errors = result.errors, .warnings = result.warnings },
        });
    } else {
        for (result.errors) |e| {
            try stderr(ctx, "error: ");
            try stderr(ctx, e);
            try stderr(ctx, "\n");
        }
        for (result.warnings) |w| {
            try stderr(ctx, "warning: ");
            try stderr(ctx, w);
            try stderr(ctx, "\n");
        }
        if (result.errors.len == 0 and result.warnings.len == 0) try stdout(ctx, "ok\n");
    }
    return if (result.errors.len == 0) 0 else 1;
}

fn cmdRecover(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8) !u8 {
    if (args.len != 0) return usage(ctx, "recover takes no arguments");
    const did = try eng.recover();
    if (ctx.json) {
        try success(ctx, "recover", RecoverData{ .recovered = did });
    } else {
        try stdout(ctx, if (did) "recovered\n" else "nothing to recover\n");
    }
    return 0;
}

fn view(lt: engine.LoadedTask) TaskView {
    return .{
        .id = lt.task.id,
        .title = lt.task.title,
        .status = if (lt.task.status == .done) "done" else "open",
        .list = lt.list.name(),
        .file = lt.file,
        .line = lt.line,
        .fields = lt.task.fields.items,
    };
}

fn viewsLoaded(ctx_alloc: std.mem.Allocator, tasks: []const engine.LoadedTask) ![]TaskView {
    var out = try ctx_alloc.alloc(TaskView, tasks.len);
    for (tasks, 0..) |lt, i| out[i] = view(lt);
    return out;
}

fn printTask(ctx: *Ctx, lt: engine.LoadedTask) !void {
    const line = try lt.task.render(ctx.alloc);
    try stdout(ctx, line);
    try stdout(ctx, " (");
    try stdout(ctx, lt.list.name());
    if (lt.line > 0) {
        try stdout(ctx, ", line ");
        var buf: [20]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{d}", .{lt.line}) catch "";
        try stdout(ctx, n);
    }
    try stdout(ctx, ")\n");
}

fn readStdin(ctx: *Ctx) ![]u8 {
    var buf: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().reader(ctx.io, &buf);
    return reader.interface.allocRemaining(ctx.alloc, .limited(16 * 1024 * 1024));
}

fn stdout(ctx: *Ctx, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(ctx.io, text);
}

fn stderr(ctx: *Ctx, text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(ctx.io, text);
}

fn writeJson(ctx: *Ctx, value: anytype) !void {
    const text = try std.json.Stringify.valueAlloc(ctx.alloc, value, .{});
    try stdout(ctx, text);
    try stdout(ctx, "\n");
}

fn success(ctx: *Ctx, command: []const u8, data: anytype) !void {
    try writeJson(ctx, .{ .ok = true, .command = command, .data = data });
}

fn fail(ctx: *Ctx, err: anyerror) !void {
    const name = engine.errorName(err);
    if (ctx.json) {
        try writeJson(ctx, ErrOut{
            .command = ctx.command,
            .@"error" = .{ .code = name, .message = @errorName(err) },
        });
    } else {
        try stderr(ctx, "ztd: ");
        try stderr(ctx, name);
        try stderr(ctx, ": ");
        try stderr(ctx, @errorName(err));
        try stderr(ctx, "\n");
    }
}

fn usage(ctx: *Ctx, msg: []const u8) !u8 {
    if (ctx.json) {
        try writeJson(ctx, ErrOut{
            .command = ctx.command,
            .@"error" = .{ .code = "usage", .message = msg },
        });
    } else {
        try stderr(ctx, "ztd: ");
        try stderr(ctx, msg);
        try stderr(ctx, "\n");
        try printHelp(ctx);
    }
    return 2;
}

fn targetName() []const u8 {
    return @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
}

fn printHelp(ctx: *Ctx) !void {
    try stderr(ctx,
        \\usage: ztd <command> [options]
        \\
        \\  init [path]                 create a ztd workspace
        \\  capture <text>... | --stdin capture tasks into the inbox
        \\  list [--context C] [--client X] [--project P] [--list L]
        \\  show <id>                   show one task
        \\  move <id> <list> [--text T] [--field k:v] [--unset k] [--expect-line N]
        \\  plan --context C [--client X] [--date YYYY-MM-DD]
        \\  check [--strict]            validate the workspace
        \\  recover                     finish an interrupted transaction
        \\  version
        \\
        \\global: --root PATH --json --today YYYY-MM-DD --dry-run
        \\
    );
}

test {
    _ = @import("model.zig");
    _ = @import("platform.zig");
    _ = @import("store.zig");
    _ = @import("config.zig");
    _ = @import("engine.zig");
    _ = @import("init.zig");
    _ = @import("mcp.zig");
}
