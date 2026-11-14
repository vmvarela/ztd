//! Typed domain operations for the agent-continuity store (assignments,
//! checkpoints and idempotent operations on top of `db.zig`).
//!
//! Memory: every string in a returned result is owned by the Store's
//! allocator. The caller owns the result and frees it with the matching
//! `deinitXResult` method on the same Store.

const std = @import("std");
const db = @import("db.zig");
const platform = @import("platform.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const CaptureError = error{
    ScopeDenied,
    UnknownAssignment,
    RevisionConflict,
    IdempotencyConflict,
    DbBusy,
    DbIncompatible,
    InvalidArgument,
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    InputOutput,
    NoSpaceLeft,
} || anyerror;

pub const CaptureInput = struct {
    scope: []const u8,
    project: ?[]const u8,
    request: []const u8,
    objective: ?[]const u8,
    constraints: ?[]const u8,
    idempotency_key: ?[]const u8,
};

pub const CheckpointInput = struct {
    assignment_id: []const u8,
    scope: []const u8,
    expect_rev: i64,
    kind: []const u8,
    result: []const u8,
    evidence: ?[]const u8,
    next_action: ?[]const u8,
    idempotency_key: ?[]const u8,
};

pub const Assignment = struct {
    id: []const u8,
    scope: []const u8,
    project: ?[]const u8,
    request: []const u8,
    objective: ?[]const u8,
    constraints: ?[]const u8,
    status: []const u8,
    rev: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Checkpoint = struct {
    id: []const u8,
    assignment_id: []const u8,
    kind: []const u8,
    result: []const u8,
    evidence: ?[]const u8,
    next_action: ?[]const u8,
    rev: i64,
    created_at: []const u8,
};

pub const CaptureResult = struct { assignment: Assignment, replayed: bool };
pub const CheckpointResult = struct { checkpoint: Checkpoint, assignment_rev: i64, replayed: bool };
pub const PrepareResult = struct { assignment: Assignment, latest: ?Checkpoint };

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    db: db.Db,

    pub fn open(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        return .{ .alloc = alloc, .io = io, .db = try db.Db.open(io, alloc, path) };
    }

    pub fn openDefault(alloc: std.mem.Allocator, io: std.Io) !Store {
        const path = try db.resolvePath(io, alloc, null);
        defer alloc.free(path);
        return open(alloc, io, path);
    }

    pub fn close(self: *Store) void {
        self.db.close();
    }

    /// Upserts the scope and inserts a new assignment at rev 1. With an
    /// `idempotency_key`, a repeat of the same input replays the stored
    /// result without writing; the same key with different input is an
    /// `error.IdempotencyConflict`.
    pub fn capture(self: *Store, input: CaptureInput) CaptureError!CaptureResult {
        if (input.scope.len == 0 or input.request.len == 0) return error.InvalidArgument;
        const digest = digestCapture(input);

        try self.db.beginImmediate();
        var committed = false;
        defer if (!committed) self.db.rollback();

        if (input.idempotency_key) |key| {
            if (try self.lookupOp(key)) |op| {
                defer {
                    self.alloc.free(op.digest);
                    self.alloc.free(op.result_json);
                }
                if (!std.mem.eql(u8, op.digest, &digest)) return error.IdempotencyConflict;
                var res = try self.parseCapture(op.result_json);
                res.replayed = true;
                return res;
            }
        }

        {
            var stmt = try self.db.prepare("INSERT INTO scope (id) VALUES (?1) ON CONFLICT (id) DO NOTHING");
            defer stmt.deinit();
            try stmt.bindText(1, input.scope);
            _ = try stmt.step();
        }

        const now = try self.nowIso();
        defer self.alloc.free(now);
        const id = try self.nextId("A", "assignment");

        var a = Assignment{
            .id = id,
            .scope = "",
            .project = null,
            .request = "",
            .objective = null,
            .constraints = null,
            .status = "",
            .rev = 1,
            .created_at = "",
            .updated_at = "",
        };
        errdefer freeAssignment(self.alloc, a);
        a.scope = try self.alloc.dupe(u8, input.scope);
        a.project = if (input.project) |v| try self.alloc.dupe(u8, v) else null;
        a.request = try self.alloc.dupe(u8, input.request);
        a.objective = if (input.objective) |v| try self.alloc.dupe(u8, v) else null;
        a.constraints = if (input.constraints) |v| try self.alloc.dupe(u8, v) else null;
        a.status = try self.alloc.dupe(u8, "open");
        a.created_at = try self.alloc.dupe(u8, now);
        a.updated_at = try self.alloc.dupe(u8, now);

        {
            var stmt = try self.db.prepare(
                \\INSERT INTO assignment (id, scope_id, request, objective, constraints, project, status, rev, created_at, updated_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            );
            defer stmt.deinit();
            try stmt.bindText(1, id);
            try stmt.bindText(2, input.scope);
            try stmt.bindText(3, input.request);
            try stmt.bindTextOpt(4, input.objective);
            try stmt.bindTextOpt(5, input.constraints);
            try stmt.bindTextOpt(6, input.project);
            try stmt.bindText(7, a.status);
            try stmt.bindInt64(8, 1);
            try stmt.bindText(9, now);
            try stmt.bindText(10, now);
            _ = try stmt.step();
        }

        const result = CaptureResult{ .assignment = a, .replayed = false };
        if (input.idempotency_key) |key| try self.recordOp(key, &digest, now, result);
        try self.db.commit();
        committed = true;
        return result;
    }

    /// Writes a checkpoint for an existing assignment in the same scope,
    /// increments the assignment rev and returns the new rev. `kind` must be
    /// `progress` or `done`; `done` also sets `status = 'done'`. An
    /// `expect_rev` that does not match the stored rev is an
    /// `error.RevisionConflict` and leaves the row untouched. Idempotency
    /// keys follow the same replay/conflict rules as `capture`, and the
    /// lookup runs first so a replay succeeds even with a stale `expect_rev`.
    pub fn checkpoint(self: *Store, input: CheckpointInput) CaptureError!CheckpointResult {
        if (input.assignment_id.len == 0 or input.scope.len == 0) return error.InvalidArgument;
        if (!std.mem.eql(u8, input.kind, "progress") and !std.mem.eql(u8, input.kind, "done")) return error.InvalidArgument;
        const digest = digestCheckpoint(input);

        try self.db.beginImmediate();
        var committed = false;
        defer if (!committed) self.db.rollback();

        if (input.idempotency_key) |key| {
            if (try self.lookupOp(key)) |op| {
                defer {
                    self.alloc.free(op.digest);
                    self.alloc.free(op.result_json);
                }
                if (!std.mem.eql(u8, op.digest, &digest)) return error.IdempotencyConflict;
                var res = try self.parseCheckpoint(op.result_json);
                res.replayed = true;
                return res;
            }
        }

        const current = try self.loadForCheckpoint(input.assignment_id);
        defer self.alloc.free(current.scope_id);
        if (!std.mem.eql(u8, current.scope_id, input.scope)) return error.ScopeDenied;
        if (current.rev != input.expect_rev) return error.RevisionConflict;
        const new_rev = current.rev + 1;

        const now = try self.nowIso();
        defer self.alloc.free(now);
        const id = try self.nextId("C", "checkpoint");

        {
            const done = std.mem.eql(u8, input.kind, "done");
            var stmt = try self.db.prepare(if (done)
                "UPDATE assignment SET rev = ?2, updated_at = ?3, status = 'done' WHERE id = ?1"
            else
                "UPDATE assignment SET rev = ?2, updated_at = ?3 WHERE id = ?1");
            defer stmt.deinit();
            try stmt.bindText(1, input.assignment_id);
            try stmt.bindInt64(2, new_rev);
            try stmt.bindText(3, now);
            _ = try stmt.step();
        }

        var c = Checkpoint{
            .id = id,
            .assignment_id = "",
            .kind = "",
            .result = "",
            .evidence = null,
            .next_action = null,
            .rev = new_rev,
            .created_at = "",
        };
        errdefer freeCheckpoint(self.alloc, c);
        c.assignment_id = try self.alloc.dupe(u8, input.assignment_id);
        c.kind = try self.alloc.dupe(u8, input.kind);
        c.result = try self.alloc.dupe(u8, input.result);
        c.evidence = if (input.evidence) |v| try self.alloc.dupe(u8, v) else null;
        c.next_action = if (input.next_action) |v| try self.alloc.dupe(u8, v) else null;
        c.created_at = try self.alloc.dupe(u8, now);

        {
            var stmt = try self.db.prepare(
                \\INSERT INTO checkpoint (id, assignment_id, kind, result, evidence, next_action, rev, created_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            );
            defer stmt.deinit();
            try stmt.bindText(1, id);
            try stmt.bindText(2, input.assignment_id);
            try stmt.bindText(3, input.kind);
            try stmt.bindText(4, input.result);
            try stmt.bindTextOpt(5, input.evidence);
            try stmt.bindTextOpt(6, input.next_action);
            try stmt.bindInt64(7, new_rev);
            try stmt.bindText(8, now);
            _ = try stmt.step();
        }

        const result = CheckpointResult{ .checkpoint = c, .assignment_rev = new_rev, .replayed = false };
        if (input.idempotency_key) |key| try self.recordOp(key, &digest, now, result);
        try self.db.commit();
        committed = true;
        return result;
    }

    /// Read-only: the assignment plus its newest checkpoint (by rev), or
    /// `error.ScopeDenied` when the assignment belongs to another scope and
    /// `error.UnknownAssignment` when there is no such assignment.
    pub fn prepare(self: *Store, assignment_id: []const u8, scope: []const u8) CaptureError!PrepareResult {
        if (assignment_id.len == 0 or scope.len == 0) return error.InvalidArgument;
        var stmt = try self.db.prepare(
            \\SELECT a.id, a.scope_id, a.request, a.objective, a.constraints, a.project, a.status, a.rev, a.created_at, a.updated_at,
            \\       c.id, c.assignment_id, c.kind, c.result, c.evidence, c.next_action, c.rev, c.created_at
            \\FROM assignment a
            \\LEFT JOIN checkpoint c ON c.id = (
            \\  SELECT id FROM checkpoint WHERE assignment_id = a.id ORDER BY rev DESC LIMIT 1
            \\)
            \\WHERE a.id = ?1
        );
        defer stmt.deinit();
        try stmt.bindText(1, assignment_id);
        if (!try stmt.step()) return error.UnknownAssignment;

        const a = try self.readAssignmentCols(&stmt, 0);
        errdefer freeAssignment(self.alloc, a);
        if (!std.mem.eql(u8, a.scope, scope)) return error.ScopeDenied;

        var latest: ?Checkpoint = null;
        if (!stmt.columnIsNull(10)) latest = try self.readCheckpointCols(&stmt, 10);
        return .{ .assignment = a, .latest = latest };
    }

    /// Frees a result returned by `capture`.
    pub fn deinitCaptureResult(self: *Store, result: CaptureResult) void {
        freeAssignment(self.alloc, result.assignment);
    }

    /// Frees a result returned by `checkpoint`.
    pub fn deinitCheckpointResult(self: *Store, result: CheckpointResult) void {
        freeCheckpoint(self.alloc, result.checkpoint);
    }

    /// Frees a result returned by `prepare`.
    pub fn deinitPrepareResult(self: *Store, result: PrepareResult) void {
        freeAssignment(self.alloc, result.assignment);
        if (result.latest) |c| freeCheckpoint(self.alloc, c);
    }

    const OpRow = struct { digest: []const u8, result_json: []const u8 };
    const Loaded = struct { scope_id: []const u8, rev: i64 };

    fn lookupOp(self: *Store, key: []const u8) !?OpRow {
        var stmt = try self.db.prepare("SELECT request_sha256, result_json FROM op_log WHERE key = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, key);
        if (!try stmt.step()) return null;
        const digest = (try stmt.columnBlob(self.alloc, 0)) orelse "";
        errdefer self.alloc.free(digest);
        const result_json = (try stmt.columnText(self.alloc, 1)) orelse "";
        return .{ .digest = digest, .result_json = result_json };
    }

    fn recordOp(self: *Store, key: []const u8, digest: []const u8, now: []const u8, result: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.alloc, result, .{});
        defer self.alloc.free(json);
        var stmt = try self.db.prepare("INSERT INTO op_log (key, request_sha256, result_json, created_at) VALUES (?1, ?2, ?3, ?4)");
        defer stmt.deinit();
        try stmt.bindText(1, key);
        try stmt.bindBlob(2, digest);
        try stmt.bindText(3, json);
        try stmt.bindText(4, now);
        _ = try stmt.step();
    }

    fn parseCapture(self: *Store, text: []const u8) !CaptureResult {
        return std.json.parseFromSliceLeaky(CaptureResult, self.alloc, text, .{ .allocate = .alloc_always });
    }

    fn parseCheckpoint(self: *Store, text: []const u8) !CheckpointResult {
        return std.json.parseFromSliceLeaky(CheckpointResult, self.alloc, text, .{ .allocate = .alloc_always });
    }

    fn loadForCheckpoint(self: *Store, assignment_id: []const u8) !Loaded {
        var stmt = try self.db.prepare("SELECT scope_id, rev FROM assignment WHERE id = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, assignment_id);
        if (!try stmt.step()) return error.UnknownAssignment;
        return .{
            .scope_id = (try stmt.columnText(self.alloc, 0)) orelse "",
            .rev = stmt.columnInt64(1),
        };
    }

    /// `A-YYYYMMDD-NNN` / `C-YYYYMMDD-NNN`: max existing suffix for the
    /// local date plus one.
    fn nextId(self: *Store, comptime prefix: []const u8, comptime table: []const u8) ![]u8 {
        const date = platform.today(self.io);
        var date_buf: [8]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d:0>4}{d:0>2}{d:0>2}", .{ date.year, date.month, date.day }) catch unreachable;
        const full_prefix = try std.fmt.allocPrint(self.alloc, "{s}-{s}-", .{ prefix, date_str });
        defer self.alloc.free(full_prefix);

        var stmt = try self.db.prepare("SELECT id FROM " ++ table ++ " WHERE substr(id, 1, 11) = ?1");
        defer stmt.deinit();
        try stmt.bindText(1, full_prefix);
        var max_n: u32 = 0;
        while (try stmt.step()) {
            const existing = (try stmt.columnText(self.alloc, 0)) orelse continue;
            defer self.alloc.free(existing);
            if (existing.len <= full_prefix.len) continue;
            const n = std.fmt.parseInt(u32, existing[full_prefix.len..], 10) catch continue;
            max_n = @max(max_n, n);
        }
        return std.fmt.allocPrint(self.alloc, "{s}{d:0>3}", .{ full_prefix, max_n + 1 });
    }

    fn nowIso(self: *Store) ![]u8 {
        const ts = std.Io.Clock.real.now(self.io);
        const secs: u64 = @intCast(@max(@divFloor(ts.nanoseconds, std.time.ns_per_s), 0));
        const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day = epoch.getDaySeconds();
        return std.fmt.allocPrint(self.alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            @backingInt(month_day.month),
            month_day.day_index + 1,
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
        });
    }

    fn readAssignmentCols(self: *Store, stmt: *db.Stmt, base: c_int) !Assignment {
        var a = Assignment{
            .id = "",
            .scope = "",
            .project = null,
            .request = "",
            .objective = null,
            .constraints = null,
            .status = "",
            .rev = 0,
            .created_at = "",
            .updated_at = "",
        };
        errdefer freeAssignment(self.alloc, a);
        a.id = (try stmt.columnText(self.alloc, base + 0)) orelse "";
        a.scope = (try stmt.columnText(self.alloc, base + 1)) orelse "";
        a.request = (try stmt.columnText(self.alloc, base + 2)) orelse "";
        a.objective = try stmt.columnText(self.alloc, base + 3);
        a.constraints = try stmt.columnText(self.alloc, base + 4);
        a.project = try stmt.columnText(self.alloc, base + 5);
        a.status = (try stmt.columnText(self.alloc, base + 6)) orelse "";
        a.rev = stmt.columnInt64(base + 7);
        a.created_at = (try stmt.columnText(self.alloc, base + 8)) orelse "";
        a.updated_at = (try stmt.columnText(self.alloc, base + 9)) orelse "";
        return a;
    }

    fn readCheckpointCols(self: *Store, stmt: *db.Stmt, base: c_int) !Checkpoint {
        var c = Checkpoint{
            .id = "",
            .assignment_id = "",
            .kind = "",
            .result = "",
            .evidence = null,
            .next_action = null,
            .rev = 0,
            .created_at = "",
        };
        errdefer freeCheckpoint(self.alloc, c);
        c.id = (try stmt.columnText(self.alloc, base + 0)) orelse "";
        c.assignment_id = (try stmt.columnText(self.alloc, base + 1)) orelse "";
        c.kind = (try stmt.columnText(self.alloc, base + 2)) orelse "";
        c.result = (try stmt.columnText(self.alloc, base + 3)) orelse "";
        c.evidence = try stmt.columnText(self.alloc, base + 4);
        c.next_action = try stmt.columnText(self.alloc, base + 5);
        c.rev = stmt.columnInt64(base + 6);
        c.created_at = (try stmt.columnText(self.alloc, base + 7)) orelse "";
        return c;
    }
};

fn freeAssignment(alloc: std.mem.Allocator, a: Assignment) void {
    alloc.free(a.id);
    alloc.free(a.scope);
    if (a.project) |v| alloc.free(v);
    alloc.free(a.request);
    if (a.objective) |v| alloc.free(v);
    if (a.constraints) |v| alloc.free(v);
    alloc.free(a.status);
    alloc.free(a.created_at);
    alloc.free(a.updated_at);
}

fn freeCheckpoint(alloc: std.mem.Allocator, c: Checkpoint) void {
    alloc.free(c.id);
    alloc.free(c.assignment_id);
    alloc.free(c.kind);
    alloc.free(c.result);
    if (c.evidence) |v| alloc.free(v);
    if (c.next_action) |v| alloc.free(v);
    alloc.free(c.created_at);
}

/// Length-prefixed fields in a fixed order, so no combination of field
/// contents can produce the same digest as another. Null optionals are
/// marked separately from present empty strings.
fn hashField(h: *Sha256, value: []const u8) void {
    var buf: [24]u8 = undefined;
    const n = std.fmt.bufPrint(&buf, "{d}:", .{value.len}) catch unreachable;
    h.update(n);
    h.update(value);
}

fn hashOptField(h: *Sha256, value: ?[]const u8) void {
    if (value) |v| hashField(h, v) else h.update("-;");
}

fn digestCapture(input: CaptureInput) [Sha256.digest_length]u8 {
    var h = Sha256.init(.{});
    hashField(&h, input.scope);
    hashOptField(&h, input.project);
    hashField(&h, input.request);
    hashOptField(&h, input.objective);
    hashOptField(&h, input.constraints);
    return h.finalResult();
}

fn digestCheckpoint(input: CheckpointInput) [Sha256.digest_length]u8 {
    var h = Sha256.init(.{});
    hashField(&h, input.assignment_id);
    hashField(&h, input.scope);
    var rev_buf: [24]u8 = undefined;
    const rev = std.fmt.bufPrint(&rev_buf, "{d}", .{input.expect_rev}) catch unreachable;
    hashField(&h, rev);
    hashField(&h, input.kind);
    hashField(&h, input.result);
    hashOptField(&h, input.evidence);
    hashOptField(&h, input.next_action);
    return h.finalResult();
}

fn tmpPath(alloc: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    return std.fs.path.join(alloc, &.{ path_buf[0..n], "agent.db" });
}

test "capture inserts at rev 1 and replays idempotently" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpPath(alloc, io, &tmp);
    defer alloc.free(db_path);

    var s = try Store.open(alloc, io, db_path);
    defer s.close();

    const r1 = try s.capture(.{
        .scope = "trabajo",
        .project = "komorebi",
        .request = "implementar continuidad",
        .objective = null,
        .constraints = "sin dependencias nuevas",
        .idempotency_key = "op-1",
    });
    defer s.deinitCaptureResult(r1);
    try std.testing.expect(!r1.replayed);
    try std.testing.expectEqual(@as(i64, 1), r1.assignment.rev);
    try std.testing.expectEqualStrings("open", r1.assignment.status);
    try std.testing.expectEqualStrings("trabajo", r1.assignment.scope);
    try std.testing.expectEqualStrings("komorebi", r1.assignment.project.?);
    try std.testing.expect(r1.assignment.objective == null);
    try std.testing.expectEqualStrings("sin dependencias nuevas", r1.assignment.constraints.?);
    try std.testing.expect(std.mem.startsWith(u8, r1.assignment.id, "A-"));
    try std.testing.expectEqualStrings("001", r1.assignment.id[11..]);

    const r2 = try s.capture(.{
        .scope = "trabajo",
        .project = "komorebi",
        .request = "implementar continuidad",
        .objective = null,
        .constraints = "sin dependencias nuevas",
        .idempotency_key = "op-1",
    });
    defer s.deinitCaptureResult(r2);
    try std.testing.expect(r2.replayed);
    try std.testing.expectEqualStrings(r1.assignment.id, r2.assignment.id);
    try std.testing.expectEqualStrings(r1.assignment.request, r2.assignment.request);
    try std.testing.expectEqual(@as(i64, 1), r2.assignment.rev);
    try std.testing.expect(r2.assignment.objective == null);

    try std.testing.expectError(error.IdempotencyConflict, s.capture(.{
        .scope = "trabajo",
        .project = null,
        .request = "otra cosa",
        .objective = null,
        .constraints = null,
        .idempotency_key = "op-1",
    }));

    const r3 = try s.capture(.{
        .scope = "trabajo",
        .project = null,
        .request = "segunda captura",
        .objective = null,
        .constraints = null,
        .idempotency_key = null,
    });
    defer s.deinitCaptureResult(r3);
    try std.testing.expectEqualStrings("002", r3.assignment.id[11..]);
}

