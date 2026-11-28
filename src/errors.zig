//! Error families and the single failure slot shared by every module.
//!
//! Zig has no exceptions with payloads, so every fallible function returns
//! `error{Ztd}` after recording the family and detail here. The CLI reads the
//! slot once, prints the Go-compatible envelope, and exits.

const std = @import("std");

pub const Family = enum {
    invalid_input,
    invalid_transition,
    not_found,
    scope_denied,
    human_decision_required,
    rules_acknowledgement_required,
    stale_revision,
    idempotency_conflict,
    focus_conflict,
    source_coverage_incomplete,
    external_outcome_unknown,
    unsupported_format,
    destination_not_empty,
    db_busy,
    db_incompatible,
    io_error,
    pending_transaction,
    conflict,

    pub fn text(self: Family) []const u8 {
        return @tagName(self);
    }
};

pub const Ztd = error{Ztd};

var family: Family = .io_error;
var detail_buf: [4096]u8 = undefined;
// A detail longer than the buffer keeps its prefix, cut on a char boundary so
// the envelope stays valid JSON.
var detail_len: usize = 0;

/// Records family and detail, then returns the shared error.
pub fn fail(f: Family, comptime fmt: []const u8, args: anytype) Ztd {
    family = f;
    var w = std.Io.Writer.fixed(&detail_buf);
    w.print(fmt, args) catch {};
    detail_len = charBoundary(w.buffered());
    return error.Ztd;
}

/// Length of the longest prefix that ends on a UTF-8 character boundary.
fn charBoundary(s: []const u8) usize {
    var n = s.len;
    while (n > 0 and (s[n - 1] & 0xC0) == 0x80) n -= 1; // drop continuation bytes
    if (n == 0) return 0;
    const lead = s[n - 1];
    const need: usize = if (lead < 0x80) 1 else if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else if (lead >= 0xC0) 2 else 1;
    if (n - 1 + need > s.len) return n - 1;
    return n;
}

/// Copies the current detail out, for callers that format it again while it is
/// still the live detail buffer.
pub fn detailCopy(out: []u8) []const u8 {
    const n = @min(detail_len, out.len);
    @memcpy(out[0..n], detail_buf[0..n]);
    return out[0..n];
}

pub fn invalid(comptime fmt: []const u8, args: anytype) Ztd {
    return fail(.invalid_input, fmt, args);
}

pub fn getFamily() Family {
    return family;
}

pub fn detail() []const u8 {
    return detail_buf[0..detail_len];
}

/// Classifies a SQLite failure the way the Go store does: contention is
/// db_busy, everything else during open/migrate is db_incompatible.
pub fn fromSqlite(message: []const u8, while_open: bool) Ztd {
    if (std.mem.indexOf(u8, message, "busy") != null or
        std.mem.indexOf(u8, message, "locked") != null)
    {
        return fail(.db_busy, "{s}", .{std.mem.trimEnd(u8, message, "\n")});
    }
    if (std.mem.indexOf(u8, message, "readonly") != null or
        std.mem.indexOf(u8, message, "unable to open") != null or
        std.mem.indexOf(u8, message, "permission denied") != null)
    {
        return fail(.io_error, "{s}", .{std.mem.trimEnd(u8, message, "\n")});
    }
    return fail(if (while_open) .db_incompatible else .io_error, "{s}", .{std.mem.trimEnd(u8, message, "\n")});
}

test "fail keeps family and detail" {
    _ = invalid("bad {s}: {d}", .{ "value", 3 }) catch {};
    try std.testing.expectEqual(Family.invalid_input, getFamily());
    try std.testing.expectEqualStrings("bad value: 3", detail());
}
