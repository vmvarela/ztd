const std = @import("std");
const engine = @import("engine.zig");
const init_mod = @import("init.zig");
const platform = @import("platform.zig");
const model = @import("model.zig");
const routine_mod = @import("routine.zig");
const store_mod = @import("store.zig");
const binding_mod = @import("binding.zig");
const migrate_mod = @import("migrate.zig");
const agent = @import("agent.zig");
const db = @import("db.zig");
const install_mod = @import("install.zig");
const tui_mod = @import("tui.zig");

const builtin = @import("builtin");
const build_options = @import("build_options");
const config_mod = @import("config.zig");
pub const version = build_options.version;
/// Store format this binary reads and writes.
pub const format = config_mod.supported_format;

const Ctx = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
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

/// `ztd status` payload. The JSON contract is deterministic: fixed keys in
/// declaration order — `root` (store path exactly as root precedence resolved
/// it), `source` (`flag` for --root, `env` for ZTD_ROOT, `home` for
/// $HOME/.ztd), `exists` (store directory present) and `format` (the
/// config.json format when readable, else null). Reading status never
/// creates the store, so it works when the store is absent.
const StatusData = struct {
    root: []const u8,
    source: []const u8,
    exists: bool,
    format: ?u32,
    binding: ?BindingView,
};

/// `.ztd.json` diagnostic appended to `status`. `value` is exactly the
/// binding's three fields and is null when the file is absent, malformed or
/// unreadable; `error` carries the diagnostic in those cases. A malformed
/// binding never suppresses the root information above it.
const BindingView = struct {
    path: []const u8,
    value: ?BindingValue,
    @"error": ?[]const u8,
};

