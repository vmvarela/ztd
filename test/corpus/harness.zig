//! Shared corpus harness: one CLI invocation becomes one normalized
//! observation, and the Go normalization rules are replayed byte for byte.
//! Port of corpus_test.go's runner/observation/normalize helpers.

const std = @import("std");
const process = std.process;

// ------------------------------------------------------------------- json

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn digitsN(s: []const u8, i: usize, n: usize) ?usize {
    if (i + n > s.len) return null;
    for (0..n) |k| {
        if (!isDigit(s[i + k])) return null;
    }
    return i + n;
}

fn boundaryBefore(s: []const u8, i: usize) bool {
    return i == 0 or !isWord(s[i - 1]);
}

fn boundaryAfter(s: []const u8, i: usize) bool {
    return i == s.len or !isWord(s[i]);
}

/// `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z` — no leading boundary,
/// matching Go's regexp exactly (leftmost, first match wins).
fn matchTimestamp(s: []const u8, i: usize) ?usize {
    var p = digitsN(s, i, 4) orelse return null;
    if (p >= s.len or s[p] != '-') return null;
    p = digitsN(s, p + 1, 2) orelse return null;
    if (p >= s.len or s[p] != '-') return null;
    p = digitsN(s, p + 1, 2) orelse return null;
    if (p >= s.len or s[p] != 'T') return null;
    p = digitsN(s, p + 1, 2) orelse return null;
    if (p >= s.len or s[p] != ':') return null;
    p = digitsN(s, p + 1, 2) orelse return null;
    if (p >= s.len or s[p] != ':') return null;
    p = digitsN(s, p + 1, 2) orelse return null;
    if (p < s.len and s[p] == '.') {
        var q = p + 1;
        while (q < s.len and isDigit(s[q])) q += 1;
        if (q == p + 1) return null; // `.` must open a `\.\d+` group
        p = q;
    }
    if (p < s.len and s[p] == 'Z') return p + 1;
    return null;
}

/// `\b[a-z][a-z_-]*-\d{15,}\b` with Go's greedy backtracking: try the
/// longest class run first, then shorter ones, digits greedy (only the full
/// digit run can satisfy the trailing boundary).
fn matchAutoKey(s: []const u8, i: usize) ?usize {
    if (!boundaryBefore(s, i)) return null;
    if (i >= s.len or s[i] < 'a' or s[i] > 'z') return null;
    var p = i + 1;
    while (p < s.len and ((s[p] >= 'a' and s[p] <= 'z') or s[p] == '_' or s[p] == '-')) p += 1;
    // Candidates are the class-run positions up to p; s[p] (when in range)
    // can never be '-', so start just below it.
    var q = @min(p, s.len - 1) + 1;
    while (q > i + 1) {
        q -= 1;
        if (s[q] != '-') continue;
        const d0 = q + 1;
        const d1 = digitsN(s, d0, 15) orelse continue;
        var end = d1;
        while (end < s.len and isDigit(s[end])) end += 1;
        if (boundaryAfter(s, end)) return end;
    }
    return null;
}

/// `C-\d{8}-\d{3}` / `T-...` / `F-...` — no word boundaries.
fn matchPrefixedId(s: []const u8, i: usize, letter: u8) ?usize {
    if (i + 1 >= s.len or s[i] != letter or s[i + 1] != '-') return null;
    const p = digitsN(s, i + 2, 8) orelse return null;
    if (p >= s.len or s[p] != '-') return null;
    return digitsN(s, p + 1, 3);
}

fn matchHash(s: []const u8, i: usize) ?usize {
    if (!boundaryBefore(s, i)) return null;
    if (i + 64 > s.len) return null;
    for (0..64) |k| {
        if (!isLowerHex(s[i + k])) return null;
    }
    if (!boundaryAfter(s, i + 64)) return null;
    return i + 64;
}

fn matchWeek(s: []const u8, i: usize) ?usize {
    if (!boundaryBefore(s, i)) return null;
    var p = digitsN(s, i, 4) orelse return null;
    if (p + 1 >= s.len or s[p] != '-' or s[p + 1] != 'W') return null;
    p = digitsN(s, p + 2, 2) orelse return null;
    if (!boundaryAfter(s, p)) return null;
    return p;
}

