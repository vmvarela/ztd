const std = @import("std");
const engine = @import("engine.zig");
const init_mod = @import("init.zig");
const platform = @import("platform.zig");
const model = @import("model.zig");
const routine_mod = @import("routine.zig");
const store_mod = @import("store.zig");
const mcp = @import("mcp.zig");
const agent = @import("agent.zig");
const db = @import("db.zig");

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
const RoutineView = struct {
    id: []const u8,
    cadence: []const u8,
    last: []const u8,
    days: i64,
};
const DueData = struct { routines: []RoutineView };
const RoutineData = struct {
    action: []const u8,
    dry_run: bool,
    routine: RoutineView,
};

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
    // Agent commands are resolved from raw argv before the global parser
    // strips flags: they never reach resolveRoot and reject legacy globals.
    if (agentDispatch(args)) |d| {
        ctx.json = true; // the JSON envelope is the default output
        ctx.command = args[d.idx];
        if (d.legacy) return usage(ctx, "agent commands do not accept global options");
        return runAgent(ctx, args[d.idx], args[d.idx + 1 ..]);
    }
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
        const target = if (rest.len > 0) rest[0] else if (root) |r| r else ".";
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
    const mutating = !dry_run and (std.mem.eql(u8, cmd, "capture") or std.mem.eql(u8, cmd, "move") or std.mem.eql(u8, cmd, "recover") or std.mem.eql(u8, cmd, "routine"));
    var eng = try engine.Engine.init(ctx.io, ctx.alloc, root_path, today, mutating);
    defer eng.deinit();

    if (std.mem.eql(u8, cmd, "capture")) return cmdCapture(ctx, &eng, rest, dry_run);
    if (std.mem.eql(u8, cmd, "list")) return cmdList(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "show")) return cmdShow(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "move")) return cmdMove(ctx, &eng, rest, dry_run);
    if (std.mem.eql(u8, cmd, "plan")) return cmdPlan(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "check")) return cmdCheck(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "recover")) return cmdRecover(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "due")) return cmdDue(ctx, &eng, rest);
    if (std.mem.eql(u8, cmd, "routine")) return cmdRoutine(ctx, &eng, rest, dry_run);

    return usage(ctx, "unknown command");
}

/// Finds an agent command in raw argv: only leading `--json` is skipped, and
/// `--root`/`--today`/`--dry-run` before the command are flagged for rejection
/// instead of being silently stripped by the global parser.
fn agentDispatch(args: []const [:0]const u8) ?struct { idx: usize, legacy: bool } {
    var i: usize = 0;
    var legacy = false;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            i += 1;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            legacy = true;
            i += 1;
        } else if (std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "--today")) {
            legacy = true;
            i += 2;
        } else if (isAgentCommand(a)) {
            return .{ .idx = i, .legacy = legacy };
        } else {
            return null;
        }
    }
    return null;
}

fn isAgentCommand(a: []const u8) bool {
    return std.mem.eql(u8, a, "agent-capture") or
        std.mem.eql(u8, a, "agent-checkpoint") or
        std.mem.eql(u8, a, "agent-prepare") or
        std.mem.eql(u8, a, "agent-backup") or
        std.mem.eql(u8, a, "agent-export") or
        std.mem.eql(u8, a, "agent-restore");
}

