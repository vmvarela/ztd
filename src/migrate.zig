//! Copy-only format-1 to format-2 store converter (`ztd migrate`).
//!
//! Both paths are explicit store directories: neither the working directory
//! nor `ZTD_ROOT` selects them. The source is read-only, the destination must
//! not exist and its parent must. Conversion runs in a private sibling stage,
//! the completed stage is validated with the strict format-2 checker and is
//! promoted with `std.Io.Dir.renamePreserve`, which never replaces an existing
//! destination. There is no inverse conversion and no live cutover.
//!
//! What is transformed — and nothing else:
//!
//! - reserved field names on the five canonical lists (`contexto` → `context`,
//!   `cliente` → `client`, `proyecto` → `project`, `capturada` → `captured_at`,
//!   `cerrada` → `closed_at`, `espera` → `waiting_on`, `resolución` →
//!   `resolution`);
//! - recognized `contexts.md` header cells in the first table row (`Contexto`
//!   → `Context`, `Uso` → `Use`, `Clientes` → `Clients`, `Conocimiento` →
//!   `Knowledge`);
//! - `config.json`: `format` 1 → 2, with every other JSON property preserved
//!   (re-serialised, values intact). A missing config is synthesised as
//!   `{"format":2,"policy":{"requireClientFor":[],"clientOnlyIn":[]}}` only
//!   when canonical v1 structure plus structural v1 evidence (a legacy task
//!   field, a `Contexto` header cell or a format-1 routine token) establishes
//!   the source as format 1; policy is never inferred from tasks;
//! - present `routines/state.md` header/cadence/day tokens (`rutina` →
//!   `routine`, `cadencia` → `cadence`, `último` → `last`, `diaria` → `daily`,
//!   `semanal:<día>` → `weekly:<day>` with `lun…dom` → `mon…sun`). Row dates
//!   are preserved byte for byte. A genuinely absent routine file is seeded
//!   with the current v2 defaults (`inbox`, `plan`, `review`) dated at the one
//!   captured conversion date — an initial scheduling baseline, not completed
//!   history — and reported as such.
//!
//! Titles, user values, field order, custom fields and every unrelated
//! regular-file byte are copied verbatim. `.git` administration and `.state`
//! are excluded from the copy. Opaque copies read raw bytes (`Dir.readFileAlloc`),
//! never `Store.read`, which normalises CRLF; renames are done on the parsed
//! field slice, never `Task.set`, which can overwrite a collision.
//!
//! Refusals (destination untouched, source never written): existing or
//! dangling destination, missing parent, source/destination overlap or alias,
//! a pending source journal, malformed canonical task lines, duplicate ids or
//! fields, mixed format-1/format-2 signals, any key-renaming collision,
//! a present-but-malformed/empty/unreadable routine table, a config that is
//! not format 1, symlink or special files anywhere in the copied tree, a
//! source that changes between the two inventory snapshots, and a staged copy
//! that fails the strict format-2 check.
//!
//! Dry run (`Options.dry_run`) performs every preflight and all transformations
//! in memory and writes nothing: no source, destination, stage, lock or report
//! file. The one validation it cannot perform is the strict format-2 check of
//! the completed copy, because that check walks a real staged directory;
//! `Report.checked` is false for a dry run and true after a real promotion.
//!
//! Quiescence: this module never locks exclusively and never creates a file in
//! the source. A real run calls `Store.lock(false)`, which takes a shared lock
//! only when the source already has `.state/lock` (nothing is created when it
//! is absent; a ztd writer cannot be active then) and fails closed if that
//! existing lock cannot be opened. The inventory and content hashes of the
//! copied set are taken before and after the conversion; any difference aborts
//! with `error.SourceChanged` and never repairs or rewrites the source.
//! Changes confined to `.git` or `.state` are not detected because those are
//! not copied. A writer that ignores the ztd lock can still change the source
//! in the window between the final snapshot and the promotion rename; it can
//! neither corrupt the source (it is never written) nor leave a partial
//! destination (the promotion is a single no-replace rename). A dry run takes
//! no lock at all. The whole source store is held in memory while converting
//! (each file is capped at `store.max_file_bytes`).

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const model = @import("model.zig");
const platform = @import("platform.zig");
const routine = @import("routine.zig");
const store_mod = @import("store.zig");
const config_mod = @import("config.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The format a convertible source declares in `config.json` (or establishes
/// structurally when the file is missing).
const legacy_format: u32 = 1;

/// The five lists whose reserved field names are translated.
const canonical_lists = [_][]const u8{
    "inbox.md",         "lists/next.md",    "lists/waiting.md",
    "lists/someday.md", "lists/archive.md",
};

/// Top-level administration excluded from the copy.
const excluded_top = [_][]const u8{ ".git", ".state" };

const FieldRename = struct { from: []const u8, to: []const u8 };

/// Format-1 reserved field names, paired with their format-2 spelling. Kept in
/// sync with `model.legacy_fields` by a test below.
const field_renames = [_]FieldRename{
    .{ .from = "contexto", .to = "context" },
    .{ .from = "cliente", .to = "client" },
    .{ .from = "proyecto", .to = "project" },
    .{ .from = "capturada", .to = "captured_at" },
    .{ .from = "cerrada", .to = "closed_at" },
    .{ .from = "espera", .to = "waiting_on" },
    .{ .from = "resolución", .to = "resolution" },
};

const context_header_renames = [_]FieldRename{
    .{ .from = "Contexto", .to = "Context" },
    .{ .from = "Uso", .to = "Use" },
    .{ .from = "Clientes", .to = "Clients" },
    .{ .from = "Conocimiento", .to = "Knowledge" },
};

const routine_header_renames = [_]FieldRename{
    .{ .from = "rutina", .to = "routine" },
    .{ .from = "cadencia", .to = "cadence" },
    .{ .from = "último", .to = "last" },
};

const day_renames = [_]FieldRename{
    .{ .from = "lun", .to = "mon" },
    .{ .from = "mar", .to = "tue" },
    .{ .from = "mié", .to = "wed" },
    .{ .from = "mie", .to = "wed" },
    .{ .from = "jue", .to = "thu" },
    .{ .from = "vie", .to = "fri" },
    .{ .from = "sáb", .to = "sat" },
    .{ .from = "sab", .to = "sat" },
    .{ .from = "dom", .to = "sun" },
};

pub const Options = struct {
    /// Format-1 store directory; read-only, must exist.
    from: []const u8,
    /// Format-2 store directory to create; must not exist, parent must.
    to: []const u8,
    /// Preflight and transform in memory only; writes nothing.
    dry_run: bool = false,
    /// The one captured conversion date, used to seed absent routines.
    today: platform.Date,
};

pub const Report = struct {
    from: []const u8,
    to: []const u8,
    dry_run: bool,
    /// `rewritten` (config.json was present) or `synthesized` (absent and
    /// established as format 1; policy arrays are empty).
    config: []const u8,
    /// `transformed`, `unchanged` or `seeded` (absent routine file).
    routines: []const u8,
    /// Regular files in the copy plan (or written to the stage).
    files: usize,
    /// Canonical task lines examined.
    tasks: usize,
    /// Reserved field names renamed across those task lines.
    fields_renamed: usize,
    /// True only after the completed copy passed the strict format-2 check;
    /// always false for a dry run, which cannot stage a copy to check.
    checked: bool,
};

/// Convert a format-1 store at `opts.from` into a new format-2 store at
/// `opts.to`. `diagnostics`, when provided, receives human-readable detail
/// for any refusal (and for every staged-check error) allocated from the
/// caller's `alloc`; the caller owns and frees the list.
pub fn run(io: std.Io, alloc: std.mem.Allocator, opts: Options, diagnostics: ?*std.ArrayList([]const u8)) !Report {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var c = Ctx{ .io = io, .a = arena.allocator(), .alloc = alloc, .diag = diagnostics };

    if (opts.from.len == 0) return c.fail("migrate needs a source path", .{}, error.InvalidWorkspace);
    if (opts.to.len == 0) return c.fail("migrate needs a destination path", .{}, error.InvalidWorkspace);

    const cwd = std.Io.Dir.cwd();

    // Source: an existing directory. A symlinked root is allowed; resolved
    // paths are used for the overlap check below.
    if (cwd.statFile(io, opts.from, .{})) |st| {
        if (st.kind != .directory) return c.fail("source is not a directory: {s}", .{opts.from}, error.InvalidWorkspace);
    } else |err| switch (err) {
        error.FileNotFound => return c.fail("source store not found: {s}", .{opts.from}, error.InvalidWorkspace),
        else => return err,
    }

    // Destination: absent — a dangling symlink counts as existing — with an
    // existing directory parent.
    if (cwd.statFile(io, opts.to, .{ .follow_symlinks = false })) |_| {
        return c.fail("destination already exists: {s}", .{opts.to}, error.DestinationExists);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const parent_path = std.fs.path.dirname(opts.to) orelse ".";
    if (cwd.statFile(io, parent_path, .{})) |st| {
        if (st.kind != .directory) return c.fail("destination parent is not a directory: {s}", .{parent_path}, error.InvalidWorkspace);
    } else |err| switch (err) {
        error.FileNotFound => return c.fail("destination parent does not exist: {s}", .{parent_path}, error.InvalidWorkspace),
        else => return err,
    }
    const base_to = std.fs.path.basename(opts.to);
    if (base_to.len == 0 or std.mem.eql(u8, base_to, ".") or std.mem.eql(u8, base_to, ".."))
        return c.fail("destination must name a directory: {s}", .{opts.to}, error.InvalidWorkspace);

    const real_from = try realPath(&c, opts.from);
    const real_parent = try realPath(&c, parent_path);
    const real_to = try std.fs.path.join(c.a, &.{ real_parent, base_to });
    if (nested(real_to, real_from) or nested(real_from, real_to))
        return c.fail("source and destination overlap: {s} and {s}", .{ opts.from, opts.to }, error.PathOverlap);

    // Read-only coordination with existing ztd writers. `Store.lock(false)`
    // creates nothing when the source has no lock file; it is skipped
    // entirely for a dry run, which writes nothing anywhere.
    var src = try store_mod.Store.open(io, c.a, opts.from);
    defer src.deinit();
    if (!opts.dry_run) try src.lock(false);
    if (src.exists(".state/pending.json"))
        return c.fail("source has a pending journal (.state/pending.json); run `ztd recover` first", .{}, error.PendingTransaction);

    const before = try snapshot(&c, opts.from);

    for (canonical_lists) |rel| {
        if (findEntry(before, rel) == null)
            return c.fail("source is missing the canonical list {s}", .{rel}, error.InvalidWorkspace);
    }
    if (findEntry(before, "contexts.md") == null)
        return c.fail("source is missing contexts.md", .{}, error.InvalidWorkspace);

    var st: Stats = .{};
    var seen: std.ArrayList([]const u8) = .empty;
    var list_out: [canonical_lists.len][]const u8 = undefined;
    for (canonical_lists, 0..) |rel, i| {
        list_out[i] = try convertList(&c, rel, findEntry(before, rel).?.bytes, &seen, &st);
    }

    const contexts_out = try convertContexts(&c, findEntry(before, "contexts.md").?.bytes, &st);

    const routines_entry = findEntry(before, routine.path);
    var routines_out: []const u8 = undefined;
    if (routines_entry) |e| {
        routines_out = try convertRoutines(&c, e.bytes, &st);
        // Rows are arena-owned; the parse itself is the validation.
        _ = routine.parse(c.a, routines_out) catch |err| switch (err) {
            error.DuplicateId => return c.fail("routines/state.md: duplicate routine id", .{}, error.DuplicateId),
            error.MalformedRoutine => return c.fail("routines/state.md: malformed or empty routine table", .{}, error.MalformedRoutine),
            else => return err,
        };
    } else {
        routines_out = try seedRoutines(&c, opts.today);
    }

    const config_entry = findEntry(before, "config.json");
    var config_out: []const u8 = undefined;
    var config_synthesized = false;
    if (config_entry) |e| {
        config_out = try convertConfig(&c, e.bytes);
    } else {
        if (!(st.legacy_evidence or st.contexts_evidence or st.routines_evidence))
            return c.fail(
                "config.json is missing and nothing establishes a format-1 source (need a legacy task field, a `Contexto` contexts.md header or a format-1 routine token)",
                .{},
                error.AmbiguousSource,
            );
        config_out = try synthesizeConfig(&c);
        config_synthesized = true;
    }
    // An established format-1 store must not carry format-2 reserved keys:
    // converting one would silently change the meaning of user data.
    if (st.english) return c.fail("mixed format signals: {s}", .{st.english_where}, error.MixedSignals);

    var plan: std.ArrayList(PlanEntry) = .empty;
    var files: usize = 0;
    for (before) |e| {
        if (e.kind == .directory) {
            try plan.append(c.a, .{ .rel = e.rel, .kind = .directory, .bytes = "" });
            continue;
        }
        const bytes: []const u8 = blk: {
            if (canonicalIndex(e.rel)) |i| break :blk list_out[i];
            if (std.mem.eql(u8, e.rel, "contexts.md")) break :blk contexts_out;
            if (std.mem.eql(u8, e.rel, "config.json")) break :blk config_out;
            if (std.mem.eql(u8, e.rel, routine.path)) break :blk routines_out;
            break :blk e.bytes;
        };
        try plan.append(c.a, .{ .rel = e.rel, .kind = .file, .bytes = bytes });
        files += 1;
    }
    if (config_entry == null) {
        try plan.append(c.a, .{ .rel = "config.json", .kind = .file, .bytes = config_out });
        files += 1;
    }
    if (routines_entry == null) {
        try plan.append(c.a, .{ .rel = routine.path, .kind = .file, .bytes = routines_out });
        files += 1;
    }

    var report = Report{
        .from = opts.from,
        .to = opts.to,
        .dry_run = opts.dry_run,
        .config = if (config_synthesized) "synthesized" else "rewritten",
        .routines = if (routines_entry == null)
            "seeded"
        else if (std.mem.eql(u8, routines_entry.?.bytes, routines_out))
            "unchanged"
        else
            "transformed",
        .files = files,
        .tasks = st.tasks,
        .fields_renamed = st.fields_renamed,
        .checked = false,
    };

    if (opts.dry_run) {
        const after = try snapshot(&c, opts.from);
        if (!sameSnapshot(before, after)) return c.fail("source changed during the dry run", .{}, error.SourceChanged);
        return report;
    }

    // Private sibling stage of the destination, unique per attempt.
    const stage_name = try stageName(&c, base_to);
    var parent_dir = try openDirPath(io, parent_path, .{});
    defer parent_dir.close(io);
    if (parent_dir.statFile(io, stage_name, .{ .follow_symlinks = false })) |_| {
        return c.fail("staging path already exists: {s}", .{stage_name}, error.PathAlreadyExists);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try parent_dir.createDirPath(io, stage_name);
    var stage_live = true;
    defer if (stage_live) parent_dir.deleteTree(io, stage_name) catch {};
    const stage_path = try std.fs.path.join(c.a, &.{ parent_path, stage_name });

    {
        var stage_store = try store_mod.Store.open(io, c.a, stage_path);
        defer stage_store.deinit();
        for (plan.items) |p| switch (p.kind) {
            .directory => stage_store.dir.createDirPath(io, p.rel) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            },
            .file => {
                if (std.fs.path.dirname(p.rel)) |d| stage_store.dir.createDirPath(io, d) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                try stage_store.writeAtomic(p.rel, p.bytes);
            },
        };
    }

    // The completed copy must pass the strict format-2 checker before it can
    // become the destination; every error is reported through diagnostics.
    {
        var eng = try engine.Engine.init(io, c.a, stage_path, opts.today, false);
        defer eng.deinit();
        const res = try eng.check(true);
        if (res.errors.len > 0) {
            for (res.errors) |e| appendDiag(&c, e);
            return c.fail("the staged copy failed the strict format-2 check ({d} error(s))", .{res.errors.len}, error.StageInvalid);
        }
    }

    const after = try snapshot(&c, opts.from);
    if (!sameSnapshot(before, after))
        return c.fail("source changed during conversion; nothing was written to the destination", .{}, error.SourceChanged);

    // No-replace promotion: on any failure the destination stays absent and
    // only our own stage is removed. Never a replacing rename.
    std.Io.Dir.renamePreserve(parent_dir, stage_name, parent_dir, base_to, io) catch |err| switch (err) {
        error.PathAlreadyExists => return c.fail("destination appeared during conversion: {s}", .{opts.to}, error.DestinationExists),
        else => return err,
    };
    stage_live = false;
    // Same durability step as `Store.writeAtomic`: the rename is on disk.
    if (builtin.os.tag != .windows) {
        _ = std.c.fsync(parent_dir.handle);
    }

    report.checked = true;
    return report;
}

/// Stable JSON codes for migration-specific refusals; shared refusals fall
/// through to `engine.errorName`.
pub fn errorName(err: anyerror) []const u8 {
    return switch (err) {
        error.AmbiguousSource => "ambiguous_source",
        error.MixedSignals => "mixed_signals",
        error.KeyCollision => "key_collision",
        error.DestinationExists => "destination_exists",
        error.PathOverlap => "path_overlap",
        error.UnsupportedEntry => "unsupported_entry",
        error.StageInvalid => "stage_invalid",
        error.SourceChanged => "source_changed",
        else => engine.errorName(err),
    };
}

const Ctx = struct {
    io: std.Io,
    /// Run-scoped arena: all conversion data lives exactly as long as `run`.
    a: std.mem.Allocator,
    /// Caller's allocator: diagnostics outlive the arena.
    alloc: std.mem.Allocator,
    diag: ?*std.ArrayList([]const u8),

    fn fail(self: *const Ctx, comptime fmt: []const u8, args: anytype, err: anyerror) anyerror {
        if (self.diag) |d| {
            const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return err;
            d.append(self.alloc, msg) catch {};
        }
        return err;
    }
};

fn appendDiag(c: *Ctx, msg: []const u8) void {
    if (c.diag) |d| {
        const copy = c.alloc.dupe(u8, msg) catch return;
        d.append(c.alloc, copy) catch {};
    }
}

const Stats = struct {
    tasks: usize = 0,
    fields_renamed: usize = 0,
    /// A legacy reserved field on a canonical task line.
    legacy_evidence: bool = false,
    /// A format-1 routine header or cadence token.
    routines_evidence: bool = false,
    /// A recognized format-1 contexts.md header cell.
    contexts_evidence: bool = false,
    /// A format-2 reserved key found in an established format-1 store.
    english: bool = false,
    english_where: []const u8 = "",
};

const EntryKind = enum { file, directory };

const Entry = struct {
    rel: []const u8,
    kind: EntryKind,
    bytes: []const u8,
    hash: [32]u8,
};

const PlanEntry = struct {
    rel: []const u8,
    kind: EntryKind,
    bytes: []const u8,
};

fn realPath(c: *Ctx, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(c.io, path, &buf);
    return c.a.dupe(u8, buf[0..n]);
}

/// True when `inner` is `outer` or lives inside it, comparing resolved paths.
fn nested(inner: []const u8, outer: []const u8) bool {
    if (std.mem.eql(u8, inner, outer)) return true;
    if (outer.len == 0) return false;
    if (outer[outer.len - 1] == std.fs.path.sep) return std.mem.startsWith(u8, inner, outer);
    if (!std.mem.startsWith(u8, inner, outer)) return false;
    return inner.len > outer.len and inner[outer.len] == std.fs.path.sep;
}

fn openDirPath(io: std.Io, path: []const u8, opts: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, opts);
    return std.Io.Dir.cwd().openDir(io, path, opts);
}

/// Inventory of the copied set: every regular file (raw bytes plus SHA-256)
/// and every directory below `root`, excluding top-level `.git` and `.state`.
/// Symlinks and special files are refused instead of followed or read.
fn snapshot(c: *Ctx, root: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var root_dir = try openDirPath(c.io, root, .{ .iterate = true });
    defer root_dir.close(c.io);
    try walk(c, &root_dir, "", &out);
    std.mem.sort(Entry, out.items, {}, lessThan);
    return out.toOwnedSlice(c.a);
}

fn walk(c: *Ctx, dir: *std.Io.Dir, prefix: []const u8, out: *std.ArrayList(Entry)) !void {
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (prefix.len == 0 and isExcluded(entry.name)) continue;
        const rel = if (prefix.len == 0)
            try c.a.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(c.a, "{s}/{s}", .{ prefix, entry.name });
        // lstat: a symlink or special file is rejected by kind before any read.
        const st = try dir.statFile(c.io, entry.name, .{ .follow_symlinks = false });
        switch (st.kind) {
            .directory => {
                try out.append(c.a, .{ .rel = rel, .kind = .directory, .bytes = "", .hash = @splat(0) });
                var sub = try dir.openDir(c.io, entry.name, .{ .iterate = true });
                defer sub.close(c.io);
                try walk(c, &sub, rel, out);
            },
            .file => {
                const bytes = try dir.readFileAlloc(c.io, entry.name, c.a, .limited(store_mod.max_file_bytes));
                var digest: [32]u8 = undefined;
                Sha256.hash(bytes, &digest, .{});
                try out.append(c.a, .{ .rel = rel, .kind = .file, .bytes = bytes, .hash = digest });
            },
            else => return c.fail(
                "{s}: unsupported entry ({s}); only regular files and directories can be converted",
                .{ rel, @tagName(st.kind) },
                error.UnsupportedEntry,
            ),
        }
    }
}