const BindingValue = struct {
    context: []const u8,
    client: ?[]const u8,
    project: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    var ctx = Ctx{ .io = init.io, .alloc = alloc, .gpa = init.gpa, .env_map = init.environ_map, .root_env = init.environ_map.get("ZTD_ROOT") };
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
    var root: ?[]const u8 = if (ctx.root_env) |env| (if (env.len > 0) env else null) else null;
    var root_flag = false;
    var local = false;
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
            root_flag = true;
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--local")) {
            local = true;
            i += 1;
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
                try stdout(ctx, " format " ++ std.fmt.comptimePrint("{d}", .{format}) ++ "\n");
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
    if (local and !std.mem.eql(u8, cmd, "init")) return usage(ctx, "--local is only valid for init");

    if (std.mem.eql(u8, cmd, "version")) {
        if (ctx.json) {
            try writeJson(ctx, .{ .ok = true, .command = "version", .data = .{ .version = version, .format = format, .target = targetName() } });
        } else {
            try stdout(ctx, "ztd ");
            try stdout(ctx, version);
            try stdout(ctx, " ");
            try stdout(ctx, targetName());
            try stdout(ctx, " format " ++ std.fmt.comptimePrint("{d}", .{format}) ++ "\n");
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp(ctx);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        // Store selection: --local > explicit path > --root/ZTD_ROOT > $HOME/.ztd.
        // An explicit path is the store directory itself, never a parent to
        // which a `ztd` component is appended.
        if (local) {
            if (rest.len > 0) return usage(ctx, "init --local takes no path");
            if (root_flag) return usage(ctx, "init --local conflicts with --root");
        }
        const target: []const u8 = if (local)
            "ztd"
        else if (rest.len > 0)
            rest[0]
        else if (root) |r|
            r
        else
            try store_mod.rootPath(ctx.io, ctx.alloc, null);
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

    // Status never needs an existing store: it reports what the precedence
    // resolved and what is actually on disk, without creating anything.
    if (std.mem.eql(u8, cmd, "status")) {
        const source: []const u8 = if (root_flag) "flag" else if (root != null) "env" else "home";
        return cmdStatus(ctx, root, source);
    }

    // `install` publishes embedded assets: opencode into its config dir,
    // templates into the store resolved by the normal root precedence.
    // No store is created for either adapter, so `today` is not needed here.
    if (std.mem.eql(u8, cmd, "install")) {
        if (rest.len != 1) return usage(ctx, "install needs an adapter: ztd install opencode | ztd install templates");
        if (std.mem.eql(u8, rest[0], "opencode")) return cmdInstall(ctx, "opencode", null, dry_run);
        if (std.mem.eql(u8, rest[0], "templates")) {
            const root_path = try store_mod.resolveRoot(ctx.io, ctx.alloc, root);
            return cmdInstall(ctx, "templates", root_path, dry_run);
        }
        return usage(ctx, "unknown install adapter");
    }

    const today = if (today_arg) |t| platform.parseDate(t) catch return usage(ctx, "--today must be YYYY-MM-DD") else platform.today(ctx.io);
    // Conversion names both stores explicitly: the resolved root, the working
    // directory and ZTD_ROOT never select them.
    if (std.mem.eql(u8, cmd, "migrate")) {
        if (root_flag) return usage(ctx, "migrate takes --from/--to, not --root");
        return cmdMigrate(ctx, rest, dry_run, today);
    }
    const root_path = try store_mod.resolveRoot(ctx.io, ctx.alloc, root);
    if (std.mem.eql(u8, cmd, "tui")) {
        if (ctx.json) return usage(ctx, "tui has no JSON output");
        if (dry_run) return usage(ctx, "tui does not accept --dry-run");
        if (rest.len > 0) return usage(ctx, "tui takes no arguments");
        return tui_mod.run(ctx.io, ctx.gpa, ctx.env_map, root_path, today);
    }
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
        std.mem.eql(u8, a, "agent-remember") or
        std.mem.eql(u8, a, "agent-recall") or
        std.mem.eql(u8, a, "agent-backup") or
        std.mem.eql(u8, a, "agent-export") or
        std.mem.eql(u8, a, "agent-restore");
}

/// `agent-recall` without `--limit`: how many ranked matches to return.
const recall_default_limit: i64 = 20;

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
    var kind: ?[]const u8 = null;
    var result: ?[]const u8 = null;
    var evidence: ?[]const u8 = null;
    var next_action: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var history_limit: ?usize = null;
    var text: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var query: ?[]const u8 = null;
    var limit: ?i64 = null;

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
            else if (std.mem.eql(u8, a, "--text")) text = v //
            else if (std.mem.eql(u8, a, "--source")) source = v //
            else if (std.mem.eql(u8, a, "--query")) query = v //
            else if (std.mem.eql(u8, a, "--history")) {
                const n = std.fmt.parseInt(usize, v, 10) catch return usage(ctx, "--history needs a number");
                if (n == 0) return usage(ctx, "--history must be positive");
                history_limit = n;
            } else if (std.mem.eql(u8, a, "--kind")) {
                kind = v; // the accepted set differs per command; checked below
            } else if (std.mem.eql(u8, a, "--limit")) {
                const n = std.fmt.parseInt(i64, v, 10) catch return usage(ctx, "--limit needs a number");
                if (n <= 0) return usage(ctx, "--limit must be positive");
                limit = n;
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
    } else if (std.mem.eql(u8, cmd, "agent-remember")) {
        if (id != null) return usage(ctx, "agent-remember takes no id");
        if (scope == null) return usage(ctx, "agent-remember needs --scope");
        if (text == null) return usage(ctx, "agent-remember needs --text");
        if (kind == null) return usage(ctx, "agent-remember needs --kind");
    } else if (std.mem.eql(u8, cmd, "agent-recall")) {
        if (id != null) return usage(ctx, "agent-recall takes no id");
        if (scope == null) return usage(ctx, "agent-recall needs --scope");
        if (query == null) return usage(ctx, "agent-recall needs --query");
    } else {
        if (id == null) return usage(ctx, "agent command needs an id");
        if (scope == null) return usage(ctx, "agent command needs --scope");
        if (std.mem.eql(u8, cmd, "agent-checkpoint")) {
            if (expect_rev == null) return usage(ctx, "agent-checkpoint needs --expect-rev");
            if (result == null) return usage(ctx, "agent-checkpoint needs --result");
            const k = kind orelse "progress";
            if (!std.mem.eql(u8, k, "progress") and !std.mem.eql(u8, k, "done"))
                return usage(ctx, "--kind must be progress or done");
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
            .kind = kind orelse "progress",
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
    if (std.mem.eql(u8, cmd, "agent-remember")) {
        const r = store.remember(.{
            .scope = scope.?,
            .kind = kind.?,
            .text = text.?,
            .source = source,
            .idempotency_key = idempotency_key,
        }) catch |err| switch (err) {
            error.InvalidArgument => return invalidArgument(ctx),
            else => return err,
        };
        defer store.deinitRememberResult(r);
        try success(ctx, cmd, r);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "agent-recall")) {
        const items = store.recall(.{
            .scope = scope.?,
            .query = query.?,
            .limit = limit orelse recall_default_limit,
        }) catch |err| switch (err) {
            error.InvalidArgument => return invalidArgument(ctx),
            else => return err,
        };
        defer store.deinitRecall(items);
        try success(ctx, cmd, .{ .knowledge = items });
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
        "--out",         "--from",            "--history", "--text",
        "--source",      "--query",           "--limit",
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
    if (std.mem.eql(u8, cmd, "agent-remember"))
        return std.mem.eql(u8, flag, "--scope") or std.mem.eql(u8, flag, "--kind") or
            std.mem.eql(u8, flag, "--text") or std.mem.eql(u8, flag, "--source") or
            std.mem.eql(u8, flag, "--idempotency-key");
    if (std.mem.eql(u8, cmd, "agent-recall"))
        return std.mem.eql(u8, flag, "--scope") or std.mem.eql(u8, flag, "--query") or
            std.mem.eql(u8, flag, "--limit");
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

/// Commands report a store-level `error.InvalidArgument` refusal (durability:
/// non-empty restore target, existing backup file, malformed export; knowledge:
/// unknown kind, non-positive limit, malformed FTS5 query) as
/// `invalid_argument`; `engine.errorName` has no entry for it and would
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
    var bindings = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, a, "--bindings")) {
            bindings = true;
        } else {
            return usage(ctx, "unknown check option");
        }
    }
    const result = try eng.check(strict);
    var errors: std.ArrayList([]const u8) = .empty;
    defer errors.deinit(ctx.alloc);
    try errors.appendSlice(ctx.alloc, result.errors);
    if (bindings) try checkBinding(ctx, eng, &errors);
    const found = errors.items;
    const warnings = result.warnings;
    if (ctx.json) {
        try writeJson(ctx, .{
            .ok = found.len == 0,
            .command = "check",
            .data = CheckData{ .errors = found, .warnings = warnings },
        });
    } else {
        for (found) |e| {
            try stderr(ctx, "error: ");
            try stderr(ctx, e);
            try stderr(ctx, "\n");
        }
        for (warnings) |w| {
            try stderr(ctx, "warning: ");
            try stderr(ctx, w);
            try stderr(ctx, "\n");
        }
        if (found.len == 0 and warnings.len == 0) try stdout(ctx, "ok\n");
    }
    return if (found.len == 0) 0 else 1;
}