fn matchDate(s: []const u8, i: usize) ?usize {
    if (!boundaryBefore(s, i)) return null;
    var p = digitsN(s, i, 4) orelse return null;
    if (p >= s.len or s[p] != '-') return null;
    p = digitsN(s, p + 1, 2) orelse return null;
    if (p >= s.len or s[p] != '-') return null;
    p = digitsN(s, p + 1, 2) orelse return null;
    if (!boundaryAfter(s, p)) return null;
    return p;
}

const Matcher = *const fn (s: []const u8, i: usize) ?usize;

fn replaceAll(a: std.mem.Allocator, s: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    if (needle.len == 0) return a.dupe(u8, s);
    if (std.mem.indexOf(u8, s, needle) == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (true) {
        const hit = std.mem.indexOfPos(u8, s, i, needle) orelse break;
        try out.appendSlice(a, s[i..hit]);
        try out.appendSlice(a, repl);
        i = hit + needle.len;
    }
    try out.appendSlice(a, s[i..]);
    return out.toOwnedSlice(a);
}

fn replacePass(a: std.mem.Allocator, s: []const u8, matcher: Matcher, repl: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (matcher(s, i)) |end| {
            try out.appendSlice(a, repl);
            i = end;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// Erases the parts that legitimately differ between two runs: the clock,
/// generated IDs, content hashes and temporary paths. Same order as Go's
/// normalize: the given paths first, then the process temp dir, then each
/// pattern pass.
pub fn normalize(a: std.mem.Allocator, s: []const u8, paths: []const []const u8, sys_tmp: []const u8) ![]u8 {
    var cur = try a.dupe(u8, s);
    for (paths) |p| {
        if (p.len > 0) cur = try replaceAll(a, cur, p, "<tmp>");
    }
    if (sys_tmp.len > 0) cur = try replaceAll(a, cur, sys_tmp, "<tmp>");
    cur = try replacePass(a, cur, matchTimestamp, "<ts>");
    cur = try replacePass(a, cur, matchAutoKey, "<key>");
    cur = try replacePass(a, cur, matchIdC, "<cid>");
    cur = try replacePass(a, cur, matchIdT, "<tid>");
    cur = try replacePass(a, cur, matchIdF, "<fid>");
    cur = try replacePass(a, cur, matchHash, "<hash>");
    cur = try replacePass(a, cur, matchWeek, "<week>");
    cur = try replacePass(a, cur, matchDate, "<date>");
    return cur;
}

fn matchIdC(s: []const u8, i: usize) ?usize {
    return matchPrefixedId(s, i, 'C');
}
fn matchIdT(s: []const u8, i: usize) ?usize {
    return matchPrefixedId(s, i, 'T');
}
fn matchIdF(s: []const u8, i: usize) ?usize {
    return matchPrefixedId(s, i, 'F');
}

// ------------------------------------------------------------ json writing

/// Byte-wise string ordering for std.mem.sort (Go's map key order).
pub fn lessStr(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// JSON string escaping as the checked-in goldens show it: like Go's
/// encoding/json minus the HTML escaping (the goldens carry literal `<`).
pub fn writeJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x20) {
            switch (b) {
                '\n' => try out.appendSlice(a, "\\n"),
                '\r' => try out.appendSlice(a, "\\r"),
                '\t' => try out.appendSlice(a, "\\t"),
                else => try out.print(a, "\\u00{x:0>2}", .{@as(u32, b)}),
            }
            i += 1;
            continue;
        }
        switch (b) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            else => {},
        }
        if (b == '"' or b == '\\') {
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            try out.appendSlice(a, "\\ufffd");
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            try out.appendSlice(a, "\\ufffd");
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            try out.appendSlice(a, "\\ufffd");
            i += 1;
            continue;
        };
        if (cp == 0x2028) {
            try out.appendSlice(a, "\\u2028");
        } else if (cp == 0x2029) {
            try out.appendSlice(a, "\\u2029");
        } else {
            try out.appendSlice(a, s[i .. i + n]);
        }
        i += n;
    }
    try out.append(a, '"');
}

/// Float rendering copied from src/json.zig so recorded bytes match what the
/// product printed (Go encoding/json semantics: shortest, exponential for
/// extreme magnitudes).
pub fn writeFloat(out: *std.ArrayList(u8), a: std.mem.Allocator, v: f64) !void {
    const abs: f64 = @abs(v);
    if (abs != 0 and (abs < 1e-6 or abs >= 1e21)) {
        var buf: [512]u8 = undefined;
        const dec = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return out.print(a, "{d}", .{v});
        return writeExponential(out, a, dec);
    }
    return out.print(a, "{d}", .{v});
}

