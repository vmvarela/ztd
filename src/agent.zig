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

pub const RememberInput = struct {
    scope: []const u8,
    kind: []const u8,
    text: []const u8,
    source: ?[]const u8,
    idempotency_key: ?[]const u8,
};

pub const RecallInput = struct { scope: []const u8, query: []const u8, limit: i64 };

pub const Knowledge = struct {
    id: []const u8,
    scope: []const u8,
    kind: []const u8,
    text: []const u8,
    source: ?[]const u8,
    rev: i64,
    created_at: []const u8,
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
pub const RememberResult = struct { knowledge: Knowledge, replayed: bool };

pub const ExportCounts = struct { scopes: usize, assignments: usize, checkpoints: usize, operations: usize, knowledge: usize };

/// On-disk shape of `exportJson`/`restoreJson`: the schema column names, null
/// columns as JSON null and `request_sha256` as lowercase hex.
const ExportScope = struct { id: []const u8 };
const ExportAssignment = struct {
    id: []const u8,
    scope_id: []const u8,
    request: []const u8,
    objective: ?[]const u8,
    constraints: ?[]const u8,
    project: ?[]const u8,
    status: []const u8,
    rev: i64,
    created_at: []const u8,
    updated_at: []const u8,
};
const ExportCheckpoint = struct {
    id: []const u8,
    assignment_id: []const u8,
    kind: []const u8,
    result: []const u8,
    evidence: ?[]const u8,
    next_action: ?[]const u8,
    rev: i64,
    created_at: []const u8,
};
const ExportOp = struct {
    key: []const u8,
    request_sha256: []const u8,
    result_json: []const u8,
    created_at: []const u8,
};
const ExportKnowledge = struct {
    id: []const u8,
    scope: []const u8,
    kind: []const u8,
    text: []const u8,
    source: ?[]const u8,
    rev: i64,
    created_at: []const u8,
};
const ExportFile = struct {
    format: []const u8,
    version: i64,
    scopes: []ExportScope,
    assignments: []ExportAssignment,
    checkpoints: []ExportCheckpoint,
    operations: []ExportOp,
    /// Absent from version-1 documents: those carry no knowledge rows.
    knowledge: []const ExportKnowledge = &.{},
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    db: db.Db,

    pub fn open(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        return .{ .alloc = alloc, .io = io, .db = try db.Db.open(io, alloc, path) };
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
        if (!stmt.columnIsNull(10)) latest = try readCheckpointCols(self.alloc, &stmt, 10);
        return .{ .assignment = a, .latest = latest };
    }

    /// Read-only: up to `limit` checkpoints of `assignment_id`, newest-first by
    /// rev (`limit` 0 returns none). The scope rules match `prepare`:
    /// `error.ScopeDenied` for a foreign assignment, `error.UnknownAssignment`
    /// when absent. The caller owns the result and frees every checkpoint and
    /// the slice with the allocator passed here.
    pub fn history(self: *Store, alloc: std.mem.Allocator, assignment_id: []const u8, scope: []const u8, limit: usize) ![]Checkpoint {
        if (assignment_id.len == 0 or scope.len == 0) return error.InvalidArgument;
        const current = try self.loadForCheckpoint(assignment_id);
        defer self.alloc.free(current.scope_id);
        if (!std.mem.eql(u8, current.scope_id, scope)) return error.ScopeDenied;

        var stmt = try self.db.prepare(
            \\SELECT id, assignment_id, kind, result, evidence, next_action, rev, created_at
            \\FROM checkpoint WHERE assignment_id = ?1 ORDER BY rev DESC LIMIT ?2
        );
        defer stmt.deinit();
        try stmt.bindText(1, assignment_id);
        try stmt.bindInt64(2, std.math.cast(i64, limit) orelse std.math.maxInt(i64));

        var out: std.ArrayList(Checkpoint) = .empty;
        errdefer {
            for (out.items) |c| freeCheckpoint(alloc, c);
            out.deinit(alloc);
        }
        while (try stmt.step()) {
            const c = try readCheckpointCols(alloc, &stmt, 0);
            errdefer freeCheckpoint(alloc, c);
            try out.append(alloc, c);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Upserts the scope and inserts a knowledge record at rev 1 together with
    /// its `knowledge_fts` row, both in one `BEGIN IMMEDIATE` transaction so
    /// the standalone FTS index mirrors `knowledge` exactly. `kind` must be
    /// `fact`, `decision`, `constraint` or `procedure`. Idempotency keys
    /// follow the same replay/conflict rules as `capture`: the same key with
    /// the same input replays the stored result, a different input is an
    /// `error.IdempotencyConflict`.
    pub fn remember(self: *Store, input: RememberInput) CaptureError!RememberResult {
        if (input.scope.len == 0 or input.text.len == 0) return error.InvalidArgument;
        if (!validKnowledgeKind(input.kind)) return error.InvalidArgument;
        const digest = digestRemember(input);

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
                var res = try self.parseRemember(op.result_json);
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
        const id = try self.nextId("K", "knowledge");

        var k = Knowledge{
            .id = id,
            .scope = "",
            .kind = "",
            .text = "",
            .source = null,
            .rev = 1,
            .created_at = "",
        };
        errdefer freeKnowledge(self.alloc, k);
        k.scope = try self.alloc.dupe(u8, input.scope);
        k.kind = try self.alloc.dupe(u8, input.kind);
        k.text = try self.alloc.dupe(u8, input.text);
        k.source = if (input.source) |v| try self.alloc.dupe(u8, v) else null;
        k.created_at = try self.alloc.dupe(u8, now);

        try self.insertKnowledge(k);

        const result = RememberResult{ .knowledge = k, .replayed = false };
        if (input.idempotency_key) |key| try self.recordOp(key, &digest, now, result);
        try self.db.commit();
        committed = true;
        return result;
    }

    /// Read-only full-text recall over one scope. The scope filter runs in SQL
    /// before ranking, `knowledge_fts` joins on `knowledge.rowid` and rows come
    /// back ordered by `bm25(knowledge_fts)` (ascending: best match first), at
    /// most `limit` of them. `limit` must be positive; an unknown scope yields
    /// an empty list. A malformed FTS5 query is `error.InvalidArgument`, while
    /// an I/O failure stays `error.InputOutput`. The caller owns the result and
    /// frees it with `deinitRecall`.
    pub fn recall(self: *Store, input: RecallInput) CaptureError![]Knowledge {
        if (input.scope.len == 0 or input.query.len == 0) return error.InvalidArgument;
        if (input.limit <= 0) return error.InvalidArgument;

        var stmt = self.db.prepare(
            \\SELECT k.id, k.scope_id, k.kind, k.text, k.source, k.rev, k.created_at
            \\FROM knowledge_fts, knowledge k
            \\WHERE knowledge_fts MATCH ?1 AND k.rowid = knowledge_fts.rowid
            \\  AND k.scope_id = ?2
            \\ORDER BY bm25(knowledge_fts)
            \\LIMIT ?3
        ) catch |err| return self.recallError(err);
        defer stmt.deinit();
        try stmt.bindText(1, input.query);
        try stmt.bindText(2, input.scope);
        try stmt.bindInt64(3, input.limit);

        var out: std.ArrayList(Knowledge) = .empty;
        errdefer {
            for (out.items) |k| freeKnowledge(self.alloc, k);
            out.deinit(self.alloc);
        }
        while (true) {
            const has_row = stmt.step() catch |err| return self.recallError(err);
            if (!has_row) break;
            const k = try readKnowledgeCols(self.alloc, &stmt, 0);
            errdefer freeKnowledge(self.alloc, k);
            try out.append(self.alloc, k);
        }
        return out.toOwnedSlice(self.alloc);
    }

    /// FTS5 reports a malformed MATCH query as SQLite's generic
    /// `SQLITE_ERROR`, which the shared mapping turns into `InputOutput`; the
    /// connection's result code tells that apart from a real I/O, busy or
    /// corruption failure, which must keep its own error.
    fn recallError(self: *Store, err: anyerror) CaptureError {
        if (err == error.InputOutput and self.db.lastWasGenericError()) return error.InvalidArgument;
        return err;
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

    /// Frees a result returned by `remember`.
    pub fn deinitRememberResult(self: *Store, result: RememberResult) void {
        freeKnowledge(self.alloc, result.knowledge);
    }

    /// Frees the slice returned by `recall`.
    pub fn deinitRecall(self: *Store, items: []Knowledge) void {
        for (items) |k| freeKnowledge(self.alloc, k);
        self.alloc.free(items);
    }

    /// Serialises the whole store as one JSON object
    /// `{"format":"ztd-agent-export","version":2,"scopes":[...],"assignments":[...],"checkpoints":[...],"operations":[...],"knowledge":[...]}`,
    /// with the schema column names (knowledge rows carry the record fields:
    /// `id`, `scope`, `kind`, `text`, `source`, `rev`, `created_at`), rows
    /// ordered by id (`op_log` by key), null columns as JSON null and
    /// `request_sha256` as lowercase hex. The caller owns the result.
    pub fn exportJson(self: *Store, alloc: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var scopes: std.ArrayList(ExportScope) = .empty;
        {
            var stmt = try self.db.prepare("SELECT id FROM scope ORDER BY id");
            defer stmt.deinit();
            while (try stmt.step()) {
                try scopes.append(a, .{ .id = (try stmt.columnText(a, 0)) orelse "" });
            }
        }

        var assignments: std.ArrayList(ExportAssignment) = .empty;
        {
            var stmt = try self.db.prepare(
                \\SELECT id, scope_id, request, objective, constraints, project, status, rev, created_at, updated_at
                \\FROM assignment ORDER BY id
            );
            defer stmt.deinit();
            while (try stmt.step()) {
                try assignments.append(a, .{
                    .id = (try stmt.columnText(a, 0)) orelse "",
                    .scope_id = (try stmt.columnText(a, 1)) orelse "",
                    .request = (try stmt.columnText(a, 2)) orelse "",
                    .objective = try stmt.columnText(a, 3),
                    .constraints = try stmt.columnText(a, 4),
                    .project = try stmt.columnText(a, 5),
                    .status = (try stmt.columnText(a, 6)) orelse "",
                    .rev = stmt.columnInt64(7),
                    .created_at = (try stmt.columnText(a, 8)) orelse "",
                    .updated_at = (try stmt.columnText(a, 9)) orelse "",
                });
            }
        }

        var checkpoints: std.ArrayList(ExportCheckpoint) = .empty;
        {
            var stmt = try self.db.prepare(
                \\SELECT id, assignment_id, kind, result, evidence, next_action, rev, created_at
                \\FROM checkpoint ORDER BY id
            );
            defer stmt.deinit();
            while (try stmt.step()) {
                try checkpoints.append(a, .{
                    .id = (try stmt.columnText(a, 0)) orelse "",
                    .assignment_id = (try stmt.columnText(a, 1)) orelse "",
                    .kind = (try stmt.columnText(a, 2)) orelse "",
                    .result = (try stmt.columnText(a, 3)) orelse "",
                    .evidence = try stmt.columnText(a, 4),
                    .next_action = try stmt.columnText(a, 5),
                    .rev = stmt.columnInt64(6),
                    .created_at = (try stmt.columnText(a, 7)) orelse "",
                });
            }
        }

        var operations: std.ArrayList(ExportOp) = .empty;
        {
            var stmt = try self.db.prepare("SELECT key, request_sha256, result_json, created_at FROM op_log ORDER BY key");
            defer stmt.deinit();
            while (try stmt.step()) {
                const digest = (try stmt.columnBlob(a, 1)) orelse "";
                try operations.append(a, .{
                    .key = (try stmt.columnText(a, 0)) orelse "",
                    .request_sha256 = try hexLower(a, digest),
                    .result_json = (try stmt.columnText(a, 2)) orelse "",
                    .created_at = (try stmt.columnText(a, 3)) orelse "",
                });
            }
        }

        var knowledge: std.ArrayList(ExportKnowledge) = .empty;
        {
            var stmt = try self.db.prepare(
                \\SELECT id, scope_id, kind, text, source, rev, created_at
                \\FROM knowledge ORDER BY id
            );
            defer stmt.deinit();
            while (try stmt.step()) {
                try knowledge.append(a, .{
                    .id = (try stmt.columnText(a, 0)) orelse "",
                    .scope = (try stmt.columnText(a, 1)) orelse "",
                    .kind = (try stmt.columnText(a, 2)) orelse "",
                    .text = (try stmt.columnText(a, 3)) orelse "",
                    .source = try stmt.columnText(a, 4),
                    .rev = stmt.columnInt64(5),
                    .created_at = (try stmt.columnText(a, 6)) orelse "",
                });
            }
        }

        return std.json.Stringify.valueAlloc(alloc, ExportFile{
            .format = "ztd-agent-export",
            .version = 2,
            .scopes = scopes.items,
            .assignments = assignments.items,
            .checkpoints = checkpoints.items,
            .operations = operations.items,
            .knowledge = knowledge.items,
        }, .{});
    }

    /// Reads an `exportJson` document into an empty store. The document must
    /// declare `format` `ztd-agent-export` and `version` 1 or 2 (a version-1
    /// document carries no knowledge array and restores no knowledge rows); a
    /// malformed or inconsistent document, a non-empty store, duplicate ids,
    /// missing parents, a knowledge row outside the stored shape or bad hex is
    /// `error.InvalidArgument`. Every row is inserted in one transaction and
    /// the row counts — knowledge included — and each assignment's revision
    /// are verified before the commit, so a refusal leaves the store
    /// untouched. Returns the inserted counts.
    pub fn restoreJson(self: *Store, alloc: std.mem.Allocator, json: []const u8) !ExportCounts {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const file = std.json.parseFromSliceLeaky(ExportFile, a, json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgument,
        };
        if (!std.mem.eql(u8, file.format, "ztd-agent-export")) return error.InvalidArgument;
        if (file.version != 1 and file.version != 2) return error.InvalidArgument;

        // Structural problems are rejected before the transaction so they
        // surface as InvalidArgument instead of a SQLite constraint error.
        for (file.scopes, 0..) |s, i| {
            if (s.id.len == 0) return error.InvalidArgument;
            for (file.scopes[0..i]) |p| if (std.mem.eql(u8, p.id, s.id)) return error.InvalidArgument;
        }
        for (file.assignments, 0..) |x, i| {
            if (x.id.len == 0) return error.InvalidArgument;
            for (file.assignments[0..i]) |p| if (std.mem.eql(u8, p.id, x.id)) return error.InvalidArgument;
            if (!hasId(file.scopes, x.scope_id)) return error.InvalidArgument;
            if (!validStatus(x.status) or x.rev < 1) return error.InvalidArgument;
        }
        for (file.checkpoints, 0..) |c, i| {
            if (c.id.len == 0) return error.InvalidArgument;
            for (file.checkpoints[0..i]) |p| if (std.mem.eql(u8, p.id, c.id)) return error.InvalidArgument;
            const parent_rev = assignmentRev(file.assignments, c.assignment_id) orelse return error.InvalidArgument;
            if (!validKind(c.kind)) return error.InvalidArgument;
            if (c.rev < 2 or c.rev > parent_rev) return error.InvalidArgument;
            for (file.checkpoints[0..i]) |p| {
                if (std.mem.eql(u8, p.assignment_id, c.assignment_id) and p.rev == c.rev)
                    return error.InvalidArgument;
            }
        }
        const digests = try a.alloc([]const u8, file.operations.len);
        for (file.operations, 0..) |op, i| {
            if (op.key.len == 0 or op.request_sha256.len != 64) return error.InvalidArgument;
            for (file.operations[0..i]) |p| if (std.mem.eql(u8, p.key, op.key)) return error.InvalidArgument;
            const digest = try a.alloc(u8, 32);
            _ = std.fmt.hexToBytes(digest, op.request_sha256) catch return error.InvalidArgument;
            digests[i] = digest;
        }
        for (file.knowledge, 0..) |k, i| {
            if (k.id.len == 0 or k.scope.len == 0) return error.InvalidArgument;
            for (file.knowledge[0..i]) |p| if (std.mem.eql(u8, p.id, k.id)) return error.InvalidArgument;
            if (!hasId(file.scopes, k.scope)) return error.InvalidArgument;
            if (!validKnowledgeKind(k.kind) or k.rev != 1) return error.InvalidArgument;
        }

        try self.db.beginImmediate();
        var committed = false;
        defer if (!committed) self.db.rollback();

        const empty = ExportCounts{ .scopes = 0, .assignments = 0, .checkpoints = 0, .operations = 0, .knowledge = 0 };
        if (!std.meta.eql(try self.counts(), empty)) return error.InvalidArgument;

        for (file.scopes) |s| {
            var stmt = try self.db.prepare("INSERT INTO scope (id) VALUES (?1)");
            defer stmt.deinit();
            try stmt.bindText(1, s.id);
            _ = try stmt.step();
        }
        for (file.assignments) |x| {
            var stmt = try self.db.prepare(
                \\INSERT INTO assignment (id, scope_id, request, objective, constraints, project, status, rev, created_at, updated_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            );
            defer stmt.deinit();
            try stmt.bindText(1, x.id);
            try stmt.bindText(2, x.scope_id);
            try stmt.bindText(3, x.request);
            try stmt.bindTextOpt(4, x.objective);
            try stmt.bindTextOpt(5, x.constraints);
            try stmt.bindTextOpt(6, x.project);
            try stmt.bindText(7, x.status);
            try stmt.bindInt64(8, x.rev);
            try stmt.bindText(9, x.created_at);
            try stmt.bindText(10, x.updated_at);
            _ = try stmt.step();
        }
        for (file.checkpoints) |c| {
            var stmt = try self.db.prepare(
                \\INSERT INTO checkpoint (id, assignment_id, kind, result, evidence, next_action, rev, created_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            );
            defer stmt.deinit();
            try stmt.bindText(1, c.id);
            try stmt.bindText(2, c.assignment_id);
            try stmt.bindText(3, c.kind);
            try stmt.bindText(4, c.result);
            try stmt.bindTextOpt(5, c.evidence);
            try stmt.bindTextOpt(6, c.next_action);
            try stmt.bindInt64(7, c.rev);
            try stmt.bindText(8, c.created_at);
            _ = try stmt.step();
        }
        for (file.operations, 0..) |op, i| {
            var stmt = try self.db.prepare("INSERT INTO op_log (key, request_sha256, result_json, created_at) VALUES (?1, ?2, ?3, ?4)");
            defer stmt.deinit();
            try stmt.bindText(1, op.key);
            try stmt.bindBlob(2, digests[i]);
            try stmt.bindText(3, op.result_json);
            try stmt.bindText(4, op.created_at);
            _ = try stmt.step();
        }
        for (file.knowledge) |k| {
            try self.insertKnowledge(.{
                .id = k.id,
                .scope = k.scope,
                .kind = k.kind,
                .text = k.text,
                .source = k.source,
                .rev = k.rev,
                .created_at = k.created_at,
            });
        }

        const final = try self.counts();
        if (final.scopes != file.scopes.len or final.assignments != file.assignments.len or
            final.checkpoints != file.checkpoints.len or final.operations != file.operations.len or
            final.knowledge != file.knowledge.len)
            return error.InvalidArgument;
        if (try self.revisionMismatches() != 0) return error.InvalidArgument;

        try self.db.commit();
        committed = true;
        return final;
    }

    /// Copies the store to `path` with `VACUUM INTO`, refusing to overwrite an
    /// existing file. The path is resolved to absolute and single quotes are
    /// doubled for the SQL literal; the copy carries the schema version, so it
    /// opens and passes the gate.
    pub fn backupTo(self: *Store, alloc: std.mem.Allocator, path: []const u8) !void {
        if (path.len == 0) return error.InvalidArgument;
        const abs = try db.resolvePath(self.io, alloc, path);
        defer alloc.free(abs);
        if (std.Io.Dir.accessAbsolute(self.io, abs, .{})) |_| {
            return error.InvalidArgument;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(alloc);
        try sql.appendSlice(alloc, "VACUUM INTO '");
        for (abs) |c| {
            if (c == '\'') {
                try sql.appendSlice(alloc, "''");
            } else {
                try sql.append(alloc, c);
            }
        }
        try sql.append(alloc, '\'');
        const z = try alloc.allocSentinel(u8, sql.items.len, 0);
        defer alloc.free(z);
        @memcpy(z, sql.items);
        try self.db.exec(z);
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

    fn parseRemember(self: *Store, text: []const u8) !RememberResult {
        return std.json.parseFromSliceLeaky(RememberResult, self.alloc, text, .{ .allocate = .alloc_always });
    }

    /// Inserts one `knowledge` row and its `knowledge_fts` twin (same rowid).
    /// Both statements run on the caller's open transaction, so the standalone
    /// index cannot drift from the table.
    fn insertKnowledge(self: *Store, k: Knowledge) !void {
        {
            var stmt = try self.db.prepare(
                \\INSERT INTO knowledge (id, scope_id, kind, text, source, rev, created_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            );
            defer stmt.deinit();
            try stmt.bindText(1, k.id);
            try stmt.bindText(2, k.scope);
            try stmt.bindText(3, k.kind);
            try stmt.bindText(4, k.text);
            try stmt.bindTextOpt(5, k.source);
            try stmt.bindInt64(6, k.rev);
            try stmt.bindText(7, k.created_at);
            _ = try stmt.step();
        }
        {
            var stmt = try self.db.prepare(
                \\INSERT INTO knowledge_fts (rowid, text, source, id)
                \\SELECT rowid, ?2, ?3, ?1 FROM knowledge WHERE id = ?1
            );
            defer stmt.deinit();
            try stmt.bindText(1, k.id);
            try stmt.bindText(2, k.text);
            try stmt.bindTextOpt(3, k.source);
            _ = try stmt.step();
        }
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

    fn counts(self: *Store) !ExportCounts {
        var stmt = try self.db.prepare(
            \\SELECT (SELECT count(*) FROM scope), (SELECT count(*) FROM assignment),
            \\       (SELECT count(*) FROM checkpoint), (SELECT count(*) FROM op_log),
            \\       (SELECT count(*) FROM knowledge)
        );
        defer stmt.deinit();
        if (!try stmt.step()) return error.InvalidArgument;
        return .{
            .scopes = try countToUsize(stmt.columnInt64(0)),
            .assignments = try countToUsize(stmt.columnInt64(1)),
            .checkpoints = try countToUsize(stmt.columnInt64(2)),
            .operations = try countToUsize(stmt.columnInt64(3)),
            .knowledge = try countToUsize(stmt.columnInt64(4)),
        };
    }

    /// Assignments whose rev is not `1 + their checkpoint count`.
    fn revisionMismatches(self: *Store) !usize {
        var stmt = try self.db.prepare(
            \\SELECT count(*) FROM assignment a
            \\WHERE a.rev != 1 + (SELECT count(*) FROM checkpoint c WHERE c.assignment_id = a.id)
        );
        defer stmt.deinit();
        if (!try stmt.step()) return error.InvalidArgument;
        return countToUsize(stmt.columnInt64(0));
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

    fn readCheckpointCols(alloc: std.mem.Allocator, stmt: *db.Stmt, base: c_int) !Checkpoint {
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
        errdefer freeCheckpoint(alloc, c);
        c.id = (try stmt.columnText(alloc, base + 0)) orelse "";
        c.assignment_id = (try stmt.columnText(alloc, base + 1)) orelse "";
        c.kind = (try stmt.columnText(alloc, base + 2)) orelse "";
        c.result = (try stmt.columnText(alloc, base + 3)) orelse "";
        c.evidence = try stmt.columnText(alloc, base + 4);
        c.next_action = try stmt.columnText(alloc, base + 5);
        c.rev = stmt.columnInt64(base + 6);
        c.created_at = (try stmt.columnText(alloc, base + 7)) orelse "";
        return c;
    }

    fn readKnowledgeCols(alloc: std.mem.Allocator, stmt: *db.Stmt, base: c_int) !Knowledge {
        var k = Knowledge{
            .id = "",
            .scope = "",
            .kind = "",
            .text = "",
            .source = null,
            .rev = 0,
            .created_at = "",
        };
        errdefer freeKnowledge(alloc, k);
        k.id = (try stmt.columnText(alloc, base + 0)) orelse "";
        k.scope = (try stmt.columnText(alloc, base + 1)) orelse "";
        k.kind = (try stmt.columnText(alloc, base + 2)) orelse "";
        k.text = (try stmt.columnText(alloc, base + 3)) orelse "";
        k.source = try stmt.columnText(alloc, base + 4);
        k.rev = stmt.columnInt64(base + 5);
        k.created_at = (try stmt.columnText(alloc, base + 6)) orelse "";
        return k;
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

fn freeKnowledge(alloc: std.mem.Allocator, k: Knowledge) void {
    alloc.free(k.id);
    alloc.free(k.scope);
    alloc.free(k.kind);
    alloc.free(k.text);
    if (k.source) |v| alloc.free(v);
    alloc.free(k.created_at);
}

fn countToUsize(value: i64) !usize {
    return std.math.cast(usize, value) orelse return error.InvalidArgument;
}

fn hasId(items: anytype, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn assignmentRev(assignments: anytype, id: []const u8) ?i64 {
    for (assignments) |item| if (std.mem.eql(u8, item.id, id)) return item.rev;
    return null;
}

fn validStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "open") or std.mem.eql(u8, s, "done") or std.mem.eql(u8, s, "cancelled");
}

fn validKind(k: []const u8) bool {
    return std.mem.eql(u8, k, "progress") or std.mem.eql(u8, k, "done");
}

fn validKnowledgeKind(k: []const u8) bool {
    return std.mem.eql(u8, k, "fact") or std.mem.eql(u8, k, "decision") or
        std.mem.eql(u8, k, "constraint") or std.mem.eql(u8, k, "procedure");
}

const hex_chars = "0123456789abcdef";

fn hexLower(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
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

fn digestRemember(input: RememberInput) [Sha256.digest_length]u8 {
    var h = Sha256.init(.{});
    hashField(&h, input.scope);
    hashField(&h, input.kind);
    hashField(&h, input.text);
    hashOptField(&h, input.source);
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

    // Lifecycle: a progress note after completion is recorded, and status stays done.
    const p3 = try s.prepare(id, "trabajo");
    defer s.deinitPrepareResult(p3);
    try std.testing.expectEqualStrings("done", p3.assignment.status);
    try std.testing.expectEqual(@as(i64, 4), p3.assignment.rev);
    try std.testing.expectEqualStrings(c3.checkpoint.id, p3.latest.?.id);

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

test "export and restore round trip preserves revisions and digests" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const src_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "src.db" });
    defer alloc.free(src_path);
    const dst_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "dst.db" });
    defer alloc.free(dst_path);

    var src = try Store.open(alloc, io, src_path);
    defer src.close();

    const input = CaptureInput{
        .scope = "trabajo",
        .project = "komorebi",
        .request = "exportar la tienda",
        .objective = "recuperar el estado",
        .constraints = null,
        .idempotency_key = "op-1",
    };
    const r = try src.capture(input);
    defer src.deinitCaptureResult(r);
    const id = r.assignment.id;

    const c1 = try src.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "progress",
        .result = "avance",
        .evidence = null,
        .next_action = null,
        .idempotency_key = "ck-1",
    });
    defer src.deinitCheckpointResult(c1);
    const c2 = try src.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 2,
        .kind = "done",
        .result = "terminado",
        .evidence = "commit abc",
        .next_action = null,
        .idempotency_key = null,
    });
    defer src.deinitCheckpointResult(c2);

    const json = try src.exportJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"format\":\"ztd-agent-export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":2") != null);
    // null columns stay JSON null, never ""
    try std.testing.expect(std.mem.indexOf(u8, json, "\"constraints\":null") != null);
    const expected_digest = digestCapture(input);
    const expected_hex = try hexLower(alloc, &expected_digest);
    defer alloc.free(expected_hex);
    try std.testing.expect(std.mem.indexOf(u8, json, expected_hex) != null);

    var dst = try Store.open(alloc, io, dst_path);
    defer dst.close();
    const counts = try dst.restoreJson(alloc, json);
    try std.testing.expectEqual(@as(usize, 1), counts.scopes);
    try std.testing.expectEqual(@as(usize, 1), counts.assignments);
    try std.testing.expectEqual(@as(usize, 2), counts.checkpoints);
    try std.testing.expectEqual(@as(usize, 2), counts.operations);

    const p = try dst.prepare(id, "trabajo");
    defer dst.deinitPrepareResult(p);
    try std.testing.expectEqualStrings(input.request, p.assignment.request);
    try std.testing.expectEqualStrings("done", p.assignment.status);
    try std.testing.expectEqual(@as(i64, 3), p.assignment.rev);
    try std.testing.expectEqualStrings(r.assignment.created_at, p.assignment.created_at);
    try std.testing.expectEqualStrings(r.assignment.updated_at, p.assignment.updated_at);
    try std.testing.expectEqualStrings(c2.checkpoint.id, p.latest.?.id);
    try std.testing.expectEqual(@as(i64, 3), p.latest.?.rev);

    const src_op = (try src.lookupOp("op-1")).?;
    defer {
        alloc.free(src_op.digest);
        alloc.free(src_op.result_json);
    }
    const dst_op = (try dst.lookupOp("op-1")).?;
    defer {
        alloc.free(dst_op.digest);
        alloc.free(dst_op.result_json);
    }
    try std.testing.expectEqualSlices(u8, &expected_digest, src_op.digest);
    try std.testing.expectEqualSlices(u8, src_op.digest, dst_op.digest);
    try std.testing.expectEqualStrings(src_op.result_json, dst_op.result_json);
}

test "restore refuses a non-empty store" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const src_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "src.db" });
    defer alloc.free(src_path);
    const dst_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "dst.db" });
    defer alloc.free(dst_path);

    var src = try Store.open(alloc, io, src_path);
    defer src.close();
    const exported = try src.capture(.{
        .scope = "trabajo",
        .project = null,
        .request = "para exportar",
        .objective = null,
        .constraints = null,
        .idempotency_key = null,
    });
    defer src.deinitCaptureResult(exported);
    const json = try src.exportJson(alloc);
    defer alloc.free(json);

    var dst = try Store.open(alloc, io, dst_path);
    defer dst.close();
    const existing = try dst.capture(.{
        .scope = "otra",
        .project = null,
        .request = "ya hay una fila",
        .objective = null,
        .constraints = null,
        .idempotency_key = null,
    });
    defer dst.deinitCaptureResult(existing);

    try std.testing.expectError(error.InvalidArgument, dst.restoreJson(alloc, json));

    // the refusal wrote nothing and the existing row is untouched
    const counts = try dst.counts();
    try std.testing.expectEqual(@as(usize, 1), counts.scopes);
    try std.testing.expectEqual(@as(usize, 1), counts.assignments);
    try std.testing.expectEqual(@as(usize, 0), counts.checkpoints);
    try std.testing.expectEqual(@as(usize, 0), counts.operations);
    const p = try dst.prepare(existing.assignment.id, "otra");
    defer dst.deinitPrepareResult(p);
    try std.testing.expectEqual(@as(i64, 1), p.assignment.rev);
    try std.testing.expectEqualStrings("ya hay una fila", p.assignment.request);
}

