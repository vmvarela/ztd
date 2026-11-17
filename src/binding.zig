const std = @import("std");
const config = @import("config.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

/// Repository binding file name. The file holds exactly
/// `{context, client, project}` — no paths, URLs, roots or store config.
pub const file_name = ".ztd.json";

/// The three required keys. Strings are owned by the allocator passed to
/// `parse`.
pub const Binding = struct {
    context: []const u8,
    /// Required key, nullable value: `null` when the repository declares no
    /// client. The field has no default on purpose, so a missing key fails
    /// with `error.MissingField` instead of reading as `null`.
    client: ?[]const u8,
    project: []const u8,

    pub fn deinit(self: Binding, alloc: std.mem.Allocator) void {
        alloc.free(self.context);
        alloc.free(self.project);
        if (self.client) |c| alloc.free(c);
    }
};

/// Why a binding file was refused, for `status`/`check` reporting.
pub const Problem = enum {
    /// Not a JSON document (or an empty one).
    syntax,
    /// A value has the wrong JSON type.
    type_mismatch,
    /// One of `context`, `client`, `project` is absent.
    missing_key,
    /// A key outside the exact three.
    unknown_key,
    /// A repeated key.
    duplicate_key,
    /// Empty or whitespace-only `context`, `client` or `project`.
    blank_value,
    /// Path-like `context`/`client`, or a `project` that fails
    /// `config.projectValid` (traversal, absolute, separator).
    unsafe_value,
    /// `project` is not exactly `context/name` or `context/client/name`.
    inconsistent,
    /// The file is a symlink; discovery never follows one.
    symlink,
    /// The file exists but cannot be inspected or read.
    unreadable,

    pub fn message(self: Problem) []const u8 {
        return switch (self) {
            .syntax => "not valid JSON",
            .type_mismatch => "value has the wrong type",
            .missing_key => "missing required key",
            .unknown_key => "unknown key",
            .duplicate_key => "duplicate key",
            .blank_value => "blank value",
            .unsafe_value => "unsafe identifier or project path",
            .inconsistent => "project does not match context and client",
            .symlink => "must not be a symlink",
            .unreadable => "cannot be inspected or read",
        };
    }
};

/// Result of `parse`: an owned binding, or the problem found.
pub const Parsed = union(enum) {
    binding: Binding,
    invalid: Problem,

    pub fn deinit(self: Parsed, alloc: std.mem.Allocator) void {
        switch (self) {
            .binding => |b| b.deinit(alloc),
            .invalid => {},
        }
    }
};

/// On-disk shape. Parsed with the `std.json` defaults, so duplicate fields,
/// unknown fields and type mismatches fail closed.
const Raw = struct {
    context: []const u8,
    client: ?[]const u8,
    project: []const u8,
};

/// Strict parse plus file-level validation: exact keys, nonblank values,
/// segment-safe `context`/`client`/project parts (no control bytes, no
/// cross-platform path-invalid or reserved segments), a
/// `config.projectValid` project, and a project fully qualified as
/// `context/name` or `context/client/name` — never a suffix. Returns the
/// owned binding or the problem; only `OutOfMemory` is an error.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Parsed {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{ .invalid = .syntax };
    var parsed = std.json.parseFromSlice(Raw, alloc, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .invalid = jsonProblem(err) },
    };
    defer parsed.deinit();
    const raw = parsed.value;

    if (blank(raw.context) or blank(raw.project)) return .{ .invalid = .blank_value };
    if (raw.client) |c| if (blank(c)) return .{ .invalid = .blank_value };
    if (!segmentSafe(raw.context)) return .{ .invalid = .unsafe_value };
    if (raw.client) |c| if (!segmentSafe(c)) return .{ .invalid = .unsafe_value };
    if (!config.projectValid(raw.project)) return .{ .invalid = .unsafe_value };
    var parts = std.mem.splitScalar(u8, raw.project, '/');
    while (parts.next()) |part| {
        if (!segmentSafe(part)) return .{ .invalid = .unsafe_value };
    }
    if (!consistent(raw)) return .{ .invalid = .inconsistent };

    const context = try alloc.dupe(u8, raw.context);
    errdefer alloc.free(context);
    const project = try alloc.dupe(u8, raw.project);
    errdefer alloc.free(project);
    const client: ?[]const u8 = if (raw.client) |c| try alloc.dupe(u8, c) else null;
    return .{ .binding = .{ .context = context, .client = client, .project = project } };
}