fn writeExponential(out: *std.ArrayList(u8), a: std.mem.Allocator, dec: []const u8) !void {
    var body = dec;
    if (body.len > 0 and body[0] == '-') {
        try out.append(a, '-');
        body = body[1..];
    }
    const dot = std.mem.indexOfScalar(u8, body, '.');
    const ip = if (dot) |d| body[0..d] else body;
    const fp = if (dot) |d| body[d + 1 ..] else body[0..0];

    var digits_buf: [512]u8 = undefined;
    if (ip.len + fp.len > digits_buf.len) return out.appendSlice(a, dec);
    @memcpy(digits_buf[0..ip.len], ip);
    @memcpy(digits_buf[ip.len .. ip.len + fp.len], fp);
    var digits = digits_buf[0 .. ip.len + fp.len];
    var start: usize = 0;
    while (start < digits.len and digits[start] == '0') start += 1;
    if (start == digits.len) return out.appendSlice(a, if (dec[0] == '-') "-0" else "0");
    digits = digits[start..];
    const exp: i64 = @as(i64, @intCast(digits.len)) - @as(i64, @intCast(fp.len)) - 1;
    var end = digits.len;
    while (end > 1 and digits[end - 1] == '0') end -= 1;
    const mant = digits[0..end];

    try out.append(a, mant[0]);
    if (mant.len > 1) {
        try out.append(a, '.');
        try out.appendSlice(a, mant[1..]);
    }
    try out.append(a, 'e');
    try out.append(a, if (exp < 0) '-' else '+');
    var e: u64 = @intCast(if (exp < 0) -exp else exp);
    var ebuf: [4]u8 = undefined;
    var n = ebuf.len;
    while (true) {
        n -= 1;
        ebuf[n] = @intCast('0' + @as(u8, @intCast(e % 10)));
        e /= 10;
        if (e == 0) break;
    }
    try out.appendSlice(a, ebuf[n..]);
}

/// Renders a `std.json.Value` with Go's `json.MarshalIndent(v, "", "  ")`
/// layout: every nested container indents two spaces deeper.
pub fn writeJsonValue(out: *std.ArrayList(u8), a: std.mem.Allocator, v: std.json.Value, level: usize) !void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |i| try out.print(a, "{d}", .{i}),
        .float => |f| try writeFloat(out, a, f),
        .number_string => |s| try out.appendSlice(a, s),
        .string => |s| try writeJsonString(out, a, s),
        .array => |arr| {
            if (arr.items.len == 0) return out.appendSlice(a, "[]");
            try out.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try out.append(a, '\n');
                try out.appendNTimes(a, ' ', 2 * (level + 1));
                try writeJsonValue(out, a, item, level + 1);
            }
            try out.append(a, '\n');
            try out.appendNTimes(a, ' ', 2 * level);
            try out.append(a, ']');
        },
        .object => |obj| {
            if (obj.count() == 0) return out.appendSlice(a, "{}");
            try out.append(a, '{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try out.append(a, ',');
                first = false;
                try out.append(a, '\n');
                try out.appendNTimes(a, ' ', 2 * (level + 1));
                try writeJsonString(out, a, entry.key_ptr.*);
                try out.appendSlice(a, ": ");
                try writeJsonValue(out, a, entry.value_ptr.*, level + 1);
            }
            try out.append(a, '\n');
            try out.appendNTimes(a, ' ', 2 * level);
            try out.append(a, '}');
        },
    }
}

// -------------------------------------------------------------- value paths

fn scanIndex(s: []const u8) ?i64 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    if (i >= s.len or !isDigit(s[i])) return null;
    var v: i64 = 0;
    while (i < s.len and isDigit(s[i])) {
        v = std.math.mul(i64, v, 10) catch return null;
        v = std.math.add(i64, v, s[i] - '0') catch return null;
        i += 1;
    }
    return if (neg) -v else v;
}

