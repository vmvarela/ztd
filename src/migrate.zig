//! Copy-only format-1 → format-2 store converter (English canonical v2).
//!
//! `run` reads an exact source store directory, converts the recognized
//! format-1 structural vocabulary into format 2, copies everything else
//! byte-for-byte, and promotes the staged result into a new exact
//! destination directory. The source is never written to and never locked;
//! the destination is never replaced.
//!
//! Interface (as wired by `ztd migrate --from --to [--dry-run]`):
//!
//!     run(io, alloc, opts: Options, diagnostics) !Report
//!     errorName(err) []const u8
//!
//! `Options.from` and `Options.to` are exact store directories (no `ztd`
//! suffix is appended); `Options.today` is the single date stamped when a
//! missing routine table must be seeded. `dry_run` performs the same
//! read-only preflight and in-memory structural transformation checks but
//! creates no files, directories, locks or reports; only the real staged run
//! performs the full v2 `Engine.check`, reported as `checked: true` (a dry
//! run reports `false`). A refusal — and every staged-check error — appends
//! human-readable lines to `diagnostics` when it is provided; the caller
//! owns the list.
//!
//! The error set is inferred: it contains every member of `Error` below plus
//! any I/O errors from `std.Io`. `errorName` maps them to CLI codes
//! (`ambiguous_source`, `mixed_signals`, `key_collision`, …) with the
//! engine's vocabulary as the fallback.
//!
//! A refusal returns an error: no destination is created and the CLI must
//! exit nonzero. `.git` and `.state` administration is excluded only at the
//! top level of the source; nested `.git`/`.state` content is ordinary
//! data and is copied.

const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const platform = @import("platform.zig");
const routine = @import("routine.zig");
const engine = @import("engine.zig");
const store_mod = @import("store.zig");

/// Domain errors of the conversion. `run` may also return any `std.Io` error.
pub const Error = error{
    SourceNotFound,
    DestinationExists,
    DestinationParentMissing,
    InvalidDestination,
    PathOverlap,
    PendingTransaction,
    InvalidStoreStructure,
    InvalidConfig,
    /// An explicit config.json format other than exactly 1.
    UnsupportedFormat,
    /// Missing config without any format-1 structural marker.
    AmbiguousSource,
    /// Missing config whose markers are format-2 or mixed.
    MixedSignals,
    MalformedTask,
    DuplicateId,
    KeyCollision,
    MalformedRoutine,
    /// A symlink or special file inside the copied tree.
    UnsupportedEntry,
    /// The source inventory changed while converting.
    SourceChanged,
    /// The staged strict format-2 check rejected the converted copy.
    StageInvalid,
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
    /// Source path exactly as passed by the caller.
    from: []const u8,
    /// Destination path exactly as passed by the caller.
    to: []const u8,
    dry_run: bool,
    /// `rewritten` (config.json was present) or `synthesized` (absent and
    /// established as format 1; policy arrays are empty).
    config: []const u8,
    /// `transformed` (existing table converted) or `seeded` (absent routine
    /// file, stamped with `seed_date`).
    routines: []const u8,
    /// Set when `routines` is `seeded`: the single captured date (YYYY-MM-DD).
    seed_date: ?[]const u8,
    /// Regular source files in the copy set (converted or copied verbatim).
    files: usize,
    /// Canonical task lines examined.
    tasks: usize,
    /// Reserved field names renamed across those task lines.
    fields_renamed: usize,
    /// True only after the completed copy passed the strict format-2 check;
    /// always false for a dry run, which cannot stage a copy to check.
    checked: bool,
};

/// Legacy task key → English format-2 key. Kept in lockstep with
/// `model.legacy_fields` (asserted by a test below).
const key_renames = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "contexto", .to = "context" },
    .{ .from = "cliente", .to = "client" },
    .{ .from = "proyecto", .to = "project" },
    .{ .from = "capturada", .to = "captured_at" },
    .{ .from = "cerrada", .to = "closed_at" },
    .{ .from = "espera", .to = "waiting_on" },
    .{ .from = "resolución", .to = "resolution" },
};

/// The seven canonical format-2 task keys; their presence is v2 evidence.
const english_keys = [_][]const u8{
    "context",   "client",     "project",    "captured_at",
    "closed_at", "waiting_on", "resolution",
};

const task_list_rels = [_][]const u8{
    "inbox.md",
    "lists/next.md",
    "lists/waiting.md",
    "lists/someday.md",
    "lists/archive.md",
};

/// Canonical structure every source must have: contexts plus the five lists.
const required_rels = [_][]const u8{
    "contexts.md",
    "inbox.md",
    "lists/next.md",
    "lists/waiting.md",
    "lists/someday.md",
    "lists/archive.md",
};

const routines_rel = "routines/state.md";
const config_rel = "config.json";
const contexts_rel = "contexts.md";

/// The synthesized config for the inferred path: format 2 and the baseline
/// empty policy arrays, nothing else.
const synthesized_config =
    "{\"format\":2,\"policy\":{\"requireClientFor\":[],\"clientOnlyIn\":[]}}\n";

const Special = enum { config, contexts, task_list, routines, verbatim };