fn jsonProblem(err: anyerror) Problem {
    return switch (err) {
        error.MissingField => .missing_key,
        error.UnknownField => .unknown_key,
        error.DuplicateField => .duplicate_key,
        error.UnexpectedToken => .type_mismatch,
        else => .syntax, // SyntaxError and friends: malformed document.
    };
}

fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

/// A path segment usable on every supported platform: no control bytes
/// (including NUL, newline and DEL), none of Windows' invalid characters,
/// no reserved device name, no trailing dot or space, no dot segment.
/// Ordinary Unicode and internal spaces stay valid.
fn segmentSafe(seg: []const u8) bool {
    if (seg.len == 0) return false;
    for (seg) |c| {
        if (c < 0x20 or c == 0x7f) return false; // control bytes + DEL
        switch (c) {
            '/', '\\', '<', '>', ':', '"', '|', '?', '*' => return false,
            else => {},
        }
    }
    if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    const last = seg[seg.len - 1];
    if (last == '.' or last == ' ') return false; // Win32 strips these away
    return !reserved(seg);
}

/// Windows device names stay reserved with or without an extension, in any
/// case, so a `lists/projects/<context>/...` path remains creatable there.
fn reserved(seg: []const u8) bool {
    const base_len = std.mem.indexOfScalar(u8, seg, '.') orelse seg.len;
    const base = seg[0..base_len];
    const names = [_][]const u8{
        "CON",  "PRN",  "AUX",  "NUL",
        "COM1", "COM2", "COM3", "COM4",
        "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3",
        "LPT4", "LPT5", "LPT6", "LPT7",
        "LPT8", "LPT9",
    };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(base, n)) return true;
    }
    return false;
}

fn consistent(raw: Raw) bool {
    var it = std.mem.splitScalar(u8, raw.project, '/');
    if (!std.mem.eql(u8, it.next() orelse return false, raw.context)) return false;
    if (raw.client) |c| {
        // context/client/name — exactly three parts.
        if (!std.mem.eql(u8, it.next() orelse return false, c)) return false;
        _ = it.next() orelse return false;
        return it.next() == null;
    }
    // context/name — exactly two parts.
    _ = it.next() orelse return false;
    return it.next() == null;
}

/// A discovered binding: the file it came from plus the parsed values.
pub const Found = struct {
    path: []const u8,
    binding: Binding,

    pub fn deinit(self: Found, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        self.binding.deinit(alloc);
    }
};