fn isExcluded(name: []const u8) bool {
    for (excluded_top) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.lessThan(u8, lhs.rel, rhs.rel);
}

fn findEntry(entries: []const Entry, rel: []const u8) ?*const Entry {
    for (entries) |*e| if (std.mem.eql(u8, e.rel, rel)) return e;
    return null;
}

fn sameSnapshot(a: []const Entry, b: []const Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.rel, y.rel)) return false;
        if (x.kind != y.kind) return false;
        if (x.kind == .file and !std.mem.eql(u8, &x.hash, &y.hash)) return false;
    }
    return true;
}

fn canonicalIndex(rel: []const u8) ?usize {
    for (canonical_lists, 0..) |l, i| if (std.mem.eql(u8, l, rel)) return i;
    return null;
}

fn renameTarget(key: []const u8) ?[]const u8 {
    for (field_renames) |r| if (std.mem.eql(u8, r.from, key)) return r.to;
    return null;
}

fn isV2Reserved(key: []const u8) bool {
    for (field_renames) |r| if (std.mem.eql(u8, r.to, key)) return true;
    return false;
}

fn lookup(map: []const FieldRename, token: []const u8) ?[]const u8 {
    for (map) |r| if (std.mem.eql(u8, r.from, token)) return r.to;
    return null;
}

