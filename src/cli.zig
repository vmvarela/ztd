//! CLI surface: global flags, the JSON envelope and the command dispatch.
//!
//! The port is incremental: only the commands registered in `run` exist, and
//! every unimplemented command fails with the same unknown-command error the
//! Go binary gives for a command it does not know.

const std = @import("std");
const Io = std.Io;
const errors = @import("errors.zig");
const timeutil = @import("timeutil.zig");
const jsonw = @import("json.zig");
const domain = @import("domain.zig");
const store_mod = @import("store/store.zig");
const core = @import("store/core.zig");
const doc = @import("docs.zig");
const mcp = @import("mcp.zig");
const version = @import("version.zig").version;

const Store = store_mod.Store;

pub const Cli = struct {
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    json: bool = false,
    db: []const u8 = "",
    actor: []const u8 = "",
    ztd_scopes: ?[]const u8 = null,
    home: ?[]const u8 = null,
    sources_path: ?[]const u8 = null,
};

fn envGet(init: std.process.Init, key: []const u8) ?[]const u8 {
    return init.environ_map.get(key);
}

fn defaultActor(init: std.process.Init) []const u8 {
    return envGet(init, "USER") orelse "operator";
}

/// --db > ZTD_DB > ~/.ztd/ztd.db, resolved before any command runs.
fn resolveDb(c: *Cli, init: std.process.Init) errors.Ztd!void {
    if (c.db.len > 0) return;
    if (envGet(init, "ZTD_DB")) |p| {
        c.db = p;
        return;
    }
    const home = envGet(init, "HOME") orelse return errors.fail(.io_error, "cannot resolve the home directory", .{});
    c.db = std.fmt.allocPrint(c.arena, "{s}/.ztd/ztd.db", .{home}) catch
        return errors.fail(.io_error, "out of memory", .{});
}

fn succeedData(c: *Cli, command: []const u8, data: []const u8) !void {
    if (!c.json) {
        // shortcut: text mode prints compact JSON instead of Go's indented
        // form; the corpus and hosts read --json, revisit for human output.
        try c.out.writeAll(data);
        try c.out.writeByte('\n');
        return;
    }
    var o = try jsonw.Obj.init(c.out);
    try o.boolean("ok", true);
    try o.str("command", command);
    try o.raw("data", data);
    try o.end();
    try c.out.writeByte('\n');
}

fn failEnvelope(c: *Cli, command: []const u8, family: errors.Family, detail: []const u8) !void {
    if (!c.json) {
        try c.err.print("{s}: {s}\n", .{ family.text(), detail });
        return;
    }
    var o = try jsonw.Obj.init(c.out);
    try o.boolean("ok", false);
    if (command.len > 0) try o.str("command", command);
    var e = try o.obj("error");
    try e.str("family", family.text());
    try e.str("detail", detail);
    try e.end();
    try o.end();
    try c.out.writeByte('\n');
}

// ------------------------------------------------------------ flag parsing

const Spec = struct { name: []const u8, value: bool, multi: bool = false };

const Parsed = struct {
    values: std.StringHashMap([]const u8),
    multi: std.StringHashMap(std.ArrayList([]const u8)),
    positional: []const []const u8,
    seen: std.StringHashMap(void),

    fn get(self: Parsed, name: []const u8, default: []const u8) []const u8 {
        return self.values.get(name) orelse default;
    }

    fn has(self: Parsed, name: []const u8) bool {
        return self.seen.contains(name);
    }
};

fn flagError(comptime fmt: []const u8, args: anytype) errors.Ztd {
    return errors.invalid(fmt, args);
}

/// Mirrors Go's `flag` package: parsing stops at the first non-flag argument.
fn parseFlags(a: std.mem.Allocator, args: []const []const u8, specs: []const Spec) !Parsed {
    var parsed = Parsed{
        .values = std.StringHashMap([]const u8).init(a),
        .multi = std.StringHashMap(std.ArrayList([]const u8)).init(a),
        .positional = &.{},
        .seen = std.StringHashMap(void).init(a),
    };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-' or arg.len == 1) break;
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        const name = std.mem.trimStart(u8, arg, "-");
        var spec: ?Spec = null;
        for (specs) |s| if (std.mem.eql(u8, s.name, name)) {
            spec = s;
        };
        const s = spec orelse return flagError("flag provided but not defined: -{s}", .{name});
        try parsed.seen.put(name, {});
        if (s.value) {
            if (i + 1 >= args.len) return flagError("flag needs an argument: -{s}", .{name});
            i += 1;
            if (s.multi) {
                const entry = try parsed.multi.getOrPut(name);
                if (!entry.found_existing) entry.value_ptr.* = std.ArrayList([]const u8).empty;
                try entry.value_ptr.append(a, args[i]);
            }
            try parsed.values.put(name, args[i]);
        } else {
            try parsed.values.put(name, "true");
        }
    }
    parsed.positional = args[i..];
    return parsed;
}

// -------------------------------------------------------------- entry point

pub fn run(init: std.process.Init, w: *Io.Writer, ew: *Io.Writer, args: []const []const u8) !u8 {
    const a = init.arena.allocator();
    var c = Cli{
        .arena = a,
        .io = init.io,
        .out = w,
        .err = ew,
        .actor = defaultActor(init),
        .ztd_scopes = envGet(init, "ZTD_SCOPES"),
        .home = envGet(init, "HOME"),
        .sources_path = envGet(init, "ZTD_SOURCES"),
    };

    var rest = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            c.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--db")) {
            if (i + 1 >= args.len) {
                try failEnvelope(&c, "", .invalid_input, "--db needs a value");
                return 1;
            }
            i += 1;
            c.db = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--actor")) {
            if (i + 1 >= args.len) {
                try failEnvelope(&c, "", .invalid_input, "--actor needs a value");
                return 1;
            }
            i += 1;
            c.actor = args[i];
            continue;
        }
        try rest.append(a, arg);
    }

    if (rest.items.len == 0) {
        try ew.writeAll(usage);
        return 2;
    }
    const command = rest.items[0];
    const cmd_args = rest.items[1..];

    dispatch(&c, init, command, cmd_args) catch |e| switch (e) {
        error.Ztd => {
            try failEnvelope(&c, command, errors.getFamily(), errors.detail());
            return 1;
        },
        else => return e,
    };
    return 0;
}

fn dispatch(c: *Cli, init: std.process.Init, command: []const u8, args: []const []const u8) !void {
    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        var aw = Io.Writer.Allocating.init(c.arena);
        var o = try jsonw.Obj.init(&aw.writer);
        try o.str("version", version);
        try o.end();
        return succeedData(c, "version", aw.written());
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try c.out.writeAll(usage);
        return;
    }
    try resolveDb(c, init);
    if (std.mem.eql(u8, command, "init")) return cmdInit(c, args);
    if (std.mem.eql(u8, command, "status")) return cmdStatus(c, args);
    if (std.mem.eql(u8, command, "capture")) return cmdCapture(c, args);
    if (std.mem.eql(u8, command, "inbox")) return cmdInbox(c, args);
    if (std.mem.eql(u8, command, "process")) return cmdProcess(c, args);
    if (std.mem.eql(u8, command, "show")) return cmdShow(c, args);
    if (std.mem.eql(u8, command, "find")) return cmdFind(c, args);
    if (std.mem.eql(u8, command, "list")) return cmdList(c, args);
    if (std.mem.eql(u8, command, "move")) return cmdMove(c, args);
    if (std.mem.eql(u8, command, "goal")) return cmdGoal(c, args);
    if (std.mem.eql(u8, command, "prepare")) return cmdPrepare(c, args);
    if (std.mem.eql(u8, command, "plan")) return cmdPlan(c, args);
    if (std.mem.eql(u8, command, "focus")) return cmdFocus(c, args);
    if (std.mem.eql(u8, command, "review")) return cmdReview(c, args);
    if (std.mem.eql(u8, command, "routines")) return cmdRoutines(c, args);
    if (std.mem.eql(u8, command, "due")) {
        const forwarded = try c.arena.alloc([]const u8, args.len + 1);
        forwarded[0] = "due";
        @memcpy(forwarded[1..], args);
        return cmdRoutines(c, forwarded);
    }
    if (std.mem.eql(u8, command, "routine")) {
        if (args.len == 0 or (!std.mem.eql(u8, args[0], "done") and !std.mem.eql(u8, args[0], "add"))) {
            return errors.invalid("usage: routine done [flags] <routine-id> | routine add --id ID --cadence daily|weekly:<day> [--last YYYY-MM-DD]", .{});
        }
        const forwarded = try c.arena.alloc([]const u8, args.len + 1);
        forwarded[0] = "routines";
        @memcpy(forwarded[1..], args);
        return cmdRoutines(c, forwarded);
    }
    if (std.mem.eql(u8, command, "check")) return cmdCheck(c, args);
    if (std.mem.eql(u8, command, "override")) return cmdOverride(c, args);
    if (std.mem.eql(u8, command, "learn")) return cmdLearn(c, args);
    if (std.mem.eql(u8, command, "doc")) return cmdDoc(c, args);
    if (std.mem.eql(u8, command, "trace")) return cmdTrace(c, args);
    if (std.mem.eql(u8, command, "mcp")) return cmdMcp(c, args);
    if (std.mem.eql(u8, command, "export")) return cmdExport(c, args);
    if (std.mem.eql(u8, command, "restore")) return cmdRestore(c, args);
    if (std.mem.eql(u8, command, "snapshot")) return cmdSnapshot(c, args);
    if (std.mem.eql(u8, command, "recover")) return cmdRecover(c, args);
    if (std.mem.eql(u8, command, "scope")) return cmdScope(c, args);
    if (std.mem.eql(u8, command, "context")) return cmdContext(c, args);
    if (std.mem.eql(u8, command, "project")) return cmdProject(c, args);
    if (std.mem.eql(u8, command, "source")) return cmdSource(c, args);
    return errors.invalid("unknown command \"{s}\" (see usage)", .{command});
}

fn openStore(c: *Cli) !Store {
    const path = c.arena.dupeSentinel(u8, c.db, 0) catch return errors.fail(.io_error, "out of memory", .{});
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/');
    if (dir_end) |idx| {
        const dir = path[0..idx];
        // createDirPath is relative-only; walk the absolute prefix instead.
        var i: usize = 1;
        while (i <= dir.len) : (i += 1) {
            if (i == dir.len or dir[i] == '/') {
                _ = std.Io.Dir.createDirAbsolute(c.io, dir[0..i], .default_dir) catch {};
            }
        }
    }
    return Store.open(path);
}

fn nowSeconds(c: *Cli) timeutil.Timestamp {
    return timeutil.now(c.io);
}

fn newKey(c: *Cli, prefix: []const u8) ![]const u8 {
    const nanos = Io.Timestamp.now(c.io, .real).nanoseconds;
    return std.fmt.allocPrint(c.arena, "{s}-{d}", .{ prefix, nanos }) catch
        return errors.fail(.io_error, "out of memory", .{});
}

// --------------------------------------------------------------------- init