test "a corrupted export is refused without writing any row" {
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

    // truncated document
    try std.testing.expectError(error.InvalidArgument, s.restoreJson(
        alloc,
        "{\"format\":\"ztd-agent-export\",\"version\":1,\"scopes\":[{\"id\":\"tr",
    ));
    // wrong format and wrong version
    try std.testing.expectError(error.InvalidArgument, s.restoreJson(
        alloc,
        "{\"format\":\"something-else\",\"version\":1,\"scopes\":[],\"assignments\":[],\"checkpoints\":[],\"operations\":[]}",
    ));
    try std.testing.expectError(error.InvalidArgument, s.restoreJson(
        alloc,
        "{\"format\":\"ztd-agent-export\",\"version\":3,\"scopes\":[],\"assignments\":[],\"checkpoints\":[],\"operations\":[]}",
    ));
    // trailing garbage and a missing field
    try std.testing.expectError(error.InvalidArgument, s.restoreJson(
        alloc,
        "{\"format\":\"ztd-agent-export\",\"version\":1,\"scopes\":[],\"assignments\":[],\"checkpoints\":[],\"operations\":[]} junk",
    ));
    try std.testing.expectError(error.InvalidArgument, s.restoreJson(alloc, "{}"));
    // partial document: an assignment whose scope is not in the export
    try std.testing.expectError(error.InvalidArgument, s.restoreJson(alloc,
        \\{"format":"ztd-agent-export","version":1,"scopes":[],
        \\ "assignments":[{"id":"A-20260101-001","scope_id":"missing","request":"x","objective":null,"constraints":null,"project":null,"status":"open","rev":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}],
        \\ "checkpoints":[],"operations":[]}
    ));

    // a second connection sees an untouched, empty store
    var other = try Store.open(alloc, io, db_path);
    defer other.close();
    const counts = try other.counts();
    try std.testing.expectEqual(@as(usize, 0), counts.scopes);
    try std.testing.expectEqual(@as(usize, 0), counts.assignments);
    try std.testing.expectEqual(@as(usize, 0), counts.checkpoints);
    try std.testing.expectEqual(@as(usize, 0), counts.operations);
}