/// Translate reserved field names on one canonical list. Lines that are not
/// canonical task lines keep their exact bytes; a task line with no legacy
/// field is validated but also kept byte for byte, so only renamed lines are
/// re-rendered. Malformed `- [` lines, duplicate ids and renaming collisions
/// fail closed with `file:line` diagnostics.
fn convertList(c: *Ctx, rel: []const u8, bytes: []const u8, seen: *std.ArrayList([]const u8), st: *Stats) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var line_no: usize = 0;
    var first = true;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        if (!first) try out.append(c.a, '\n');
        first = false;
        const has_cr = raw.len > 0 and raw[raw.len - 1] == '\r';
        const line = if (has_cr) raw[0 .. raw.len - 1] else raw;
        if (std.mem.startsWith(u8, line, "- [")) {
            const parsed = model.parseLine(c.a, line) catch |err| switch (err) {
                error.MalformedTask, error.InvalidId => return c.fail("{s}:{d}: malformed task", .{ rel, line_no }, error.MalformedTask),
                else => return err,
            };
            const task = parsed.?;
            st.tasks += 1;
            for (seen.items) |id| {
                if (std.mem.eql(u8, id, task.id))
                    return c.fail("{s}:{d}: duplicate id {s}", .{ rel, line_no, task.id }, error.DuplicateId);
            }
            try seen.append(c.a, task.id);

            var renamed: usize = 0;
            for (task.fields.items) |*f| {
                if (isV2Reserved(f.key)) {
                    st.english = true;
                    if (st.english_where.len == 0)
                        st.english_where = try std.fmt.allocPrint(c.a, "{s}:{d} ({s})", .{ rel, line_no, f.key });
                    continue;
                }
                const target = renameTarget(f.key) orelse continue;
                st.legacy_evidence = true;
                for (task.fields.items) |other| {
                    if (std.mem.eql(u8, other.key, target))
                        return c.fail(
                            "{s}:{d}: {s} would rename to {s}, already present on {s}",
                            .{ rel, line_no, f.key, target, task.id },
                            error.KeyCollision,
                        );
                }
                // The rename is a pointer swap onto a static spelling: field
                // order and values are untouched and no `Task.set` can collide.
                f.key = target;
                renamed += 1;
            }
            st.fields_renamed += renamed;
            const rendered: []const u8 = if (renamed > 0) try task.render(c.a) else line;
            try out.appendSlice(c.a, rendered);
        } else {
            try out.appendSlice(c.a, line);
        }
        if (has_cr) try out.append(c.a, '\r');
    }
    return out.toOwnedSlice(c.a);
}

