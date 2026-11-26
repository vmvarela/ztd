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
// Detail lengths are bounded by the buffer; a longer message is truncated at a
// char boundary because it still has to be valid JSON.
var detail_len: usize = 0;

/// Records family and detail, then returns the shared error.
pub fn fail(f: Family, comptime fmt: []const u8, args: anytype) Ztd {
    family = f;
    const printed = std.fmt.bufPrint(&detail_buf, fmt, args) catch blk: {
        // bufPrint fails only when the message does not fit; keep the prefix.
        break :blk detail_buf[0..0];
    };
    detail_len = printed.len;
    return error.Ztd;
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