/// Local parser for the agent commands; the global option parser is not used.
fn runAgent(ctx: *Ctx, cmd: []const u8, args: []const [:0]const u8) !u8 {
    var scope: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var request: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var objective: ?[]const u8 = null;
    var constraints: ?[]const u8 = null;
    var idempotency_key: ?[]const u8 = null;
    var db_opt: ?[]const u8 = null;
    var expect_rev: ?i64 = null;
    var kind: []const u8 = "progress";
    var result: ?[]const u8 = null;
    var evidence: ?[]const u8 = null;
    var next_action: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var history_limit: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) continue;
        if (std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "--today") or std.mem.eql(u8, a, "--dry-run"))
            return usage(ctx, "agent commands do not accept global options");
        if (std.mem.startsWith(u8, a, "--")) {
            if (!agentValueFlag(a)) return usage(ctx, "unknown agent option");
            if (!agentFlagAllowed(cmd, a)) return usage(ctx, "option not accepted by this command");
            if (i + 1 >= args.len) return usage(ctx, "option needs a value");
            const v = args[i + 1];
            i += 1;
            if (std.mem.eql(u8, a, "--scope")) scope = v //
            else if (std.mem.eql(u8, a, "--request")) request = v //
            else if (std.mem.eql(u8, a, "--project")) project = v //
            else if (std.mem.eql(u8, a, "--objective")) objective = v //
            else if (std.mem.eql(u8, a, "--constraints")) constraints = v //
            else if (std.mem.eql(u8, a, "--idempotency-key")) idempotency_key = v //
            else if (std.mem.eql(u8, a, "--db")) db_opt = v //
            else if (std.mem.eql(u8, a, "--evidence")) evidence = v //
            else if (std.mem.eql(u8, a, "--next")) next_action = v //
            else if (std.mem.eql(u8, a, "--result")) result = v //
            else if (std.mem.eql(u8, a, "--out")) out = v //
            else if (std.mem.eql(u8, a, "--from")) from = v //
            else if (std.mem.eql(u8, a, "--history")) {
                const n = std.fmt.parseInt(usize, v, 10) catch return usage(ctx, "--history needs a number");
                if (n == 0) return usage(ctx, "--history must be positive");
                history_limit = n;
            } else if (std.mem.eql(u8, a, "--kind")) {
                if (!std.mem.eql(u8, v, "progress") and !std.mem.eql(u8, v, "done"))
                    return usage(ctx, "--kind must be progress or done");
                kind = v;
            } else if (std.mem.eql(u8, a, "--expect-rev")) {
                expect_rev = std.fmt.parseInt(i64, v, 10) catch return usage(ctx, "--expect-rev needs a number");
            } else return usage(ctx, "unknown agent option");
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) return usage(ctx, "unknown agent option");
        if (id != null) return usage(ctx, "unexpected argument");
        id = a;
    }

    if (std.mem.eql(u8, cmd, "agent-capture")) {
        if (id != null) return usage(ctx, "agent-capture takes no id");
        if (scope == null) return usage(ctx, "agent-capture needs --scope");
        if (request == null) return usage(ctx, "agent-capture needs --request");
    } else if (std.mem.eql(u8, cmd, "agent-backup") or std.mem.eql(u8, cmd, "agent-export")) {
        if (id != null) return usage(ctx, "this command takes no id");
        if (out == null) return usage(ctx, "this command needs --out");
    } else if (std.mem.eql(u8, cmd, "agent-restore")) {
        if (id != null) return usage(ctx, "agent-restore takes no id");
        if (from == null) return usage(ctx, "agent-restore needs --from");
    } else {
        if (id == null) return usage(ctx, "agent command needs an id");
        if (scope == null) return usage(ctx, "agent command needs --scope");
        if (std.mem.eql(u8, cmd, "agent-checkpoint")) {
            if (expect_rev == null) return usage(ctx, "agent-checkpoint needs --expect-rev");
            if (result == null) return usage(ctx, "agent-checkpoint needs --result");
        }
    }

    const db_path = try db.resolvePath(ctx.io, ctx.alloc, db_opt);
    defer ctx.alloc.free(db_path);
    var store = try agent.Store.open(ctx.alloc, ctx.io, db_path);
    defer store.close();

    if (std.mem.eql(u8, cmd, "agent-capture")) {
        const r = try store.capture(.{
            .scope = scope.?,
            .project = project,
            .request = request.?,
            .objective = objective,
            .constraints = constraints,
            .idempotency_key = idempotency_key,
        });
        defer store.deinitCaptureResult(r);
        try success(ctx, cmd, r);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "agent-checkpoint")) {
        const r = try store.checkpoint(.{
            .assignment_id = id.?,
            .scope = scope.?,
            .expect_rev = expect_rev.?,
            .kind = kind,
            .result = result.?,
            .evidence = evidence,
            .next_action = next_action,
            .idempotency_key = idempotency_key,
        });
        defer store.deinitCheckpointResult(r);
        try success(ctx, cmd, r);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "agent-backup")) {
        const out_path = try db.resolvePath(ctx.io, ctx.alloc, out.?);
        defer ctx.alloc.free(out_path);
        store.backupTo(ctx.alloc, out_path) catch |err| switch (err) {
            error.InvalidArgument => return invalidArgument(ctx),
            else => return err,
        };
        try success(ctx, cmd, .{ .out = out_path });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "agent-export")) {
        const out_path = try db.resolvePath(ctx.io, ctx.alloc, out.?);
        defer ctx.alloc.free(out_path);
        const data = try store.exportJson(ctx.alloc);
        defer ctx.alloc.free(data);
        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out_path, .data = data });
        try success(ctx, cmd, .{ .out = out_path });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "agent-restore")) {
        const from_path = try db.resolvePath(ctx.io, ctx.alloc, from.?);
        defer ctx.alloc.free(from_path);
        const data = try std.Io.Dir.cwd().readFileAlloc(ctx.io, from_path, ctx.alloc, .limited(1 << 30));
        defer ctx.alloc.free(data);
        const counts = store.restoreJson(ctx.alloc, data) catch |err| switch (err) {
            error.InvalidArgument => return invalidArgument(ctx),
            else => return err,
        };
        try success(ctx, cmd, counts);
        return 0;
    }
    const r = try store.prepare(id.?, scope.?);
    defer store.deinitPrepareResult(r);
    if (history_limit) |n| {
        const hist = try store.history(ctx.alloc, id.?, scope.?, n);
        try success(ctx, cmd, .{ .assignment = r.assignment, .latest = r.latest, .history = hist });
        return 0;
    }
    try success(ctx, cmd, r);
    return 0;
}