fn parseScopeDecl(raw: []const u8) !core.ScopeCmd {
    if (core.trimmed(raw).len == 0) return errors.invalid("scope declaration is empty", .{});
    var id: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var name: []const u8 = "";
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse
            return errors.invalid("scope declaration \"{s}\": every field must be key=value", .{raw});
        const key = core.trimmed(part[0..eq]);
        const value = core.trimmed(part[eq + 1 ..]);
        if (key.len == 0 or value.len == 0) {
            return errors.invalid("scope declaration \"{s}\": every field must be key=value", .{raw});
        }
        if (std.mem.eql(u8, key, "id")) {
            if (id != null) return errors.invalid("scope declaration \"{s}\": duplicate field \"id\"", .{raw});
            id = value;
        } else if (std.mem.eql(u8, key, "kind")) {
            if (kind != null) return errors.invalid("scope declaration \"{s}\": duplicate field \"kind\"", .{raw});
            kind = value;
        } else if (std.mem.eql(u8, key, "name")) {
            if (name.len > 0) return errors.invalid("scope declaration \"{s}\": duplicate field \"name\"", .{raw});
            name = value;
        } else {
            return errors.invalid("scope declaration \"{s}\": unknown field \"{s}\"", .{ raw, key });
        }
    }
    const cmd = core.ScopeCmd{ .id = id orelse "", .kind = kind orelse "", .name = name };
    try core.validateScopeCmd(cmd.id, cmd.kind);
    return cmd;
}

fn cmdInit(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true, .multi = true },
        .{ .name = "actor", .value = true },
        .{ .name = "non-interactive", .value = false },
    };
    var parsed = try parseFlags(c.arena, args, &specs);
    if (parsed.positional.len != 0) return errors.invalid("init takes no positional arguments", .{});
    if (parsed.get("actor", "").len > 0) c.actor = parsed.get("actor", "");
    const raw_scopes = parsed.multi.get("scope");

    var scopes = std.ArrayList(core.ScopeCmd).empty;
    if (raw_scopes) |list| {
        for (list.items) |raw| try scopes.append(c.arena, try parseScopeDecl(raw));
    }
    // shortcut: the interactive prompt is not ported; a bare init without a
    // terminal (or with --non-interactive) fails exactly like the script path.
    _ = parsed.has("non-interactive");
    if (scopes.items.len == 0) {
        return errors.invalid("init needs at least one scope declaration (pass --scope id=...,kind=...)", .{});
    }
    if (c.actor.len == 0) return errors.invalid("actor is required", .{});

    var ids = std.ArrayList([]const u8).empty;
    for (scopes.items) |s| try ids.append(c.arena, s.id);
    var profiles = [_]core.ProfileCmd{.{
        .id = "personal",
        .kind = "personal",
        .actor = c.actor,
        .scopes = ids.items,
    }};

    var st = try openStore(c);
    defer st.close();
    const res = try core.applyConfig(&st, c.arena, scopes.items, &profiles, nowSeconds(c));

    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    // Go marshals the init map with sorted keys.
    try o.str("actor", c.actor);
    try o.str("database", c.db);
    try writeEntries(&o, "profiles", res.profiles);
    try writeEntries(&o, "scopes", res.scopes);
    try o.end();
    try succeedData(c, "init", aw.written());
}

fn writeEntries(o: *jsonw.Obj, name: []const u8, entries: []domain.ConfigEntry) !void {
    var arr = try o.arr(name);
    for (entries) |e| {
        var obj = try arr.obj();
        try obj.str("id", e.id);
        try obj.boolean("existed", e.existed);
        try obj.end();
    }
    try arr.end();
}

// ------------------------------------------------------------------- status

fn cmdStatus(c: *Cli, args: []const []const u8) !void {
    const parsed = try parseFlags(c.arena, args, &.{});
    if (parsed.positional.len != 0) return errors.invalid("usage: status", .{});

    var scopes: []domain.Scope = &.{};
    var effective: []const []const u8 = &.{};
    const db_exists = blk: {
        _ = Io.Dir.cwd().statFile(c.io, c.db, .{}) catch break :blk false;
        break :blk true;
    };
    if (db_exists) {
        var st = try openStore(c);
        defer st.close();
        scopes = try core.listScopes(&st, c.arena);
        const owned = core.profileScopes(&st, c.arena, "personal") catch |e| blk: {
            if (e == error.Ztd and errors.getFamily() == .not_found) break :blk &.{};
            return e;
        };
        effective = try resolveScopes(c, owned, scopes, &.{});
    }

    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.str("database", c.db);
    try o.str("profile", "personal");
    try o.str("actor", c.actor);
    try writeStringArray(&o, "scopes", try scopeIds(c.arena, scopes));
    try writeStringArray(&o, "effective_scopes", effective);
    const hint = readBindingHint(c);
    try o.raw("binding", hint.json);
    if (hint.warning.len > 0) try o.str("warning", hint.warning);
    try o.end();
    try succeedData(c, "status", aw.written());
}

fn scopeIds(a: std.mem.Allocator, scopes: []domain.Scope) ![][]const u8 {
    const out = try a.alloc([]const u8, scopes.len);
    for (scopes, 0..) |s, i| out[i] = s.id;
    return out;
}

fn writeStringArray(o: *jsonw.Obj, name: []const u8, items: []const []const u8) !void {
    var arr = try o.arr(name);
    for (items) |it| try arr.str(it);
    try arr.end();
}

const Hint = struct { json: []const u8, warning: []const u8 = "" };

fn readBindingHint(c: *Cli) Hint {
    const raw = Io.Dir.cwd().readFileAlloc(c.io, ".ztd.json", c.arena, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return .{ .json = "null", .warning = ".ztd.json not found in the current directory" },
        else => return .{ .json = "null", .warning = ".ztd.json cannot be read" },
    };
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, raw, .{}) catch {
        return .{ .json = "null", .warning = ".ztd.json is not a valid JSON object" };
    };
    if (parsed.value != .object) return .{ .json = "null", .warning = ".ztd.json is not a JSON object" };
    var aw = Io.Writer.Allocating.init(c.arena);
    std.json.Stringify.value(parsed.value, .{}, &aw.writer) catch return .{ .json = "null" };
    return .{ .json = aw.written() };
}

// -------------------------------------------------------- binding resolution

fn resolveScopes(
    c: *Cli,
    owned: []const []const u8,
    declared: []const domain.Scope,
    explicit: []const []const u8,
) ![]const []const u8 {
    if (explicit.len > 0) return narrowToProfile(owned, explicit);
    if (c.ztd_scopes) |v| {
        var list = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |part| {
            const t = core.trimmed(part);
            if (t.len == 0) return errors.invalid("ZTD_SCOPES must be a comma-separated list of scope ids, got \"{s}\"", .{v});
            try list.append(c.arena, t);
        }
        return narrowToProfile(owned, list.items);
    }
    const hint = readBindingHint(c);
    if (hint.warning.len == 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, c.arena, hint.json, .{}) catch null;
        if (parsed) |p| {
            if (hintScope(p.value, declared)) |id| {
                if (covers(owned, id)) return &.{try c.arena.dupe(u8, id)};
            }
        }
    }
    return defaultView(c.arena, owned, declared);
}

fn hintScope(v: std.json.Value, declared: []const domain.Scope) ?[]const u8 {
    if (v != .object) return null;
    const obj = v.object;
    const context = blk: {
        const raw = obj.get("context") orelse break :blk "";
        if (raw != .string) return null;
        break :blk core.trimmed(raw.string);
    };
    const client = blk: {
        const raw = obj.get("client") orelse break :blk "";
        if (raw != .string) return null;
        break :blk core.trimmed(raw.string);
    };
    if (context.len > 0) {
        for (declared) |s| if (std.mem.eql(u8, s.id, context)) return s.id;
    }
    if (client.len > 0) {
        for (declared) |s| {
            if (std.mem.startsWith(u8, s.id, "client:") and std.mem.eql(u8, s.id[7..], client)) return s.id;
        }
    }
    if (context.len == 0 and client.len == 0) {
        for (declared) |s| if (std.mem.eql(u8, s.id, "personal")) return s.id;
    }
    return null;
}

fn covers(owned: []const []const u8, id: []const u8) bool {
    for (owned) |sc| if (std.mem.eql(u8, sc, id)) return true;
    return false;
}

fn narrowToProfile(owned: []const []const u8, want: []const []const u8) ![]const []const u8 {
    for (want) |sc| {
        if (!covers(owned, sc)) {
            return errors.fail(.scope_denied, "scope {s} is not covered by the planning profile", .{sc});
        }
    }
    return want;
}

fn defaultView(a: std.mem.Allocator, owned: []const []const u8, declared: []const domain.Scope) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (owned) |id| {
        var kind: []const u8 = "";
        for (declared) |s| if (std.mem.eql(u8, s.id, id)) {
            kind = s.kind;
        };
        if (isClientOrWork(id, kind)) continue;
        try out.append(a, id);
    }
    if (out.items.len == 0) return owned;
    return out.items;
}

fn isClientOrWork(id: []const u8, kind: []const u8) bool {
    return std.mem.eql(u8, kind, "client") or std.mem.eql(u8, kind, "work") or
        std.mem.startsWith(u8, id, "client:") or std.mem.eql(u8, id, "work");
}

/// Opens the database and resolves the implicit planning profile binding.
fn bound(c: *Cli, explicit: []const []const u8) !struct { st: Store, b: domain.Binding } {
    var st = try openStore(c);
    errdefer st.close();
    const owned = core.profileScopes(&st, c.arena, "personal") catch |e| {
        if (e == error.Ztd and errors.getFamily() == .not_found) {
            return errors.fail(.not_found, "planning profile personal not found: run `ztd init` first", .{});
        }
        return e;
    };
    const declared = try core.listScopes(&st, c.arena);
    const ids = try resolveScopes(c, owned, declared, explicit);
    return .{ .st = st, .b = .{ .profile = "personal", .actor = c.actor, .scopes = ids } };
}

// Storage for the single-scope binding; a stack literal dangles in release builds.
var one_scope_buf: [1][]const u8 = undefined;

fn oneScope(scope: []const u8) []const []const u8 {
    if (scope.len == 0) return &.{};
    one_scope_buf[0] = scope;
    return one_scope_buf[0..1];
}

// ------------------------------------------------------------------ capture

fn cmdCapture(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "source", .value = true },
        .{ .name = "key", .value = true },
        .{ .name = "stdin", .value = false },
    };
    var parsed = try parseFlags(c.arena, args, &specs);
    var text = std.ArrayList(u8).empty;
    for (parsed.positional, 0..) |arg, idx| {
        if (idx > 0) try text.append(c.arena, ' ');
        try text.appendSlice(c.arena, arg);
    }
    if (parsed.has("stdin")) {
        // shortcut: --stdin reads at most 64 KiB + 1 and rejects the overflow.
        var in_buf: [4096]u8 = undefined;
        var stdin: Io.File.Reader = .init(.stdin(), c.io, &in_buf);
        const raw = stdin.interface.allocRemaining(c.arena, .limited(64 * 1024 + 1)) catch
            return errors.fail(.io_error, "read stdin", .{});
        try text.appendSlice(c.arena, raw);
    }
    if (core.trimmed(text.items).len == 0) return errors.invalid("capture text is required", .{});
    const key = if (parsed.get("key", "").len > 0) parsed.get("key", "") else try newKey(c, "capture");

    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const cap = try core.capture(&opened.st, c.arena, .{
        .binding = opened.b,
        .key = key,
        .text = text.items,
        .source_id = parsed.get("source", ""),
    }, nowSeconds(c));

    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try cap.write(&o);
    try o.end();
    try succeedData(c, "capture", aw.written());
}