test "restore rejects checkpoint shapes the store cannot produce" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpPath(alloc, io, &tmp);
    defer alloc.free(db_path);

    const head =
        \\{"format":"ztd-agent-export","version":1,
        \\ "scopes":[{"id":"trabajo"}],
        \\ "assignments":[{"id":"A-20260101-001","scope_id":"trabajo","request":"x","objective":null,"constraints":null,"project":null,"status":"open","rev":2,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}],
        \\ "checkpoints":[
    ;
    const tail = "],\"operations\":[]}";

    const cases = [_][]const u8{
        // checkpoint rev above the assignment rev
        "{\"id\":\"C-20260101-001\",\"assignment_id\":\"A-20260101-001\",\"kind\":\"progress\",\"result\":\"r\",\"evidence\":null,\"next_action\":null,\"rev\":3,\"created_at\":\"2026-01-01T00:00:00Z\"}",
        // unknown kind
        "{\"id\":\"C-20260101-001\",\"assignment_id\":\"A-20260101-001\",\"kind\":\"banana\",\"result\":\"r\",\"evidence\":null,\"next_action\":null,\"rev\":2,\"created_at\":\"2026-01-01T00:00:00Z\"}",
        // rev below the first checkpoint
        "{\"id\":\"C-20260101-001\",\"assignment_id\":\"A-20260101-001\",\"kind\":\"progress\",\"result\":\"r\",\"evidence\":null,\"next_action\":null,\"rev\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}",
        // two checkpoints sharing one rev
        "{\"id\":\"C-20260101-001\",\"assignment_id\":\"A-20260101-001\",\"kind\":\"progress\",\"result\":\"r\",\"evidence\":null,\"next_action\":null,\"rev\":2,\"created_at\":\"2026-01-01T00:00:00Z\"},{\"id\":\"C-20260101-002\",\"assignment_id\":\"A-20260101-001\",\"kind\":\"progress\",\"result\":\"r\",\"evidence\":null,\"next_action\":null,\"rev\":2,\"created_at\":\"2026-01-01T00:00:00Z\"}",
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (cases) |body| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(alloc, head);
        try buf.appendSlice(alloc, body);
        try buf.appendSlice(alloc, tail);
        var s = try Store.open(alloc, io, db_path);
        defer s.close();
        try std.testing.expectError(error.InvalidArgument, s.restoreJson(alloc, buf.items));
        const counts = try s.counts();
        try std.testing.expectEqual(@as(usize, 0), counts.checkpoints);
    }

    // a digest that is not 32 bytes
    buf.clearRetainingCapacity();
    try buf.appendSlice(alloc,
        \\{"format":"ztd-agent-export","version":1,"scopes":[],"assignments":[],"checkpoints":[],
        \\ "operations":[{"key":"k","request_sha256":"aa","result_json":"{}","created_at":"2026-01-01T00:00:00Z"}]}
    );
    var s2 = try Store.open(alloc, io, db_path);
    defer s2.close();
    try std.testing.expectError(error.InvalidArgument, s2.restoreJson(alloc, buf.items));
}

test "history is newest-first and honours the limit" {
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

    const r = try s.capture(.{
        .scope = "trabajo",
        .project = null,
        .request = "historial",
        .objective = null,
        .constraints = null,
        .idempotency_key = null,
    });
    defer s.deinitCaptureResult(r);
    const id = r.assignment.id;

    const c1 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "progress",
        .result = "uno",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    });
    defer s.deinitCheckpointResult(c1);
    const c2 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 2,
        .kind = "progress",
        .result = "dos",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    });
    defer s.deinitCheckpointResult(c2);
    const c3 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 3,
        .kind = "done",
        .result = "tres",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    });
    defer s.deinitCheckpointResult(c3);

    const h2 = try s.history(alloc, id, "trabajo", 2);
    defer {
        for (h2) |c| freeCheckpoint(alloc, c);
        alloc.free(h2);
    }
    try std.testing.expectEqual(@as(usize, 2), h2.len);
    try std.testing.expectEqual(@as(i64, 4), h2[0].rev);
    try std.testing.expectEqual(@as(i64, 3), h2[1].rev);
    try std.testing.expectEqualStrings(c3.checkpoint.id, h2[0].id);
    try std.testing.expectEqualStrings(c2.checkpoint.id, h2[1].id);

    const h0 = try s.history(alloc, id, "trabajo", 0);
    try std.testing.expectEqual(@as(usize, 0), h0.len);
    alloc.free(h0);

    const hall = try s.history(alloc, id, "trabajo", 99);
    defer {
        for (hall) |c| freeCheckpoint(alloc, c);
        alloc.free(hall);
    }
    try std.testing.expectEqual(@as(usize, 3), hall.len);
    try std.testing.expectEqual(@as(i64, 4), hall[0].rev);
    try std.testing.expectEqual(@as(i64, 3), hall[1].rev);
    try std.testing.expectEqual(@as(i64, 2), hall[2].rev);
    try std.testing.expectEqualStrings(c1.checkpoint.id, hall[2].id);

    // the newest history entry is the checkpoint prepare reports as latest
    const p = try s.prepare(id, "trabajo");
    defer s.deinitPrepareResult(p);
    try std.testing.expectEqualStrings(p.latest.?.id, hall[0].id);

    try std.testing.expectError(error.ScopeDenied, s.history(alloc, id, "salud", 2));
    try std.testing.expectError(error.UnknownAssignment, s.history(alloc, "A-19990101-001", "trabajo", 2));
}

