//! Minimal streaming JSON writer plus readers for `std.json.Value`.
//!
//! Zig has reflection, but no struct tags to mirror Go's `json:"name"`, so the
//! CLI emits objects field by field. Field order follows the Go structs: the
//! corpus compares normalized bytes, and a reader of the CLI sees the same shape.

const std = @import("std");
const Io = std.Io;

/// Escapes a string exactly like Go's encoding/json with the default
/// HTML escaping: control chars, quote, backslash, `<`, `>`, `&` and the
/// U+2028/U+2029 separators. Invalid UTF-8 becomes U+FFFD. Byte parity here
/// also keeps request hashes identical to the Go binary's.
pub fn writeString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x20) {
            switch (b) {
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.print("\\u00{x:0>2}", .{@as(u32, b)}),
            }
            i += 1;
            continue;
        }
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '<' => try w.writeAll("\\u003c"),
            '>' => try w.writeAll("\\u003e"),
            '&' => try w.writeAll("\\u0026"),
            else => {},
        }
        if (b == '"' or b == '\\' or b == '<' or b == '>' or b == '&') {
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            try w.writeAll("\\ufffd");
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            try w.writeAll("\\ufffd");
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            try w.writeAll("\\ufffd");
            i += 1;
            continue;
        };
        if (cp == 0x2028) {
            try w.writeAll("\\u2028");
        } else if (cp == 0x2029) {
            try w.writeAll("\\u2029");
        } else {
            try w.writeAll(s[i .. i + n]);
        }
        i += n;
    }
    try w.writeByte('"');
}

pub const Obj = struct {
    w: *Io.Writer,
    first: bool = true,

    pub fn init(w: *Io.Writer) !Obj {
        try w.writeByte('{');
        return .{ .w = w };
    }

    fn sep(self: *Obj) !void {
        if (!self.first) try self.w.writeByte(',');
        self.first = false;
    }

    pub fn key(self: *Obj, name: []const u8) !void {
        try self.sep();
        try writeString(self.w, name);
        try self.w.writeByte(':');
    }

    pub fn str(self: *Obj, name: []const u8, value: []const u8) !void {
        try self.key(name);
        try writeString(self.w, value);
    }

    /// Emits the field only when the value is present, like `omitempty`.
    pub fn optStr(self: *Obj, name: []const u8, value: ?[]const u8) !void {
        if (value) |v| try self.str(name, v);
    }

    pub fn int(self: *Obj, name: []const u8, value: i64) !void {
        try self.key(name);
        try self.w.print("{d}", .{value});
    }

    pub fn boolean(self: *Obj, name: []const u8, value: bool) !void {
        try self.key(name);
        try self.w.writeAll(if (value) "true" else "false");
    }

    /// Emits already-serialized JSON, for nested objects and arrays.
    pub fn raw(self: *Obj, name: []const u8, value: []const u8) !void {
        try self.key(name);
        try self.w.writeAll(value);
    }

    pub fn obj(self: *Obj, name: []const u8) !Obj {
        try self.key(name);
        return Obj.init(self.w);
    }

    pub fn arr(self: *Obj, name: []const u8) !Arr {
        try self.key(name);
        return Arr.init(self.w);
    }

    pub fn end(self: *Obj) !void {
        try self.w.writeByte('}');
    }
};

pub const Arr = struct {
    w: *Io.Writer,
    first: bool = true,

    pub fn init(w: *Io.Writer) !Arr {
        try w.writeByte('[');
        return .{ .w = w };
    }

    fn sep(self: *Arr) !void {
        if (!self.first) try self.w.writeByte(',');
        self.first = false;
    }

    pub fn str(self: *Arr, value: []const u8) !void {
        try self.sep();
        try writeString(self.w, value);
    }

    pub fn raw(self: *Arr, value: []const u8) !void {
        try self.sep();
        try self.w.writeAll(value);
    }

    pub fn obj(self: *Arr) !Obj {
        try self.sep();
        return Obj.init(self.w);
    }

    pub fn end(self: *Arr) !void {
        try self.w.writeByte(']');
    }
};

pub fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(name),
        else => null,
    };
}

pub fn strField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = field(v, name) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

pub fn intField(v: std.json.Value, name: []const u8) ?i64 {
    const f = field(v, name) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

pub fn boolField(v: std.json.Value, name: []const u8) ?bool {
    const f = field(v, name) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

pub fn arrField(v: std.json.Value, name: []const u8) ?[]std.json.Value {
    const f = field(v, name) orelse return null;
    return switch (f) {
        .array => |a| a.items,
        else => null,
    };
}

test "object writer keeps field order and escapes strings" {
    var bw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bw.deinit();
    var o = try Obj.init(&bw.writer);
    try o.str("id", "C-1");
    try o.optStr("missing", null);
    try o.int("n", 2);
    try o.boolean("ok", true);
    var inner = try o.obj("nested");
    try inner.str("text", "a\"b");
    try inner.end();
    try o.end();
    try std.testing.expectEqualStrings(
        "{\"id\":\"C-1\",\"n\":2,\"ok\":true,\"nested\":{\"text\":\"a\\\"b\"}}",
        bw.written(),
    );
}

test "readers walk objects and arrays" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"id":"x","n":3,"list":[{"k":"a"}]}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("x", strField(parsed.value, "id").?);
    try std.testing.expectEqual(@as(i64, 3), intField(parsed.value, "n").?);
    const list = arrField(parsed.value, "list").?;
    try std.testing.expectEqualStrings("a", strField(list[0], "k").?);
}