/// A file was refused — the binding itself, or the `.git` marker that could
/// not be inspected — and nothing above it is consulted.
pub const Invalid = struct {
    path: []const u8,
    problem: Problem,

    pub fn deinit(self: Invalid, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

/// Outcome of the upward search. All payloads are owned by the allocator
/// passed to `discover`.
pub const Discovery = union(enum) {
    found: Found,
    invalid: Invalid,
    /// No binding file in scope (repository boundary reached, or filesystem
    /// root when there is no boundary).
    absent,

    pub fn deinit(self: Discovery, alloc: std.mem.Allocator) void {
        switch (self) {
            .found => |f| f.deinit(alloc),
            .invalid => |i| i.deinit(alloc),
            .absent => {},
        }
    }
};

/// Read-only discovery from the current working directory: walks upward
/// through the current Git repository only — a `.git` directory or worktree
/// `.git` file makes a directory the last one inspected (its own binding is
/// still included) — and with no boundary continues to the filesystem root.
/// The nearest `.ztd.json` wins; a malformed, symlinked or unreadable one is
/// reported as `.invalid` and nothing above it is consulted, and a `.git`
/// marker that cannot be inspected fails closed the same way. Never reads
/// the store and never affects `store.rootPath`.
pub fn discover(io: std.Io, alloc: std.mem.Allocator) !Discovery {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(io, &buf);
    return discoverFrom(io, alloc, buf[0..n]);
}

fn discoverFrom(io: std.Io, alloc: std.mem.Allocator, start: []const u8) !Discovery {
    var current = try alloc.dupe(u8, start);
    defer alloc.free(current);
    while (true) {
        if (try inspect(io, alloc, current)) |d| return d;
        if (try boundary(io, alloc, current)) |d| return d;
        const parent = std.fs.path.dirname(current) orelse return .absent;
        if (std.mem.eql(u8, parent, current)) return .absent;
        const next = try alloc.dupe(u8, parent);
        alloc.free(current);
        current = next;
    }
}

/// Classifies a marker lookup failure: `null` only for genuine absence, so
/// the walk continues; every other failure stops it with a diagnostic — an
/// inaccessible marker is never read as "no marker here".
fn pathProblem(err: anyerror) ?Problem {
    return switch (err) {
        error.FileNotFound => null,
        error.SymLinkLoop => .symlink,
        else => .unreadable,
    };
}

fn diagnostic(alloc: std.mem.Allocator, path: []const u8, problem: Problem) error{OutOfMemory}!?Discovery {
    const owned = try alloc.dupe(u8, path);
    return .{ .invalid = .{ .path = owned, .problem = problem } };
}

/// The `.git` marker in `dir`: genuine absence continues the walk; any
/// present marker — directory, worktree file or symlink, never followed —
/// stops it at the repository boundary; other stat failures fail closed as
/// a diagnostic instead of walking into a parent repository.
fn boundary(io: std.Io, alloc: std.mem.Allocator, dir: []const u8) !?Discovery {
    const git = try std.fs.path.join(alloc, &.{ dir, ".git" });
    defer alloc.free(git);
    _ = std.Io.Dir.cwd().statFile(io, git, .{ .follow_symlinks = false }) catch |err| {
        if (pathProblem(err)) |problem| return diagnostic(alloc, git, problem);
        return null; // genuine FileNotFound: no marker in this directory
    };
    return .absent; // present marker of any kind: repository boundary
}

/// The binding in `dir`, or null when it is genuinely absent (keep walking).
/// The file is opened with `O_NOFOLLOW`, so a symlinked binding is refused
/// atomically and never followed; access, type and read errors become a
/// diagnostic instead of falling through, and OOM propagates.
fn inspect(io: std.Io, alloc: std.mem.Allocator, dir: []const u8) !?Discovery {
    const candidate = try std.fs.path.join(alloc, &.{ dir, file_name });
    defer alloc.free(candidate);

    var file = std.Io.Dir.cwd().openFile(io, candidate, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| {
        if (pathProblem(err)) |problem| return diagnostic(alloc, candidate, problem);
        return null;
    };
    defer file.close(io);

    // The descriptor is the opened inode; the kind check covers platforms
    // that hand back a reparse point instead of refusing it.
    const st = file.stat(io) catch return diagnostic(alloc, candidate, .unreadable);
    switch (st.kind) {
        .file => {},
        .sym_link => return diagnostic(alloc, candidate, .symlink),
        else => return diagnostic(alloc, candidate, .unreadable),
    }

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const text = reader.interface.allocRemaining(alloc, .limited(store_mod.max_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return diagnostic(alloc, candidate, .unreadable),
    };
    defer alloc.free(text);

    const path = try alloc.dupe(u8, candidate);
    errdefer alloc.free(path);
    return switch (try parse(alloc, text)) {
        .binding => |b| .{ .found = .{ .path = path, .binding = b } },
        .invalid => |p| .{ .invalid = .{ .path = path, .problem = p } },
    };
}

/// Read-only validation of a parsed binding against the resolved store: the
/// context must be registered in `contexts.md`; an absent client blocks only
/// when the context is in `requireClientFor`, while a present client needs
/// the context in `clientOnlyIn`; and the fully qualified project must be
/// registered under `lists/projects/` (exact path, no suffix matching).
/// Never reads the repository or its remotes. Domain errors:
/// `InvalidContext`, `InvalidClient`, `MissingClient`, `InvalidProject` —
/// plus the store read errors of `config.load`/`loadContexts`.
pub fn validate(store: *Store, alloc: std.mem.Allocator, b: Binding) !void {
    var contexts = try config.loadContexts(store, alloc);
    defer {
        for (contexts.items) |c| alloc.free(c);
        contexts.deinit(alloc);
    }
    if (!config.contains(contexts.items, b.context)) return error.InvalidContext;

    // As in Engine.init, the policy returned by config.load is arena-owned:
    // pass an arena-backed allocator.
    const cfg = try config.load(store, alloc);
    if (b.client != null) {
        if (!config.contains(cfg.policy.clientOnlyIn, b.context)) return error.InvalidClient;
    } else if (config.contains(cfg.policy.requireClientFor, b.context)) {
        return error.MissingClient;
    }

    if (!config.projectRegistered(store, alloc, b.project)) return error.InvalidProject;
}

const valid_binding = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/blog\"}";

fn mkdirP(io: std.Io, tmp: *std.testing.TmpDir, path: []const u8) !void {
    tmp.dir.createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeTmp(io: std.Io, tmp: *std.testing.TmpDir, rel: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel)) |dir| try mkdirP(io, tmp, dir);
    try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = data });
}

fn startPath(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ base, rel });
}