/// Convert a format-1 store at `opts.from` into a new format-2 store at
/// `opts.to`. Both are exact directories: the source must exist, the
/// destination must not, and its parent must exist. Equality, overlap and
/// symlink aliases of the two paths are rejected. `diagnostics`, when
/// provided, receives one human-readable line per refusal and one line per
/// staged-check error; the strings come from `alloc` and the caller owns the
/// list.
pub fn run(
    io: std.Io,
    alloc: std.mem.Allocator,
    opts: Options,
    diagnostics: ?*std.ArrayList([]const u8),
) !Report {
    const source_path = opts.from;
    const destination_path = opts.to;
    const dry_run = opts.dry_run;
    const today = opts.today;

    // ---- path preflight: no writes, no locks, no source state ----
    var src = openExact(io, source_path) catch |err| switch (err) {
        error.FileNotFound => {
            note(diagnostics, alloc, "source store not found: {s}", .{source_path});
            return error.SourceNotFound;
        },
        else => return err,
    };
    defer src.close(io);
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_n = try src.realPath(io, &src_buf);
    const src_real = src_buf[0..src_n];

    const trimmed_dest = trimTrailingSeps(destination_path);
    const dest_base = std.fs.path.basename(trimmed_dest);
    if (dest_base.len == 0 or std.mem.eql(u8, dest_base, ".") or std.mem.eql(u8, dest_base, "..")) {
        note(diagnostics, alloc, "destination has no usable directory name: {s}", .{destination_path});
        return error.InvalidDestination;
    }
    const parent_path = std.fs.path.dirname(trimmed_dest) orelse ".";
    var parent = openExact(io, parent_path) catch |err| switch (err) {
        error.FileNotFound => {
            note(diagnostics, alloc, "destination parent does not exist: {s}", .{parent_path});
            return error.DestinationParentMissing;
        },
        else => return err,
    };
    defer parent.close(io);
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_n = try parent.realPath(io, &parent_buf);
    const parent_real = parent_buf[0..parent_n];
    const dest_real = try std.fs.path.join(alloc, &.{ parent_real, dest_base });
    defer alloc.free(dest_real);

    if (isWithin(src_real, dest_real) or isWithin(dest_real, src_real)) {
        note(diagnostics, alloc, "source and destination overlap: {s} and {s}", .{ source_path, destination_path });
        return error.PathOverlap;
    }
    if (try destinationPresent(parent, io, dest_base)) {
        note(diagnostics, alloc, "destination already exists: {s}", .{destination_path});
        return error.DestinationExists;
    }

    if (try pathPresentStrict(src, io, ".state/pending.json")) {
        note(diagnostics, alloc, "source has a pending transaction: {s}/.state/pending.json", .{source_path});
        return error.PendingTransaction;
    }
    for (required_rels) |rel| {
        if (!try pathPresentStrict(src, io, rel)) {
            note(diagnostics, alloc, "source is missing canonical store file: {s}", .{rel});
            return error.InvalidStoreStructure;
        }
    }
    const routines_present = try pathPresentStrict(src, io, routines_rel);

    // ---- uniquely owned sibling staging directory (real runs only) ----
    var stage: ?Stage = null;
    defer if (stage) |*s| {
        if (s.dir) |d| d.close(io);
        parent.deleteTree(io, s.name) catch {};
    };
    if (!dry_run) stage = try createStage(io, alloc, parent, dest_base, parent_real);

    // ---- inventory before conversion (source consistency baseline) ----
    var before = try inventory(io, alloc, src);
    defer before.deinit();

    // ---- conversion pass: transform canonical files, copy the rest ----
    var stats = Stats{ .routines_present = routines_present };
    defer {
        for (stats.ids.items) |id| alloc.free(id);
        stats.ids.deinit(alloc);
    }
    convert(io, alloc, src, if (stage) |*s| s else null, &stats) catch |err| {
        note(diagnostics, alloc, "conversion refused: {s}", .{@errorName(err)});
        return err;
    };

    // One task id may appear only once across the canonical lists.
    std.mem.sort([]const u8, stats.ids.items, {}, lessThanId);
    var i: usize = 1;
    while (i < stats.ids.items.len) : (i += 1) {
        if (std.mem.eql(u8, stats.ids.items[i - 1], stats.ids.items[i])) {
            note(diagnostics, alloc, "duplicate task id in the canonical lists: {s}", .{stats.ids.items[i]});
            return error.DuplicateId;
        }
    }

    // ---- source must not change while we convert ----
    verifyUnchanged(io, alloc, src, &before) catch |err| switch (err) {
        error.SourceChanged => {
            note(diagnostics, alloc, "source changed during conversion: {s}", .{source_path});
            return error.SourceChanged;
        },
        else => return err,
    };
    if (try pathPresentStrict(src, io, ".state/pending.json")) {
        note(diagnostics, alloc, "source gained a pending transaction: {s}/.state/pending.json", .{source_path});
        return error.PendingTransaction;
    }

    // ---- config decision (explicit format 1, or strict-v1 inference) ----
    const config_result: []const u8 = blk: {
        if (stats.config_seen) {
            // An explicit format-1 config whose store already carries
            // format-2 markers is mixed evidence too: an English task key
            // would be reinterpreted as a reserved v2 field after conversion.
            if (stats.tasks_v2 or stats.contexts_v2_header) {
                note(diagnostics, alloc, "format-1 config with format-2 markers: {s}", .{source_path});
                return error.MixedSignals;
            }
            break :blk "rewritten";
        }
        const v1_evidence = stats.contexts_rewritten or stats.tasks_v1 or routines_present;
        const v2_evidence = stats.contexts_v2_header or stats.tasks_v2;
        // Format-2 or mixed markers with no explicit config are never
        // converted; without any v1 marker the source is ambiguous.
        if (v2_evidence) {
            note(diagnostics, alloc, "missing config with format-2 or mixed evidence: {s}", .{source_path});
            return error.MixedSignals;
        }
        if (!v1_evidence) {
            note(diagnostics, alloc, "missing config without a format-1 marker: {s}", .{source_path});
            return error.AmbiguousSource;
        }
        if (stage) |*st| if (st.dir) |d| try d.writeFile(io, .{ .sub_path = config_rel, .data = synthesized_config });
        break :blk "synthesized";
    };

    // ---- routine table: convert or seed the baseline ----
    const routines_result: []const u8 = if (routines_present) "transformed" else "seeded";
    const seed_date: ?[]const u8 = if (routines_present) null else blk: {
        var buf: [10]u8 = undefined;
        const date = try alloc.dupe(u8, today.format(&buf));
        if (stage) |*st| if (st.dir) |d| {
            const seed_text = try seedRoutineText(alloc, date);
            defer alloc.free(seed_text);
            try d.createDirPath(io, "routines");
            try d.writeFile(io, .{ .sub_path = routines_rel, .data = seed_text });
        };
        break :blk date;
    };

    if (dry_run) {
        return Report{
            .from = try alloc.dupe(u8, source_path),
            .to = try alloc.dupe(u8, destination_path),
            .dry_run = true,
            .config = config_result,
            .routines = routines_result,
            .seed_date = seed_date,
            .tasks = stats.tasks,
            .fields_renamed = stats.renamed,
            .files = stats.files,
            .checked = false,
        };
    }

    // ---- staged strict v2 check ----
    const st = &stage.?;
    {
        var eng = engine.Engine.init(io, alloc, st.path, today, true) catch |err| {
            note(diagnostics, alloc, "staged store cannot be opened: {s}", .{@errorName(err)});
            return err;
        };
        defer eng.deinit();
        const res = try eng.check(true);
        if (res.errors.len > 0) {
            if (diagnostics) |d| {
                for (res.errors) |e| d.append(alloc, e) catch {};
            }
            return error.StageInvalid;
        }
    }
    // Drop the operational state the exclusive engine lock created; the
    // destination must not carry it.
    if (st.dir) |d| try d.deleteTree(io, ".state");

    const report = Report{
        .from = try alloc.dupe(u8, source_path),
        .to = try alloc.dupe(u8, destination_path),
        .dry_run = false,
        .config = config_result,
        .routines = routines_result,
        .seed_date = seed_date,
        .tasks = stats.tasks,
        .fields_renamed = stats.renamed,
        .files = stats.files,
        .checked = true,
    };

    // ---- atomic promotion, never replacing an existing destination ----
    if (st.dir) |d| {
        d.close(io);
        st.dir = null;
    }
    parent.renamePreserve(st.name, parent, dest_base, io) catch |err| switch (err) {
        // A concurrent creator won the destination: fail without touching it.
        error.PathAlreadyExists => {
            note(diagnostics, alloc, "destination appeared during conversion: {s}", .{destination_path});
            return error.DestinationExists;
        },
        else => return err,
    };
    // Same durability step as `Store.writeAtomic`: the rename is on disk.
    if (builtin.os.tag != .windows) {
        _ = std.c.fsync(parent.handle);
    }
    return report;
}

/// Appends one human-readable refusal/check detail line; the string is
/// allocated from `alloc` and owned by the diagnostics list.
fn note(diag: ?*std.ArrayList([]const u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (diag) |d| {
        const msg = std.fmt.allocPrint(alloc, fmt, args) catch return;
        d.append(alloc, msg) catch {};
    }
}

/// Stable error codes for CLI output; everything unmapped falls through to
/// the engine vocabulary (`invalid_field`, `pending_transaction`, …).
pub fn errorName(err: anyerror) []const u8 {
    return switch (err) {
        error.AmbiguousSource => "ambiguous_source",
        error.MixedSignals => "mixed_signals",
        error.UnsupportedFormat => "unsupported_format",
        error.KeyCollision => "key_collision",
        error.DestinationExists => "destination_exists",
        error.PathOverlap => "path_overlap",
        error.UnsupportedEntry => "unsupported_entry",
        error.StageInvalid => "stage_invalid",
        error.SourceChanged => "source_changed",
        error.SourceNotFound,
        error.DestinationParentMissing,
        error.InvalidDestination,
        error.InvalidStoreStructure,
        => "invalid_workspace",
        else => engine.errorName(err),
    };
}

const Stage = struct {
    dir: ?std.Io.Dir,
    /// Single path component, sibling of the destination, relative to parent.
    name: []const u8,
    /// Absolute path (parent real path + name), for `Engine.init`.
    path: []const u8,
};

const Stats = struct {
    routines_present: bool,
    /// Owned task ids collected during conversion, sorted for the
    /// duplicate-id rejection.
    ids: std.ArrayList([]const u8) = .empty,
    files: usize = 0,
    tasks: usize = 0,
    renamed: usize = 0,
    contexts_rewritten: bool = false,
    contexts_v2_header: bool = false,
    tasks_v1: bool = false,
    tasks_v2: bool = false,
    config_seen: bool = false,
};

/// Opens an exact directory path (absolute or cwd-relative) without walking.
fn openExact(io: std.Io, path: []const u8) !std.Io.Dir {
    const options: std.Io.Dir.OpenOptions = .{ .iterate = true };
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, options);
    }
    return std.Io.Dir.cwd().openDir(io, path, options);
}