/// Walks a field path over parsed JSON; "" when absent, like Go's
/// observation.value (which only yields strings).
pub fn jsonValuePath(parsed: std.json.Value, path: []const []const u8) []const u8 {
    var v = parsed;
    for (path) |p| {
        switch (v) {
            .object => |obj| v = obj.get(p) orelse return "",
            .array => |arr| {
                const idx = scanIndex(p) orelse return "";
                if (idx < 0 or idx >= @as(i64, @intCast(arr.items.len))) return "";
                v = arr.items[@intCast(idx)];
            },
            else => return "",
        }
    }
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Finds the byte span of the top-level `key` value inside one JSON document,
/// so byte-cap assertions count the same bytes Go's json.RawMessage held.
pub fn topLevelValueSpan(s: []const u8, key: []const u8) ?[]const u8 {
    var i = skipWs(s, 0);
    if (i >= s.len or s[i] != '{') return null;
    i += 1;
    while (true) {
        i = skipWs(s, i);
        if (i >= s.len or s[i] != '"') return null;
        const key_end = scanString(s, i) orelse return null;
        const raw_key = s[i + 1 .. key_end - 1];
        i = skipWs(s, key_end);
        if (i >= s.len or s[i] != ':') return null;
        i = skipWs(s, i + 1);
        const val_start = i;
        const val_end = valueSpan(s, i) orelse return null;
        if (std.mem.eql(u8, raw_key, key)) return s[val_start..val_end];
        i = skipWs(s, val_end);
        if (i >= s.len) return null;
        if (s[i] == ',') {
            i += 1;
            continue;
        }
        if (s[i] == '}') return null;
        return null;
    }
}

fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n' or s[j] == '\r')) j += 1;
    return j;
}

fn scanString(s: []const u8, i: usize) ?usize {
    // i points at '"'
    var j = i + 1;
    while (j < s.len) {
        if (s[j] == '\\') {
            j += 2;
            continue;
        }
        if (s[j] == '"') return j + 1;
        j += 1;
    }
    return null;
}

fn valueSpan(s: []const u8, i: usize) ?usize {
    if (i >= s.len) return null;
    return switch (s[i]) {
        '"' => scanString(s, i),
        '{', '[' => blk: {
            var depth: usize = 0;
            var j = i;
            var in_str = false;
            while (j < s.len) {
                const c = s[j];
                if (in_str) {
                    if (c == '\\') {
                        j += 2;
                        continue;
                    }
                    if (c == '"') in_str = false;
                } else if (c == '"') {
                    in_str = true;
                } else if (c == '{' or c == '[') {
                    depth += 1;
                } else if (c == '}' or c == ']') {
                    depth -= 1;
                    if (depth == 0) break :blk j + 1;
                }
                j += 1;
            }
            return null;
        },
        't' => if (std.mem.startsWith(u8, s[i..], "true")) i + 4 else null,
        'f' => if (std.mem.startsWith(u8, s[i..], "false")) i + 5 else null,
        'n' => if (std.mem.startsWith(u8, s[i..], "null")) i + 4 else null,
        else => blk: {
            var j = i;
            if (j < s.len and s[j] == '-') j += 1;
            while (j < s.len and (isDigit(s[j]) or s[j] == '.' or s[j] == 'e' or s[j] == 'E' or s[j] == '+' or s[j] == '-')) j += 1;
            if (j == i) return null;
            break :blk j;
        },
    };
}

// ------------------------------------------------------------ runner

pub const Obs = struct {
    code: i64,
    /// Normalized JSON envelope text, or null when stdout was empty.
    envelope: ?[]const u8,
    stderr_text: []const u8,
    /// Trimmed raw stdout, or null when empty (unnormalized, for readers).
    raw: ?[]const u8,
    argv: []const []const u8,

    /// Decodes the raw envelope and walks a field path; "" when absent.
    pub fn value(self: Obs, a: std.mem.Allocator, path: []const []const u8) []const u8 {
        const raw = self.raw orelse return "";
        const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return "";
        return jsonValuePath(parsed.value, path);
    }

    pub fn id(self: Obs, a: std.mem.Allocator) []const u8 {
        const id_path = [_][]const u8{ "data", "id" };
        return self.value(a, &id_path);
    }
};