test "a backup opens and passes the gate" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const src_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "src.db" });
    defer alloc.free(src_path);
    const bpath = try std.fs.path.join(alloc, &.{ path_buf[0..n], "backup.db" });
    defer alloc.free(bpath);

    var s = try Store.open(alloc, io, src_path);
    defer s.close();
    const r = try s.capture(.{
        .scope = "trabajo",
        .project = null,
        .request = "respaldar",
        .objective = null,
        .constraints = null,
        .idempotency_key = "op-1",
    });
    defer s.deinitCaptureResult(r);
    const id = r.assignment.id;
    const c1 = try s.checkpoint(.{
        .assignment_id = id,
        .scope = "trabajo",
        .expect_rev = 1,
        .kind = "done",
        .result = "listo",
        .evidence = null,
        .next_action = null,
        .idempotency_key = null,
    });
    defer s.deinitCheckpointResult(c1);

    try s.backupTo(alloc, bpath);
    // never overwrites an existing file
    try std.testing.expectError(error.InvalidArgument, s.backupTo(alloc, bpath));

    // a single quote in the path must be doubled, not tripled
    const quoted = try std.fs.path.join(alloc, &.{ path_buf[0..n], "it's.db" });
    defer alloc.free(quoted);
    try s.backupTo(alloc, quoted);
    var q = try Store.open(alloc, io, quoted);
    q.close();

    // opening runs the schema gate on the copy
    var b = try Store.open(alloc, io, bpath);
    defer b.close();
    const p = try b.prepare(id, "trabajo");
    defer b.deinitPrepareResult(p);
    try std.testing.expectEqual(@as(i64, 2), p.assignment.rev);
    try std.testing.expectEqualStrings("done", p.assignment.status);
    try std.testing.expectEqualStrings(c1.checkpoint.id, p.latest.?.id);

    const counts = try b.counts();
    try std.testing.expectEqual(@as(usize, 1), counts.scopes);
    try std.testing.expectEqual(@as(usize, 1), counts.assignments);
    try std.testing.expectEqual(@as(usize, 1), counts.checkpoints);
    try std.testing.expectEqual(@as(usize, 1), counts.operations);

    const op = (try b.lookupOp("op-1")).?;
    defer {
        alloc.free(op.digest);
        alloc.free(op.result_json);
    }
    const expected = digestCapture(.{
        .scope = "trabajo",
        .project = null,
        .request = "respaldar",
        .objective = null,
        .constraints = null,
        .idempotency_key = "op-1",
    });
    try std.testing.expectEqualSlices(u8, &expected, op.digest);
}