/// No-follow presence check for the destination: a symlink entry counts as
/// present even when it dangles, so the refusal happens here with an honest
/// diagnostic instead of at promotion.
fn destinationPresent(dir: std.Io.Dir, io: std.Io, rel: []const u8) !bool {
    _ = dir.statFile(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn pathPresentStrict(dir: std.Io.Dir, io: std.Io, rel: []const u8) !bool {
    dir.access(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn trimTrailingSeps(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == std.fs.path.sep) end -= 1;
    return path[0..end];
}

/// True when `child` is `parent` itself or lives underneath it. Both paths
/// must be canonical and separator-normalized (no trailing separator except
/// the filesystem root).
fn isWithin(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    const sep = std.fs.path.sep;
    if (parent[parent.len - 1] == sep) return true;
    return child[parent.len] == sep;
}

/// Walker paths become `/`-separated, matching the rest of the product
/// (`engine.check` normalizes the same way).
fn normalizeRel(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, raw);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Only a top-level `.git` or `.state` is excluded from the copy; nested
/// ones are ordinary content and are copied byte-for-byte.
fn isExcluded(rel: []const u8) bool {
    const first_end = std.mem.indexOfScalar(u8, rel, '/') orelse rel.len;
    const first = rel[0..first_end];
    return std.mem.eql(u8, first, ".git") or std.mem.eql(u8, first, ".state");
}

fn eqlPath(rel: []const u8, parts: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    for (parts) |part| {
        const seg = it.next() orelse return false;
        if (!std.mem.eql(u8, seg, part)) return false;
    }
    return it.next() == null;
}

fn classify(rel: []const u8) Special {
    if (std.mem.eql(u8, rel, config_rel)) return .config;
    if (std.mem.eql(u8, rel, contexts_rel)) return .contexts;
    if (std.mem.eql(u8, rel, routines_rel)) return .routines;
    for (task_list_rels) |list_rel| {
        if (std.mem.eql(u8, rel, list_rel)) return .task_list;
    }
    return .verbatim;
}

/// Creates the unique sibling staging directory used for a real run.
fn createStage(io: std.Io, alloc: std.mem.Allocator, parent: std.Io.Dir, dest_base: []const u8, parent_real: []const u8) !Stage {
    var entropy: std.Random.IoSource = .{ .io = io };
    const rnd = entropy.interface();
    var attempt: u8 = 0;
    while (attempt < 16) : (attempt += 1) {
        var raw: [8]u8 = undefined;
        rnd.bytes(&raw);
        var hex_buf: [16]u8 = undefined;
        const hex = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            hex_buf[i * 2] = hex[b >> 4];
            hex_buf[i * 2 + 1] = hex[b & 0xf];
        }
        const name = try std.fmt.allocPrint(alloc, "{s}.ztd-migrate-{s}", .{ dest_base, hex_buf });
        parent.createDir(io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(name);
                continue;
            },
            else => {
                alloc.free(name);
                return err;
            },
        };
        const path = try std.fs.path.join(alloc, &.{ parent_real, name });
        const dir = parent.openDir(io, name, .{ .iterate = true }) catch |err| {
            parent.deleteTree(io, name) catch {};
            alloc.free(name);
            alloc.free(path);
            return err;
        };
        return .{ .dir = dir, .name = name, .path = path };
    }
    return error.SystemResources;
}

const Inventory = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    const Kind = enum { dir, file };
    const Entry = struct {
        path: []const u8,
        kind: Kind,
        hash: [32]u8 = undefined,
    };

    fn deinit(self: *Inventory) void {
        for (self.entries.items) |e| self.alloc.free(e.path);
        self.entries.deinit(self.alloc);
    }
};

fn lessThanEntry(_: void, a: Inventory.Entry, b: Inventory.Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn lessThanId(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Content inventory of the copy set (everything except `.git` and `.state`),
/// sorted for stable before/after comparison. Also rejects symlinks and
/// special files: the copy set may contain only directories and regular files.
fn inventory(io: std.Io, alloc: std.mem.Allocator, src: std.Io.Dir) !Inventory {
    var inv = Inventory{ .alloc = alloc, .entries = .empty };
    errdefer inv.deinit();
    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const rel = try normalizeRel(alloc, entry.path);
        if (isExcluded(rel)) {
            alloc.free(rel);
            continue;
        }
        switch (entry.kind) {
            .directory => try inv.entries.append(alloc, .{ .path = rel, .kind = .dir }),
            .file => {
                const bytes = try entry.dir.readFileAlloc(io, entry.basename, alloc, .limited(store_mod.max_file_bytes));
                defer alloc.free(bytes);
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
                try inv.entries.append(alloc, .{ .path = rel, .kind = .file, .hash = hash });
            },
            else => {
                alloc.free(rel);
                return error.UnsupportedEntry;
            },
        }
    }
    std.mem.sort(Inventory.Entry, inv.entries.items, {}, lessThanEntry);
    return inv;
}

/// The source must be byte-identical to the baseline taken before conversion.
fn verifyUnchanged(io: std.Io, alloc: std.mem.Allocator, src: std.Io.Dir, before: *const Inventory) !void {
    var after = try inventory(io, alloc, src);
    defer after.deinit();
    if (after.entries.items.len != before.entries.items.len) return error.SourceChanged;
    for (after.entries.items, before.entries.items) |a, b| {
        if (a.kind != b.kind or !std.mem.eql(u8, a.path, b.path)) return error.SourceChanged;
        if (a.kind == .file and !std.mem.eql(u8, &a.hash, &b.hash)) return error.SourceChanged;
    }
}

/// One conversion walk: transform the canonical files, copy everything else
/// byte-for-byte, and record the markers `run` needs for config inference.
fn convert(io: std.Io, alloc: std.mem.Allocator, src: std.Io.Dir, stage: ?*Stage, stats: *Stats) !void {
    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const rel = try normalizeRel(alloc, entry.path);
        defer alloc.free(rel);
        if (isExcluded(rel)) continue;
        switch (entry.kind) {
            .directory => {
                // Canonical files may never be directories.
                if (classify(rel) != .verbatim) return error.InvalidStoreStructure;
                if (stage) |s| if (s.dir) |d| try d.createDirPath(io, rel);
            },
            .file => {
                const bytes = try entry.dir.readFileAlloc(io, entry.basename, alloc, .limited(store_mod.max_file_bytes));
                defer alloc.free(bytes);
                stats.files += 1;
                const out: []const u8 = switch (classify(rel)) {
                    .config => blk: {
                        stats.config_seen = true;
                        break :blk try transformConfig(alloc, bytes);
                    },
                    .contexts => blk: {
                        const r = try transformContexts(alloc, bytes);
                        defer alloc.free(r.text);
                        if (r.rewritten) stats.contexts_rewritten = true;
                        if (r.v2_header) stats.contexts_v2_header = true;
                        break :blk try alloc.dupe(u8, r.text);
                    },
                    .task_list => blk: {
                        const r = try transformTasks(alloc, bytes, &stats.ids);
                        defer alloc.free(r.text);
                        stats.tasks += r.tasks;
                        stats.renamed += r.renamed;
                        if (r.saw_legacy) stats.tasks_v1 = true;
                        if (r.saw_english) stats.tasks_v2 = true;
                        break :blk try alloc.dupe(u8, r.text);
                    },
                    .routines => blk: {
                        const r = try transformRoutines(alloc, bytes);
                        defer alloc.free(r.text);
                        break :blk try alloc.dupe(u8, r.text);
                    },
                    .verbatim => try alloc.dupe(u8, bytes),
                };
                defer alloc.free(out);
                if (stage) |s| if (s.dir) |d| try d.writeFile(io, .{ .sub_path = rel, .data = out });
            },
            else => return error.UnsupportedEntry,
        }
    }
}

const TaskTransform = struct {
    text: []u8,
    tasks: usize,
    renamed: usize,
    saw_legacy: bool,
    saw_english: bool,
};

const ContextsTransform = struct {
    text: []u8,
    rewritten: bool,
    v2_header: bool,
};

fn isEscaped(s: []const u8, i: usize) bool {
    var n: usize = 0;
    var j = i;
    while (j > 0 and s[j - 1] == '\\') : (j -= 1) n += 1;
    return n % 2 == 1;
}

/// Same separator rule as `model.parseLine`: an unescaped ` | `.
fn findSeparator(s: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 <= s.len) : (i += 1) {
        if (s[i] == ' ' and s[i + 1] == '|' and s[i + 2] == ' ' and !isEscaped(s, i + 1)) {
            return i;
        }
    }
    return null;
}

fn freeTask(alloc: std.mem.Allocator, task: model.Task) void {
    // The fields list shares its buffer with the caller's copy; deinit on a
    // mutable local frees the same allocation.
    var t = task;
    alloc.free(t.id);
    alloc.free(t.title);
    for (t.fields.items) |f| {
        alloc.free(f.key);
        alloc.free(f.value);
    }
    t.fields.deinit(alloc);
}