fn seedStore(io: std.Io, tmp: *std.testing.TmpDir, alloc: std.mem.Allocator, base: []const u8) !void {
    const init_mod = @import("init.zig");
    _ = try init_mod.initWorkspace(io, alloc, base, false);
    // `work` requires and allows a client; `personal` allows one optionally;
    // `health` allows none.
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data = "{\"format\":2,\"policy\":{\"requireClientFor\":[\"work\"],\"clientOnlyIn\":[\"work\",\"personal\"]}}\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "contexts.md",
        .data = "| Context | Use |\n| --- | --- |\n| personal | Personal |\n| work | Work |\n| health | Health |\n",
    });
    try mkdirP(io, tmp, "lists/projects/personal/acme");
    try mkdirP(io, tmp, "lists/projects/work/acme");
    try tmp.dir.writeFile(io, .{ .sub_path = "lists/projects/personal/blog.md", .data = "# Blog\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lists/projects/personal/acme/notes.md", .data = "# Notes\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lists/projects/work/acme/demo.md", .data = "# Demo\n" });
}

test "binding parsing accepts the exact shape and keeps a known client" {
    const alloc = std.testing.allocator;

    var with_client = try parse(alloc, "{\"context\":\"personal\",\"client\":\"acme\",\"project\":\"personal/acme/notes\"}");
    defer with_client.deinit(alloc);
    try std.testing.expect(with_client == .binding);
    try std.testing.expectEqualStrings("personal", with_client.binding.context);
    try std.testing.expectEqualStrings("acme", with_client.binding.client.?);
    try std.testing.expectEqualStrings("personal/acme/notes", with_client.binding.project);

    var null_client = try parse(alloc, "{\"context\":\"work\",\"client\":null,\"project\":\"work/demo\"}");
    defer null_client.deinit(alloc);
    try std.testing.expect(null_client == .binding);
    try std.testing.expect(null_client.binding.client == null);
}