// -------------------------------------------------------------------- inbox

fn cmdInbox(c: *Cli, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "next")) {
        return errors.invalid("usage: inbox next [flags]", .{});
    }
    const parsed = try parseFlags(c.arena, args[1..], &.{.{ .name = "scope", .value = true }});
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const cap = try core.inboxNext(&opened.st, c.arena, opened.b, nowSeconds(c));
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try cap.write(&o);
    try o.end();
    try succeedData(c, "inbox next", aw.written());
}

// ------------------------------------------------------------------ process

fn cmdProcess(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "key", .value = true },
        .{ .name = "expected", .value = true },
        .{ .name = "outcome", .value = true },
        .{ .name = "project", .value = true },
        .{ .name = "area", .value = true },
        .{ .name = "context", .value = true },
        .{ .name = "waiting-on", .value = true },
        .{ .name = "review-after", .value = true },
        .{ .name = "reason", .value = true },
        .{ .name = "evidence", .value = true },
        .{ .name = "decision", .value = true },
        .{ .name = "title", .value = true, .multi = true },
    };
    var parsed = try parseFlags(c.arena, args, &specs);
    if (parsed.positional.len != 1) {
        // Go's flag package stops at the first non-flag, so flags precede the ID.
        return errors.invalid("usage: process [flags] <capture-id>", .{});
    }
    const key = if (parsed.get("key", "").len > 0) parsed.get("key", "") else try newKey(c, "process");
    const expected = std.fmt.parseInt(i64, parsed.get("expected", "0"), 10) catch
        return errors.invalid("invalid value \"{s}\" for flag -expected", .{parsed.get("expected", "")});

    var outcome = domain.Outcome{
        .kind = parsed.get("outcome", ""),
        .waiting_on = parsed.get("waiting-on", ""),
        .reason = parsed.get("reason", ""),
        .result_evidence = parsed.get("evidence", ""),
    };
    if (parsed.multi.get("title")) |titles| outcome.titles = titles.items;
    if (parsed.get("project", "").len > 0) outcome.project_id = parsed.get("project", "");
    if (parsed.get("area", "").len > 0) outcome.area_id = parsed.get("area", "");
    if (parsed.get("context", "").len > 0) outcome.context_id = parsed.get("context", "");
    if (parsed.get("review-after", "").len > 0) {
        const t = timeutil.parseDate(parsed.get("review-after", "")) catch
            return errors.invalid("review-after must be YYYY-MM-DD", .{});
        outcome.review_after = try core.fmtTs(c.arena, t);
    }

    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const res = try core.process(&opened.st, c.arena, .{
        .binding = opened.b,
        .key = key,
        .id = parsed.positional[0],
        .expected = expected,
        .outcome = outcome,
    }, parsed.get("decision", ""), nowSeconds(c));

    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    var cap_obj = try o.obj("capture");
    try res.capture.write(&cap_obj);
    try cap_obj.end();
    if (res.work_items.len > 0) {
        var arr = try o.arr("work_items");
        for (res.work_items) |item| {
            var iobj = try arr.obj();
            try item.write(&iobj);
            try iobj.end();
        }
        try arr.end();
    }
    try o.end();
    try succeedData(c, "process", aw.written());
}

// --------------------------------------------------------------------- show

fn cmdShow(c: *Cli, args: []const []const u8) !void {
    const parsed = try parseFlags(c.arena, args, &.{.{ .name = "scope", .value = true }});
    if (parsed.positional.len != 1) return errors.invalid("usage: show <id> [flags]", .{});
    const id = parsed.positional[0];
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();

    var aw = Io.Writer.Allocating.init(c.arena);
    if (std.mem.startsWith(u8, id, "C-")) {
        const cap = try core.getCapture(&opened.st, c.arena, opened.b, id);
        var o = try jsonw.Obj.init(&aw.writer);
        try cap.write(&o);
        try o.end();
    } else {
        const result = try core.getWorkItemWithCheckpoint(&opened.st, c.arena, opened.b, id);
        var o = try jsonw.Obj.init(&aw.writer);
        try result.item.write(&o);
        if (result.checkpoint) |cp| {
            var inner = try o.obj("checkpoint");
            try cp.write(&inner);
            try inner.end();
        } else {
            try o.raw("checkpoint", "null");
        }
        try o.end();
    }
    try succeedData(c, "show", aw.written());
}

// --------------------------------------------------------------------- find

fn cmdFind(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "limit", .value = true },
    };
    const parsed = try parseFlags(c.arena, args, &specs);
    if (parsed.positional.len == 0) return errors.invalid("usage: find <query> [flags]", .{});
    const limit = std.fmt.parseInt(i64, parsed.get("limit", "10"), 10) catch
        return errors.invalid("invalid value \"{s}\" for flag -limit", .{parsed.get("limit", "")});
    var query = std.ArrayList(u8).empty;
    for (parsed.positional, 0..) |arg, idx| {
        if (idx > 0) try query.append(c.arena, ' ');
        try query.appendSlice(c.arena, arg);
    }
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const items = try core.find(&opened.st, c.arena, opened.b, query.items, limit);
    var aw = Io.Writer.Allocating.init(c.arena);
    var writable = try jsonw.Arr.init(&aw.writer);
    for (items) |item| {
        var iobj = try writable.obj();
        try item.write(&iobj);
        try iobj.end();
    }
    try writable.end();
    try succeedData(c, "find", aw.written());
}

// --------------------------------------------------------------------- list

fn cmdList(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "list", .value = true },
        .{ .name = "context", .value = true },
        .{ .name = "project", .value = true },
    };
    const parsed = try parseFlags(c.arena, args, &specs);
    if (parsed.positional.len != 0) {
        return errors.invalid("usage: list [--list L] [--context C] [--project P] [--scope S]", .{});
    }
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const name = parsed.get("list", "next");
    var aw = Io.Writer.Allocating.init(c.arena);
    if (std.mem.eql(u8, name, "inbox")) {
        const caps = try core.listInbox(&opened.st, c.arena, opened.b, nowSeconds(c));
        var arr = try jsonw.Arr.init(&aw.writer);
        for (caps) |cap| {
            var obj = try arr.obj();
            try cap.write(&obj);
            try obj.end();
        }
        try arr.end();
        return succeedData(c, "list", aw.written());
    }
    const lifecycle = blk: {
        if (std.mem.eql(u8, name, "next")) break :blk "next";
        if (std.mem.eql(u8, name, "waiting")) break :blk "waiting";
        if (std.mem.eql(u8, name, "someday")) break :blk "someday";
        if (std.mem.eql(u8, name, "archive")) break :blk "archived";
        return errors.invalid("--list must be inbox, next, waiting, someday or archive, got \"{s}\"", .{name});
    };
    const items = try core.listWorkItems(&opened.st, c.arena, opened.b, .{
        .lifecycle = lifecycle,
        .context = parsed.get("context", ""),
        .project = parsed.get("project", ""),
    });
    var arr = try jsonw.Arr.init(&aw.writer);
    for (items) |item| {
        var obj = try arr.obj();
        try item.write(&obj);
        try obj.end();
    }
    try arr.end();
    try succeedData(c, "list", aw.written());
}

// --------------------------------------------------------------------- move

fn cmdMove(c: *Cli, args: []const []const u8) !void {
    // Move accepts flags anywhere: split them out before parsing.
    const value_flags = [_][]const u8{
        "scope", "text", "field", "waiting-on", "resolution", "closure", "expected", "key",
    };
    var flag_args = std.ArrayList([]const u8).empty;
    var positional = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const is_flag = blk: {
            if (arg.len < 2 or arg[0] != '-') break :blk false;
            const name = std.mem.trimStart(u8, arg, "-");
            for (value_flags) |f| if (std.mem.eql(u8, f, name)) break :blk true;
            break :blk false;
        };
        if (is_flag) {
            try flag_args.append(c.arena, arg);
            if (i + 1 < args.len) {
                i += 1;
                try flag_args.append(c.arena, args[i]);
            }
        } else {
            try positional.append(c.arena, arg);
        }
    }
    if (positional.items.len != 2) {
        return errors.invalid("usage: move [flags] ID LIST, where LIST is next|waiting|someday|archive", .{});
    }
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "text", .value = true },
        .{ .name = "field", .value = true, .multi = true },
        .{ .name = "waiting-on", .value = true },
        .{ .name = "resolution", .value = true },
        .{ .name = "closure", .value = true },
        .{ .name = "expected", .value = true },
        .{ .name = "key", .value = true },
    };
    var parsed = try parseFlags(c.arena, flag_args.items, &specs);
    parsed.positional = positional.items;

    const target = blk: {
        const raw = parsed.positional[1];
        if (std.mem.eql(u8, raw, "next")) break :blk "next";
        if (std.mem.eql(u8, raw, "waiting")) break :blk "waiting";
        if (std.mem.eql(u8, raw, "someday")) break :blk "someday";
        if (std.mem.eql(u8, raw, "archive")) break :blk "archived";
        return errors.invalid("LIST must be next, waiting, someday or archive, got \"{s}\" (inbox is not a move target)", .{raw});
    };
    var text: ?[]const u8 = null;
    if (parsed.has("text")) text = parsed.get("text", "");
    var waiting: ?[]const u8 = null;
    if (parsed.has("waiting-on")) waiting = parsed.get("waiting-on", "");
    var resolution: ?[]const u8 = null;
    if (parsed.has("resolution")) resolution = parsed.get("resolution", "");

    var fields = std.ArrayList([2][]const u8).empty;
    if (parsed.multi.get("field")) |raw_fields| {
        for (raw_fields.items) |raw| {
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse
                return errors.invalid("--field \"{s}\" must be key:value", .{raw});
            const key = core.trimmed(raw[0..colon]);
            const value = raw[colon + 1 ..];
            if (key.len == 0) return errors.invalid("--field \"{s}\" must be key:value", .{raw});
            if (std.mem.eql(u8, key, "waiting_on")) {
                waiting = value;
                continue;
            }
            if (std.mem.eql(u8, key, "resolution")) {
                resolution = value;
                continue;
            }
            try fields.append(c.arena, .{ key, value });
        }
    }
    const key = if (parsed.get("key", "").len > 0) parsed.get("key", "") else try newKey(c, "move");
    const expected = std.fmt.parseInt(i64, parsed.get("expected", "0"), 10) catch
        return errors.invalid("invalid value \"{s}\" for flag -expected", .{parsed.get("expected", "")});

    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const item = try core.moveWorkItem(&opened.st, c.arena, .{
        .binding = opened.b,
        .key = key,
        .id = parsed.positional[0],
        .target = target,
        .text = text,
        .waiting_on = waiting,
        .resolution = resolution,
        .closure_kind = parsed.get("closure", ""),
        .fields = fields.items,
        .expected = expected,
    }, nowSeconds(c));

    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try item.write(&o);
    try o.end();
    try succeedData(c, "move", aw.written());
}