/// Splits `text` into lines while keeping each original terminator intact.
const LineIterator = struct {
    text: []const u8,
    pos: usize = 0,

    const Line = struct { content: []const u8, eol: []const u8 };

    fn next(self: *LineIterator) ?Line {
        if (self.pos >= self.text.len) return null;
        const rest = self.text[self.pos..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        if (nl) |n| {
            var content_end = n;
            var eol: []const u8 = "\n";
            if (content_end > 0 and rest[content_end - 1] == '\r') {
                content_end -= 1;
                eol = "\r\n";
            }
            self.pos += n + 1;
            return .{ .content = rest[0..content_end], .eol = eol };
        }
        self.pos = self.text.len;
        return .{ .content = rest, .eol = "" };
    }
};

/// Converts the five canonical task lists: renames the seven legacy keys in
/// place (byte-preserving everywhere else), rejecting malformed lines,
/// duplicate fields/ids and any legacy→English key collision. The rewritten
/// line is re-parsed before it is accepted.
fn transformTasks(alloc: std.mem.Allocator, bytes: []const u8, ids: *std.ArrayList([]const u8)) !TaskTransform {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var res = TaskTransform{ .text = undefined, .tasks = 0, .renamed = 0, .saw_legacy = false, .saw_english = false };

    var lines: LineIterator = .{ .text = bytes };
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line.content, "- [")) {
            try out.appendSlice(alloc, line.content);
            try out.appendSlice(alloc, line.eol);
            continue;
        }
        // Fail closed on anything the product would refuse to load.
        const parsed = model.parseLine(alloc, line.content) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.MalformedTask,
        };
        const task = parsed orelse {
            try out.appendSlice(alloc, line.content);
            try out.appendSlice(alloc, line.eol);
            continue;
        };
        const id_copy = try alloc.dupe(u8, task.id);
        ids.append(alloc, id_copy) catch |err| {
            alloc.free(id_copy);
            return err;
        };
        freeTask(alloc, task);
        res.tasks += 1;

        // Locate field segments and collect raw keys (escape-aware, so a
        // legacy word inside an escaped pipe in the title is never renamed).
        var ranges: std.ArrayList(struct { start: usize, end: usize, to: []const u8 }) = .empty;
        defer ranges.deinit(alloc);
        var field_keys: std.ArrayList([]const u8) = .empty;
        defer field_keys.deinit(alloc);
        var cursor: usize = 0;
        var seg_index: usize = 0;
        while (true) {
            const rel_sep = findSeparator(line.content[cursor..]);
            const end = if (rel_sep) |r| cursor + r else line.content.len;
            if (seg_index >= 2) {
                const segment = line.content[cursor..end];
                if (std.mem.indexOf(u8, segment, ": ")) |c| {
                    if (c > 0) {
                        const raw_key = segment[0..c];
                        try field_keys.append(alloc, raw_key);
                        for (key_renames) |kr| {
                            if (std.mem.eql(u8, raw_key, kr.from)) {
                                try ranges.append(alloc, .{ .start = cursor, .end = cursor + c, .to = kr.to });
                            }
                        }
                        for (english_keys) |ek| {
                            if (std.mem.eql(u8, raw_key, ek)) res.saw_english = true;
                        }
                    }
                }
            }
            seg_index += 1;
            if (rel_sep == null) break;
            cursor = end + 3;
        }

        // Any legacy key whose English target is already a field on this task
        // is a collision — rejected even when the values would be equal.
        for (ranges.items) |r| {
            for (field_keys.items) |k| {
                if (std.mem.eql(u8, k, r.to)) return error.KeyCollision;
            }
        }
        if (ranges.items.len > 0) res.saw_legacy = true;
        res.renamed += ranges.items.len;

        // Rebuild the line with only the key ranges replaced, then re-parse
        // the rewritten line before accepting it (in-memory structural check
        // that also runs in dry-run).
        var line_out: std.ArrayList(u8) = .empty;
        defer line_out.deinit(alloc);
        var pos: usize = 0;
        for (ranges.items) |r| {
            try line_out.appendSlice(alloc, line.content[pos..r.start]);
            try line_out.appendSlice(alloc, r.to);
            pos = r.end;
        }
        try line_out.appendSlice(alloc, line.content[pos..]);
        const reparsed = model.parseLine(alloc, line_out.items) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.MalformedTask,
        };
        const rewritten_task = reparsed orelse return error.MalformedTask;
        freeTask(alloc, rewritten_task);
        try out.appendSlice(alloc, line_out.items);
        try out.appendSlice(alloc, line.eol);
    }
    res.text = try out.toOwnedSlice(alloc);
    return res;
}

/// Rewrites the parser-sensitive contexts header cell `Contexto` → `Context`.
/// Context/client names and user prose are preserved byte-for-byte.
/// The recognized contexts-table header labels of the first table row.
const context_header_labels = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "Contexto", .to = "Context" },
    .{ .from = "Uso", .to = "Use" },
    .{ .from = "Clientes", .to = "Clients" },
    .{ .from = "Conocimiento", .to = "Knowledge" },
};

const Replacement = struct { start: usize, end: usize, to: []const u8 };

/// Rewrites the parser-sensitive contexts header: the recognized labels of
/// the first table row (`Contexto` → `Context`, `Uso` → `Use`, `Clientes` →
/// `Clients`, `Conocimiento` → `Knowledge`) and, on later rows, a first cell
/// `Contexto` → `Context` (invisible in format 1, still invisible as
/// `Context` in format 2). Context/client names and user prose are preserved
/// byte-for-byte.
fn transformContexts(alloc: std.mem.Allocator, bytes: []const u8) !ContextsTransform {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var res = ContextsTransform{ .text = undefined, .rewritten = false, .v2_header = false };
    var lines: LineIterator = .{ .text = bytes };
    var first_row = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line.content, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '|') {
            try out.appendSlice(alloc, line.content);
            try out.appendSlice(alloc, line.eol);
            continue;
        }
        const first = std.mem.indexOfScalar(u8, line.content, '|');
        const last = std.mem.lastIndexOfScalar(u8, line.content, '|');
        if (first == null or last == null or last.? <= first.?) {
            try out.appendSlice(alloc, line.content);
            try out.appendSlice(alloc, line.eol);
            continue;
        }
        const f = first.?;
        const l = last.?;
        var regions: std.ArrayList(struct { start: usize, len: usize }) = .empty;
        defer regions.deinit(alloc);
        {
            var cursor: usize = f + 1;
            var it = std.mem.splitScalar(u8, line.content[f + 1 .. l], '|');
            while (it.next()) |seg| {
                try regions.append(alloc, .{ .start = cursor, .len = seg.len });
                cursor += seg.len + 1;
            }
        }
        var reps: std.ArrayList(Replacement) = .empty;
        defer reps.deinit(alloc);
        for (regions.items, 0..) |r, idx| {
            const c = cellTextRegion(line.content, r.start, r.len);
            if (first_row) {
                for (context_header_labels) |label| {
                    if (std.mem.eql(u8, c.text, label.from)) {
                        try reps.append(alloc, .{ .start = c.start, .end = c.end, .to = label.to });
                        if (std.mem.eql(u8, label.from, "Contexto")) res.rewritten = true;
                    }
                }
                if (idx == 0 and std.mem.eql(u8, c.text, "Context")) res.v2_header = true;
            } else if (idx == 0) {
                if (std.mem.eql(u8, c.text, "Contexto")) {
                    try reps.append(alloc, .{ .start = c.start, .end = c.end, .to = "Context" });
                    res.rewritten = true;
                } else if (std.mem.eql(u8, c.text, "Context")) {
                    res.v2_header = true;
                }
            }
        }
        first_row = false;
        if (reps.items.len == 0) {
            try out.appendSlice(alloc, line.content);
        } else {
            var pos: usize = 0;
            for (reps.items) |r| {
                try out.appendSlice(alloc, line.content[pos..r.start]);
                try out.appendSlice(alloc, r.to);
                pos = r.end;
            }
            try out.appendSlice(alloc, line.content[pos..]);
        }
        try out.appendSlice(alloc, line.eol);
    }
    res.text = try out.toOwnedSlice(alloc);
    return res;
}

const RoutinesTransform = struct { text: []u8 };

/// The v1 weekly cadence spellings and their English format-2 equivalents.
const weekly_pairs = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "semanal:lun", .to = "weekly:mon" },
    .{ .from = "semanal:mar", .to = "weekly:tue" },
    .{ .from = "semanal:mie", .to = "weekly:wed" },
    .{ .from = "semanal:mié", .to = "weekly:wed" },
    .{ .from = "semanal:jue", .to = "weekly:thu" },
    .{ .from = "semanal:vie", .to = "weekly:fri" },
    .{ .from = "semanal:sab", .to = "weekly:sat" },
    .{ .from = "semanal:sáb", .to = "weekly:sat" },
    .{ .from = "semanal:dom", .to = "weekly:sun" },
};

fn freeRows(alloc: std.mem.Allocator, rows: []const routine.Row) void {
    for (rows) |r| {
        alloc.free(r.id);
        alloc.free(r.cadence);
    }
    alloc.free(rows);
}

/// One routine-table cell's exact text region inside the raw line.
const CellRegion = struct { start: usize, end: usize, text: []const u8 };

fn cellTextRegion(content: []const u8, start: usize, len: usize) CellRegion {
    const seg = content[start .. start + len];
    const trimmed = std.mem.trim(u8, seg, " \t\r");
    const lead = seg.len - std.mem.trimStart(u8, seg, " \t\r").len;
    return .{ .start = start + lead, .end = start + lead + trimmed.len, .text = trimmed };
}

const v1_weekly_days = [_][]const u8{ "lun", "mar", "mie", "mié", "jue", "vie", "sab", "sáb", "dom" };

fn v1RoutineIdValid(id: []const u8) bool {
    if (id.len == 0 or id[0] < 'a' or id[0] > 'z') return false;
    for (id[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn v1IsSeparator(id: []const u8) bool {
    for (id) |c| {
        if (c != '-') return false;
    }
    return id.len > 0;
}

/// Validates an existing routine table with the format-1 vocabulary
/// (`rutina`, `diaria`, `semanal:<lun…dom>`). The product parser only knows
/// format 2 now, so the source file needs its own v1 validation; duplicate
/// ids and empty tables are rejected by the format-2 re-parse of the
/// rewritten text, which preserves ids and dates.
fn validateV1RoutineTable(text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '|') continue;
        if (trimmed[trimmed.len - 1] != '|') return error.MalformedRoutine;
        var cells: [3][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], '|');
        while (it.next()) |cell| {
            if (count >= cells.len) return error.MalformedRoutine;
            cells[count] = std.mem.trim(u8, cell, " \t");
            count += 1;
        }
        if (count != cells.len) return error.MalformedRoutine;
        const id = cells[0];
        const cadence = cells[1];
        if (std.mem.eql(u8, id, "rutina") or v1IsSeparator(id)) continue;
        if (!v1RoutineIdValid(id)) return error.MalformedRoutine;
        if (!std.mem.eql(u8, cadence, "diaria")) {
            if (!std.mem.startsWith(u8, cadence, "semanal:")) return error.MalformedRoutine;
            const day = cadence["semanal:".len..];
            var known = false;
            for (v1_weekly_days) |d| {
                if (std.mem.eql(u8, d, day)) known = true;
            }
            if (!known) return error.MalformedRoutine;
        }
        _ = platform.parseDate(cells[2]) catch return error.MalformedRoutine;
    }
}