test "remember inserts at rev 1 and recall finds it in its scope" {
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

    const r = try s.remember(.{
        .scope = "trabajo",
        .kind = "decision",
        .text = "usar FTS5 para el recall",
        .source = "spec 10",
        .idempotency_key = null,
    });
    defer s.deinitRememberResult(r);
    try std.testing.expect(!r.replayed);
    try std.testing.expectEqual(@as(i64, 1), r.knowledge.rev);
    try std.testing.expectEqualStrings("trabajo", r.knowledge.scope);
    try std.testing.expectEqualStrings("decision", r.knowledge.kind);
    try std.testing.expectEqualStrings("usar FTS5 para el recall", r.knowledge.text);
    try std.testing.expectEqualStrings("spec 10", r.knowledge.source.?);
    try std.testing.expect(std.mem.startsWith(u8, r.knowledge.id, "K-"));
    try std.testing.expectEqualStrings("001", r.knowledge.id[11..]);

    const hits = try s.recall(.{ .scope = "trabajo", .query = "FTS5", .limit = 10 });
    defer s.deinitRecall(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings(r.knowledge.id, hits[0].id);
    try std.testing.expectEqualStrings("trabajo", hits[0].scope);
    try std.testing.expectEqual(@as(i64, 1), hits[0].rev);
    try std.testing.expectEqualStrings("spec 10", hits[0].source.?);

    // another scope sees nothing even for a matching query
    const other = try s.recall(.{ .scope = "salud", .query = "FTS5", .limit = 10 });
    defer s.deinitRecall(other);
    try std.testing.expectEqual(@as(usize, 0), other.len);
}

test "recall ranks by bm25, folds diacritics and refuses bad input" {
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

    const a = try s.remember(.{
        .scope = "demo",
        .kind = "fact",
        .text = "el build cache vive en zig-out",
        .source = null,
        .idempotency_key = null,
    });
    defer s.deinitRememberResult(a);
    const b = try s.remember(.{
        .scope = "demo",
        .kind = "decision",
        .text = "build cache",
        .source = null,
        .idempotency_key = null,
    });
    defer s.deinitRememberResult(b);
    const c = try s.remember(.{
        .scope = "salud",
        .kind = "procedure",
        .text = "revisión del sistema",
        .source = null,
        .idempotency_key = null,
    });
    defer s.deinitRememberResult(c);

    // bm25 ascending: the shorter, better match ranks first
    const hits = try s.recall(.{ .scope = "demo", .query = "build cache", .limit = 10 });
    defer s.deinitRecall(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings(b.knowledge.id, hits[0].id);
    try std.testing.expectEqualStrings(a.knowledge.id, hits[1].id);

    // unicode61 remove_diacritics 2: "revision" finds "revisión"
    const accented = try s.recall(.{ .scope = "salud", .query = "revision", .limit = 10 });
    defer s.deinitRecall(accented);
    try std.testing.expectEqual(@as(usize, 1), accented.len);
    try std.testing.expectEqualStrings(c.knowledge.id, accented[0].id);

    // an unknown scope is an empty list, not an error
    const none = try s.recall(.{ .scope = "inexistente", .query = "build", .limit = 10 });
    defer s.deinitRecall(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // a positive limit is mandatory
    try std.testing.expectError(error.InvalidArgument, s.recall(.{ .scope = "demo", .query = "build", .limit = 0 }));
    try std.testing.expectError(error.InvalidArgument, s.recall(.{ .scope = "demo", .query = "build", .limit = -1 }));
    // a malformed FTS5 query is a refusal, not an I/O error
    try std.testing.expectError(error.InvalidArgument, s.recall(.{ .scope = "demo", .query = "\"", .limit = 10 }));
    // unknown kind
    try std.testing.expectError(error.InvalidArgument, s.remember(.{
        .scope = "demo",
        .kind = "banana",
        .text = "x",
        .source = null,
        .idempotency_key = null,
    }));
}

test "remember replays idempotently and conflicts on a different digest" {
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

    const input = RememberInput{
        .scope = "demo",
        .kind = "constraint",
        .text = "sin dependencias nuevas",
        .source = "revisión técnica",
        .idempotency_key = "k-1",
    };
    const r1 = try s.remember(input);
    defer s.deinitRememberResult(r1);
    try std.testing.expect(!r1.replayed);

    const r2 = try s.remember(input);
    defer s.deinitRememberResult(r2);
    try std.testing.expect(r2.replayed);
    try std.testing.expectEqualStrings(r1.knowledge.id, r2.knowledge.id);
    try std.testing.expectEqualStrings(r1.knowledge.text, r2.knowledge.text);
    try std.testing.expectEqual(@as(i64, 1), r2.knowledge.rev);

    const hits = try s.recall(.{ .scope = "demo", .query = "dependencias", .limit = 10 });
    defer s.deinitRecall(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);

    // same key, different payload: conflict, nothing written
    try std.testing.expectError(error.IdempotencyConflict, s.remember(.{
        .scope = "demo",
        .kind = "constraint",
        .text = "otro texto",
        .source = "revisión técnica",
        .idempotency_key = "k-1",
    }));
    const after = try s.recall(.{ .scope = "demo", .query = "dependencias", .limit = 10 });
    defer s.deinitRecall(after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
}

test "export and restore round trip keeps knowledge and recall answers on the copy" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const src_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "src.db" });
    defer alloc.free(src_path);
    const dst_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "dst.db" });
    defer alloc.free(dst_path);

    var src = try Store.open(alloc, io, src_path);
    defer src.close();

    const cap = try src.capture(.{
        .scope = "demo",
        .project = null,
        .request = "tarea con conocimiento",
        .objective = null,
        .constraints = null,
        .idempotency_key = null,
    });
    defer src.deinitCaptureResult(cap);
    const a = try src.remember(.{
        .scope = "demo",
        .kind = "fact",
        .text = "el build cache vive en zig-out",
        .source = null,
        .idempotency_key = null,
    });
    defer src.deinitRememberResult(a);
    const b = try src.remember(.{
        .scope = "demo",
        .kind = "decision",
        .text = "build cache",
        .source = "spec 10",
        .idempotency_key = null,
    });
    defer src.deinitRememberResult(b);

    const json = try src.exportJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"knowledge\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source\":null") != null);
    // knowledge rows are ordered by id
    const pos_a = std.mem.indexOf(u8, json, a.knowledge.id).?;
    const pos_b = std.mem.indexOf(u8, json, b.knowledge.id).?;
    try std.testing.expect(pos_a < pos_b);

    var dst = try Store.open(alloc, io, dst_path);
    defer dst.close();
    const counts = try dst.restoreJson(alloc, json);
    try std.testing.expectEqual(@as(usize, 1), counts.scopes);
    try std.testing.expectEqual(@as(usize, 1), counts.assignments);
    try std.testing.expectEqual(@as(usize, 0), counts.checkpoints);
    try std.testing.expectEqual(@as(usize, 0), counts.operations);
    try std.testing.expectEqual(@as(usize, 2), counts.knowledge);

    const p = try dst.prepare(cap.assignment.id, "demo");
    defer dst.deinitPrepareResult(p);
    try std.testing.expectEqualStrings("tarea con conocimiento", p.assignment.request);

    // the restored store answers recall with the original records
    const hits = try dst.recall(.{ .scope = "demo", .query = "build cache", .limit = 10 });
    defer dst.deinitRecall(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings(b.knowledge.id, hits[0].id);
    try std.testing.expectEqualStrings("decision", hits[0].kind);
    try std.testing.expectEqualStrings("spec 10", hits[0].source.?);
    try std.testing.expectEqual(@as(i64, 1), hits[0].rev);
    try std.testing.expectEqualStrings(b.knowledge.created_at, hits[0].created_at);
    try std.testing.expectEqualStrings(a.knowledge.id, hits[1].id);
    try std.testing.expect(hits[1].source == null);
}