test "binding parsing rejects wrong, missing, extra and duplicate keys" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { text: []const u8, problem: Problem }{
        .{ .text = "{}", .problem = .missing_key },
        .{ .text = "{\"context\":\"personal\",\"client\":null}", .problem = .missing_key },
        .{ .text = "{\"context\":\"personal\",\"project\":\"personal/blog\"}", .problem = .missing_key },
        .{ .text = "{\"client\":null,\"project\":\"personal/blog\"}", .problem = .missing_key },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/blog\",\"root\":\"/srv\"}", .problem = .unknown_key },
        .{ .text = "{\"context\":\"personal\",\"context\":\"work\",\"client\":null,\"project\":\"personal/blog\"}", .problem = .duplicate_key },
        .{ .text = "{\"context\":5,\"client\":null,\"project\":\"personal/blog\"}", .problem = .type_mismatch },
        .{ .text = "{\"context\":\"personal\",\"client\":false,\"project\":\"personal/blog\"}", .problem = .type_mismatch },
        .{ .text = "{\"context\":null,\"client\":null,\"project\":\"personal/blog\"}", .problem = .type_mismatch },
        .{ .text = "[\"personal\",null,\"personal/blog\"]", .problem = .type_mismatch },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/blog\"", .problem = .syntax },
        .{ .text = "not json", .problem = .syntax },
        .{ .text = "", .problem = .syntax },
    };
    for (cases) |case| {
        var parsed = try parse(alloc, case.text);
        defer parsed.deinit(alloc);
        try std.testing.expect(parsed == .invalid);
        try std.testing.expectEqual(case.problem, parsed.invalid);
    }
}

test "binding parsing rejects blank and unsafe values" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { text: []const u8, problem: Problem }{
        .{ .text = "{\"context\":\"  \",\"client\":null,\"project\":\"personal/blog\"}", .problem = .blank_value },
        .{ .text = "{\"context\":\"personal\",\"client\":\"\\t \",\"project\":\"personal/blog\"}", .problem = .blank_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"   \"}", .problem = .blank_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"../outside\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/../../etc\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"/etc/passwd\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal\\\\notes\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"a/b\",\"client\":null,\"project\":\"a/b/name\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\".\",\"client\":null,\"project\":\"./name\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":\"a/b\",\"project\":\"personal/a/b/name\"}", .problem = .unsafe_value },
    };
    for (cases) |case| {
        var parsed = try parse(alloc, case.text);
        defer parsed.deinit(alloc);
        try std.testing.expect(parsed == .invalid);
        try std.testing.expectEqual(case.problem, parsed.invalid);
    }
}

test "segment safety rejects control and platform-invalid characters" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { text: []const u8, problem: Problem }{
        // Control bytes reach values through JSON escapes only.
        .{ .text = "{\"context\":\"a\\u0000b\",\"client\":null,\"project\":\"a\\u0000b/blog\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"line\\nbreak\",\"client\":null,\"project\":\"line\\nbreak/blog\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"tab\\there\",\"client\":null,\"project\":\"tab\\there/blog\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"del\\u007f\",\"client\":null,\"project\":\"del\\u007f/blog\"}", .problem = .unsafe_value },
        // Windows-invalid characters in any segment.
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/bad:name\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/a|b\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/q?x\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/wild*\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/<tag>\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/say\\\"hi\"}", .problem = .unsafe_value },
        // Reserved device names, with or without extension, any case.
        .{ .text = "{\"context\":\"CON\",\"client\":null,\"project\":\"CON/blog\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"work\",\"client\":\"com1\",\"project\":\"work/com1/demo\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/nul.md\"}", .problem = .unsafe_value },
        // Win32 strips trailing dots and spaces from names.
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/trailing.\"}", .problem = .unsafe_value },
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/trailing \"}", .problem = .unsafe_value },
    };
    for (cases) |case| {
        var parsed = try parse(alloc, case.text);
        defer parsed.deinit(alloc);
        try std.testing.expect(parsed == .invalid);
        try std.testing.expectEqual(case.problem, parsed.invalid);
    }

    // Ordinary Unicode and internal spaces stay valid.
    var spaces = try parse(alloc, "{\"context\":\"my project\",\"client\":null,\"project\":\"my project/niño\"}");
    defer spaces.deinit(alloc);
    try std.testing.expect(spaces == .binding);
    var unicode = try parse(alloc, "{\"context\":\"café room\",\"client\":null,\"project\":\"café room/blog\"}");
    defer unicode.deinit(alloc);
    try std.testing.expect(unicode == .binding);
}