/// Translate recognized header cells in the first table row of `contexts.md`.
/// Every other byte of the file is preserved.
fn convertContexts(c: *Ctx, bytes: []const u8, st: *Stats) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var header_done = false;
    var first = true;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        if (!first) try out.append(c.a, '\n');
        first = false;
        const has_cr = raw.len > 0 and raw[raw.len - 1] == '\r';
        const line = if (has_cr) raw[0 .. raw.len - 1] else raw;
        var emit = line;
        if (!header_done) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '|') {
                header_done = true;
                emit = try translateCells(c, line, &context_header_renames, &st.contexts_evidence);
            }
        }
        try out.appendSlice(c.a, emit);
        if (has_cr) try out.append(c.a, '\r');
    }
    return out.toOwnedSlice(c.a);
}

/// Replace recognized tokens in the `|`-separated cells of one line,
/// preserving cell spacing; returns the original slice when nothing matched.
fn translateCells(c: *Ctx, line: []const u8, map: []const FieldRename, evidence: *bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    var first = true;
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |part| {
        if (!first) try out.append(c.a, '|');
        first = false;
        const trimmed = std.mem.trim(u8, part, " \t");
        if (lookup(map, trimmed)) |replacement| {
            const ls = std.mem.trimStart(u8, part, " \t");
            const ts = std.mem.trimEnd(u8, ls, " \t");
            try out.appendSlice(c.a, part[0 .. part.len - ls.len]);
            try out.appendSlice(c.a, replacement);
            try out.appendSlice(c.a, ls[ts.len..]);
            changed = true;
            evidence.* = true;
        } else {
            try out.appendSlice(c.a, part);
        }
    }
    return if (changed) try out.toOwnedSlice(c.a) else line;
}

/// Translate the header/cadence/day tokens of a present `routines/state.md`.
/// Ids and dates keep their exact bytes; the result is validated by
/// `routine.parse` afterwards, so unknown tokens fail rather than pass.
fn convertRoutines(c: *Ctx, bytes: []const u8, st: *Stats) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        if (!first) try out.append(c.a, '\n');
        first = false;
        const has_cr = raw.len > 0 and raw[raw.len - 1] == '\r';
        const line = if (has_cr) raw[0 .. raw.len - 1] else raw;
        try out.appendSlice(c.a, try transformRoutineLine(c, line, st));
        if (has_cr) try out.append(c.a, '\r');
    }
    return out.toOwnedSlice(c.a);
}

fn transformRoutineLine(c: *Ctx, line: []const u8, st: *Stats) ![]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 2 or trimmed[0] != '|' or trimmed[trimmed.len - 1] != '|') return line;
    var cells: [3][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], '|');
    while (it.next()) |cell| {
        if (count == cells.len) return line; // wrong shape: routine.parse rejects it
        cells[count] = cell;
        count += 1;
    }
    if (count != 3) return line;

    const c0 = std.mem.trim(u8, cells[0], " \t");
    const c1 = std.mem.trim(u8, cells[1], " \t");
    const c2 = std.mem.trim(u8, cells[2], " \t");
    const is_header = (std.mem.eql(u8, c0, "routine") or std.mem.eql(u8, c0, "rutina")) and
        (std.mem.eql(u8, c1, "cadence") or std.mem.eql(u8, c1, "cadencia"));
    if (is_header) return translateCells(c, line, &routine_header_renames, &st.routines_evidence);
    if (allDash(c0) and allDash(c1) and allDash(c2)) return line;

    const cadence = (try translateCadence(c, c1, st)) orelse return line;
    // Rebuild with only the cadence cell's token replaced: ids, dates and all
    // cell spacing stay byte exact.
    const lead_len = line.len - std.mem.trimStart(u8, line, " \t").len;
    const rest = line[lead_len..];
    const trail_len = rest.len - std.mem.trimEnd(u8, rest, " \t").len;
    const raw_cadence = cells[1];
    const ls = std.mem.trimStart(u8, raw_cadence, " \t");
    const ts = std.mem.trimEnd(u8, ls, " \t");
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(c.a, line[0..lead_len]);
    try out.append(c.a, '|');
    try out.appendSlice(c.a, cells[0]);
    try out.append(c.a, '|');
    try out.appendSlice(c.a, raw_cadence[0 .. raw_cadence.len - ls.len]);
    try out.appendSlice(c.a, cadence);
    try out.appendSlice(c.a, ls[ts.len..]);
    try out.append(c.a, '|');
    try out.appendSlice(c.a, cells[2]);
    try out.append(c.a, '|');
    try out.appendSlice(c.a, rest[rest.len - trail_len ..]);
    return out.toOwnedSlice(c.a);
}