/// Converts the existing routine table: header cells
/// `rutina|cadencia|última` → `routine|cadence|last`, `diaria` → `daily`,
/// `semanal:<lun…dom>` → `weekly:<mon…sun>` (Monday-first), preserving ids,
/// dates and every byte outside the vocabulary cells. The source table must
/// already parse (a malformed file fails), and the rewritten text must parse
/// as a format-2 table before it is accepted.
fn transformRoutines(alloc: std.mem.Allocator, bytes: []const u8) !RoutinesTransform {
    try validateV1RoutineTable(bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines: LineIterator = .{ .text = bytes };
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line.content, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '|') {
            try out.appendSlice(alloc, line.content);
            try out.appendSlice(alloc, line.eol);
            continue;
        }
        const first = std.mem.indexOfScalar(u8, line.content, '|') orelse return error.MalformedRoutine;
        const last = std.mem.lastIndexOfScalar(u8, line.content, '|') orelse return error.MalformedRoutine;
        if (last <= first) return error.MalformedRoutine;
        const inner = line.content[first + 1 .. last];
        var regions: [3]struct { start: usize, len: usize } = undefined;
        var count: usize = 0;
        var cursor: usize = first + 1;
        var it = std.mem.splitScalar(u8, inner, '|');
        while (it.next()) |cell_seg| {
            if (count >= regions.len) return error.MalformedRoutine;
            regions[count] = .{ .start = cursor, .len = cell_seg.len };
            cursor += cell_seg.len + 1;
            count += 1;
        }
        if (count != regions.len) return error.MalformedRoutine;

        var reps: [3]?struct { start: usize, end: usize, to: []const u8 } = .{ null, null, null };
        const c0 = cellTextRegion(line.content, regions[0].start, regions[0].len);
        // A v1 data row named `routine` would become an invisible v2 header
        // row; format 2 cannot represent it, so the file fails instead.
        if (std.mem.eql(u8, c0.text, "routine")) return error.MalformedRoutine;
        if (std.mem.eql(u8, c0.text, "rutina")) reps[0] = .{ .start = c0.start, .end = c0.end, .to = "routine" };

        const c1 = cellTextRegion(line.content, regions[1].start, regions[1].len);
        if (std.mem.eql(u8, c1.text, "cadencia")) {
            reps[1] = .{ .start = c1.start, .end = c1.end, .to = "cadence" };
        } else if (std.mem.eql(u8, c1.text, "diaria")) {
            reps[1] = .{ .start = c1.start, .end = c1.end, .to = "daily" };
        } else if (std.mem.startsWith(u8, c1.text, "semanal:")) {
            for (weekly_pairs) |pair| {
                if (std.mem.eql(u8, c1.text, pair.from)) {
                    reps[1] = .{ .start = c1.start, .end = c1.end, .to = pair.to };
                    break;
                }
            }
            if (reps[1] == null) return error.MalformedRoutine;
        }

        const c2 = cellTextRegion(line.content, regions[2].start, regions[2].len);
        if (std.mem.eql(u8, c2.text, "última")) reps[2] = .{ .start = c2.start, .end = c2.end, .to = "last" };

        var pos: usize = 0;
        for (&reps) |*rep| {
            if (rep.*) |r| {
                try out.appendSlice(alloc, line.content[pos..r.start]);
                try out.appendSlice(alloc, r.to);
                pos = r.end;
            }
        }
        try out.appendSlice(alloc, line.content[pos..]);
        try out.appendSlice(alloc, line.eol);
    }

    const text = try out.toOwnedSlice(alloc);
    errdefer alloc.free(text);
    const rows = routine.parse(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.MalformedRoutine,
    };
    freeRows(alloc, rows);
    return .{ .text = text };
}