test "binding parsing requires the project to match context and client" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { text: []const u8, problem: Problem }{
        // Another context's project is not a suffix match for this one.
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"work/blog\"}", .problem = .inconsistent },
        // No project name after the context.
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal\"}", .problem = .inconsistent },
        // A client segment without a declared client.
        .{ .text = "{\"context\":\"personal\",\"client\":null,\"project\":\"personal/acme/notes\"}", .problem = .inconsistent },
        // A declared client without its segment.
        .{ .text = "{\"context\":\"work\",\"client\":\"acme\",\"project\":\"work/demo\"}", .problem = .inconsistent },
        // A client segment naming a different client.
        .{ .text = "{\"context\":\"work\",\"client\":\"other\",\"project\":\"work/acme/demo\"}", .problem = .inconsistent },
        // Deeper than the qualified layout.
        .{ .text = "{\"context\":\"work\",\"client\":\"acme\",\"project\":\"work/acme/demo/extra\"}", .problem = .inconsistent },
    };
    for (cases) |case| {
        var parsed = try parse(alloc, case.text);
        defer parsed.deinit(alloc);
        try std.testing.expect(parsed == .invalid);
        try std.testing.expectEqual(case.problem, parsed.invalid);
    }
}

test "a malformed binding is reported without falling back to an outer one" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    try writeTmp(io, &tmp, ".ztd.json", valid_binding);
    try writeTmp(io, &tmp, "inner/.ztd.json", "{\"context\":\"personal\",\"client\":null}");
    try mkdirP(io, &tmp, "inner/deep");

    const start = try startPath(alloc, base, "inner/deep");
    defer alloc.free(start);
    const d = try discoverFrom(io, alloc, start);
    defer d.deinit(alloc);

    try std.testing.expect(d == .invalid);
    try std.testing.expectEqual(Problem.missing_key, d.invalid.problem);
    const expected = try startPath(alloc, base, "inner/.ztd.json");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, d.invalid.path);
}

test "a nested git boundary stops the search above the repository" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    try writeTmp(io, &tmp, "outer/.ztd.json", valid_binding);
    try mkdirP(io, &tmp, "outer/repo/.git");
    try mkdirP(io, &tmp, "outer/repo/sub");

    const start = try startPath(alloc, base, "outer/repo/sub");
    defer alloc.free(start);
    const d = try discoverFrom(io, alloc, start);
    defer d.deinit(alloc);
    try std.testing.expect(d == .absent);
}

test "a dangling .git symlink still stops the walk as a boundary" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    // Following the marker would report FileNotFound, read "no boundary"
    // and reach the parent binding; no-follow lstat sees the link itself.
    try writeTmp(io, &tmp, "outer/.ztd.json", valid_binding);
    try mkdirP(io, &tmp, "outer/repo/sub");
    try tmp.dir.symLink(io, "/nonexistent/.git", "outer/repo/.git", .{});

    const start = try startPath(alloc, base, "outer/repo/sub");
    defer alloc.free(start);
    const d = try discoverFrom(io, alloc, start);
    defer d.deinit(alloc);
    try std.testing.expect(d == .absent);
}

test "the binding at the repository root is included before the boundary stops the walk" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    try mkdirP(io, &tmp, "repo/.git");
    try writeTmp(io, &tmp, "repo/.ztd.json", valid_binding);
    try mkdirP(io, &tmp, "repo/sub");

    const start = try startPath(alloc, base, "repo/sub");
    defer alloc.free(start);
    const d = try discoverFrom(io, alloc, start);
    defer d.deinit(alloc);

    try std.testing.expect(d == .found);
    const expected = try startPath(alloc, base, "repo/.ztd.json");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, d.found.path);
    try std.testing.expectEqualStrings("personal", d.found.binding.context);
    try std.testing.expect(d.found.binding.client == null);
    try std.testing.expectEqualStrings("personal/blog", d.found.binding.project);
}