fn translateCadence(c: *Ctx, cadence: []const u8, st: *Stats) !?[]const u8 {
    if (std.mem.eql(u8, cadence, "diaria")) {
        st.routines_evidence = true;
        return "daily";
    }
    if (std.mem.startsWith(u8, cadence, "semanal:")) {
        st.routines_evidence = true;
        const day = lookup(&day_renames, cadence["semanal:".len..]) orelse cadence["semanal:".len..];
        return try std.fmt.allocPrint(c.a, "weekly:{s}", .{day});
    }
    if (std.mem.startsWith(u8, cadence, "weekly:")) {
        const day = cadence["weekly:".len..];
        if (lookup(&day_renames, day)) |mapped| {
            st.routines_evidence = true;
            return try std.fmt.allocPrint(c.a, "weekly:{s}", .{mapped});
        }
    }
    return null; // already v2, or invalid: routine.parse decides
}

fn allDash(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| if (ch != '-') return false;
    return true;
}

/// The current v2 defaults at the captured conversion date: an initial
/// scheduling baseline, not a record of completed history.
fn seedRoutines(c: *Ctx, today: platform.Date) ![]u8 {
    var buf: [10]u8 = undefined;
    const date = today.format(&buf);
    return std.fmt.allocPrint(c.a,
        \\# Routine state
        \\
        \\| routine | cadence | last |
        \\| --- | --- | --- |
        \\| inbox | daily | {s} |
        \\| plan | daily | {s} |
        \\| review | weekly:sat | {s} |
        \\
    , .{ date, date, date });
}

/// `config.json` must be a JSON object declaring `format` 1. The format key
/// is rewritten in place and every other property (unknown keys included) is
/// preserved through the `Value` round trip.
fn convertConfig(c: *Ctx, bytes: []const u8) ![]u8 {
    var value = std.json.parseFromSliceLeaky(std.json.Value, c.a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => c.fail("config.json is not readable JSON", .{}, error.InvalidConfig),
        };
    };
    switch (value) {
        .object => |*obj| {
            const fmt = obj.get("format") orelse return c.fail("config.json does not declare \"format\"", .{}, error.InvalidConfig);
            switch (fmt) {
                .integer => |n| {
                    if (n != legacy_format)
                        return c.fail("config.json declares format {d}; only a format-{d} source can be converted", .{ n, legacy_format }, error.InvalidConfig);
                },
                else => return c.fail("config.json \"format\" must be {d}", .{legacy_format}, error.InvalidConfig),
            }
            obj.getPtr("format").?.* = .{ .integer = config_mod.supported_format };
        },
        else => return c.fail("config.json must be a JSON object", .{}, error.InvalidConfig),
    }
    const text = try std.json.Stringify.valueAlloc(c.a, value, .{});
    return std.fmt.allocPrint(c.a, "{s}\n", .{text});
}

fn synthesizeConfig(c: *Ctx) ![]u8 {
    return std.fmt.allocPrint(
        c.a,
        "{{\"format\":{d},\"policy\":{{\"requireClientFor\":[],\"clientOnlyIn\":[]}}}}\n",
        .{config_mod.supported_format},
    );
}

fn stageName(c: *Ctx, base: []const u8) ![]u8 {
    var suffix: [8]u8 = undefined;
    c.io.randomSecure(&suffix) catch {
        const ns: u64 = @truncate(@as(u128, @intCast(std.Io.Clock.real.now(c.io).nanoseconds)));
        std.mem.writeInt(u64, &suffix, ns, .little);
    };
    return std.fmt.allocPrint(c.a, ".{s}.ztd-stage-{x:0>16}", .{ base, std.mem.readInt(u64, &suffix, .little) });
}

// --- tests ---------------------------------------------------------------

const FileSpec = struct { rel: []const u8, data: []const u8 };

fn writeFiles(io: std.Io, alloc: std.mem.Allocator, root: []const u8, files: []const FileSpec) !void {
    const cwd = std.Io.Dir.cwd();
    for (files) |f| {
        const full = try std.fs.path.join(alloc, &.{ root, f.rel });
        if (std.fs.path.dirname(full)) |d| try cwd.createDirPath(io, d);
        try cwd.writeFile(io, .{ .sub_path = full, .data = f.data });
    }
}

fn dirNames(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| try out.append(alloc, try alloc.dupe(u8, e.name));
    const items = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return items;
}

fn testCtx(io: std.Io, alloc: std.mem.Allocator, a: std.mem.Allocator) Ctx {
    return .{ .io = io, .a = a, .alloc = alloc, .diag = null };
}

fn expectSourceUnchanged(io: std.Io, alloc: std.mem.Allocator, a: std.mem.Allocator, src: []const u8, before: []const Entry) !void {
    var c = testCtx(io, alloc, a);
    const after = try snapshot(&c, src);
    try std.testing.expect(sameSnapshot(before, after));
}

/// The fixture below is a complete format-1 store: Spanish reserved keys,
/// a `Contexto` header, format-1 routine tokens, unknown config properties,
/// a git directory and a `.state` lock that must not be copied.
const v1_files = [_]FileSpec{
    .{ .rel = "config.json", .data = "{\"format\":1,\"note\":\"keep me\",\"policy\":{\"requireClientFor\":[],\"clientOnlyIn\":[\"work\"]}}\n" },
    .{ .rel = "contexts.md", .data = "# Contextos\n\n| Contexto | Uso |\n| --- | --- |\n| personal | Asuntos personales |\n| work | Trabajo |\n" },
    .{ .rel = "inbox.md", .data = "# Bandeja\n\n- [ ] T-20261101-001 | Comprar \\| verduras | contexto: personal | capturada: 2026-11-01 | estimate: 2d\n" },
    .{ .rel = "lists/next.md", .data = "# Siguiente\n\n- [ ] T-20261102-001 | Llamar al banco | contexto: work | cliente: acme | proyecto: work/acme/demo | capturada: 2026-11-02\n" },
    .{ .rel = "lists/waiting.md", .data = "# Espera\n\n- [ ] T-20261103-001 | Firmar contrato | contexto: work | cliente: acme | espera: legal | capturada: 2026-11-03\n" },
    .{ .rel = "lists/someday.md", .data = "# Algún día\n\n" },
    .{ .rel = "lists/archive.md", .data = "# Archivo\n\n- [x] T-20261104-001 | Terminado | contexto: personal | resolución: hecho | cerrada: 2026-11-04\n" },
    .{ .rel = "lists/projects/work/acme/demo.md", .data = "# demo\n" },
    .{ .rel = "routines/state.md", .data = "# Rutinas\n\n| rutina | cadencia | último |\n| --- | --- | --- |\n| inbox | diaria | 2026-11-01 |\n| plan | diaria | 2026-11-05 |\n| review | semanal:dom | 2026-11-02 |\n" },
    .{ .rel = "README.md", .data = "# store\n" },
    .{ .rel = ".gitignore", .data = ".state/\n" },
    .{ .rel = ".git/config", .data = "gitdata\n" },
    .{ .rel = ".state/lock", .data = "locked\n" },
};