/// The v2 baseline routine rows stamped with the single captured date: a
/// fresh scheduling baseline, not a history of completions.
fn seedRoutineText(alloc: std.mem.Allocator, date: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
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

const Range = struct { start: usize, end: usize };

fn isJsonWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isJsonDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isJsonNumberChar(c: u8) bool {
    return isJsonDigit(c) or c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E';
}

/// Byte range of the top-level `format` number token. The text was already
/// validated as JSON with unique keys, so there is at most one such key;
/// anything unexpected returns null and the caller fails closed.
fn findFormatRange(text: []const u8) ?Range {
    var depth: usize = 0;
    var want_number = false;
    var in_string = false;
    var str_start: usize = 0;
    var escaped = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (want_number) {
            const c = text[i];
            if (isJsonWs(c) or c == ':') continue;
            if (!isJsonDigit(c)) return null;
            const start = i;
            while (i < text.len and isJsonNumberChar(text[i])) i += 1;
            return .{ .start = start, .end = i };
        }
        if (in_string) {
            const c = text[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_string = false;
                if (depth == 1) {
                    var j = i + 1;
                    while (j < text.len and isJsonWs(text[j])) j += 1;
                    if (j < text.len and text[j] == ':' and rawKeyIsFormat(text[str_start + 1 .. i])) {
                        want_number = true;
                        i = j; // the loop step steps over the ':'
                    }
                }
            }
            continue;
        }
        const c = text[i];
        switch (c) {
            '"' => {
                in_string = true;
                str_start = i;
            },
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// True when the raw JSON string contents decode to exactly "format"
/// (handles the `\u0066`-style spelling of the same key).
fn rawKeyIsFormat(raw: []const u8) bool {
    const expected = "format";
    var i: usize = 0;
    var k: usize = 0;
    while (i < raw.len) {
        var cp: u21 = undefined;
        if (raw[i] == '\\') {
            i += 1;
            if (i >= raw.len) return false;
            switch (raw[i]) {
                '"' => {
                    cp = '"';
                    i += 1;
                },
                '\\' => {
                    cp = '\\';
                    i += 1;
                },
                '/' => {
                    cp = '/';
                    i += 1;
                },
                'b' => {
                    cp = 0x08;
                    i += 1;
                },
                'f' => {
                    cp = 0x0C;
                    i += 1;
                },
                'n' => {
                    cp = 0x0A;
                    i += 1;
                },
                'r' => {
                    cp = 0x0D;
                    i += 1;
                },
                't' => {
                    cp = 0x09;
                    i += 1;
                },
                'u' => {
                    if (i + 4 >= raw.len) return false;
                    cp = std.fmt.parseInt(u21, raw[i + 1 .. i + 5], 16) catch return false;
                    i += 5;
                },
                else => return false,
            }
        } else {
            cp = raw[i];
            i += 1;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return false;
        if (k + len > expected.len) return false;
        if (!std.mem.eql(u8, expected[k .. k + len], buf[0..len])) return false;
        k += len;
    }
    return k == expected.len;
}

/// Rewrites an explicit format-1 config to format 2 while preserving every
/// unknown property byte-for-byte: only the top-level `format` number token
/// is spliced. Malformed JSON, duplicate keys at any depth, a wrong-typed
/// policy or a format that is not exactly 1 are rejected; the spliced result
/// must reload as a format-2 config.
fn transformConfig(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidConfig;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidConfig;
        switch (root.object.get("format") orelse return error.AmbiguousSource) {
            .integer => |n| if (n != 1) return error.UnsupportedFormat,
            else => return error.InvalidConfig,
        }
        try validatePolicyShape(root);
    }

    const range = findFormatRange(bytes) orelse return error.InvalidConfig;
    var out = try alloc.alloc(u8, bytes.len - (range.end - range.start) + 1);
    errdefer alloc.free(out);
    @memcpy(out[0..range.start], bytes[0..range.start]);
    out[range.start] = '2';
    @memcpy(out[range.start + 1 ..], bytes[range.end..]);

    {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidConfig;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidConfig;
        switch (root.object.get("format") orelse return error.InvalidConfig) {
            .integer => |n| if (n != 2) return error.InvalidConfig,
            else => return error.InvalidConfig,
        }
        try validatePolicyShape(root);
    }
    return out;
}

fn validatePolicyShape(root: std.json.Value) !void {
    const policy = root.object.get("policy") orelse return;
    if (policy != .object) return error.InvalidConfig;
    for ([_][]const u8{ "requireClientFor", "clientOnlyIn" }) |key| {
        if (policy.object.get(key)) |list| {
            if (list != .array) return error.InvalidConfig;
            for (list.array.items) |item| {
                if (item != .string) return error.InvalidConfig;
            }
        }
    }
}

// ============================ tests ============================
// Every test builds only synthetic stores under a fresh temp directory and
// asserts that failures and dry runs leave the source byte-identical and no
// destination or staging directory behind. The tests pass an arena to `run`
// because the engine APIs it drives are arena-oriented.

/// Writes `data` at `<store_root>/<rel>` inside the test temp directory.
fn put(
    io: std.Io,
    alloc: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    store_root: []const u8,
    rel: []const u8,
    data: []const u8,
) !void {
    tmp.dir.createDirPath(io, store_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    if (std.fs.path.dirname(rel)) |parent_rel| {
        if (parent_rel.len > 0) {
            const parent_full = try std.fs.path.join(alloc, &.{ store_root, parent_rel });
            defer alloc.free(parent_full);
            tmp.dir.createDirPath(io, parent_full) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
    const full = try std.fs.path.join(alloc, &.{ store_root, rel });
    defer alloc.free(full);
    try tmp.dir.writeFile(io, .{ .sub_path = full, .data = data });
}

fn readStoreFile(alloc: std.mem.Allocator, io: std.Io, store_abs: []const u8, rel: []const u8) ![]u8 {
    var d = try openExact(io, store_abs);
    defer d.close(io);
    return d.readFileAlloc(io, rel, alloc, .limited(store_mod.max_file_bytes));
}

fn snapshot(alloc: std.mem.Allocator, io: std.Io, store_abs: []const u8) !Inventory {
    var d = try openExact(io, store_abs);
    defer d.close(io);
    return inventory(io, alloc, d);
}

fn expectSourceUnchanged(alloc: std.mem.Allocator, io: std.Io, store_abs: []const u8, before: *const Inventory) !void {
    var d = try openExact(io, store_abs);
    defer d.close(io);
    try verifyUnchanged(io, alloc, d, before);
}

/// Staging directories left next to a destination (must always be zero once
/// `run` returns, success or failure).
fn countStages(alloc: std.mem.Allocator, io: std.Io, parent_abs: []const u8) !usize {
    _ = alloc;
    var d = try openExact(io, parent_abs);
    defer d.close(io);
    var it = d.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        if (std.mem.indexOf(u8, entry.name, "ztd-migrate-") != null) count += 1;
    }
    return count;
}

fn listNames(alloc: std.mem.Allocator, io: std.Io, parent_abs: []const u8) ![][]const u8 {
    var d = try openExact(io, parent_abs);
    defer d.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |n| alloc.free(n);
        list.deinit(alloc);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| try list.append(alloc, try alloc.dupe(u8, entry.name));
    std.mem.sort([]const u8, list.items, {}, lessThanId);
    return list.toOwnedSlice(alloc);
}

/// A realistic format-1 store: all seven legacy keys spread over the five
/// lists, an unknown config property, v1 contexts/routine vocabulary, and
/// copy-only noise (plans, templates, `.git`, `.state`).
fn writeV1Store(io: std.Io, alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, root: []const u8) !void {
    try put(io, alloc, tmp, root, "contexts.md", "# Active contexts\n\n| Contexto | Uso |\n| --- | --- |\n| personal | Personal matters |\n| work | Work |\n");
    try put(io, alloc, tmp, root, "config.json", "{\"format\":1,\"policy\":{\"requireClientFor\":[],\"clientOnlyIn\":[\"personal\"]},\"custom\":{\"keep\":true}}\n");
    try put(io, alloc, tmp, root, "inbox.md", "- [ ] T-20260101-001 | Fix contexto: now | contexto: personal | cliente: acme | proyecto: alpha | capturada: 2026-01-01\n");
    try put(io, alloc, tmp, root, "lists/next.md", "- [ ] T-20260101-002 | Next legacy | contexto: personal | prioridad: alta\n");
    try put(io, alloc, tmp, root, "lists/waiting.md", "- [ ] T-20260101-003 | Waiting legacy | contexto: personal | espera: the bank\n");
    try put(io, alloc, tmp, root, "lists/someday.md", "- [ ] T-20260101-004 | Someday legacy | contexto: personal\n");
    try put(io, alloc, tmp, root, "lists/archive.md", "- [x] T-20260101-005 | Archived | contexto: personal | resolución: done | cerrada: 2026-01-01\n");
    try put(io, alloc, tmp, root, "lists/projects/alpha.md", "# Alpha\n\n");
    try put(io, alloc, tmp, root, "routines/state.md", "# Routine state\n\n| rutina | cadencia | última |\n| --- | --- | --- |\n| inbox | diaria | 2026-01-01 |\n| review | semanal:sab | 2025-12-27 |\n| plan | semanal:lun | 2025-12-29 |\n");
    try put(io, alloc, tmp, root, "plans/daily/2026-01-02.md", "T-20260101-002\n");
    try put(io, alloc, tmp, root, "templates/.gitkeep", "");
    try put(io, alloc, tmp, root, "README.md", "# Workspace\n\nByte-for-byte copy.\n");
    try put(io, alloc, tmp, root, ".gitignore", ".state/\n");
    try put(io, alloc, tmp, root, ".gitattributes", "* text eol=lf\n");
    try put(io, alloc, tmp, root, ".git/HEAD", "ref: refs/heads/main\n");
    try put(io, alloc, tmp, root, ".state/last-transaction.json", "{}\n");
    // Nested `.git`/`.state` are ordinary content and must be copied.
    try put(io, alloc, tmp, root, "knowledge/.git/HEAD", "nested\n");
}

/// Five empty canonical lists plus a contexts file, for evidence tests.
fn putBareStructure(io: std.Io, alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, root: []const u8) !void {
    for ([_][]const u8{ "inbox.md", "lists/next.md", "lists/waiting.md", "lists/someday.md", "lists/archive.md" }) |rel| {
        try put(io, alloc, tmp, root, rel, "# Empty\n\n");
    }
}

test "converts a realistic format-1 store to format 2" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    const before = try snapshot(a, io, src_abs);

    const report = try run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null);

    try std.testing.expect(!report.dry_run);
    try std.testing.expectEqualStrings("rewritten", report.config);
    try std.testing.expectEqualStrings("transformed", report.routines);
    try std.testing.expect(report.seed_date == null);
    try std.testing.expectEqual(@as(usize, 5), report.tasks);
    try std.testing.expectEqual(@as(usize, 11), report.fields_renamed);
    try std.testing.expectEqual(@as(usize, 15), report.files);
    try std.testing.expect(report.checked);

    // Config: format 2 with every unknown property preserved byte-for-byte.
    const cfg = try readStoreFile(a, io, dest_abs, "config.json");
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"format\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"keep\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"clientOnlyIn\":[\"personal\"]") != null);

    // Contexts header renamed; context names and prose untouched.
    const contexts = try readStoreFile(a, io, dest_abs, "contexts.md");
    try std.testing.expect(std.mem.indexOf(u8, contexts, "| Context | Use |") != null);
    try std.testing.expect(std.mem.indexOf(u8, contexts, "Contexto") == null);
    try std.testing.expect(std.mem.indexOf(u8, contexts, "| personal | Personal matters |") != null);

    // All seven keys converted; title prose and custom fields preserved.
    const inbox = try readStoreFile(a, io, dest_abs, "inbox.md");
    try std.testing.expect(std.mem.indexOf(u8, inbox, "context: personal") != null);
    try std.testing.expect(std.mem.indexOf(u8, inbox, "client: acme") != null);
    try std.testing.expect(std.mem.indexOf(u8, inbox, "project: alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, inbox, "captured_at: 2026-01-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, inbox, "Fix contexto: now") != null);
    try std.testing.expect(std.mem.indexOf(u8, inbox, "| contexto:") == null);
    try std.testing.expect(std.mem.indexOf(u8, inbox, "| cliente:") == null);
    const next = try readStoreFile(a, io, dest_abs, "lists/next.md");
    try std.testing.expect(std.mem.indexOf(u8, next, "prioridad: alta") != null);
    const waiting = try readStoreFile(a, io, dest_abs, "lists/waiting.md");
    try std.testing.expect(std.mem.indexOf(u8, waiting, "waiting_on: the bank") != null);
    const archive = try readStoreFile(a, io, dest_abs, "lists/archive.md");
    try std.testing.expect(std.mem.indexOf(u8, archive, "resolution: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "closed_at: 2026-01-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "- [x]") != null);

    // Routine vocabulary converted; ids and dates untouched.
    const routines = try readStoreFile(a, io, dest_abs, "routines/state.md");
    try std.testing.expect(std.mem.indexOf(u8, routines, "| routine | cadence | last |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "| inbox | daily | 2026-01-01 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "weekly:sat") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "weekly:mon") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "diaria") == null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "semanal") == null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "cadencia") == null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "última") == null);

    // Everything else is byte-for-byte.
    const plan_src = try readStoreFile(a, io, src_abs, "plans/daily/2026-01-02.md");
    const plan_dest = try readStoreFile(a, io, dest_abs, "plans/daily/2026-01-02.md");
    try std.testing.expectEqualStrings(plan_src, plan_dest);
    const readme = try readStoreFile(a, io, dest_abs, "README.md");
    try std.testing.expectEqualStrings("# Workspace\n\nByte-for-byte copy.\n", readme);
    const gitignore = try readStoreFile(a, io, dest_abs, ".gitignore");
    try std.testing.expectEqualStrings(".state/\n", gitignore);

    // `.git` and `.state` never reach the destination; no stage is left.
    var dest_dir = try openExact(io, dest_abs);
    defer dest_dir.close(io);
    try std.testing.expect(!try pathPresentStrict(dest_dir, io, ".git"));
    try std.testing.expect(!try pathPresentStrict(dest_dir, io, ".state"));
    const nested_git = try readStoreFile(a, io, dest_abs, "knowledge/.git/HEAD");
    try std.testing.expectEqualStrings("nested\n", nested_git);
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));

    // The source is byte-identical to the pre-conversion baseline.
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "dry run creates nothing and defers the staged check" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    const before = try snapshot(a, io, src_abs);
    const names_before = try listNames(a, io, base);

    const report = try run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = true }, null);

    try std.testing.expect(report.dry_run);
    try std.testing.expect(!report.checked);
    try std.testing.expectEqualStrings("rewritten", report.config);
    try std.testing.expectEqualStrings("transformed", report.routines);
    try std.testing.expectEqual(@as(usize, 11), report.fields_renamed);

    // No destination, no staging directory, no new entries next to the source.
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    const names_after = try listNames(a, io, base);
    try std.testing.expectEqual(names_before.len, names_after.len);
    for (names_before, names_after) |x, y| try std.testing.expectEqualStrings(x, y);
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "missing config is inferred only from strict v1 evidence" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    // No config: keep every v1 marker, drop the client field so the
    // synthesized empty policy still passes the strict staged check.
    try tmp.dir.deleteFile(io, "src/config.json");
    try put(io, a, &tmp, "src", "inbox.md", "- [ ] T-20260101-001 | Fix contexto: now | contexto: personal | proyecto: alpha | capturada: 2026-01-01\n");

    const report = try run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null);

    try std.testing.expectEqualStrings("synthesized", report.config);
    try std.testing.expect(report.checked);
    const cfg = try readStoreFile(a, io, dest_abs, "config.json");
    try std.testing.expectEqualStrings(synthesized_config, cfg);
    const inbox = try readStoreFile(a, io, dest_abs, "inbox.md");
    try std.testing.expect(std.mem.indexOf(u8, inbox, "context: personal") != null);
}