test "a worktree .git file is a repository boundary" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    // Binding at the worktree root: included, then the file stops the walk.
    try writeTmp(io, &tmp, "wt/.git", "gitdir: /elsewhere/.git\n");
    try writeTmp(io, &tmp, "wt/.ztd.json", valid_binding);
    try mkdirP(io, &tmp, "wt/sub");
    const wt_start = try startPath(alloc, base, "wt/sub");
    defer alloc.free(wt_start);
    const wt = try discoverFrom(io, alloc, wt_start);
    defer wt.deinit(alloc);
    try std.testing.expect(wt == .found);
    const wt_expected = try startPath(alloc, base, "wt/.ztd.json");
    defer alloc.free(wt_expected);
    try std.testing.expectEqualStrings(wt_expected, wt.found.path);

    // Binding above the worktree: unreachable across the file boundary.
    try writeTmp(io, &tmp, "outer/.ztd.json", valid_binding);
    try writeTmp(io, &tmp, "outer/work/.git", "gitdir: /elsewhere/.git\n");
    try mkdirP(io, &tmp, "outer/work/sub");
    const out_start = try startPath(alloc, base, "outer/work/sub");
    defer alloc.free(out_start);
    const out = try discoverFrom(io, alloc, out_start);
    defer out.deinit(alloc);
    try std.testing.expect(out == .absent);
}

test "without a git boundary the search continues through ancestors" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    try writeTmp(io, &tmp, "plain/.ztd.json", valid_binding);
    try mkdirP(io, &tmp, "plain/a/b/c");

    const start = try startPath(alloc, base, "plain/a/b/c");
    defer alloc.free(start);
    const d = try discoverFrom(io, alloc, start);
    defer d.deinit(alloc);

    try std.testing.expect(d == .found);
    const expected = try startPath(alloc, base, "plain/.ztd.json");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, d.found.path);
}

test "marker lookup errors map to absence only for a genuine FileNotFound" {
    try std.testing.expect(pathProblem(error.FileNotFound) == null);
    try std.testing.expectEqual(Problem.symlink, pathProblem(error.SymLinkLoop).?);
    try std.testing.expectEqual(Problem.unreadable, pathProblem(error.AccessDenied).?);
    try std.testing.expectEqual(Problem.unreadable, pathProblem(error.PermissionDenied).?);
    try std.testing.expectEqual(Problem.unreadable, pathProblem(error.IsDir).?);
    try std.testing.expectEqual(Problem.unreadable, pathProblem(error.NotDir).?);
    try std.testing.expectEqual(Problem.unreadable, pathProblem(error.NameTooLong).?);
    try std.testing.expectEqual(Problem.unreadable, pathProblem(error.SystemResources).?);
}

test "a symlinked binding is refused and never followed" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    // Valid content outside the repository, plus a valid outer binding as
    // fallback bait: neither may be reached through the link or above it.
    try writeTmp(io, &tmp, "outside/.ztd.json", valid_binding);
    try writeTmp(io, &tmp, ".ztd.json", valid_binding);
    try mkdirP(io, &tmp, "repo/sub");
    try tmp.dir.symLink(io, "../outside/.ztd.json", "repo/.ztd.json", .{});

    const start = try startPath(alloc, base, "repo/sub");
    defer alloc.free(start);
    const d = try discoverFrom(io, alloc, start);
    defer d.deinit(alloc);

    try std.testing.expect(d == .invalid);
    try std.testing.expectEqual(Problem.symlink, d.invalid.problem);
    const expected = try startPath(alloc, base, "repo/.ztd.json");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, d.invalid.path);
}