test "converts a format-1 store with routines and preserves everything else" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = try a.dupe(u8, buf[0..n]);
    const src = try std.fs.path.join(a, &.{ base, "src" });
    const dst = try std.fs.path.join(a, &.{ base, "dst" });
    try writeFiles(io, a, src, &v1_files);

    var c = testCtx(io, alloc, a);
    const before = try snapshot(&c, src);

    var diag: std.ArrayList([]const u8) = .empty;
    defer {
        for (diag.items) |m| alloc.free(m);
        diag.deinit(alloc);
    }
    const today = try platform.parseDate("2026-11-17");
    const rep = try run(io, alloc, .{ .from = src, .to = dst, .today = today }, &diag);
    try std.testing.expectEqual(@as(usize, 0), diag.items.len);
    try std.testing.expect(!rep.dry_run);
    try std.testing.expect(rep.checked);
    try std.testing.expectEqualStrings("rewritten", rep.config);
    try std.testing.expectEqualStrings("transformed", rep.routines);
    try std.testing.expectEqual(@as(usize, 4), rep.tasks);
    try std.testing.expectEqual(@as(usize, 13), rep.fields_renamed);
    // config, contexts, five lists, project, routines, README, .gitignore
    try std.testing.expectEqual(@as(usize, 11), rep.files);

    // Field names, header cells, cadence and day tokens are translated;
    // titles, values, field order, ids and custom fields are untouched.
    const inbox = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, "inbox.md" }), alloc, .limited(1 << 20));
    defer alloc.free(inbox);
    try std.testing.expectEqualStrings(
        "# Bandeja\n\n- [ ] T-20261101-001 | Comprar \\| verduras | context: personal | captured_at: 2026-11-01 | estimate: 2d\n",
        inbox,
    );
    const contexts = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, "contexts.md" }), alloc, .limited(1 << 20));
    defer alloc.free(contexts);
    try std.testing.expect(std.mem.indexOf(u8, contexts, "| Context | Use |") != null);
    try std.testing.expect(std.mem.indexOf(u8, contexts, "| Contexto |") == null);

    const config_text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, "config.json" }), alloc, .limited(1 << 20));
    defer alloc.free(config_text);
    try std.testing.expect(std.mem.indexOf(u8, config_text, "\"format\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_text, "\"note\":\"keep me\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_text, "\"clientOnlyIn\":[\"work\"]") != null);

    const routines_text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, routine.path }), alloc, .limited(1 << 20));
    defer alloc.free(routines_text);
    try std.testing.expect(std.mem.indexOf(u8, routines_text, "| routine | cadence | last |") != null);
    // Row dates are preserved exactly; only cadence/day tokens change.
    try std.testing.expect(std.mem.indexOf(u8, routines_text, "| inbox | daily | 2026-11-01 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines_text, "| plan | daily | 2026-11-05 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines_text, "| review | weekly:sun | 2026-11-02 |") != null);

    // Unrelated bytes are byte-identical; `.git` administration and `.state`
    // are not copied.
    const project = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, "lists/projects/work/acme/demo.md" }), alloc, .limited(1 << 20));
    defer alloc.free(project);
    try std.testing.expectEqualStrings("# demo\n", project);
    const gitignore = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, ".gitignore" }), alloc, .limited(1 << 20));
    defer alloc.free(gitignore);
    try std.testing.expectEqualStrings(".state/\n", gitignore);
    try std.testing.expect(!store_mod.pathExists(io, try std.fs.path.join(a, &.{ dst, ".git" })));
    try std.testing.expect(!store_mod.pathExists(io, try std.fs.path.join(a, &.{ dst, ".state" })));

    // The destination is a clean format-2 store under the strict checker.
    var eng = try engine.Engine.init(io, a, dst, today, false);
    defer eng.deinit();
    const res = try eng.check(true);
    try std.testing.expectEqual(@as(usize, 0), res.errors.len);
    try std.testing.expectEqual(@as(usize, 0), res.warnings.len);
    try std.testing.expect(!store_mod.pathExists(io, try std.fs.path.join(a, &.{ dst, ".state" })));

    // The source is untouched, lock included: the shared lock neither writes
    // the existing lock file nor adds anything to `.state`.
    try expectSourceUnchanged(io, alloc, a, src, before);
    const lock_text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ src, ".state/lock" }), alloc, .limited(1 << 20));
    defer alloc.free(lock_text);
    try std.testing.expectEqualStrings("locked\n", lock_text);
    const state_names = try dirNames(io, a, try std.fs.path.join(a, &.{ src, ".state" }));
    try std.testing.expectEqualStrings("lock", try std.mem.join(a, ",", state_names));
}

test "missing config is accepted only with legacy evidence and synthesises empty policy" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = try a.dupe(u8, buf[0..n]);
    const src = try std.fs.path.join(a, &.{ base, "src" });
    const dst = try std.fs.path.join(a, &.{ base, "dst" });
    // Canonical v1 structure, `Contexto` evidence, no config, no routines.
    try writeFiles(io, a, src, &.{
        .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | Personal |\n" },
        .{ .rel = "inbox.md", .data = "- [ ] T-20261101-001 | Una cosa | contexto: personal | capturada: 2026-11-01\n" },
        .{ .rel = "lists/next.md", .data = "# Siguiente\n\n" },
        .{ .rel = "lists/waiting.md", .data = "# Espera\n\n" },
        .{ .rel = "lists/someday.md", .data = "# Algún día\n\n" },
        .{ .rel = "lists/archive.md", .data = "# Archivo\n\n" },
    });

    var c = testCtx(io, alloc, a);
    const before = try snapshot(&c, src);
    const today = try platform.parseDate("2026-11-17");
    const rep = try run(io, alloc, .{ .from = src, .to = dst, .today = today }, null);
    try std.testing.expectEqualStrings("synthesized", rep.config);
    try std.testing.expectEqualStrings("seeded", rep.routines);
    try std.testing.expect(rep.checked);

    const config_text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, "config.json" }), alloc, .limited(1 << 20));
    defer alloc.free(config_text);
    try std.testing.expectEqualStrings(
        "{\"format\":2,\"policy\":{\"requireClientFor\":[],\"clientOnlyIn\":[]}}\n",
        config_text,
    );

    // The absent routine file is seeded at the conversion date: an initial
    // baseline, not completed history.
    const routines_text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dst, routine.path }), alloc, .limited(1 << 20));
    defer alloc.free(routines_text);
    try std.testing.expect(std.mem.indexOf(u8, routines_text, "| inbox | daily | 2026-11-17 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines_text, "| plan | daily | 2026-11-17 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines_text, "| review | weekly:sat | 2026-11-17 |") != null);

    var eng = try engine.Engine.init(io, a, dst, today, false);
    defer eng.deinit();
    const res = try eng.check(true);
    try std.testing.expectEqual(@as(usize, 0), res.errors.len);
    try std.testing.expectEqual(@as(usize, 0), res.warnings.len);

    try expectSourceUnchanged(io, alloc, a, src, before);
}

test "dry run transforms in memory and writes nothing" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = try a.dupe(u8, buf[0..n]);
    const src = try std.fs.path.join(a, &.{ base, "src" });
    const dst = try std.fs.path.join(a, &.{ base, "dst" });
    try writeFiles(io, a, src, &v1_files);

    var c = testCtx(io, alloc, a);
    const before = try snapshot(&c, src);
    const names_before = try dirNames(io, a, base);

    const today = try platform.parseDate("2026-11-17");
    const rep = try run(io, alloc, .{ .from = src, .to = dst, .dry_run = true, .today = today }, null);
    try std.testing.expect(rep.dry_run);
    // The strict checker needs a real staged directory; a dry run cannot run it.
    try std.testing.expect(!rep.checked);
    try std.testing.expectEqualStrings("rewritten", rep.config);
    try std.testing.expectEqual(@as(usize, 11), rep.files);
    try std.testing.expectEqual(@as(usize, 13), rep.fields_renamed);

    try std.testing.expect(!store_mod.pathExists(io, dst));
    const names_after = try dirNames(io, a, base);
    try std.testing.expectEqualStrings(
        try std.mem.join(a, ",", names_before),
        try std.mem.join(a, ",", names_after),
    );
    try expectSourceUnchanged(io, alloc, a, src, before);
}

