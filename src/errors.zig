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
    detail_len = utf8Prefix(w.buffered(), w.buffered().len).len;
    return error.Ztd;
}

/// The longest prefix of `s` of at most `max` bytes that ends on a UTF-8
/// character boundary. A complete character at the cut is kept whole; an
/// incomplete sequence at the end of the input is dropped.
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    var n = @min(s.len, max);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    if (n < s.len) return s[0..n];
    var i = n;
    while (i > 0 and (s[i - 1] & 0xC0) == 0x80) i -= 1;
    if (i == 0) return s[0..0];
    const lead = s[i - 1];
    const need: usize = if (lead < 0x80) 1 else if (lead & 0xF8 == 0xF0) 4 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xE0 == 0xC0) 2 else 1;
    if (i - 1 + need > s.len) return s[0 .. i - 1];
    return s;
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

test "utf8Prefix keeps a complete character and drops an incomplete one" {
    try std.testing.expectEqualStrings("café", utf8Prefix("café", 5));
    try std.testing.expectEqualStrings("caf", utf8Prefix("café", 4));
    try std.testing.expectEqualStrings("ab", utf8Prefix("ab\xC3", 10)); // truncated read
    try std.testing.expectEqualStrings("", utf8Prefix("é", 1));
    try std.testing.expectEqualStrings("abc", utf8Prefix("abc", 10));
}