/// `check --bindings` validates only the binding of the repository holding the
/// current directory. A missing or malformed binding is an error: the flag is
/// an explicit request to check one, never a request to crawl repositories.
fn checkBinding(ctx: *Ctx, eng: *engine.Engine, errors: *std.ArrayList([]const u8)) !void {
    switch (try binding_mod.discover(ctx.io, ctx.alloc)) {
        .absent => try errors.append(ctx.alloc, "no .ztd.json binding in the current repository"),
        .invalid => |inv| try errors.append(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "{s}: {s}", .{ inv.path, inv.problem.message() })),
        .found => |f| binding_mod.validate(&eng.store, ctx.alloc, f.binding) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try errors.append(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "{s}: {s}", .{ f.path, bindingErrorText(err) })),
        },
    }
}

fn bindingErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidContext => "context is not listed in contexts.md",
        error.InvalidClient => "client is not allowed in this context",
        error.MissingClient => "context requires a client",
        error.InvalidProject => "project is not registered under lists/projects",
        else => @errorName(err),
    };
}

/// `migrate --from SOURCE --to DEST [--dry-run]`: copy-only conversion of a
/// format-1 store into a new format-2 store. Both paths are explicit, so the
/// resolved root, `ZTD_ROOT` and the working directory never select them.
fn cmdMigrate(ctx: *Ctx, args: []const []const u8, dry_run: bool, today: platform.Date) !u8 {
    var from: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--from") or std.mem.eql(u8, a, "--to")) {
            if (i + 1 >= args.len) return usage(ctx, "--from and --to need a path");
            if (a[2] == 'f') from = args[i + 1] else to = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--from=")) {
            from = a["--from=".len..];
        } else if (std.mem.startsWith(u8, a, "--to=")) {
            to = a["--to=".len..];
        } else {
            return usage(ctx, "unknown migrate option");
        }
        i += 1;
    }
    if (from == null or to == null) return usage(ctx, "migrate needs --from SOURCE and --to DEST");

    var diags: std.ArrayList([]const u8) = .empty;
    defer diags.deinit(ctx.alloc);
    const rep = migrate_mod.run(ctx.io, ctx.alloc, .{
        .from = from.?,
        .to = to.?,
        .dry_run = dry_run,
        .today = today,
    }, &diags) catch |err| {
        if (!ctx.json) {
            for (diags.items) |d| {
                try stderr(ctx, "detail: ");
                try stderr(ctx, d);
                try stderr(ctx, "\n");
            }
        }
        return failCode(ctx, migrate_mod.errorName(err), err);
    };
    if (ctx.json) {
        try success(ctx, "migrate", rep);
    } else {
        if (rep.dry_run) try stdout(ctx, "would convert ") else try stdout(ctx, "converted ");
        try stdout(ctx, rep.from);
        try stdout(ctx, " -> ");
        try stdout(ctx, rep.to);
        try stdout(ctx, "\n  config: ");
        try stdout(ctx, rep.config);
        try stdout(ctx, "\n  routines: ");
        try stdout(ctx, rep.routines);
        if (rep.seed_date) |date| {
            try stdout(ctx, " (");
            try stdout(ctx, date);
            try stdout(ctx, ")");
        }
        try stdout(ctx, "\n  files: ");
        try printInt(ctx, rep.files);
        try stdout(ctx, "\n  tasks: ");
        try printInt(ctx, rep.tasks);
        try stdout(ctx, " (");
        try printInt(ctx, rep.fields_renamed);
        try stdout(ctx, " fields renamed)\n  checked: ");
        try stdout(ctx, if (rep.checked) "yes\n" else "no\n");
    }
    return 0;
}