test "dry run on a broken store also writes nothing" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = try a.dupe(u8, buf[0..n]);
    const src = try std.fs.path.join(a, &.{ base, "src" });
    const dst = try std.fs.path.join(a, &.{ base, "dst" });
    try writeFiles(io, a, src, &.{
        .{ .rel = "config.json", .data = "{\"format\":1}\n" },
        .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
        .{ .rel = "inbox.md", .data = "- [ ] not a task\n" },
        .{ .rel = "lists/next.md", .data = "" },
        .{ .rel = "lists/waiting.md", .data = "" },
        .{ .rel = "lists/someday.md", .data = "" },
        .{ .rel = "lists/archive.md", .data = "" },
    });

    var c = testCtx(io, alloc, a);
    const before = try snapshot(&c, src);
    const names_before = try dirNames(io, a, base);

    const today = try platform.parseDate("2026-11-17");
    try std.testing.expectError(error.MalformedTask, run(io, alloc, .{ .from = src, .to = dst, .dry_run = true, .today = today }, null));
    try std.testing.expect(!store_mod.pathExists(io, dst));
    const names_after = try dirNames(io, a, base);
    try std.testing.expectEqualStrings(
        try std.mem.join(a, ",", names_before),
        try std.mem.join(a, ",", names_after),
    );
    try expectSourceUnchanged(io, alloc, a, src, before);
}

/// Every refusal leaves the destination absent, the source byte-identical and
/// no staging directory behind in the parent.
fn expectRefusal(io: std.Io, alloc: std.mem.Allocator, a: std.mem.Allocator, src: []const u8, dst: []const u8, files: []const FileSpec, expected: anyerror) !void {
    try writeFiles(io, a, src, files);
    var c = testCtx(io, alloc, a);
    // The baseline cannot hash a symlink or special file — that refusal is
    // the very behaviour under test — so the source-hash comparison is
    // skipped exactly when the baseline itself is refused; the top-level
    // listing is compared either way.
    const before = snapshot(&c, src) catch |err| blk: {
        try std.testing.expectEqual(expected, err);
        break :blk null;
    };
    const names_before = try dirNames(io, a, std.fs.path.dirname(dst).?);

    var diag: std.ArrayList([]const u8) = .empty;
    defer {
        for (diag.items) |m| alloc.free(m);
        diag.deinit(alloc);
    }
    const today = try platform.parseDate("2026-11-17");
    try std.testing.expectError(expected, run(io, alloc, .{ .from = src, .to = dst, .today = today }, &diag));
    try std.testing.expect(!store_mod.pathExists(io, dst));
    const names_after = try dirNames(io, a, std.fs.path.dirname(dst).?);
    try std.testing.expectEqualStrings(
        try std.mem.join(a, ",", names_before),
        try std.mem.join(a, ",", names_after),
    );
    if (before) |b| try expectSourceUnchanged(io, alloc, a, src, b);
}

const minimal_v1 = [_]FileSpec{
    .{ .rel = "config.json", .data = "{\"format\":1}\n" },
    .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
    .{ .rel = "inbox.md", .data = "# Bandeja\n\n" },
    .{ .rel = "lists/next.md", .data = "" },
    .{ .rel = "lists/waiting.md", .data = "" },
    .{ .rel = "lists/someday.md", .data = "" },
    .{ .rel = "lists/archive.md", .data = "" },
};

test "refuses ambiguous or mixed format signals" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No config and no v1 evidence: a store that is not established as v1.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "contexts.md", .data = "| Context | Use |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "# Inbox\n\n" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
        }, error.AmbiguousSource);
    }

    // Format-2 keys with no config: not a convertible source either.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "contexts.md", .data = "| Context | Use |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "- [ ] T-20261101-001 | New style | context: personal\n" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
        }, error.AmbiguousSource);
    }

    // Declared format 1 but carrying format-2 keys: mixed signals.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "- [ ] T-20261101-001 | Mixed | context: personal\n" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
        }, error.MixedSignals);
    }
}

test "refuses a key-renaming collision and malformed or duplicate tasks" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_]struct { name: []const u8, inbox: []const u8, next: []const u8, expected: anyerror }{
        // A legacy key that would land on an existing format-2 key.
        .{ .name = "collision", .inbox = "- [ ] T-20261101-001 | C | contexto: personal | context: work\n", .next = "", .expected = error.KeyCollision },
        .{ .name = "malformed", .inbox = "- [ ] not a task\n", .next = "", .expected = error.MalformedTask },
        .{ .name = "duplicate fields", .inbox = "- [ ] T-20261101-001 | D | contexto: a | contexto: b\n", .next = "", .expected = error.MalformedTask },
        .{ .name = "duplicate ids", .inbox = "- [ ] T-20261101-001 | One | contexto: personal\n", .next = "- [ ] T-20261101-001 | Two | contexto: personal\n", .expected = error.DuplicateId },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = case.inbox },
            .{ .rel = "lists/next.md", .data = case.next },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
        }, case.expected);
    }
}

test "refuses a present but malformed, empty or unreadable routine table" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Unknown cadence token.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
            .{ .rel = "routines/state.md", .data = "| rutina | cadencia | último |\n| --- | --- | --- |\n| inbox | hourly | 2026-11-01 |\n" },
        }, error.MalformedRoutine);
    }

    // Empty table (no rows at all).
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
            .{ .rel = "routines/state.md", .data = "# Rutinas\n\n| rutina | cadencia | último |\n| --- | --- | --- |\n" },
        }, error.MalformedRoutine);
    }

    // Unreadable: a directory where the routine table must be. Any failure is
    // a refusal; nothing is written.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try writeFiles(io, a, src, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
        });
        try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ src, routine.path }));
        var c = testCtx(io, alloc, a);
        const before = try snapshot(&c, src);
        const today = try platform.parseDate("2026-11-17");
        var failed = false;
        if (run(io, alloc, .{ .from = src, .to = dst, .today = today }, null)) |_| {} else |_| failed = true;
        try std.testing.expect(failed);
        try std.testing.expect(!store_mod.pathExists(io, dst));
        try expectSourceUnchanged(io, alloc, a, src, before);
    }
}

test "refuses a pending journal, a non-format-1 config and missing structure" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Pending journal: inspected without creating any file.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        var files: [minimal_v1.len + 1]FileSpec = undefined;
        @memcpy(files[0..minimal_v1.len], &minimal_v1);
        files[minimal_v1.len] = .{ .rel = ".state/pending.json", .data = "{\"version\":1,\"files\":[]}\n" };
        try expectRefusal(io, alloc, a, src, dst, &files, error.PendingTransaction);
    }

    // A format-2 (or malformed) config is not a convertible source.
    for ([_]struct { data: []const u8, expected: anyerror }{
        .{ .data = "{\"format\":2}\n", .expected = error.InvalidConfig },
        .{ .data = "not json\n", .expected = error.InvalidConfig },
        .{ .data = "{\"policy\":{}}\n", .expected = error.InvalidConfig },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        var files: [minimal_v1.len]FileSpec = undefined;
        @memcpy(&files, &minimal_v1);
        files[0] = .{ .rel = "config.json", .data = case.data };
        try expectRefusal(io, alloc, a, src, dst, &files, case.expected);
    }

    // Missing canonical list: not a complete store.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
        }, error.InvalidWorkspace);
    }
}