test "an inaccessible binding is a diagnostic and never falls back to the parent" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    // A valid parent binding must not be reached past an unreadable nearest
    // one. Root and mode-ignoring filesystems cannot be tested this way.
    try writeTmp(io, &tmp, "outer/.ztd.json", valid_binding);
    try writeTmp(io, &tmp, "outer/repo/.ztd.json", valid_binding);
    try mkdirP(io, &tmp, "outer/repo/sub");
    try tmp.dir.setFilePermissions(io, "outer/repo/.ztd.json", @fromBackingInt(@intCast(0o000)), .{});
    defer tmp.dir.setFilePermissions(io, "outer/repo/.ztd.json", @fromBackingInt(@intCast(0o644)), .{}) catch {};

    const start = try startPath(alloc, base, "outer/repo/sub");
    defer alloc.free(start);
    const d = try discoverFrom(io, alloc, start);
    defer d.deinit(alloc);
    if (d == .found) return error.SkipZigTest; // permissions not enforced here
    try std.testing.expect(d == .invalid);
    try std.testing.expectEqual(Problem.unreadable, d.invalid.problem);
    const expected = try startPath(alloc, base, "outer/repo/.ztd.json");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, d.invalid.path);
}

test "a binding at the working directory never influences store root resolution" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];

    try writeTmp(io, &tmp, "workdir/.ztd.json", valid_binding);

    // Move the working directory onto the binding so `discover` sees it.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_n = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
    const orig = try alloc.dupe(u8, cwd_buf[0..cwd_n]);
    defer alloc.free(orig);
    const target = try startPath(alloc, base, "workdir");
    defer alloc.free(target);
    try std.Io.Threaded.chdir(target);
    defer std.Io.Threaded.chdir(orig) catch {};

    const d = try discover(io, alloc);
    defer d.deinit(alloc);
    try std.testing.expect(d == .found);
    const expected = try startPath(alloc, base, "workdir/.ztd.json");
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, d.found.path);

    // Root precedence is built from the environment alone, binding or not.
    const root = try store_mod.rootPath(io, alloc, null);
    defer alloc.free(root);
    const home = try store_mod.homeDir(io, alloc);
    defer alloc.free(home);
    const want = try std.fs.path.join(alloc, &.{ home, ".ztd" });
    defer alloc.free(want);
    try std.testing.expectEqualStrings(want, root);

    const explicit = try store_mod.rootPath(io, alloc, "/explicit/store");
    defer alloc.free(explicit);
    try std.testing.expectEqualStrings("/explicit/store", explicit);
}

test "binding validation accepts a registered context and project, keeping an optional client" {
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
    const base = path_buf[0..n];

    try seedStore(io, &tmp, a, base);
    var store = try Store.open(io, a, base);
    defer store.deinit();

    try validate(&store, a, .{ .context = "personal", .client = null, .project = "personal/blog" });
    try validate(&store, a, .{ .context = "work", .client = "acme", .project = "work/acme/demo" });

    // A known optional client parses, is preserved and passes policy.
    var parsed = try parse(a, "{\"context\":\"personal\",\"client\":\"acme\",\"project\":\"personal/acme/notes\"}");
    defer parsed.deinit(a);
    try std.testing.expect(parsed == .binding);
    try std.testing.expectEqualStrings("acme", parsed.binding.client.?);
    try validate(&store, a, parsed.binding);
}

test "binding validation enforces context, client policy and exact project registration" {
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
    const base = path_buf[0..n];

    try seedStore(io, &tmp, a, base);
    var store = try Store.open(io, a, base);
    defer store.deinit();

    try std.testing.expectError(error.InvalidContext, validate(&store, a, .{ .context = "family", .client = null, .project = "family/blog" }));
    // `work` is in requireClientFor: an absent client blocks, and only that
    // policy decides it.
    try std.testing.expectError(error.MissingClient, validate(&store, a, .{ .context = "work", .client = null, .project = "work/acme/demo" }));
    // `health` is in no client policy: a present client is invalid.
    try std.testing.expectError(error.InvalidClient, validate(&store, a, .{ .context = "health", .client = "acme", .project = "health/acme/checkup" }));
    try std.testing.expectError(error.InvalidProject, validate(&store, a, .{ .context = "personal", .client = null, .project = "personal/missing" }));
    // No suffix matching: `blog` is not `personal/blog`.
    try std.testing.expectError(error.InvalidProject, validate(&store, a, .{ .context = "personal", .client = null, .project = "blog" }));
}
