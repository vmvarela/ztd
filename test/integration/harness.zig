//! Shared plumbing for the Zig integration runner, ported from the helpers in
//! `cli_test.go`: throwaway HOME/TMPDIR directories, the `--json` envelope
//! wrapper around one product invocation, and the small JSON accessors the
//! MCP tests need.

const std = @import("std");
const Io = std.Io;
const json = std.json;

pub const TestFailed = error{TestFailed};

// ------------------------------------------------------------------ JSON

pub fn jget(v: json.Value, key: []const u8) ?json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

pub fn jstr(v: json.Value, key: []const u8) ?[]const u8 {
    return switch (jget(v, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn jint(v: json.Value, key: []const u8) ?i64 {
    return switch (jget(v, key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

pub fn jbool(v: json.Value, key: []const u8) bool {
    return switch (jget(v, key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

pub fn jarr(v: json.Value, key: []const u8) ?[]json.Value {
    return switch (jget(v, key) orelse return null) {
        .array => |a| a.items,
        else => null,
    };
}

/// Stringifies a JSON value for failure messages (Go's `scJSON`).
pub fn dump(a: std.mem.Allocator, v: json.Value) []const u8 {
    var aw = Io.Writer.Allocating.init(a);
    json.Stringify.value(v, .{}, &aw.writer) catch return "<unprintable>";
    return aw.written();
}

/// Go's `containsString`: walks whatever JSON came back so assertions do
/// not pin the container shape.
pub fn containsString(v: json.Value, want: []const u8) bool {
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, want),
        .array => |a| blk: {
            for (a.items) |item| if (containsString(item, want)) break :blk true;
            break :blk false;
        },
        .object => |o| blk: {
            for (o.values()) |item| if (containsString(item, want)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// True for C-YYYYMMDD-NNN (>=3 trailing digits), the Go capture id regex.
pub fn isId(s: []const u8, comptime prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    var i = prefix.len;
    const digits_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i - digits_start != 8) return false;
    if (i >= s.len or s[i] != '-') return false;
    i += 1;
    const tail_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    return i == s.len and i - tail_start >= 3;
}

pub const Ctx = struct {
    arena: std.mem.Allocator,
    io: Io,
    /// Product binary under test (argv[1] > ZTD_BIN > ./zig-out/bin/ztd).
    bin: []const u8,
    /// Parent PATH, copied into every child environment.
    path: []const u8,
    /// Base directory for every temp dir (TMPDIR of the test process).
    tmp_base: []const u8,
    seq: u32 = 0,
    /// Failures recorded so far: t.Errorf-style entries continue the test.
    failures: std.ArrayList([]const u8) = .empty,

    // ------------------------------------------------------------ temp dirs

    /// A fresh directory under tmp_base; nothing inside it exists yet.
    pub fn tempDir(self: *Ctx, tag: []const u8) ![]const u8 {
        const stamp = Io.Timestamp.now(self.io, .real).nanoseconds;
        while (true) : (self.seq += 1) {
            const path = try std.fmt.allocPrint(
                self.arena,
                "{s}/ztd-it-{d}-{d}{s}",
                .{ self.tmp_base, stamp, self.seq, tag },
            );
            Io.Dir.cwd().createDir(self.io, path, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => continue,
                else => return e,
            };
            return path;
        }
    }

    /// `<tempdir>/ztd.db`, the database path passed as `--db`.
    pub fn tempDb(self: *Ctx) ![]const u8 {
        const dir = try self.tempDir("-db");
        return std.fmt.allocPrint(self.arena, "{s}/ztd.db", .{dir});
    }

    // ----------------------------------------------------------- assertions

    /// t.Errorf style: record the failure and keep going.
    pub fn err(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.failures.append(self.arena, msg) catch {};
    }

    /// t.Fatalf style: record the failure and abandon the test.
    pub fn fatal(self: *Ctx, comptime fmt: []const u8, args: anytype) TestFailed {
        self.err(fmt, args);
        return error.TestFailed;
    }

    /// Decodes a JSON value into a Go-style struct: unknown fields are
    /// ignored, absent fields keep their Zig defaults.
    pub fn decode(self: *Ctx, comptime T: type, v: json.Value) !T {
        return json.parseFromValueLeaky(T, self.arena, v, .{ .ignore_unknown_fields = true }) catch |e|
            return self.fatal("decode {s}: {s}\nvalue: {s}", .{ @typeName(T), @errorName(e), dump(self.arena, v) });
    }

    // ------------------------------------------------------------ child env

    /// The Go suites replace the child environment outright with exactly
    /// these five variables, so nothing can fall back to the real profile.
    pub fn childEnv(self: *Ctx, home: []const u8, tmp: []const u8) !std.process.Environ.Map {
        var map = std.process.Environ.Map.init(self.arena);
        try map.put("PATH", self.path);
        try map.put("HOME", home);
        try map.put("USERPROFILE", home);
        try map.put("TMPDIR", tmp);
        try map.put("USER", "ztd-test");
        return map;
    }

    // ----------------------------------------------------------------- CLI

    pub const Res = struct {
        code: i32,
        stdout: []const u8,
        stderr: []const u8,
        env: json.Value,
    };

    /// One `ztd --json --db <db> ...` invocation under a fresh HOME.
    pub fn run(self: *Ctx, db: []const u8, args: []const []const u8) !Res {
        const home = try self.tempDir("-home");
        return self.runHome(home, db, args);
    }

    /// `run` with a fixed HOME, for commands whose defaults live under it.
    pub fn runHome(self: *Ctx, home: []const u8, db: []const u8, args: []const []const u8) !Res {
        const tmp = try self.tempDir("-tmp");
        return self.runIn(home, tmp, db, args);
    }

    pub fn runIn(self: *Ctx, home: []const u8, tmp: []const u8, db: []const u8, args: []const []const u8) !Res {
        const env = try self.childEnv(home, tmp);
        const argv = try self.arena.alloc([]const u8, args.len + 4);
        argv[0] = self.bin;
        argv[1] = "--json";
        argv[2] = "--db";
        argv[3] = db;
        @memcpy(argv[4..], args);

        const result = std.process.run(self.arena, self.io, .{
            .argv = argv,
            .environ_map = &env,
        }) catch |e|
            return self.fatal("run {s}: {s}", .{ fmtArgs(self.arena, argv), @errorName(e) });

        const code: i32 = switch (result.term) {
            .exited => |c| @intCast(c),
            .signal => |sig| return self.fatal("run {s}: killed by signal {d}\nstderr: {s}", .{ fmtArgs(self.arena, argv), sig, result.stderr }),
            else => return self.fatal("run {s}: abnormal term", .{fmtArgs(self.arena, argv)}),
        };

        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        const envv = json.parseFromSliceLeaky(json.Value, self.arena, trimmed, .{}) catch |e|
            return self.fatal("decode envelope: {s}\nstdout: {s}\nstderr: {s}", .{ @errorName(e), result.stdout, result.stderr });

        return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr, .env = envv };
    }

    /// wantOK asserts exit 0 plus a success envelope and returns `data`.
    pub fn wantOK(self: *Ctx, r: Res, command: []const u8) !json.Value {
        if (r.code != 0)
            return self.fatal("exit = {d}, want 0 (command {s})\nstdout: {s}\nstderr: {s}", .{ r.code, command, r.stdout, r.stderr });
        if (!jbool(r.env, "ok") or jget(r.env, "error") != null)
            return self.fatal("ok = false, want success envelope (command {s})\nstdout: {s}", .{ command, r.stdout });
        const cmd = jstr(r.env, "command") orelse "";
        if (!std.mem.eql(u8, cmd, command))
            return self.fatal("command = \"{s}\", want \"{s}\"\nstdout: {s}", .{ cmd, command, r.stdout });
        return jget(r.env, "data") orelse json.Value.null;
    }

    /// wantErr asserts a failure envelope with the given exit status, command
    /// and error family; `data` stays on the result for further decoding.
    pub fn wantErr(self: *Ctx, r: Res, code: i32, command: []const u8, family: []const u8) !void {
        if (r.code != code)
            return self.fatal("exit = {d}, want {d} (command {s})\nstdout: {s}\nstderr: {s}", .{ r.code, code, command, r.stdout, r.stderr });
        if (jbool(r.env, "ok") or jget(r.env, "error") == null)
            return self.fatal("want failure envelope for {s}, got ok=true\nstdout: {s}", .{ command, r.stdout });
        const cmd = jstr(r.env, "command") orelse "";
        if (!std.mem.eql(u8, cmd, command))
            return self.fatal("command = \"{s}\", want \"{s}\"\nstdout: {s}", .{ cmd, command, r.stdout });
        const error_obj = jget(r.env, "error").?;
        const got_family = jstr(error_obj, "family") orelse "<missing>";
        if (!std.mem.eql(u8, got_family, family))
            return self.fatal("error family = \"{s}\", want \"{s}\"\nerror: {s}\nstdout: {s}", .{ got_family, family, dump(self.arena, error_obj), r.stdout });
    }

    // ----------------------------------------------------------- filesystem

    pub fn readFile(self: *Ctx, path: []const u8, limit: usize) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(limit)) catch |e|
            return self.fatal("read {s}: {s}", .{ path, @errorName(e) });
    }

    pub fn exists(self: *Ctx, path: []const u8) bool {
        _ = Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }

    pub fn writeFile(self: *Ctx, path: []const u8, data: []const u8) !void {
        var file = Io.Dir.cwd().createFile(self.io, path, .{}) catch |e|
            return self.fatal("write {s}: {s}", .{ path, @errorName(e) });
        defer file.close(self.io);
        file.writeStreamingAll(self.io, data) catch |e|
            return self.fatal("write {s}: {s}", .{ path, @errorName(e) });
    }

    /// countBundle counts the repository files below each directory — the same
    /// set the binary embeds — so expected install counts track the bundle.
    pub fn countBundle(self: *Ctx, rels: []const []const u8) !usize {
        var total: usize = 0;
        for (rels) |rel| {
            var dir = Io.Dir.cwd().openDir(self.io, rel, .{ .iterate = true }) catch |e|
                return self.fatal("walk {s}: {s}", .{ rel, @errorName(e) });
            defer dir.close(self.io);
            var walker = dir.walk(self.arena) catch |e|
                return self.fatal("walk {s}: {s}", .{ rel, @errorName(e) });
            defer walker.deinit();
            while (walker.next(self.io) catch |e|
                return self.fatal("walk {s}: {s}", .{ rel, @errorName(e) })) |entry|
            {
                if (entry.kind == .directory) continue;
                total += 1;
            }
        }
        return total;
    }

    // ---------------------------------------------------------------- time

    /// Today's calendar date in UTC, `YYYY-MM-DD` (Go's time.Now().UTC()).
    pub fn todayUTC(self: *Ctx) ![]const u8 {
        const secs = Io.Timestamp.now(self.io, .real).toSeconds();
        const days = @divFloor(secs, 86400);
        const date = civilFromDays(days);
        return std.fmt.allocPrint(
            self.arena,
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ @as(u32, @intCast(date.year)), date.month, date.day },
        );
    }

    const Civil = struct { year: i64, month: u8, day: u8 };

    /// Howard Hinnant's days_from_civil, as src/timeutil.zig does it.
    fn civilFromDays(days_in: i64) Civil {
        const z = days_in + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divTrunc(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m: i64 = if (mp < 10) mp + 3 else mp - 9;
        return .{
            .year = if (m <= 2) y + 1 else y,
            .month = @intCast(if (m <= 2) m + 12 else m),
            .day = @intCast(d),
        };
    }
};

fn fmtArgs(a: std.mem.Allocator, argv: []const []const u8) []const u8 {
    return std.mem.join(a, " ", argv) catch "<argv>";
}