test "refuses symlinks and special files in the copied tree" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A symlink where a canonical list belongs.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        // Only the directory needs to exist for the link itself.
        try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ src, "lists" }));
        const link = try std.fs.path.join(a, &.{ src, "lists/someday.md" });
        try std.Io.Dir.cwd().symLink(io, "../inbox.md", link, .{});
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
        }, error.UnsupportedEntry);
    }

    // A FIFO is a special file and must never be read (reading it would block).
    if (builtin.os.tag != .windows) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const base = try a.dupe(u8, buf[0..n]);
        const src = try std.fs.path.join(a, &.{ base, "src" });
        const dst = try std.fs.path.join(a, &.{ base, "dst" });
        try writeFiles(io, a, src, &minimal_v1);
        const pipe_path = try std.fs.path.join(a, &.{ src, "notes.pipe" });
        const pipe = try a.allocSentinel(u8, pipe_path.len, 0);
        @memcpy(pipe, pipe_path);
        try std.testing.expectEqual(@as(c_int, 0), mkfifo(pipe, 0o600));
        try expectRefusal(io, alloc, a, src, dst, &.{
            .{ .rel = "config.json", .data = "{\"format\":1}\n" },
            .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
            .{ .rel = "inbox.md", .data = "" },
            .{ .rel = "lists/next.md", .data = "" },
            .{ .rel = "lists/waiting.md", .data = "" },
            .{ .rel = "lists/someday.md", .data = "" },
            .{ .rel = "lists/archive.md", .data = "" },
        }, error.UnsupportedEntry);
    }
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;

test "refuses overlapping paths, an existing destination and a missing parent" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = try a.dupe(u8, buf[0..n]);
    const src = try std.fs.path.join(a, &.{ base, "src" });
    try writeFiles(io, a, src, &minimal_v1);

    var c = testCtx(io, alloc, a);
    const before = try snapshot(&c, src);
    const today = try platform.parseDate("2026-11-17");

    // Destination inside the source: refused before anything is written.
    try std.testing.expectError(
        error.PathOverlap,
        run(io, alloc, .{ .from = src, .to = try std.fs.path.join(a, &.{ src, "nested" }), .today = today }, null),
    );

    // Destination parent missing.
    try std.testing.expectError(
        error.InvalidWorkspace,
        run(io, alloc, .{ .from = src, .to = try std.fs.path.join(a, &.{ base, "absent", "dst" }), .today = today }, null),
    );

    // Source missing.
    try std.testing.expectError(
        error.InvalidWorkspace,
        run(io, alloc, .{ .from = try std.fs.path.join(a, &.{ base, "ghost" }), .to = try std.fs.path.join(a, &.{ base, "dst1" }), .today = today }, null),
    );

    // Existing destination directory, then a dangling symlink at the same path.
    const dst = try std.fs.path.join(a, &.{ base, "dst" });
    try std.Io.Dir.cwd().createDirPath(io, dst);
    try std.testing.expectError(error.DestinationExists, run(io, alloc, .{ .from = src, .to = dst, .today = today }, null));
    try std.Io.Dir.cwd().deleteTree(io, dst);
    try std.Io.Dir.cwd().symLink(io, "nowhere", dst, .{});
    try std.testing.expectError(error.DestinationExists, run(io, alloc, .{ .from = src, .to = dst, .today = today }, null));

    try expectSourceUnchanged(io, alloc, a, src, before);
}

test "a strict check failure keeps the destination absent and removes the stage" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = try a.dupe(u8, buf[0..n]);
    const src = try std.fs.path.join(a, &.{ base, "src" });
    const dst = try std.fs.path.join(a, &.{ base, "dst" });
    // Passes every preflight step; only the strict checker of the staged copy
    // rejects it (`captured_at` disagrees with the id date).
    try writeFiles(io, a, src, &.{
        .{ .rel = "config.json", .data = "{\"format\":1}\n" },
        .{ .rel = "contexts.md", .data = "| Contexto | Uso |\n| --- | --- |\n| personal | P |\n" },
        .{ .rel = "inbox.md", .data = "- [ ] T-20261111-001 | Mismatch | contexto: personal | capturada: 2026-01-01\n" },
        .{ .rel = "lists/next.md", .data = "" },
        .{ .rel = "lists/waiting.md", .data = "" },
        .{ .rel = "lists/someday.md", .data = "" },
        .{ .rel = "lists/archive.md", .data = "" },
    });

    var c = testCtx(io, alloc, a);
    const before = try snapshot(&c, src);
    const names_before = try dirNames(io, a, base);

    var diag: std.ArrayList([]const u8) = .empty;
    defer {
        for (diag.items) |m| alloc.free(m);
        diag.deinit(alloc);
    }
    const today = try platform.parseDate("2026-11-17");
    try std.testing.expectError(error.StageInvalid, run(io, alloc, .{ .from = src, .to = dst, .today = today }, &diag));
    var saw_detail = false;
    for (diag.items) |m| {
        if (std.mem.indexOf(u8, m, "captured_at does not match id date") != null) saw_detail = true;
    }
    try std.testing.expect(saw_detail);

    try std.testing.expect(!store_mod.pathExists(io, dst));
    const names_after = try dirNames(io, a, base);
    try std.testing.expectEqualStrings(
        try std.mem.join(a, ",", names_before),
        try std.mem.join(a, ",", names_after),
    );
    try expectSourceUnchanged(io, alloc, a, src, before);
}

test "the rename table covers exactly the legacy reserved keys" {
    try std.testing.expectEqual(model.legacy_fields.len, field_renames.len);
    for (model.legacy_fields) |key| try std.testing.expect(renameTarget(key) != null);
    for (field_renames) |r| try std.testing.expect(model.isLegacyField(r.from));
    for (field_renames) |r| try std.testing.expect(isV2Reserved(r.to));
}

test "migration error names are stable" {
    try std.testing.expectEqualStrings("ambiguous_source", errorName(error.AmbiguousSource));
    try std.testing.expectEqualStrings("mixed_signals", errorName(error.MixedSignals));
    try std.testing.expectEqualStrings("key_collision", errorName(error.KeyCollision));
    try std.testing.expectEqualStrings("destination_exists", errorName(error.DestinationExists));
    try std.testing.expectEqualStrings("path_overlap", errorName(error.PathOverlap));
    try std.testing.expectEqualStrings("unsupported_entry", errorName(error.UnsupportedEntry));
    try std.testing.expectEqualStrings("stage_invalid", errorName(error.StageInvalid));
    try std.testing.expectEqualStrings("source_changed", errorName(error.SourceChanged));
    try std.testing.expectEqualStrings("invalid_field", errorName(error.MalformedTask));
    try std.testing.expectEqualStrings("duplicate_id", errorName(error.DuplicateId));
    try std.testing.expectEqualStrings("pending_transaction", errorName(error.PendingTransaction));
    try std.testing.expectEqualStrings("invalid_workspace", errorName(error.InvalidWorkspace));
    try std.testing.expectEqualStrings("unsupported_format", errorName(error.InvalidConfig));
}