// --------------------------------------------------------------------- goal

fn writeJson(c: *Cli, command: []const u8, value: anytype) !void {
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try value.write(&o);
    try o.end();
    try succeedData(c, command, aw.written());
}

fn cmdGoal(c: *Cli, args: []const []const u8) !void {
    if (args.len == 0) return errors.invalid("usage: goal set|show|complete|cancel [flags]", .{});
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "set")) {
        const specs = [_]Spec{
            .{ .name = "scope", .value = true },
            .{ .name = "key", .value = true },
            .{ .name = "kind", .value = true },
            .{ .name = "start-on", .value = true },
            .{ .name = "end-on", .value = true },
            .{ .name = "statement", .value = true },
        };
        var parsed = try parseFlags(c.arena, rest, &specs);
        var statement = parsed.get("statement", "");
        if (statement.len == 0) statement = try std.mem.join(c.arena, " ", parsed.positional);
        const key = if (parsed.get("key", "").len > 0) parsed.get("key", "") else try newKey(c, "goal");
        var opened = try bound(c, oneScope(parsed.get("scope", "")));
        defer opened.st.close();
        const goal = try core.setGoal(&opened.st, c.arena, .{
            .binding = opened.b,
            .key = key,
            .kind = parsed.get("kind", "primary"),
            .start_on = parsed.get("start-on", ""),
            .end_on = parsed.get("end-on", ""),
            .statement = statement,
        }, nowSeconds(c));
        return writeJson(c, "goal set", goal);
    }
    if (std.mem.eql(u8, sub, "show")) {
        const specs = [_]Spec{.{ .name = "scope", .value = true }};
        const parsed = try parseFlags(c.arena, rest, &specs);
        var opened = try bound(c, oneScope(parsed.get("scope", "")));
        defer opened.st.close();
        const goal = try core.activeGoal(&opened.st, c.arena, opened.b);
        var aw = Io.Writer.Allocating.init(c.arena);
        if (goal) |g| {
            var o = try jsonw.Obj.init(&aw.writer);
            try g.write(&o);
            try o.end();
        } else try aw.writer.writeAll("null");
        return succeedData(c, "goal show", aw.written());
    }
    if (std.mem.eql(u8, sub, "complete") or std.mem.eql(u8, sub, "cancel")) {
        const specs = [_]Spec{.{ .name = "scope", .value = true }};
        const parsed = try parseFlags(c.arena, rest, &specs);
        if (parsed.positional.len != 0) {
            return errors.invalid("usage: goal {s} [--scope S]", .{sub});
        }
        var opened = try bound(c, oneScope(parsed.get("scope", "")));
        defer opened.st.close();
        const status: []const u8 = if (std.mem.eql(u8, sub, "complete")) "completed" else "cancelled";
        const goal = try core.setGoalStatus(&opened.st, c.arena, opened.b, status, nowSeconds(c));
        var aw = Io.Writer.Allocating.init(c.arena);
        var o = try jsonw.Obj.init(&aw.writer);
        try goal.write(&o);
        try o.end();
        return succeedData(c, try std.fmt.allocPrint(c.arena, "goal {s}", .{sub}), aw.written());
    }
    return errors.invalid("unknown goal subcommand \"{s}\"", .{sub});
}

// ------------------------------------------------------------------ prepare

fn cmdPrepare(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "date", .value = true },
        .{ .name = "packet", .value = false },
    };
    const parsed = try parseFlags(c.arena, args, &specs);
    if (parsed.positional.len != 0) return errors.invalid("usage: prepare [flags]", .{});
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    if (parsed.has("packet")) {
        const packet = try core.preparePacket(&opened.st, c.arena, opened.b, parsed.get("date", ""), nowSeconds(c));
        return succeedData(c, "prepare", packet);
    }
    const brief = try core.prepare(&opened.st, c.arena, opened.b, parsed.get("date", ""), nowSeconds(c));
    return writeJson(c, "prepare", brief);
}

// --------------------------------------------------------------------- plan

fn cmdPlan(c: *Cli, args: []const []const u8) !void {
    const is_commit = args.len > 0 and std.mem.eql(u8, args[0], "commit");
    if (!is_commit) {
        const specs = [_]Spec{
            .{ .name = "scope", .value = true },
            .{ .name = "context", .value = true },
            .{ .name = "date", .value = true },
            .{ .name = "client", .value = true },
        };
        const parsed = try parseFlags(c.arena, args, &specs);
        if (parsed.positional.len != 0) return errors.invalid("usage: plan [flags]", .{});
        var opened = try bound(c, oneScope(parsed.get("scope", "")));
        defer opened.st.close();
        var brief = try core.prepare(&opened.st, c.arena, opened.b, parsed.get("date", ""), nowSeconds(c));
        const context = parsed.get("context", "");
        if (context.len > 0) {
            brief.mits = try filterContext(c.arena, brief.mits, context);
            brief.next = try filterContext(c.arena, brief.next, context);
            brief.waiting = try filterContext(c.arena, brief.waiting, context);
        }
        return writeJson(c, "plan", brief);
    }

    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "kind", .value = true },
        .{ .name = "period", .value = true },
        .{ .name = "expected", .value = true },
        .{ .name = "override", .value = true },
        .{ .name = "decision", .value = true },
        .{ .name = "key", .value = true },
        .{ .name = "item", .value = true, .multi = true },
    };
    const parsed = try parseFlags(c.arena, args[1..], &specs);
    if (parsed.positional.len != 0) return errors.invalid("usage: plan commit [flags]", .{});
    const period = parsed.get("period", "");
    if (period.len == 0) return errors.invalid("--period is required", .{});

    var items = std.ArrayList(core.PlanItemCmd).empty;
    if (parsed.multi.get("item")) |raw_items| {
        for (raw_items.items, 0..) |raw, idx| {
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse
                return errors.invalid("item \"{s}\" must be ID:role", .{raw});
            try items.append(c.arena, .{
                .work_item_id = raw[0..colon],
                .role = raw[colon + 1 ..],
                .position = @intCast(idx),
            });
        }
    }
    const key = if (parsed.get("key", "").len > 0) parsed.get("key", "") else try newKey(c, "plan");
    const expected = std.fmt.parseInt(i64, parsed.get("expected", "0"), 10) catch
        return errors.invalid("invalid value \"{s}\" for flag -expected", .{parsed.get("expected", "")});
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const plan = try core.commitPlan(&opened.st, c.arena, .{
        .binding = opened.b,
        .key = key,
        .kind = parsed.get("kind", "daily"),
        .period = period,
        .expected = expected,
        .items = items.items,
        .override_id = parsed.get("override", ""),
    }, parsed.get("decision", ""), nowSeconds(c));
    return writeJson(c, "plan commit", plan);
}

fn filterContext(a: std.mem.Allocator, items: []const domain.WorkItem, context: []const u8) ![]const domain.WorkItem {
    var suffix_buf = std.Io.Writer.Allocating.init(a);
    try suffix_buf.writer.print(":{s}", .{context});
    const suffix = suffix_buf.written();
    var out = std.ArrayList(domain.WorkItem).empty;
    for (items) |item| {
        const id = item.context_id orelse continue;
        if (std.mem.endsWith(u8, id, suffix)) try out.append(a, item);
    }
    return out.items;
}

// -------------------------------------------------------------------- focus

fn cmdFocus(c: *Cli, args: []const []const u8) !void {
    if (args.len == 0) return errors.invalid("usage: focus start|checkpoint|finish [flags]", .{});
    const sub = args[0];
    const rest = args[1..];
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "key", .value = true },
        .{ .name = "result", .value = true },
        .{ .name = "next", .value = true },
        .{ .name = "evidence", .value = true },
        .{ .name = "outcome", .value = true },
    };
    const parsed = try parseFlags(c.arena, rest, &specs);
    const key = if (parsed.get("key", "").len > 0) parsed.get("key", "") else try newKey(c, sub);

    if (std.mem.eql(u8, sub, "start")) {
        if (parsed.positional.len != 1) return errors.invalid("usage: focus start [flags] <work-item-id>", .{});
        var opened = try bound(c, oneScope(parsed.get("scope", "")));
        defer opened.st.close();
        const result = try core.startFocus(&opened.st, c.arena, .{
            .binding = opened.b,
            .key = key,
            .item = parsed.positional[0],
        }, nowSeconds(c));
        var aw = Io.Writer.Allocating.init(c.arena);
        var o = try jsonw.Obj.init(&aw.writer);
        // Go builds a map here, so the keys sort alphabetically and a nil
        // checkpoint list marshals as null.
        if (result.checkpoints.len == 0) {
            try o.raw("checkpoints", "null");
        } else {
            var arr = try o.arr("checkpoints");
            for (result.checkpoints) |cp| {
                var aw_cp = Io.Writer.Allocating.init(c.arena);
                var cp_o = try jsonw.Obj.init(&aw_cp.writer);
                try cp.write(&cp_o);
                try cp_o.end();
                try arr.raw(aw_cp.written());
            }
            try arr.end();
        }
        var inner = try o.obj("focus");
        try result.focus.write(&inner);
        try inner.end();
        try o.end();
        return succeedData(c, "focus start", aw.written());
    }
    if (std.mem.eql(u8, sub, "checkpoint")) {
        if (parsed.positional.len != 1) return errors.invalid("usage: focus checkpoint [flags] <work-item-id>", .{});
        var evidence = std.ArrayList([]const u8).empty;
        const ev = parsed.get("evidence", "");
        if (ev.len > 0) try evidence.append(c.arena, ev);
        var opened = try bound(c, oneScope(parsed.get("scope", "")));
        defer opened.st.close();
        const cp = try core.recordCheckpoint(&opened.st, c.arena, .{
            .binding = opened.b,
            .key = key,
            .item = parsed.positional[0],
            .result = parsed.get("result", ""),
            .evidence = evidence.items,
            .next_action = parsed.get("next", ""),
        }, nowSeconds(c));
        return writeJson(c, "focus checkpoint", cp);
    }
    if (std.mem.eql(u8, sub, "finish")) {
        if (parsed.positional.len != 1) return errors.invalid("usage: focus finish [flags] <focus-id>", .{});
        var opened = try bound(c, oneScope(parsed.get("scope", "")));
        defer opened.st.close();
        const focus = try core.finishFocus(&opened.st, c.arena, .{
            .binding = opened.b,
            .key = key,
            .focus = parsed.positional[0],
            .outcome = parsed.get("outcome", ""),
        }, nowSeconds(c));
        return writeJson(c, "focus finish", focus);
    }
    return errors.invalid("unknown focus subcommand \"{s}\"", .{sub});
}

// ------------------------------------------------------------------- review