test "checkpoint enforces scope, revision and kind" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpPath(alloc, io, &tmp);
    defer alloc.free(db_path);

    var s = try Store.open(alloc, io, db_path);
    defer s.close();

    const r0 = try s.capture(.{
        .scope = "trabajo",
        .project = null,
        .request = "escribir el spec",
        .objective = null,
        .constraints = null,
        .idempotency_key = null,
    });
    defer s.deinitCaptureResult(r0);
    const id = r0.assignment.id;

    try std.testing.expectError(error.InvalidArgument, s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "bogus",
        .result = "x",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    }));
    try std.testing.expectError(error.UnknownAssignment, s.checkpoint(.{
        .assignment_id = "A-19990101-001",
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "progress",
        .result = "x",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    }));
    try std.testing.expectError(error.ScopeDenied, s.checkpoint(.{
        .assignment_id = id,
        .scope = "salud",
        .expect_rev = 1,
        .kind = "progress",
        .result = "x",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    }));

    const c1 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "progress",
        .result = "avancé con el diseño",
        .evidence = "commit abc123",
        .next_action = "implementar db.zig",
        .idempotency_key = null,
    });
    defer s.deinitCheckpointResult(c1);
    try std.testing.expect(!c1.replayed);
    try std.testing.expectEqual(@as(i64, 2), c1.assignment_rev);
    try std.testing.expectEqual(@as(i64, 2), c1.checkpoint.rev);
    try std.testing.expectEqualStrings(id, c1.checkpoint.assignment_id);
    try std.testing.expectEqualStrings("progress", c1.checkpoint.kind);
    try std.testing.expect(std.mem.startsWith(u8, c1.checkpoint.id, "C-"));
    try std.testing.expectEqualStrings("001", c1.checkpoint.id[11..]);

    // Stale expect_rev: rejected, row untouched (still rev 2, status open).
    try std.testing.expectError(error.RevisionConflict, s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "done",
        .result = "ya estaba hecho",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    }));

    const p1 = try s.prepare(id, "trabajo");
    defer s.deinitPrepareResult(p1);
    try std.testing.expectEqual(@as(i64, 2), p1.assignment.rev);
    try std.testing.expectEqualStrings("open", p1.assignment.status);
    try std.testing.expectEqualStrings(c1.checkpoint.id, p1.latest.?.id);

    try std.testing.expectError(error.ScopeDenied, s.prepare(id, "salud"));
    try std.testing.expectError(error.UnknownAssignment, s.prepare("A-19990101-001", "trabajo"));

    const c2 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 2,
        .kind = "done",
        .result = "terminado",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    });
    defer s.deinitCheckpointResult(c2);
    try std.testing.expectEqual(@as(i64, 3), c2.assignment_rev);

    const p2 = try s.prepare(id, "trabajo");
    defer s.deinitPrepareResult(p2);
    try std.testing.expectEqualStrings("done", p2.assignment.status);
    try std.testing.expectEqual(@as(i64, 3), p2.assignment.rev);
    try std.testing.expectEqual(@as(i64, 3), p2.latest.?.rev);
    try std.testing.expectEqualStrings(c2.checkpoint.id, p2.latest.?.id);

    // Idempotent checkpoint: replay wins over the now-stale expect_rev.
    const c3 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 3,
        .kind = "progress",
        .result = "post ✓",
        .evidence = null,
        .next_action = null,
        .idempotency_key = "ck-1",
    });
    defer s.deinitCheckpointResult(c3);
    try std.testing.expectEqual(@as(i64, 4), c3.assignment_rev);

    const c4 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 3,
        .kind = "progress",
        .result = "post ✓",
        .evidence = null,
        .next_action = null,
        .idempotency_key = "ck-1",
    });
    defer s.deinitCheckpointResult(c4);
    try std.testing.expect(c4.replayed);
    try std.testing.expectEqual(@as(i64, 4), c4.assignment_rev);
    try std.testing.expectEqualStrings(c3.checkpoint.id, c4.checkpoint.id);
    try std.testing.expectEqualStrings(c3.checkpoint.result, c4.checkpoint.result);

    try std.testing.expectError(error.IdempotencyConflict, s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 3,
        .kind = "progress",
        .result = "otro resultado",
        .evidence = null,
        .next_action = null,
        .idempotency_key = "ck-1",
    }));
}