fn agentValueFlag(a: []const u8) bool {
    const names = [_][]const u8{
        "--scope",       "--request",         "--project", "--objective",
        "--constraints", "--idempotency-key", "--db",      "--evidence",
        "--next",        "--result",          "--kind",    "--expect-rev",
        "--out",         "--from",            "--history",
    };
    for (names) |n| if (std.mem.eql(u8, a, n)) return true;
    return false;
}

/// Each agent command accepts only the options it uses, so a misplaced flag is
/// rejected instead of silently discarded.
fn agentFlagAllowed(cmd: []const u8, flag: []const u8) bool {
    if (std.mem.eql(u8, flag, "--db")) return true;
    if (std.mem.eql(u8, cmd, "agent-backup") or std.mem.eql(u8, cmd, "agent-export"))
        return std.mem.eql(u8, flag, "--out");
    if (std.mem.eql(u8, cmd, "agent-restore"))
        return std.mem.eql(u8, flag, "--from");
    if (std.mem.eql(u8, cmd, "agent-prepare"))
        return std.mem.eql(u8, flag, "--scope") or std.mem.eql(u8, flag, "--history");
    if (std.mem.eql(u8, cmd, "agent-capture"))
        return std.mem.eql(u8, flag, "--scope") or std.mem.eql(u8, flag, "--request") or
            std.mem.eql(u8, flag, "--project") or std.mem.eql(u8, flag, "--objective") or
            std.mem.eql(u8, flag, "--constraints") or std.mem.eql(u8, flag, "--idempotency-key");
    if (std.mem.eql(u8, cmd, "agent-checkpoint"))
        return std.mem.eql(u8, flag, "--scope") or std.mem.eql(u8, flag, "--expect-rev") or
            std.mem.eql(u8, flag, "--result") or std.mem.eql(u8, flag, "--kind") or
            std.mem.eql(u8, flag, "--evidence") or std.mem.eql(u8, flag, "--next") or
            std.mem.eql(u8, flag, "--idempotency-key");
    return false;
}

