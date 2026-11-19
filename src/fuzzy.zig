//! Fuzzy match: case-insensitive subsequence with simple, deterministic
//! scoring and no dependencies.

const std = @import("std");

pub const Match = struct {
    score: i32,
    start: usize, // byte index of the first matched byte
    end: usize, // byte index just past the last one
};

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

fn isSep(c: u8) bool {
    return switch (c) {
        ' ', '-', '_', '/', '.' => true,
        else => false,
    };
}

/// The match occupies a whole word: it starts at a boundary (start of
/// the text or after a separator) and ends at one (end of the text or
/// before a separator).
fn atWordBounds(haystack: []const u8, start: usize, end: usize) bool {
    const starts = start == 0 or isSep(haystack[start - 1]);
    const ends = end == haystack.len or isSep(haystack[end]);
    return starts and ends;
}

/// Case-insensitive subsequence match of `needle` in `haystack`. Returns
/// null when `needle` is not a subsequence; the empty needle matches
/// with score 0. Scoring: +3 per contiguous run, +2 when the match
/// occupies a whole word (boundary on both sides: start or after ' ',
/// '-', '_', '/', '.'; end of the text or before those same
/// separators), +1 per byte, minus the distance between matched bytes.
pub fn match(haystack: []const u8, needle: []const u8) ?Match {
    if (needle.len == 0) return .{ .score = 0, .start = 0, .end = 0 };
    if (needle.len > haystack.len) return null;

    var score: i64 = 0;
    var cursor: usize = 0;
    var prev: usize = 0;
    var start: usize = 0;
    for (needle, 0..) |nc, i| {
        const target = lower(nc);
        var hi = cursor;
        while (hi < haystack.len and lower(haystack[hi]) != target) : (hi += 1) {}
        if (hi == haystack.len) return null;
        if (i == 0) {
            start = hi;
            score += 3; // first run
        } else {
            if (hi != prev + 1) score += 3; // new run
            score -= @as(i64, @intCast(hi - prev - 1)); // distance between matched bytes
        }
        score += 1;
        prev = hi;
        cursor = hi + 1;
    }
    if (atWordBounds(haystack, start, prev + 1)) score += 2;
    // i64 accumulator so the score cannot overflow i32.
    const capped: i64 = std.math.clamp(score, std.math.minInt(i32), std.math.maxInt(i32));
    return .{ .score = @intCast(capped), .start = start, .end = prev + 1 };
}

test "empty needle matches with score zero" {
    const m = match("cualquier cosa", "").?;
    try std.testing.expectEqual(@as(i32, 0), m.score);
    try std.testing.expectEqual(@as(usize, 0), m.start);
    try std.testing.expectEqual(@as(usize, 0), m.end);
}

test "exact prefix scores higher than scattered" {
    const exact = match("abcdef", "abc").?;
    const scattered = match("axxxxbxxxxcxx", "abc").?;
    try std.testing.expect(exact.score > scattered.score);
    try std.testing.expectEqual(@as(i32, 6), exact.score);
    try std.testing.expectEqual(@as(i32, 4), scattered.score);
}

test "non-match returns null" {
    try std.testing.expect(match("abc", "abcd") == null);
    try std.testing.expect(match("abc", "xyz") == null);
    try std.testing.expect(match("", "a") == null);
}

test "ASCII case-insensitivity" {
    const m = match("HOLA Mundo", "hola mundo").?;
    try std.testing.expectEqual(@as(usize, 0), m.start);
    try std.testing.expectEqual(@as(usize, 10), m.end);
    try std.testing.expect(match("Informe Diario", "INFORME") != null);
    try std.testing.expect(match("informe", "INFORME") != null);
}

test "word-boundary bonus" {
    // "plan" occupies the whole word in "plan diario" and gets +2; in
    // "plantilla" it is only the prefix of a longer word with no end
    // boundary, and in "xplantilla" it does not even start at a boundary.
    const word = match("plan diario", "plan").?;
    const inside = match("plantilla", "plan").?;
    const mid = match("xplantilla", "plan").?;
    try std.testing.expect(word.score > inside.score);
    try std.testing.expect(word.score > mid.score);
    try std.testing.expectEqual(@as(i32, 9), word.score);
    try std.testing.expectEqual(@as(i32, 7), inside.score);
    try std.testing.expectEqual(@as(i32, 7), mid.score);
    // The whole word after a separator also earns the bonus.
    const sep_word = match("hola mundo", "mundo").?;
    const embedded = match("mundoFeliz", "mundo").?;
    try std.testing.expect(sep_word.score > embedded.score);
    try std.testing.expectEqual(@as(i32, 10), sep_word.score);
    try std.testing.expectEqual(@as(i32, 8), embedded.score);
}

test "byte offsets are byte indices" {
    // ñ occupies two bytes: the end lands on 7, not on the 6 you get counting chars.
    const m = match("mañana", "ana").?;
    try std.testing.expectEqual(@as(usize, 1), m.start);
    try std.testing.expectEqual(@as(usize, 7), m.end);
    try std.testing.expectEqual(@as(i32, 6), m.score);

    const span = match("plan diario", "di").?;
    try std.testing.expectEqual(@as(usize, 5), span.start);
    try std.testing.expectEqual(@as(usize, 7), span.end);
    try std.testing.expectEqual(@as(i32, 5), span.score);
}
