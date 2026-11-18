const std = @import("std");

/// Accent/muted/rule tones for one theme, as 256-color indices: the `_dark`
/// value is used on a dark background, `_light` on a light one.
pub const Theme = struct {
    key: []const u8, // "paper" | "tea" | "amber"
    name: []const u8, // "papel" | "té" | "ámbar"
    accent_dark: u8,
    accent_light: u8,
    muted_dark: u8,
    muted_light: u8,
    rule_dark: u8,
    rule_light: u8,
};

pub const all = [_]Theme{
    .{
        .key = "paper",
        .name = "papel",
        .accent_dark = 110,
        .accent_light = 61,
        .muted_dark = 245,
        .muted_light = 243,
        .rule_dark = 238,
        .rule_light = 250,
    },
    .{
        .key = "tea",
        .name = "té",
        .accent_dark = 108,
        .accent_light = 65,
        .muted_dark = 245,
        .muted_light = 243,
        .rule_dark = 238,
        .rule_light = 250,
    },
    .{
        .key = "amber",
        .name = "ámbar",
        .accent_dark = 179,
        .accent_light = 137,
        .muted_dark = 245,
        .muted_light = 243,
        .rule_dark = 238,
        .rule_light = 250,
    },
};

/// The configured theme; null or an unknown key falls back to paper.
pub fn byKey(key: ?[]const u8) Theme {
    const k = key orelse return all[0];
    for (all) |t| {
        if (std.mem.eql(u8, t.key, k)) return t;
    }
    return all[0];
}

/// The following theme in the cycle paper → tea → amber → paper.
pub fn next(t: Theme) Theme {
    for (all, 0..) |c, i| {
        if (std.mem.eql(u8, c.key, t.key)) return all[(i + 1) % all.len];
    }
    return all[0];
}

test "byKey resolves a known key" {
    const tea = byKey("tea");
    try std.testing.expectEqualStrings("tea", tea.key);
    try std.testing.expectEqual(@as(u8, 108), tea.accent_dark);
    try std.testing.expectEqual(@as(u8, 65), tea.accent_light);
}

test "byKey falls back to paper for unknown and null keys" {
    try std.testing.expectEqualStrings("paper", byKey("nope").key);
    try std.testing.expectEqualStrings("paper", byKey(null).key);
}

test "next cycles paper to tea to amber to paper" {
    try std.testing.expectEqualStrings("tea", next(byKey("paper")).key);
    try std.testing.expectEqualStrings("amber", next(byKey("tea")).key);
    try std.testing.expectEqualStrings("paper", next(byKey("amber")).key);
}