test "a version-1 export document restores without knowledge" {
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

    const v1_doc =
        \\{"format":"ztd-agent-export","version":1,"scopes":[{"id":"demo"}],
        \\ "assignments":[{"id":"A-20260101-001","scope_id":"demo","request":"legacy","objective":null,"constraints":null,"project":null,"status":"open","rev":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}],
        \\ "checkpoints":[],"operations":[]}
    ;
    const counts = try s.restoreJson(alloc, v1_doc);
    try std.testing.expectEqual(@as(usize, 1), counts.scopes);
    try std.testing.expectEqual(@as(usize, 1), counts.assignments);
    try std.testing.expectEqual(@as(usize, 0), counts.knowledge);

    const p = try s.prepare("A-20260101-001", "demo");
    defer s.deinitPrepareResult(p);
    try std.testing.expectEqualStrings("legacy", p.assignment.request);

    const none = try s.recall(.{ .scope = "demo", .query = "anything", .limit = 10 });
    defer s.deinitRecall(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "restore refuses knowledge rows it cannot produce" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpPath(alloc, io, &tmp);
    defer alloc.free(db_path);

    const head =
        \\{"format":"ztd-agent-export","version":2,
        \\ "scopes":[{"id":"demo"}],
        \\ "assignments":[],"checkpoints":[],"operations":[],
        \\ "knowledge":[
    ;
    const tail = "]}";

    const cases = [_][]const u8{
        // unknown kind
        "{\"id\":\"K-20260101-001\",\"scope\":\"demo\",\"kind\":\"banana\",\"text\":\"x\",\"source\":null,\"rev\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}",
        // rev is not 1
        "{\"id\":\"K-20260101-001\",\"scope\":\"demo\",\"kind\":\"fact\",\"text\":\"x\",\"source\":null,\"rev\":2,\"created_at\":\"2026-01-01T00:00:00Z\"}",
        // duplicate id
        "{\"id\":\"K-20260101-001\",\"scope\":\"demo\",\"kind\":\"fact\",\"text\":\"x\",\"source\":null,\"rev\":1,\"created_at\":\"2026-01-01T00:00:00Z\"},{\"id\":\"K-20260101-001\",\"scope\":\"demo\",\"kind\":\"fact\",\"text\":\"x\",\"source\":null,\"rev\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}",
        // scope missing from the document
        "{\"id\":\"K-20260101-001\",\"scope\":\"otra\",\"kind\":\"fact\",\"text\":\"x\",\"source\":null,\"rev\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}",
        // empty id
        "{\"id\":\"\",\"scope\":\"demo\",\"kind\":\"fact\",\"text\":\"x\",\"source\":null,\"rev\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}",
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (cases) |body| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(alloc, head);
        try buf.appendSlice(alloc, body);
        try buf.appendSlice(alloc, tail);
        var s = try Store.open(alloc, io, db_path);
        defer s.close();
        try std.testing.expectError(error.InvalidArgument, s.restoreJson(alloc, buf.items));
        const counts = try s.counts();
        try std.testing.expectEqual(@as(usize, 0), counts.scopes);
        try std.testing.expectEqual(@as(usize, 0), counts.knowledge);
    }
}