fn cmdReview(c: *Cli, args: []const []const u8) !void {
    if (args.len == 0) return errors.invalid("usage: review daily|weekly|monthly|yearly [flags]", .{});
    if (std.mem.eql(u8, args[0], "show")) return reviewShowCmd(c, args[1..]);
    const kind = args[0];
    const kind_ok = std.mem.eql(u8, kind, "daily") or std.mem.eql(u8, kind, "weekly") or
        std.mem.eql(u8, kind, "monthly") or std.mem.eql(u8, kind, "yearly");
    if (!kind_ok) return errors.invalid("unknown review kind \"{s}\"", .{kind});
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "key", .value = true },
        .{ .name = "period", .value = true },
        .{ .name = "outcomes", .value = true },
        .{ .name = "coverage", .value = true },
        .{ .name = "derive", .value = false },
        .{ .name = "calendar-assert", .value = true },
    };
    const parsed = try parseFlags(c.arena, args[1..], &specs);
    const key = if (parsed.get("key", "").len > 0) parsed.get("key", "") else try newKey(c, "review");
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const review = try core.recordReview(&opened.st, c.arena, .{
        .binding = opened.b,
        .key = key,
        .kind = kind,
        .period = parsed.get("period", ""),
        .outcomes = parsed.get("outcomes", ""),
        .coverage = parsed.get("coverage", ""),
        .complete = true,
    }, parsed.has("derive"), parsed.get("calendar-assert", ""), nowSeconds(c));
    return writeJson(c, "review", review);
}

fn reviewShowCmd(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "kind", .value = true },
        .{ .name = "period", .value = true },
    };
    const parsed = try parseFlags(c.arena, args, &specs);
    if (parsed.positional.len != 0) return errors.invalid("usage: review show --period P [--kind K] [--scope X]", .{});
    const period = parsed.get("period", "");
    if (period.len == 0) return errors.invalid("--period is required", .{});
    const kind = if (parsed.get("kind", "").len > 0) parsed.get("kind", "") else "daily";
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const m = try core.reviewShow(&opened.st, c.arena, opened.b, kind, period);
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.str("id", m.id);
    try o.str("kind", m.kind);
    try o.str("period", m.period);
    try o.raw("metrics", m.metrics_json);
    try o.end();
    return succeedData(c, "review show", aw.written());
}

fn cmdLearn(c: *Cli, args: []const []const u8) !void {
    const usage_line =
        "usage: learn propose --review ID --slug S [--title T] [--body B | --file F] [--record-kind K] [--evidence ID]... [--scope X]";
    if (args.len == 0 or !std.mem.eql(u8, args[0], "propose")) return errors.invalid("{s}", .{usage_line});
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },       .{ .name = "review", .value = true },
        .{ .name = "slug", .value = true },        .{ .name = "title", .value = true },
        .{ .name = "body", .value = true },        .{ .name = "file", .value = true },
        .{ .name = "record-kind", .value = true }, .{ .name = "evidence", .value = true, .multi = true },
    };
    const p = try parseFlags(c.arena, args[1..], &specs);
    if (p.positional.len != 0) return errors.invalid("{s}", .{usage_line});
    if (p.has("body") and p.has("file")) return errors.invalid("--body and --file are mutually exclusive", .{});
    var body = p.get("body", "");
    if (p.has("file")) body = try readBodyFile(c, p.get("file", ""));
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const out = try core.proposeLearning(&r.st, c.arena, .{
        .binding = r.b,
        .review = p.get("review", ""),
        .slug = p.get("slug", ""),
        .title = p.get("title", ""),
        .body = body,
        .record_kind = p.get("record-kind", ""),
        .evidence = if (p.multi.get("evidence")) |ev| ev.items else &.{},
    }, nowSeconds(c));
    try writeJson(c, "learn propose", out);
}

fn cmdOverride(c: *Cli, args: []const []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "add")) {
        return errors.invalid("usage: override add --rule mit|focus --date YYYY-MM-DD --reason R [--actor A]", .{});
    }
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "rule", .value = true },
        .{ .name = "date", .value = true },
        .{ .name = "reason", .value = true },
        .{ .name = "actor", .value = true },
    };
    const parsed = try parseFlags(c.arena, args[1..], &specs);
    if (parsed.positional.len != 0) return errors.invalid("usage: override add --rule mit|focus --date YYYY-MM-DD --reason R [--actor A]", .{});
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();
    const row = try core.addOverride(&opened.st, c.arena, opened.b, parsed.get("rule", ""), parsed.get("date", ""), parsed.get("reason", ""), parsed.get("actor", ""), nowSeconds(c));
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.str("actor", row.actor);
    try o.str("created_at", row.created_at);
    try o.str("id", row.id);
    try o.str("local_date", row.local_date);
    try o.str("reason", row.reason);
    try o.str("rule", row.rule);
    try o.end();
    return succeedData(c, "override add", aw.written());
}

fn cmdRoutines(c: *Cli, args: []const []const u8) !void {
    const a = c.arena;
    if (args.len == 0) return errors.invalid("usage: routines due|done|add [flags]", .{});
    const sub = args[0];
    if (std.mem.eql(u8, sub, "add")) {
        const parsed = try parseFlags(a, args[1..], &.{
            .{ .name = "scope", .value = true },
            .{ .name = "id", .value = true },
            .{ .name = "cadence", .value = true },
            .{ .name = "last", .value = true },
        });
        if (parsed.positional.len != 0) return errors.invalid(
            "usage: routines add --id ID --cadence daily|weekly:<day> [--last YYYY-MM-DD] [--scope S]",
            .{},
        );
        const parsed_scope = parsed.get("scope", "");
        var opened = try bound(c, oneScope(parsed_scope));
        defer opened.st.close();
        const r = try core.addRoutine(&opened.st, a, .{
            .binding = opened.b,
            .id = parsed.get("id", ""),
            .cadence = parsed.get("cadence", ""),
            .last = parsed.get("last", ""),
        });
        return writeJson(c, "routines add", r);
    }
    if (!std.mem.eql(u8, sub, "due") and !std.mem.eql(u8, sub, "done")) {
        return errors.invalid("unknown routines subcommand \"{s}\" (usage: routines due|done|add)", .{sub});
    }
    const parsed = try parseFlags(a, args[1..], &.{
        .{ .name = "scope", .value = true },
        .{ .name = "date", .value = true },
    });
    var date_buf: [10]u8 = undefined;
    const date_text = blk: {
        const given = parsed.get("date", "");
        if (given.len > 0) break :blk given;
        break :blk timeutil.date(nowSeconds(c), &date_buf);
    };
    var opened = try bound(c, oneScope(parsed.get("scope", "")));
    defer opened.st.close();

    if (std.mem.eql(u8, sub, "due")) {
        const due = try core.dueRoutines(&opened.st, a, opened.b, date_text);
        var aw = Io.Writer.Allocating.init(a);
        if (due) |items| {
            var arr = try jsonw.Arr.init(&aw.writer);
            for (items) |r| {
                var o = try arr.obj();
                try r.write(&o);
                try o.end();
            }
            try arr.end();
        } else {
            try aw.writer.writeAll("null");
        }
        return succeedData(c, "routines due", aw.written());
    }
    if (parsed.positional.len != 1) return errors.invalid("usage: routines done [flags] <routine-id>", .{});
    const r = try core.completeRoutine(&opened.st, a, opened.b, parsed.positional[0], date_text);
    return writeJson(c, "routines done", r);
}

fn cmdCheck(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{ .{ .name = "scope", .value = true }, .{ .name = "bindings", .value = false } };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: check [--scope S] [--bindings]", .{});
    if (p.has("bindings")) return checkBindings(c);
    const scope = p.get("scope", "");
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    if (scope.len > 0) {
        var opened = try bound(c, oneScope(scope));
        defer opened.st.close();
        const report = try core.runCheck(&opened.st, c.arena, opened.b);
        try o.boolean("ok", report.ok);
        if (report.errors.len > 0) try writeStringArray(&o, "errors", report.errors);
    } else {
        var opened = try openStore(c);
        defer opened.close();
        const report = try core.runCheck(&opened, c.arena, null);
        try o.boolean("ok", report.ok);
        if (report.errors.len > 0) try writeStringArray(&o, "errors", report.errors);
    }
    try o.end();
    return succeedData(c, "check", aw.written());
}

fn checkBindings(c: *Cli) !void {
    const raw = Io.Dir.cwd().readFileAlloc(c.io, ".ztd.json", c.arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return errors.invalid(".ztd.json not found", .{}),
        else => return errors.fail(.io_error, "read .ztd.json: {s}", .{@errorName(e)}),
    };
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, raw, .{}) catch
        return errors.invalid(".ztd.json is not valid JSON", .{});
    const hint = switch (parsed.value) {
        .object => |obj| obj,
        else => return errors.invalid(".ztd.json must be a JSON object", .{}),
    };
    for (hint.keys()) |key| {
        if (!std.mem.eql(u8, key, "context") and !std.mem.eql(u8, key, "client") and !std.mem.eql(u8, key, "project")) {
            return errors.invalid(".ztd.json has unexpected field \"{s}\" (want context, client, project)", .{key});
        }
    }
    const context_val = try hintField(hint, "context", true);
    const client_val = try hintField(hint, "client", false);
    const project_val = try hintField(hint, "project", true);

    var scopes: []const domain.Scope = &.{};
    var st_val: Store = undefined;
    var have_store = false;
    defer if (have_store) st_val.close();
    if (Io.Dir.cwd().access(c.io, c.db, .{})) |_| {
        st_val = try openStore(c);
        have_store = true;
        scopes = try core.listScopes(&st_val, c.arena);
    } else |_| {}

    var resolved: ?[]const u8 = null;
    for (scopes) |sc| {
        if (std.mem.eql(u8, sc.id, context_val)) resolved = sc.id;
    }
    if (resolved == null and client_val.len > 0) {
        const client_scope = try std.fmt.allocPrint(c.arena, "client:{s}", .{client_val});
        for (scopes) |sc| {
            if (std.mem.eql(u8, sc.id, client_scope)) resolved = sc.id;
        }
    }
    if (resolved == null) {
        for (scopes) |sc| {
            if (std.mem.eql(u8, sc.id, "personal")) resolved = sc.id;
        }
    }
    const scope_id = resolved orelse
        return errors.invalid("no scope matches .ztd.json (context \"{s}\", client \"{s}\")", .{ context_val, client_val });
    if (!have_store) return errors.fail(.not_found, "project {s} not found", .{project_val});
    const project = try core.getProject(&st_val, c.arena, .{
        .profile = "personal",
        .actor = c.actor,
        .scopes = oneScope(scope_id),
    }, project_val);

    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    var binding_aw = Io.Writer.Allocating.init(c.arena);
    try jsonw.writeValue(c.arena, &binding_aw.writer, .{ .object = hint });
    try o.raw("binding", binding_aw.written());
    try o.boolean("ok", true);
    try o.str("project", project.id);
    try o.str("scope", scope_id);
    try o.end();
    try succeedData(c, "check", aw.written());
}

fn hintField(hint: std.json.ObjectMap, name: []const u8, required: bool) ![]const u8 {
    const v = hint.get(name) orelse {
        if (required) return errors.invalid(".ztd.json is missing \"{s}\"", .{name});
        return "";
    };
    const s = switch (v) {
        .string => |sv| sv,
        else => return errors.invalid(".ztd.json field \"{s}\" must be a string", .{name}),
    };
    if (required and std.mem.trim(u8, s, " \t\n\r\x0b\x0c").len == 0) {
        return errors.invalid(".ztd.json field \"{s}\" must be non-empty", .{name});
    }
    return s;
}