fn printInt(ctx: *Ctx, value: usize) !void {
    var buf: [24]u8 = undefined;
    try stdout(ctx, std.fmt.bufPrint(&buf, "{d}", .{value}) catch "");
}

fn failCode(ctx: *Ctx, code: []const u8, err: anyerror) !u8 {
    if (ctx.json) {
        try writeJson(ctx, ErrOut{
            .command = ctx.command,
            .@"error" = .{ .code = code, .message = @errorName(err) },
        });
    } else {
        try stderr(ctx, "ztd: ");
        try stderr(ctx, code);
        try stderr(ctx, ": ");
        try stderr(ctx, @errorName(err));
        try stderr(ctx, "\n");
    }
    return 1;
}

/// `ztd install <adapter>`: publishes an embedded bundle — the skills and
/// commands into `$HOME/.config/opencode`, or the method templates into the
/// store root (`root`, already resolved by the normal precedence). A conflict
/// anywhere aborts with exit 1 and no writes; a run that writes reports
/// `N installed, M updated, K unchanged`, with zero counters omitted.
fn cmdInstall(ctx: *Ctx, adapter: []const u8, root: ?[]const u8, dry_run: bool) !u8 {
    const rep = if (root) |r|
        try install_mod.runTemplates(ctx.io, ctx.alloc, r, dry_run)
    else blk: {
        const home = try store_mod.homeDir(ctx.io, ctx.alloc);
        break :blk try install_mod.run(ctx.io, ctx.alloc, home, dry_run);
    };
    if (rep.conflicts.len > 0) {
        if (ctx.json) {
            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(ctx.alloc);
            for (rep.conflicts, 0..) |c, i| {
                if (i > 0) try msg.appendSlice(ctx.alloc, "; ");
                try msg.appendSlice(ctx.alloc, c);
            }
            try writeJson(ctx, ErrOut{
                .command = "install",
                .@"error" = .{ .code = "conflict", .message = try msg.toOwnedSlice(ctx.alloc) },
            });
        } else {
            for (rep.conflicts) |c| {
                try stderr(ctx, "ztd: conflict: ");
                try stderr(ctx, c);
                try stderr(ctx, "\n");
            }
            var nbuf: [32]u8 = undefined;
            const n = std.fmt.bufPrint(&nbuf, "{d}", .{rep.conflicts.len}) catch unreachable;
            try stderr(ctx, "ztd: aborting before any writes (");
            try stderr(ctx, n);
            try stderr(ctx, " conflict(s))\n");
        }
        return 1;
    }
    if (ctx.json) {
        try success(ctx, "install", .{
            .adapter = adapter,
            .dry_run = dry_run,
            .installed = rep.installed,
            .updated = rep.updated,
            .unchanged = rep.unchanged,
            .version = version,
        });
    } else {
        var buf: [160]u8 = undefined;
        try stdout(ctx, summaryLine(&buf, dry_run, &rep));
    }
    return 0;
}