pub const Runner = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    bin: []const u8,
    sys_tmp: []const u8,
    root: []const u8,
    home: []const u8,
    tmpdir: []const u8,
    db: []const u8,
    env: process.Environ.Map,
    steps: std.ArrayList(Obs),

    /// Creates the throwaway HOME/TMPDIR/work layout Go's t.TempDir builds:
    /// one base directory holding the database, the fixture files and home.
    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        a: std.mem.Allocator,
        bin: []const u8,
        parent_env: *const process.Environ.Map,
        sys_tmp: []const u8,
    ) !Runner {
        const sep = if (sys_tmp.len > 0 and sys_tmp[sys_tmp.len - 1] == '/') "" else "/";
        const root = try std.fmt.allocPrint(a, "{s}{s}ztd-corpus-{d}-{d}", .{
            sys_tmp,
            sep,
            std.c.getpid(),
            std.Io.Timestamp.now(io, .real).nanoseconds,
        });
        try mkdirs(io, root);
        const tmpdir = try std.fmt.allocPrint(a, "{s}/tmp", .{root});
        try mkdirs(io, tmpdir);
        const home = try std.fmt.allocPrint(a, "{s}/home", .{root});
        const db = try std.fmt.allocPrint(a, "{s}/ztd.db", .{root});

        var env = process.Environ.Map.init(gpa);
        errdefer env.deinit();
        const env_path = parent_env.get("PATH") orelse "";
        try env.put("PATH", env_path);
        try env.put("HOME", home);
        try env.put("USERPROFILE", home);
        try env.put("TMPDIR", tmpdir);
        try env.put("USER", "ztd-corpus");

        return .{
            .io = io,
            .gpa = gpa,
            .a = a,
            .bin = bin,
            .sys_tmp = sys_tmp,
            .root = root,
            .home = home,
            .tmpdir = tmpdir,
            .db = db,
            .env = env,
            .steps = .empty,
        };
    }

    pub fn deinit(self: *Runner) void {
        self.env.deinit();
        self.steps.deinit(self.a);
    }

    /// Best-effort cleanup of the throwaway tree; failure keeps the data for
    /// debugging instead of failing the suite.
    pub fn cleanup(self: *Runner) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
    }

    /// An absolute path inside the runner's work directory.
    pub fn path(self: *Runner, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, name });
    }

    /// Creates a fixture file next to the database and returns its path.
    pub fn write(self: *Runner, name: []const u8, content: []const u8) ![]const u8 {
        const p = try self.path(name);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = content });
        return p;
    }

    /// Executes one invocation with --json and a throwaway HOME, appending
    /// the normalized observation to the session.
    pub fn run(self: *Runner, args: []const []const u8) !Obs {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, self.bin);
        try argv.append(self.gpa, "--json");
        try argv.append(self.gpa, "--db");
        try argv.append(self.gpa, self.db);
        try argv.appendSlice(self.gpa, args);

        const res = process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.root },
            .environ_map = &self.env,
        }) catch |e| {
            std.debug.print("run {any}: spawn failed: {s}\n", .{ args, @errorName(e) });
            return error.RunFailed;
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);

        const code: i64 = switch (res.term) {
            .exited => |c| c,
            // Go's ExitCode() reports -1 when the process did not exit.
            else => -1,
        };

        const paths = [_][]const u8{ self.root, self.home, self.tmpdir };
        const stderr_norm = try normalize(self.a, res.stderr, &paths, self.sys_tmp);

        var obs: Obs = .{
            .code = code,
            .envelope = null,
            .stderr_text = stderr_norm,
            .raw = null,
            .argv = args,
        };

        const trimmed = trimAsciiWs(res.stdout);
        if (trimmed.len > 0) {
            _ = std.json.parseFromSlice(std.json.Value, self.a, trimmed, .{}) catch |e| {
                std.debug.print("run {any}: stdout is not JSON: {s}\n---\n{s}\n---\n", .{ args, @errorName(e), trimmed });
                return error.RunFailed;
            };
            // The owned stdout buffer is freed below; keep our own copy.
            obs.raw = try self.a.dupe(u8, trimmed);
            // The product prints compact JSON, so the trimmed document is
            // byte-identical to Go's json.Compact output here.
            obs.envelope = try normalize(self.a, trimmed, &paths, self.sys_tmp);
        }
        try self.steps.append(self.a, obs);
        return obs;
    }
};

/// mkdir -p for an absolute path: createDirPath is relative-only, so walk the
/// prefix with createDirAbsolute like the product does.
pub fn mkdirs(io: std.Io, path: []const u8) !void {
    if (path.len == 0) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            std.Io.Dir.createDirAbsolute(io, path[0..i], .default_dir) catch {};
        }
    }
}

fn trimAsciiWs(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and isWs(s[start])) start += 1;
    var end = s.len;
    while (end > start and isWs(s[end - 1])) end -= 1;
    return s[start..end];
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\x0b' or c == '\x0c' or c == '\r';
}