pub const usage =
    \\ztd — personal ZTD system
    \\
    \\usage: ztd [--json] [--db PATH] [--actor ID] <command> [flags]
    \\
    \\commands:
    \\  init        declare scopes and the planning profile
    \\  status      report the local environment
    \\  capture     add one inbox entry
    \\  inbox next  show the oldest capture awaiting processing
    \\  process     commit one typed outcome for a capture
    \\  show        show a capture or work item
    \\  find        search work item titles
    \\  list        list work items or the inbox
    \\  move        move a work item between lifecycles
    \\  version     print the version
    \\
;

test "scope declarations parse id and kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cmd = try parseScopeDecl("id=personal,kind=personal");
    try std.testing.expectEqualStrings("personal", cmd.id);
    try std.testing.expectEqualStrings("personal", cmd.kind);
    try std.testing.expectError(error.Ztd, parseScopeDecl("id=Bad,kind=personal"));
}

// --------------------------------------------------------------- documents

fn failWithData(c: *Cli, command: []const u8, family: errors.Family, detail: []const u8, data: []const u8) !void {
    if (!c.json) {
        try c.err.print("{s}: {s}\n", .{ family.text(), detail });
        return;
    }
    var o = try jsonw.Obj.init(c.out);
    try o.boolean("ok", false);
    if (command.len > 0) try o.str("command", command);
    try o.raw("data", data);
    var e = try o.obj("error");
    try e.str("family", family.text());
    try e.str("detail", detail);
    try e.end();
    try o.end();
    try c.out.writeByte('\n');
}

fn intFlag(name: []const u8, value: []const u8) !i64 {
    return std.fmt.parseInt(i64, value, 10) catch
        errors.invalid("invalid value \"{s}\" for flag -{s}: parse error", .{ value, name });
}

fn readBodyFile(c: *Cli, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(1 << 30)) catch |e|
        return errors.fail(.io_error, "read body file: {s}", .{@errorName(e)});
}

fn cmdDoc(c: *Cli, args: []const []const u8) !void {
    if (args.len == 0) return errors.invalid("usage: doc put|get|list|search|related|log|lint|archive [flags]", .{});
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "put")) return docPut(c, rest);
    if (std.mem.eql(u8, sub, "get")) return docGet(c, rest);
    if (std.mem.eql(u8, sub, "list")) return docList(c, rest);
    if (std.mem.eql(u8, sub, "search")) return docSearch(c, rest);
    if (std.mem.eql(u8, sub, "related")) return docRelated(c, rest);
    if (std.mem.eql(u8, sub, "log")) return docLog(c, rest);
    if (std.mem.eql(u8, sub, "lint")) return docLint(c, rest);
    if (std.mem.eql(u8, sub, "archive")) return docArchive(c, rest);
    if (std.mem.eql(u8, sub, "supersede")) return docSupersede(c, rest);
    return errors.invalid("usage: doc put|get|list|search|related|log|lint|archive [flags]", .{});
}

fn docPut(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },   .{ .name = "kind", .value = true },
        .{ .name = "slug", .value = true },    .{ .name = "title", .value = true },
        .{ .name = "body", .value = true },    .{ .name = "file", .value = true },
        .{ .name = "status", .value = true },  .{ .name = "expected", .value = true },
        .{ .name = "record-kind", .value = true }, .{ .name = "rationale", .value = true },
        .{ .name = "options", .value = true },     .{ .name = "evidence", .value = true, .multi = true },
        .{ .name = "approved-by", .value = true }, .{ .name = "valid-from", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc put --kind K --slug S [flags]", .{});
    const kind = p.get("kind", "");
    const slug = p.get("slug", "");
    if (kind.len == 0) return errors.invalid("--kind is required", .{});
    if (slug.len == 0) return errors.invalid("--slug is required", .{});
    if (p.has("body") and p.has("file")) return errors.invalid("--body and --file are mutually exclusive", .{});
    var body = p.get("body", "");
    if (p.has("file")) body = try readBodyFile(c, p.get("file", ""));
    const expected = try intFlag("expected", p.get("expected", "0"));
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const out = try core.putDocument(&r.st, c.arena, .{
        .binding = r.b,
        .scope = p.get("scope", ""),
        .kind = kind,
        .slug = slug,
        .title = p.get("title", slug),
        .body = body,
        .status = p.get("status", "draft"),
        .expected = expected,
        .record_kind = p.get("record-kind", ""),
        .rationale = p.get("rationale", ""),
        .options_json = p.get("options", ""),
        .evidence = if (p.multi.get("evidence")) |ev| ev.items else &.{},
        .approved_by = p.get("approved-by", ""),
        .valid_from = p.get("valid-from", ""),
    }, nowSeconds(c));
    try writeJson(c, "doc put", out);
}

fn docGet(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "kind", .value = true },
        .{ .name = "slug", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc get --kind K --slug S [--scope X]", .{});
    const kind = p.get("kind", "");
    const slug = p.get("slug", "");
    if (kind.len == 0) return errors.invalid("--kind is required", .{});
    if (slug.len == 0) return errors.invalid("--slug is required", .{});
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const out = try core.getDocument(&r.st, c.arena, r.b, kind, slug, p.get("scope", ""));
    try writeJson(c, "doc get", out);
}

fn writeDocuments(c: *Cli, command: []const u8, items: []const domain.Document) !void {
    var aw = Io.Writer.Allocating.init(c.arena);
    var arr = try jsonw.Arr.init(&aw.writer);
    for (items) |d| {
        var o = try arr.obj();
        try d.write(&o);
        try o.end();
    }
    try arr.end();
    try succeedData(c, command, aw.written());
}

fn docList(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{ .{ .name = "scope", .value = true }, .{ .name = "kind", .value = true } };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc list [--kind K] [--scope X]", .{});
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const items = try core.listDocuments(&r.st, c.arena, r.b, p.get("kind", ""));
    try writeDocuments(c, "doc list", items);
}

fn docSearch(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true }, .{ .name = "query", .value = true },
        .{ .name = "kind", .value = true },  .{ .name = "limit", .value = true },
        .{ .name = "record-kind", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc search --query Q [--kind K] [--scope X] [--limit N]", .{});
    const query = std.mem.trim(u8, p.get("query", ""), " \t\n\r\x0b\x0c");
    if (query.len == 0) return errors.invalid("--query is required", .{});
    const limit = try intFlag("limit", p.get("limit", "10"));
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const hits = try core.searchDocumentsBy(&r.st, c.arena, r.b, query, p.get("kind", ""), p.get("record-kind", ""), limit);
    var aw = Io.Writer.Allocating.init(c.arena);
    var arr = try jsonw.Arr.init(&aw.writer);
    for (hits) |h| {
        var o = try arr.obj();
        var inner = try o.obj("document");
        try h.document.write(&inner);
        try inner.end();
        try o.float("rank", h.rank);
        try o.str("snippet", h.snippet);
        try o.end();
    }
    try arr.end();
    try succeedData(c, "doc search", aw.written());
}

fn docRelated(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "kind", .value = true },
        .{ .name = "slug", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc related --kind K --slug S [--scope X]", .{});
    const kind = p.get("kind", "");
    const slug = p.get("slug", "");
    if (kind.len == 0) return errors.invalid("--kind is required", .{});
    if (slug.len == 0) return errors.invalid("--slug is required", .{});
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const source = try core.getDocument(&r.st, c.arena, r.b, kind, slug, p.get("scope", ""));
    const all = try core.listDocuments(&r.st, c.arena, r.b, "");
    const rel = try doc.relatedDocuments(c.arena, all, source);
    const edges = try core.externalEdges(&r.st, c.arena, source.id);
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try doc.writeRelations(&o, rel);
    // v3: non-document edges. Omitted when empty so v2 goldens stay identical.
    if (edges.len > 0) {
        var arr = try o.arr("links");
        for (edges) |e| {
            var item = try arr.obj();
            try item.str("relation", e.relation);
            try item.str("from_type", e.from_type);
            try item.str("from_id", e.from_id);
            try item.str("to_type", e.to_type);
            try item.str("to_id", e.to_id);
            try item.end();
        }
        try arr.end();
    }
    try o.end();
    try succeedData(c, "doc related", aw.written());
}

fn docLog(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true }, .{ .name = "kind", .value = true },
        .{ .name = "slug", .value = true },  .{ .name = "limit", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc log [--scope X] [--kind K] [--slug S] [--limit N]", .{});
    const limit = try intFlag("limit", p.get("limit", "50"));
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const entries = try core.listDocumentHistory(&r.st, c.arena, r.b, p.get("kind", ""), p.get("slug", ""), limit);
    var aw = Io.Writer.Allocating.init(c.arena);
    var arr = try jsonw.Arr.init(&aw.writer);
    for (entries) |e| {
        var o = try arr.obj();
        try o.int("seq", e.seq);
        try o.str("event", e.event);
        try o.int("revision", e.revision);
        try o.str("created_at", e.created_at);
        try o.str("scope", e.scope);
        try o.str("kind", e.kind);
        try o.str("slug", e.slug);
        try o.end();
    }
    try arr.end();
    try succeedData(c, "doc log", aw.written());
}

fn docLint(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{ .{ .name = "scope", .value = true }, .{ .name = "strict", .value = false } };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc lint [--scope X] [--strict]", .{});
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const all = try core.listDocuments(&r.st, c.arena, r.b, "");
    const report = try doc.lintDocuments(c.arena, all);
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try doc.writeReport(&o, report);
    try o.end();
    const strict = p.has("strict");
    if (report.errors.len > 0) {
        const detail = try std.fmt.allocPrint(c.arena, "doc lint reported {d} error(s)", .{report.errors.len});
        return failWithData(c, "doc lint", .conflict, detail, aw.written());
    }
    if (strict and report.warnings.len > 0) {
        const detail = try std.fmt.allocPrint(c.arena, "doc lint reported {d} warning(s) in strict mode", .{report.warnings.len});
        return failWithData(c, "doc lint", .conflict, detail, aw.written());
    }
    try succeedData(c, "doc lint", aw.written());
}

fn docArchive(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },    .{ .name = "slug", .value = true },
        .{ .name = "title", .value = true },    .{ .name = "question", .value = true },
        .{ .name = "body", .value = true },     .{ .name = "file", .value = true },
        .{ .name = "expected", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: doc archive --slug S [flags]", .{});
    const raw_slug = p.get("slug", "");
    if (raw_slug.len == 0) return errors.invalid("--slug is required", .{});
    if (p.has("body") and p.has("file")) return errors.invalid("--body and --file are mutually exclusive", .{});
    var body = p.get("body", "");
    if (p.has("file")) body = try readBodyFile(c, p.get("file", ""));
    const bare = if (std.mem.startsWith(u8, raw_slug, "answers/")) raw_slug["answers/".len..] else raw_slug;
    const slug = try std.fmt.allocPrint(c.arena, "answers/{s}", .{bare});
    var title = p.get("title", "");
    if (title.len == 0) title = slug;
    const question = std.mem.trim(u8, p.get("question", ""), " \t\n\r\x0b\x0c");
    if (question.len > 0) {
        const buf: [10]u8 = undefined;
        var day_buf = buf;
        body = try std.fmt.allocPrint(c.arena, "# {s}\n\nQuestion: {s}\nArchived: {s}\n\n{s}", .{
            title, question, timeutil.date(nowSeconds(c), &day_buf), body,
        });
    }
    const expected = try intFlag("expected", p.get("expected", "0"));
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const out = try core.putDocument(&r.st, c.arena, .{
        .binding = r.b,
        .scope = p.get("scope", ""),
        .kind = "knowledge",
        .slug = slug,
        .title = title,
        .body = body,
        .status = "draft",
        .expected = expected,
    }, nowSeconds(c));
    try writeJson(c, "doc archive", out);
}