/// The single summary line; zero counters are omitted, and `--dry-run`
/// reports `to install`/`to update` instead of past-tense results.
fn summaryLine(buf: *[160]u8, dry_run: bool, rep: *const install_mod.Report) []const u8 {
    const parts = [_]struct { n: usize, label: []const u8 }{
        .{ .n = rep.installed, .label = if (dry_run) "to install" else "installed" },
        .{ .n = rep.updated, .label = if (dry_run) "to update" else "updated" },
        .{ .n = rep.unchanged, .label = "unchanged" },
    };
    var len: usize = 0;
    for (parts) |p| {
        if (p.n == 0) continue;
        if (len > 0) {
            @memcpy(buf[len..][0..2], ", ");
            len += 2;
        }
        const piece = std.fmt.bufPrint(buf[len..], "{d} {s}", .{ p.n, p.label }) catch break;
        len += piece.len;
    }
    if (len == 0) return "nothing to do\n"; // unreachable: the bundle is non-empty
    buf[len] = '\n';
    return buf[0 .. len + 1];
}

fn cmdStatus(ctx: *Ctx, root: ?[]const u8, source: []const u8) !u8 {
    const root_path = try store_mod.rootPath(ctx.io, ctx.alloc, root);
    const exists = store_mod.pathExists(ctx.io, root_path);
    const store_format: ?u32 = if (exists) peekFormat(ctx, root_path) else null;
    var binding: ?BindingView = null;
    switch (try binding_mod.discover(ctx.io, ctx.alloc)) {
        .absent => {},
        .invalid => |inv| binding = .{ .path = inv.path, .value = null, .@"error" = inv.problem.message() },
        .found => |f| binding = .{
            .path = f.path,
            .value = .{ .context = f.binding.context, .client = f.binding.client, .project = f.binding.project },
            .@"error" = null,
        },
    }
    if (ctx.json) {
        try success(ctx, "status", StatusData{
            .root = root_path,
            .source = source,
            .exists = exists,
            .format = store_format,
            .binding = binding,
        });
    } else {
        try stdout(ctx, "root: ");
        try stdout(ctx, root_path);
        try stdout(ctx, "\nsource: ");
        try stdout(ctx, source);
        try stdout(ctx, "\nstore: ");
        if (!exists) {
            try stdout(ctx, "absent\n");
        } else if (store_format) |f| {
            try stdout(ctx, "present, format ");
            var buf: [8]u8 = undefined;
            const printed = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "";
            try stdout(ctx, printed);
            try stdout(ctx, "\n");
        } else {
            try stdout(ctx, "present, format unknown\n");
        }
        try stdout(ctx, "binding: ");
        if (binding) |b| {
            try stdout(ctx, b.path);
            if (b.@"error") |e| {
                try stdout(ctx, " (");
                try stdout(ctx, e);
                try stdout(ctx, ")");
            }
        } else {
            try stdout(ctx, "none");
        }
        try stdout(ctx, "\n");
    }
    return 0;
}

/// Read-only format probe for an existing store directory.
fn peekFormat(ctx: *Ctx, root_path: []const u8) ?u32 {
    var store = store_mod.Store.open(ctx.io, ctx.alloc, root_path) catch return null;
    defer store.deinit();
    return config_mod.formatOf(&store, ctx.alloc);
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
        \\  init [path] [--local]       create a store (default $HOME/.ztd; --local = ./ztd)
        \\  install opencode            publish skills and commands to ~/.config/opencode
        \\  install templates           publish the method templates into the store root
        \\  migrate --from SRC --to DST [--dry-run]  convert a format-1 store to format 2
        \\  status                      show root, source, exists, format, binding
        \\  capture <text>... | --stdin capture tasks into the inbox
        \\  list [--context C] [--client X] [--project P] [--list L]
        \\  show <id>                   show one task
        \\  move <id> <list> [--text T] [--field k:v] [--unset k] [--expect-line N]
        \\  plan --context C [--client X] [--date YYYY-MM-DD]
        \\  check [--strict] [--bindings]  validate the store and the repo binding
        \\  recover                     finish an interrupted transaction
        \\  due                         list routines past their cadence
        \\  routine done <id>           mark a routine as run today
        \\  tui                         browse lists and store documents (read-only)
        \\  agent-capture --scope S --request T [--project P] [--idempotency-key K] [--db PATH]
        \\  agent-checkpoint ID --scope S --expect-rev N --result T [--db PATH]
        \\  agent-prepare ID --scope S [--history N] [--db PATH]
        \\  agent-remember --scope S --kind K --text T [--source SRC] [--idempotency-key K] [--db PATH]
        \\  agent-recall --scope S --query Q [--limit N] [--db PATH]
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
    _ = @import("db.zig");
    _ = @import("agent.zig");
    _ = @import("binding.zig");
    _ = @import("migrate.zig");
    _ = @import("install.zig");
    _ = @import("tui.zig");
}