test "missing config with v2 or mixed evidence is rejected" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    // Pure format-2 evidence: v2 contexts header, no config.
    try putBareStructure(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "contexts.md", "# Contexts\n\n| Context | Use |\n| --- | --- |\n| personal | Personal |\n");
    try std.testing.expectError(error.MixedSignals, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));

    // Mixed evidence: v1 contexts header plus an English task key.
    try put(io, a, &tmp, "src", "contexts.md", "# Contexts\n\n| Contexto | Use |\n| --- | --- |\n| personal | Personal |\n");
    try put(io, a, &tmp, "src", "inbox.md", "- [ ] T-20260101-001 | Mixed | context: personal\n");
    try std.testing.expectError(error.MixedSignals, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
}

test "missing config without any v1 marker is ambiguous" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try putBareStructure(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "contexts.md", "# Contexts\n\n| Thing | Use |\n| --- | --- |\n| personal | Personal |\n");

    try std.testing.expectError(error.AmbiguousSource, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
}

test "an existing config must be exactly format 1 and well formed" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    const cases = [_]struct { data: []const u8, err: anyerror }{
        .{ .data = "{\"format\":2}\n", .err = error.UnsupportedFormat },
        .{ .data = "{\"format\":3}\n", .err = error.UnsupportedFormat },
        .{ .data = "not json\n", .err = error.InvalidConfig },
        .{ .data = "{\"format\":1,\"format\":1}\n", .err = error.InvalidConfig },
        .{ .data = "{\"format\":1,\"policy\":{\"requireClientFor\":[1]}}\n", .err = error.InvalidConfig },
        .{ .data = "{\"format\":\"1\"}\n", .err = error.InvalidConfig },
        .{ .data = "{}\n", .err = error.AmbiguousSource },
    };
    for (cases) |c| {
        try put(io, a, &tmp, "src", "config.json", c.data);
        try std.testing.expectError(c.err, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
        try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
        try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
    }
}

test "a legacy key colliding with an English key is rejected" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    // Even equal values must not paper over the collision.
    try put(io, a, &tmp, "src", "inbox.md", "- [ ] T-20260101-001 | Both | contexto: personal | context: personal\n");
    const before = try snapshot(a, io, src_abs);

    try std.testing.expectError(error.KeyCollision, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "malformed task lines and duplicate ids are rejected" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    // A malformed task line is a failure, exactly like the product loader.
    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "inbox.md", "- [ ] not a task\n");
    try std.testing.expectError(error.MalformedTask, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));

    // An invalid id is malformed too.
    try put(io, a, &tmp, "src", "inbox.md", "- [ ] BAD | x\n");
    try std.testing.expectError(error.MalformedTask, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));

    // One task id may appear only once across the canonical lists.
    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "lists/next.md", "- [ ] T-20260101-001 | Duplicate id | contexto: personal\n");
    try std.testing.expectError(error.DuplicateId, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
}

test "a missing routine file is seeded with the captured date" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    try tmp.dir.deleteFile(io, "src/routines/state.md");

    // The dry run reports the captured seed date without writing anything.
    const dry = try run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = true }, null);
    try std.testing.expectEqualStrings("seeded", dry.routines);
    try std.testing.expect(dry.seed_date != null);
    try std.testing.expectEqualStrings("2026-11-11", dry.seed_date.?);
    try std.testing.expect(!dry.checked);
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "routines/state.md"));

    const report = try run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null);

    try std.testing.expectEqualStrings("seeded", report.routines);
    try std.testing.expect(report.seed_date != null);
    try std.testing.expectEqualStrings("2026-11-11", report.seed_date.?);
    try std.testing.expect(report.checked);
    const seeded = try readStoreFile(a, io, dest_abs, "routines/state.md");
    const expected = try seedRoutineText(a, "2026-11-11");
    try std.testing.expectEqualStrings(expected, seeded);
}

test "malformed routines and missing canonical lists fail" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    // An existing but malformed routine file fails; it is never reseeded.
    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "routines/state.md", "| inbox | hourly | 2026-01-01 |\n");
    try std.testing.expectError(error.MalformedRoutine, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));

    // A missing canonical list fails the structure preflight.
    try writeV1Store(io, a, &tmp, "src");
    try tmp.dir.deleteFile(io, "src/lists/someday.md");
    try std.testing.expectError(error.InvalidStoreStructure, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
}

test "a pending journal refuses the migration before any write" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", ".state/pending.json", "{}\n");
    const before = try snapshot(a, io, src_abs);

    try std.testing.expectError(error.PendingTransaction, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "a symlink in the copy set is rejected" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    if (builtin.os.tag == .windows) return; // symlink creation is not portable here
    try writeV1Store(io, a, &tmp, "src");
    const link_abs = try std.fs.path.join(a, &.{ src_abs, "evil" });
    const target = try a.allocSentinel(u8, "plans".len, 0);
    @memcpy(target[0..5], "plans");
    const link_path = try a.allocSentinel(u8, link_abs.len, 0);
    @memcpy(link_path[0..link_abs.len], link_abs);
    if (std.c.symlink(target, link_path) != 0) return; // filesystem without symlink support

    try std.testing.expectError(error.UnsupportedEntry, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
}

test "path guards reject overlap, existing destinations and bad names" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    const before = try snapshot(a, io, src_abs);

    // equality and overlap, in both directions
    try std.testing.expectError(error.PathOverlap, run(io, a, .{ .from = src_abs, .to = src_abs, .today = today, .dry_run = false }, null));
    const inner = try std.fs.path.join(a, &.{ src_abs, "inner" });
    try std.testing.expectError(error.PathOverlap, run(io, a, .{ .from = src_abs, .to = inner, .today = today, .dry_run = false }, null));
    try std.testing.expectError(error.PathOverlap, run(io, a, .{ .from = src_abs, .to = base, .today = today, .dry_run = false }, null));

    // an existing, distinct destination (and its diagnostic line)
    try tmp.dir.createDirPath(io, "taken");
    const taken = try std.fs.path.join(a, &.{ base, "taken" });
    var diags: std.ArrayList([]const u8) = .empty;
    defer diags.deinit(a);
    try std.testing.expectError(error.DestinationExists, run(io, a, .{ .from = src_abs, .to = taken, .today = today, .dry_run = false }, &diags));
    var saw_detail = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d, "destination already exists") != null) saw_detail = true;
    }
    try std.testing.expect(saw_detail);
    try std.testing.expectEqualStrings("destination_exists", errorName(error.DestinationExists));

    // a destination whose parent does not exist
    const missing = try std.fs.path.join(a, &.{ base, "no/such/dest" });
    try std.testing.expectError(error.DestinationParentMissing, run(io, a, .{ .from = src_abs, .to = missing, .today = today, .dry_run = false }, null));

    // an unusable destination name
    const dot = try std.fs.path.join(a, &.{ base, "x/." });
    try std.testing.expectError(error.InvalidDestination, run(io, a, .{ .from = src_abs, .to = dot, .today = today, .dry_run = false }, null));

    // a symlink alias of the source resolves to the same store
    if (builtin.os.tag != .windows) {
        const alias = try std.fs.path.join(a, &.{ base, "alias" });
        const alias_z = try a.allocSentinel(u8, alias.len, 0);
        @memcpy(alias_z[0..alias.len], alias);
        const target_z = try a.allocSentinel(u8, src_abs.len, 0);
        @memcpy(target_z[0..src_abs.len], src_abs);
        if (std.c.symlink(target_z, alias_z) == 0) {
            try std.testing.expectError(error.PathOverlap, run(io, a, .{ .from = alias, .to = src_abs, .today = today, .dry_run = false }, null));
        }
    }

    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "the consistency re-check detects a changed source" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });

    try writeV1Store(io, a, &tmp, "src");
    const before = try snapshot(a, io, src_abs);
    try put(io, a, &tmp, "src", "inbox.md", "- [ ] T-20260101-001 | Changed\n");
    try std.testing.expectError(error.SourceChanged, expectSourceUnchanged(a, io, src_abs, &before));
}