// ----------------------------------------------------------------- sources

fn boundOperator(c: *Cli, scopes: []const []const u8) !struct { st: Store, b: domain.Binding } {
    const st = try openStore(c);
    return .{ .st = st, .b = .{ .profile = "operator", .actor = c.actor, .scopes = scopes } };
}

fn declaredScopes(c: *Cli, st: *Store) ![]const []const u8 {
    const all = try core.listScopes(st, c.arena);
    const out = try c.arena.alloc([]const u8, all.len);
    for (all, 0..) |sc, i| out[i] = sc.id;
    return out;
}

fn cmdSource(c: *Cli, args: []const []const u8) !void {
    if (args.len == 0) return errors.invalid("usage: source add|apply|list|review|delete [flags]", .{});
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "add")) return sourceAdd(c, rest);
    if (std.mem.eql(u8, sub, "list")) return sourceList(c, rest);
    if (std.mem.eql(u8, sub, "review")) return sourceReview(c, rest);
    if (std.mem.eql(u8, sub, "delete")) return sourceDelete(c, rest);
    if (std.mem.eql(u8, sub, "apply")) return sourceApply(c, rest);
    return errors.invalid("usage: source add|apply|list|review|delete [flags]", .{});
}

fn sourceAdd(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "id", .value = true },        .{ .name = "name", .value = true },
        .{ .name = "scope", .value = true },     .{ .name = "kind", .value = true },
        .{ .name = "connector", .value = true }, .{ .name = "provider", .value = true },
        .{ .name = "connection-ref", .value = true },
        .{ .name = "query", .value = true },     .{ .name = "cadence", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    const scope = p.get("scope", "");
    if (scope.len == 0) return errors.invalid("--scope is required", .{});
    var r = try boundOperator(c, oneScope(scope));
    defer r.st.close();
    const src = try core.addSource(&r.st, c.arena, .{
        .binding = r.b,
        .id = p.get("id", ""),
        .name = p.get("name", ""),
        .scope = scope,
        .kind = p.get("kind", ""),
        .connector = p.get("connector", ""),
        .provider = p.get("provider", ""),
        .connection_ref = p.get("connection-ref", ""),
        .non_secret_query = p.get("query", ""),
        .cadence = p.get("cadence", ""),
    }, nowSeconds(c));
    try writeJson(c, "source add", src);
}

fn sourceList(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{ .{ .name = "all", .value = false }, .{ .name = "scope", .value = true, .multi = true } };
    const p = try parseFlags(c.arena, args, &specs);
    const explicit = p.multi.get("scope");
    if (p.has("all") and explicit != null) {
        return errors.invalid("source list takes either --all or --scope, not both", .{});
    }
    var r = try boundOperator(c, &.{});
    defer r.st.close();
    const scopes: []const []const u8 = if (explicit) |list| list.items else try declaredScopes(c, &r.st);
    const b = domain.Binding{ .profile = "operator", .actor = c.actor, .scopes = scopes };
    const list = try core.listSources(&r.st, c.arena, b);
    var aw = Io.Writer.Allocating.init(c.arena);
    {
        var arr = try jsonw.Arr.init(&aw.writer);
        for (list) |src| {
            var o = try arr.obj();
            try src.write(&o);
            try o.end();
        }
        try arr.end();
    }
    try succeedData(c, "source list", aw.written());
}

fn parseRetrieval(v: ?std.json.Value) domain.SourceRetrieval {
    var r = domain.SourceRetrieval{};
    const value = v orelse return r;
    if (jsonw.strField(value, "window")) |s| r.window = s;
    if (jsonw.strField(value, "cursor")) |s| r.cursor = s;
    if (jsonw.intField(value, "requested_limit")) |n| r.requested_limit = n;
    if (jsonw.intField(value, "provider_returned_limit")) |n| r.provider_returned_limit = n;
    if (jsonw.boolField(value, "complete_window")) |b| r.complete_window = b;
    if (jsonw.boolField(value, "truncated")) |b| r.truncated = b;
    if (jsonw.arrField(value, "failures")) |arr| {
        const list = std.heap.page_allocator.alloc([]const u8, arr.len) catch unreachable;
        for (arr, 0..) |f, i| list[i] = if (f == .string) f.string else "";
        r.failures = list;
    }
    return r;
}

fn sourceReview(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true }, .{ .name = "source", .value = true },
        .{ .name = "batch", .value = true }, .{ .name = "key", .value = true },
        .{ .name = "file", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    const file = p.get("file", "");
    if (file.len == 0) return errors.invalid("--file is required", .{});
    const raw = Io.Dir.cwd().readFileAlloc(c.io, file, c.arena, .limited(1 << 30)) catch |e|
        return errors.fail(.io_error, "read batch file: {s}", .{@errorName(e)});
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, raw, .{}) catch
        return errors.invalid("parse batch file: invalid JSON", .{});
    const batch = parsed.value;
    var source_id = p.get("source", "");
    if (source_id.len == 0) source_id = jsonw.strField(batch, "source_id") orelse "";
    var batch_id = p.get("batch", "");
    if (batch_id.len == 0) batch_id = jsonw.strField(batch, "batch_id") orelse "";
    var key = p.get("key", "");
    if (key.len == 0) key = jsonw.strField(batch, "idempotency_key") orelse "";
    if (source_id.len == 0) return errors.invalid("--source is required", .{});
    if (batch_id.len == 0) return errors.invalid("--batch is required", .{});
    if (key.len == 0) key = try newKey(c, "source-review");
    var result_kind = jsonw.strField(batch, "result_kind") orelse "";
    if (result_kind.len == 0) result_kind = "reported";
    const retrieval = parseRetrieval(jsonw.field(batch, "retrieval"));
    var items: std.ArrayList(domain.SourceItem) = .empty;
    if (jsonw.arrField(batch, "items")) |list| {
        for (list) |it| {
            var occurred: ?[]const u8 = null;
            if (jsonw.strField(it, "occurred_at")) |s| {
                const ts = timeutil.parseTime(s) catch return errors.invalid("source item occurred_at must be RFC3339", .{});
                var buf: [20]u8 = undefined;
                occurred = try c.arena.dupe(u8, timeutil.fmtTime(ts, &buf));
            }
            try items.append(c.arena, .{
                .external_id = jsonw.strField(it, "external_id") orelse "",
                .external_revision = jsonw.strField(it, "external_revision") orelse "",
                .original_text = jsonw.strField(it, "original_text") orelse "",
                .source_uri = jsonw.strField(it, "source_uri"),
                .occurred_at = occurred,
                .provider_metadata_summary = jsonw.strField(it, "provider_metadata_summary"),
            });
        }
    }
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const out = try core.recordSourceReview(&r.st, c.arena, .{
        .binding = r.b,
        .source_id = source_id,
        .batch_id = batch_id,
        .key = key,
        .result_kind = result_kind,
        .retrieval = retrieval,
        .items = items.items,
    }, nowSeconds(c));
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    var arr = try o.arr("captures");
    for (out.captures) |cap| {
        var item = try arr.obj();
        try cap.write(&item);
        try item.end();
    }
    try arr.end();
    var rev = try o.obj("review");
    try out.review.write(&rev);
    try rev.end();
    try o.end();
    try succeedData(c, "source review", aw.written());
}

fn sourceDelete(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{ .{ .name = "id", .value = true } };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: source delete --id ID", .{});
    const id = p.get("id", "");
    if (id.len == 0) return errors.invalid("--id is required", .{});
    var r = try boundOperator(c, &.{});
    defer r.st.close();
    const scopes = try declaredScopes(c, &r.st);
    const b = domain.Binding{ .profile = "operator", .actor = c.actor, .scopes = scopes };
    const src = try core.deleteSource(&r.st, c.arena, b, id, "", nowSeconds(c));
    try writeJson(c, "source delete", src);
}

// ------------------------------------------------- scopes, contexts, projects

const SplitArgs = struct { flags: []const []const u8, positional: []const []const u8 };

fn splitFlagArgs(c: *Cli, args: []const []const u8, value_flags: []const []const u8) !SplitArgs {
    var flags: std.ArrayList([]const u8) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!(arg.len > 0 and arg[0] == '-') or std.mem.eql(u8, arg, "-")) {
            try pos.append(c.arena, arg);
            continue;
        }
        try flags.append(c.arena, arg);
        if (std.mem.indexOfScalar(u8, arg, '=') != null) continue;
        for (value_flags) |vf| {
            if (std.mem.eql(u8, vf, arg) and i + 1 < args.len) {
                i += 1;
                try flags.append(c.arena, args[i]);
                break;
            }
        }
    }
    return .{ .flags = flags.items, .positional = pos.items };
}

fn writeArray(c: *Cli, command: []const u8, items: anytype) !void {
    var aw = Io.Writer.Allocating.init(c.arena);
    var arr = try jsonw.Arr.init(&aw.writer);
    for (items) |item| {
        var o = try arr.obj();
        try item.write(&o);
        try o.end();
    }
    try arr.end();
    try succeedData(c, command, aw.written());
}

fn cmdScope(c: *Cli, args: []const []const u8) !void {
    const use_line = "usage: scope add --id ID --kind KIND [--name NAME] | scope list";
    if (args.len == 0) return errors.invalid(use_line, .{});
    const sub = args[0];
    if (std.mem.eql(u8, sub, "add")) {
        const specs = [_]Spec{
            .{ .name = "id", .value = true },
            .{ .name = "kind", .value = true },
            .{ .name = "name", .value = true },
        };
        const p = try parseFlags(c.arena, args[1..], &specs);
        if (p.positional.len != 0) return errors.invalid("usage: scope add --id ID --kind KIND [--name NAME]", .{});
        var st = try openStore(c);
        defer st.close();
        const out = try core.addScope(&st, c.arena, .{
            .id = p.get("id", ""),
            .kind = p.get("kind", ""),
            .name = p.get("name", ""),
        }, nowSeconds(c));
        return writeJson(c, "scope add", out);
    }
    if (std.mem.eql(u8, sub, "list")) {
        const p = try parseFlags(c.arena, args[1..], &[_]Spec{});
        if (p.positional.len != 0) return errors.invalid("usage: scope list", .{});
        var st = try openStore(c);
        defer st.close();
        const out = try core.listScopes(&st, c.arena);
        return writeArray(c, "scope list", out);
    }
    return errors.invalid(use_line, .{});
}