/// The durability commands report a store-level `error.InvalidArgument`
/// refusal (non-empty restore target, existing backup file, malformed export)
/// as `invalid_argument`; `engine.errorName` has no entry for it and would
/// otherwise hide the refusal behind `io_error`.
fn invalidArgument(ctx: *Ctx) !u8 {
    try writeJson(ctx, ErrOut{
        .command = ctx.command,
        .@"error" = .{ .code = "invalid_argument", .message = "InvalidArgument" },
    });
    return 1;
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

fn cmdDue(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8) !u8 {
    if (args.len != 0) return usage(ctx, "due takes no arguments");
    const rows = try eng.routines();
    var due: std.ArrayList(RoutineView) = .empty;
    for (rows) |r| {
        if (!routine_mod.isDue(r, eng.today)) continue;
        try due.append(ctx.alloc, try routineView(ctx, eng.today, r));
    }
    if (ctx.json) {
        try success(ctx, "due", DueData{ .routines = due.items });
        return 0;
    }
    if (due.items.len == 0) {
        try stdout(ctx, "nothing due\n");
        return 0;
    }
    for (due.items) |v| {
        try stdout(ctx, v.id);
        try stdout(ctx, " | ");
        try stdout(ctx, v.cadence);
        try stdout(ctx, " | ");
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d} day{s}\n", .{
            v.days,
            if (v.days == 1) "" else "s",
        }) catch "";
        try stdout(ctx, line);
    }
    return 0;
}

fn cmdRoutine(ctx: *Ctx, eng: *engine.Engine, args: []const []const u8, dry_run: bool) !u8 {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "done")) return usage(ctx, "routine done <id>");
    const row = try eng.routineDone(args[1], dry_run);
    const v = try routineView(ctx, eng.today, row);
    if (ctx.json) {
        try success(ctx, "routine", RoutineData{ .action = "done", .dry_run = dry_run, .routine = v });
        return 0;
    }
    try stdout(ctx, if (dry_run) "would mark done " else "done ");
    try stdout(ctx, v.id);
    try stdout(ctx, " | ");
    try stdout(ctx, v.cadence);
    try stdout(ctx, " | ");
    try stdout(ctx, v.last);
    try stdout(ctx, "\n");
    return 0;
}

fn routineView(ctx: *Ctx, today: platform.Date, r: routine_mod.Row) !RoutineView {
    var buf: [10]u8 = undefined;
    return .{
        .id = r.id,
        .cadence = r.cadence,
        .last = try ctx.alloc.dupe(u8, r.last.format(&buf)),
        .days = platform.diff(today, r.last),
    };
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
        \\  due                         list routines past their cadence
        \\  routine done <id>           mark a routine as run today
        \\  agent-capture --scope S --request T [--project P] [--idempotency-key K] [--db PATH]
        \\  agent-checkpoint ID --scope S --expect-rev N --result T [--db PATH]
        \\  agent-prepare ID --scope S [--history N] [--db PATH]
        \\  agent-backup --out FILE [--db PATH]
        \\  agent-export --out FILE [--db PATH]
        \\  agent-restore --from FILE [--db PATH]
        \\  version
        \\
        \\global: --root PATH --json --today YYYY-MM-DD --dry-run
        \\
    );
}

test {
    _ = @import("model.zig");
    _ = @import("platform.zig");
    _ = @import("routine.zig");
    _ = @import("store.zig");
    _ = @import("config.zig");
    _ = @import("engine.zig");
    _ = @import("init.zig");
    _ = @import("mcp.zig");
    _ = @import("db.zig");
    _ = @import("agent.zig");
}