test "line endings are preserved through conversion" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "lists/next.md", "- [ ] T-20260101-002 | Next | contexto: personal\r\n- [ ] T-20260101-006 | Extra | contexto: personal\r\n");

    const report = try run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null);
    try std.testing.expect(report.checked);
    const next = try readStoreFile(a, io, dest_abs, "lists/next.md");
    try std.testing.expect(std.mem.indexOf(u8, next, "context: personal\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "contexto") == null);
    try std.testing.expectEqual(std.mem.count(u8, next, "\r\n"), std.mem.count(u8, next, "\n"));
}

test "a failed staged strict check creates no destination" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    // Converts cleanly as v1 but violates format 2: `next` requires context.
    try put(io, a, &tmp, "src", "lists/next.md", "- [ ] T-20260101-002 | No context\n");
    const before = try snapshot(a, io, src_abs);

    var diags: std.ArrayList([]const u8) = .empty;
    defer diags.deinit(a);
    try std.testing.expectError(error.StageInvalid, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, &diags));

    // The staged check errors reach the diagnostics list for CLI output.
    var reported = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d, "missing context") != null) reported = true;
    }
    try std.testing.expect(reported);
    try std.testing.expectEqualStrings("stage_invalid", errorName(error.StageInvalid));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "the migration key map matches the product legacy vocabulary" {
    try std.testing.expectEqual(model.legacy_fields.len, key_renames.len);
    for (model.legacy_fields, key_renames) |legacy, pair| {
        try std.testing.expectEqualStrings(legacy, pair.from);
    }
    for (key_renames) |pair| {
        var found = false;
        for (english_keys) |ek| {
            if (std.mem.eql(u8, ek, pair.to)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "a format-1 config with format-2 markers is mixed evidence" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    // An English task key under an explicit format-1 config must not be
    // silently reinterpreted as a reserved v2 field after conversion.
    try put(io, a, &tmp, "src", "inbox.md", "- [ ] T-20260101-001 | Mixed | context: personal\n");
    const before = try snapshot(a, io, src_abs);
    var diags: std.ArrayList([]const u8) = .empty;
    defer diags.deinit(a);
    try std.testing.expectError(error.MixedSignals, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, &diags));
    var saw_detail = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d, "format-1 config with format-2 markers") != null) saw_detail = true;
    }
    try std.testing.expect(saw_detail);
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
    try expectSourceUnchanged(a, io, src_abs, &before);

    // The English `Context` header under an explicit format-1 config is the
    // same refusal.
    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "contexts.md", "# Contexts\n\n| Context | Use |\n| --- | --- |\n| personal | Personal |\n");
    diags.clearRetainingCapacity();
    try std.testing.expectError(error.MixedSignals, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, &diags));
    saw_detail = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d, "format-1 config with format-2 markers") != null) saw_detail = true;
    }
    try std.testing.expect(saw_detail);
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
}

test "a dangling destination symlink refuses before any work" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "ghost" });
    const today = try platform.parseDate("2026-11-11");

    if (builtin.os.tag == .windows) return; // symlink creation is not portable here
    try writeV1Store(io, a, &tmp, "src");
    const target_abs = try std.fs.path.join(a, &.{ base, "no-such-target" });
    const target_z = try a.allocSentinel(u8, target_abs.len, 0);
    @memcpy(target_z[0..target_abs.len], target_abs);
    const dest_z = try a.allocSentinel(u8, dest_abs.len, 0);
    @memcpy(dest_z[0..dest_abs.len], dest_abs);
    if (std.c.symlink(target_z, dest_z) != 0) return; // filesystem without symlink support
    const before = try snapshot(a, io, src_abs);

    var diags: std.ArrayList([]const u8) = .empty;
    defer diags.deinit(a);
    try std.testing.expectError(error.DestinationExists, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, &diags));

    // Refused at preflight with the honest diagnostic, not later at promotion.
    var honest = false;
    var late = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d, "destination already exists") != null) honest = true;
        if (std.mem.indexOf(u8, d, "appeared during conversion") != null) late = true;
    }
    try std.testing.expect(honest);
    try std.testing.expect(!late);
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "accented v1 routine days convert Monday-first" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", "routines/state.md", "# Routines\n\n| rutina | cadencia | última |\n| --- | --- | --- |\n| a | semanal:mié | 2026-01-05 |\n| b | semanal:sáb | 2026-01-03 |\n");

    const report = try run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = false }, null);
    try std.testing.expect(report.checked);
    const routines = try readStoreFile(a, io, dest_abs, "routines/state.md");
    try std.testing.expect(std.mem.indexOf(u8, routines, "| a | weekly:wed | 2026-01-05 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "| b | weekly:sat | 2026-01-03 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "mié") == null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "sáb") == null);
    try std.testing.expect(std.mem.indexOf(u8, routines, "semanal:") == null);
}

test "a dry run against an invalid store writes nothing" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = try a.dupe(u8, path_buf[0..n]);
    const src_abs = try std.fs.path.join(a, &.{ base, "src" });
    const dest_abs = try std.fs.path.join(a, &.{ base, "v2" });
    const today = try platform.parseDate("2026-11-11");

    try writeV1Store(io, a, &tmp, "src");
    try put(io, a, &tmp, "src", ".state/pending.json", "{}\n");
    const before = try snapshot(a, io, src_abs);

    try std.testing.expectError(error.PendingTransaction, run(io, a, .{ .from = src_abs, .to = dest_abs, .today = today, .dry_run = true }, null));
    try std.testing.expectEqual(@as(usize, 0), try countStages(a, io, base));
    try std.testing.expectError(error.FileNotFound, readStoreFile(a, io, dest_abs, "config.json"));
    try expectSourceUnchanged(a, io, src_abs, &before);
}

test "error names are stable CLI codes" {
    const pairs = [_]struct { err: anyerror, code: []const u8 }{
        .{ .err = error.AmbiguousSource, .code = "ambiguous_source" },
        .{ .err = error.MixedSignals, .code = "mixed_signals" },
        .{ .err = error.UnsupportedFormat, .code = "unsupported_format" },
        .{ .err = error.KeyCollision, .code = "key_collision" },
        .{ .err = error.DestinationExists, .code = "destination_exists" },
        .{ .err = error.PathOverlap, .code = "path_overlap" },
        .{ .err = error.UnsupportedEntry, .code = "unsupported_entry" },
        .{ .err = error.StageInvalid, .code = "stage_invalid" },
        .{ .err = error.SourceChanged, .code = "source_changed" },
        .{ .err = error.SourceNotFound, .code = "invalid_workspace" },
        .{ .err = error.DestinationParentMissing, .code = "invalid_workspace" },
        .{ .err = error.InvalidDestination, .code = "invalid_workspace" },
        .{ .err = error.InvalidStoreStructure, .code = "invalid_workspace" },
        // Engine-vocabulary fallbacks.
        .{ .err = error.PendingTransaction, .code = "pending_transaction" },
        .{ .err = error.MalformedTask, .code = "invalid_field" },
        .{ .err = error.DuplicateId, .code = "duplicate_id" },
        .{ .err = error.MalformedRoutine, .code = "invalid_field" },
        .{ .err = error.InvalidConfig, .code = "unsupported_format" },
    };
    for (pairs) |pair| {
        try std.testing.expectEqualStrings(pair.code, errorName(pair.err));
    }
}