test "a second connection with a stale rev is rejected and the row is unchanged" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpPath(alloc, io, &tmp);
    defer alloc.free(db_path);

    var a = try Store.open(alloc, io, db_path);
    defer a.close();
    var b = try Store.open(alloc, io, db_path);
    defer b.close();

    const r = try a.capture(.{
        .scope = "trabajo",
        .project = null,
        .request = "tarea compartida",
        .objective = null,
        .constraints = null,
        .idempotency_key = null,
    });
    defer a.deinitCaptureResult(r);
    const id = r.assignment.id;

    const c1 = try a.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "progress",
        .result = "avance desde a",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    });
    defer a.deinitCheckpointResult(c1);
    try std.testing.expectEqual(@as(i64, 2), c1.assignment_rev);

    // b still believes rev 1: conflict, and nothing changes on disk.
    try std.testing.expectError(error.RevisionConflict, b.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "done",
        .result = "no debe grabarse",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    }));

    const p = try b.prepare(id, "trabajo");
    defer b.deinitPrepareResult(p);
    try std.testing.expectEqual(@as(i64, 2), p.assignment.rev);
    try std.testing.expectEqualStrings("open", p.assignment.status);
    try std.testing.expectEqualStrings(c1.checkpoint.id, p.latest.?.id);
}