fn cmdContext(c: *Cli, args: []const []const u8) !void {
    const use_line = "usage: context add NAME [--scope S] | context list [--scope S]";
    if (args.len == 0) return errors.invalid(use_line, .{});
    const sub = args[0];
    const split = try splitFlagArgs(c, args[1..], &.{"--scope"});
    const specs = [_]Spec{.{ .name = "scope", .value = true }};
    const p = try parseFlags(c.arena, split.flags, &specs);
    if (std.mem.eql(u8, sub, "add")) {
        if (split.positional.len != 1) return errors.invalid("usage: context add NAME [--scope S]", .{});
        var r = try bound(c, oneScope(p.get("scope", "")));
        defer r.st.close();
        const out = try core.addContext(&r.st, c.arena, .{ .binding = r.b, .name = split.positional[0] }, nowSeconds(c));
        return writeJson(c, "context add", out);
    }
    if (std.mem.eql(u8, sub, "list")) {
        if (split.positional.len != 0) return errors.invalid("usage: context list [--scope S]", .{});
        var r = try bound(c, oneScope(p.get("scope", "")));
        defer r.st.close();
        const out = try core.listContexts(&r.st, c.arena, r.b);
        return writeArray(c, "context list", out);
    }
    return errors.invalid(use_line, .{});
}

fn cmdProject(c: *Cli, args: []const []const u8) !void {
    const use_line = "usage: project add ID [flags] | project list [--scope S] | project show ID [--scope S]";
    if (args.len == 0) return errors.invalid(use_line, .{});
    const sub = args[0];
    const split = try splitFlagArgs(c, args[1..], &.{ "--scope", "--desired-outcome", "--status", "--repo-url", "--clone-path" });
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "desired-outcome", .value = true },
        .{ .name = "status", .value = true },
        .{ .name = "repo-url", .value = true },
        .{ .name = "clone-path", .value = true },
    };
    const p = try parseFlags(c.arena, split.flags, &specs);
    if (std.mem.eql(u8, sub, "add")) {
        if (split.positional.len != 1) {
            return errors.invalid("usage: project add ID [--scope S] [--desired-outcome TEXT] [--status ...] [--repo-url URL] [--clone-path PATH]", .{});
        }
        var r = try bound(c, oneScope(p.get("scope", "")));
        defer r.st.close();
        const out = try core.addProject(&r.st, c.arena, .{
            .binding = r.b,
            .id = split.positional[0],
            .desired_outcome = p.get("desired-outcome", ""),
            .status = p.get("status", "active"),
            .repo_url = p.get("repo-url", ""),
            .clone_path = p.get("clone-path", ""),
        }, nowSeconds(c));
        return writeJson(c, "project add", out);
    }
    if (std.mem.eql(u8, sub, "list")) {
        if (split.positional.len != 0) return errors.invalid("usage: project list [--scope S]", .{});
        var r = try bound(c, oneScope(p.get("scope", "")));
        defer r.st.close();
        const out = try core.listProjects(&r.st, c.arena, r.b);
        return writeArray(c, "project list", out);
    }
    if (std.mem.eql(u8, sub, "show")) {
        if (split.positional.len != 1) return errors.invalid("usage: project show ID [--scope S]", .{});
        var r = try bound(c, oneScope(p.get("scope", "")));
        defer r.st.close();
        const out = try core.getProject(&r.st, c.arena, r.b, split.positional[0]);
        return writeJson(c, "project show", out);
    }
    return errors.invalid(use_line, .{});
}

fn sourceApply(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{.{ .name = "file", .value = true }};
    const p = try parseFlags(c.arena, args, &specs);
    const path = blk: {
        if (p.has("file")) break :blk p.get("file", "");
        if (c.sources_path) |v| break :blk v;
        break :blk try std.fmt.allocPrint(c.arena, "{s}/.ztd/sources.json", .{c.home orelse ""});
    };
    const raw = Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(1 << 20)) catch |e|
        return errors.fail(.io_error, "read source configuration: {s}", .{@errorName(e)});
    const parsed = std.json.parseFromSlice(std.json.Value, c.arena, raw, .{}) catch
        return errors.invalid("parse source configuration: invalid JSON", .{});
    if (parsed.value != .object) return errors.invalid("parse source configuration: expected an object", .{});
    const list_val = jsonw.field(parsed.value, "sources") orelse
        return errors.invalid("parse source configuration: missing sources", .{});
    if (list_val != .array) return errors.invalid("parse source configuration: sources must be an array", .{});
    const entries = list_val.array.items;

    var scopes: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        const sc = jsonw.strField(e, "scope") orelse "";
        if (sc.len == 0) continue;
        var seen = false;
        for (scopes.items) |s| {
            if (std.mem.eql(u8, s, sc)) {
                seen = true;
                break;
            }
        }
        if (!seen) try scopes.append(c.arena, sc);
    }

    var r = try boundOperator(c, scopes.items);
    defer r.st.close();
    const declared = try core.listScopes(&r.st, c.arena);
    for (scopes.items) |sc| {
        var ok = false;
        for (declared) |d| {
            if (std.mem.eql(u8, d.id, sc)) {
                ok = true;
                break;
            }
        }
        if (!ok) return errors.invalid("unknown scope reference {s}", .{sc});
    }

    var cmds: std.ArrayList(core.SourceCmd) = .empty;
    for (entries) |e| {
        try cmds.append(c.arena, .{
            .binding = r.b,
            .id = jsonw.strField(e, "id") orelse "",
            .name = jsonw.strField(e, "name") orelse "",
            .scope = jsonw.strField(e, "scope") orelse "",
            .kind = jsonw.strField(e, "kind") orelse "",
            .connector = jsonw.strField(e, "connector") orelse "",
            .provider = jsonw.strField(e, "provider") orelse "",
            .connection_ref = jsonw.strField(e, "connection_ref") orelse "",
            .non_secret_query = jsonw.strField(e, "non_secret_query") orelse "",
            .cadence = jsonw.strField(e, "cadence") orelse "",
        });
    }
    const out = try core.applySources(&r.st, c.arena, cmds.items, nowSeconds(c));
    var aw = Io.Writer.Allocating.init(c.arena);
    var arr = try jsonw.Arr.init(&aw.writer);
    for (out) |src| {
        var o = try arr.obj();
        try src.write(&o);
        try o.end();
    }
    try arr.end();
    try succeedData(c, "source apply", aw.written());
}

// -------------------------------------------------------------- durability

fn pathEnvelope(c: *Cli, command: []const u8, path: []const u8) !void {
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.str("path", path);
    try o.end();
    try succeedData(c, command, aw.written());
}

fn cmdExport(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{.{ .name = "out", .value = true }};
    const p = try parseFlags(c.arena, args, &specs);
    const out = p.get("out", "");
    if (out.len == 0) return errors.invalid("--out is required", .{});
    var st = try openStore(c);
    defer st.close();
    try core.exportTo(&st, c.arena, c.io, out);
    try pathEnvelope(c, "export", out);
}

fn lessCount(_: void, x: core.TableCount, y: core.TableCount) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

fn cmdRestore(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{.{ .name = "from", .value = true }};
    const p = try parseFlags(c.arena, args, &specs);
    const from = p.get("from", "");
    if (from.len == 0) return errors.invalid("--from is required", .{});
    var st = try openStore(c);
    defer st.close();
    const counts = try core.restoreFrom(&st, c.arena, c.io, from);
    const sorted = try c.arena.dupe(core.TableCount, counts);
    std.mem.sort(core.TableCount, sorted, {}, lessCount);
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    var tables = try o.obj("tables");
    for (sorted) |tc| try tables.int(tc.name, tc.count);
    try tables.end();
    try o.end();
    try succeedData(c, "restore", aw.written());
}

fn cmdSnapshot(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{.{ .name = "out", .value = true }};
    const p = try parseFlags(c.arena, args, &specs);
    const out = p.get("out", "");
    if (out.len == 0) return errors.invalid("--out is required", .{});
    var st = try openStore(c);
    defer st.close();
    _ = try core.snapshot(&st, c.arena, c.io, out);
    try pathEnvelope(c, "snapshot", out);
}

fn cmdRecover(c: *Cli, args: []const []const u8) !void {
    if (args.len != 0) return errors.invalid("usage: recover", .{});
    var aw = Io.Writer.Allocating.init(c.arena);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.boolean("recovered", false);
    try o.end();
    try succeedData(c, "recover", aw.written());
}

fn cmdMcp(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "allow-delete-source", .value = false },
        .{ .name = "scope", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 0) return errors.invalid("usage: mcp [--scope S] [--allow-delete-source]", .{});
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    try mcp.serve(c.arena, c.io, c.out, &r.st, r.b, p.has("allow-delete-source"));
    try c.out.flush();
}

// -------------------------------------------------------------- provenance

const trace_cap = 1024;

fn renderTrace(a: std.mem.Allocator, t: core.TraceResult, edges: []const core.TraceEdge, omitted: i64) ![]const u8 {
    var aw = Io.Writer.Allocating.init(a);
    var o = try jsonw.Obj.init(&aw.writer);
    try o.str("id", t.id);
    try o.str("kind", t.kind);
    if (t.label.len > 0) try o.str("label", t.label);
    var arr = try o.arr("edges");
    for (edges) |e| {
        var item = try arr.obj();
        try item.str("relation", e.relation);
        try item.str("from_type", e.from_type);
        try item.str("from_id", e.from_id);
        try item.str("to_type", e.to_type);
        try item.str("to_id", e.to_id);
        try item.end();
    }
    try arr.end();
    if (omitted > 0) {
        try o.int("omitted", omitted);
        try o.boolean("truncated", true);
    }
    try o.end();
    return aw.written();
}

fn cmdTrace(c: *Cli, args: []const []const u8) !void {
    const p = try parseFlags(c.arena, args, &.{});
    if (p.positional.len != 1) return errors.invalid("usage: trace ID", .{});
    var r = try bound(c, &.{});
    defer r.st.close();
    const t = try core.traceEntity(&r.st, c.arena, p.positional[0]);
    var edges = t.edges;
    var omitted: i64 = 0;
    var data = try renderTrace(c.arena, t, edges, omitted);
    while (data.len > trace_cap and edges.len > 0) {
        edges = edges[0 .. edges.len - 1];
        omitted += 1;
        data = try renderTrace(c.arena, t, edges, omitted);
    }
    try succeedData(c, "trace", data);
}

fn docSupersede(c: *Cli, args: []const []const u8) !void {
    const specs = [_]Spec{
        .{ .name = "scope", .value = true },
        .{ .name = "kind", .value = true },
    };
    const p = try parseFlags(c.arena, args, &specs);
    if (p.positional.len != 2) return errors.invalid("usage: doc supersede OLD NEW [--kind K] [--scope X]", .{});
    const kind = p.get("kind", "knowledge");
    var r = try bound(c, oneScope(p.get("scope", "")));
    defer r.st.close();
    const out = try core.supersedeDocument(
        &r.st,
        c.arena,
        r.b,
        kind,
        p.get("scope", ""),
        p.positional[0],
        p.positional[1],
        nowSeconds(c),
    );
    try writeJson(c, "doc supersede", out);
}
