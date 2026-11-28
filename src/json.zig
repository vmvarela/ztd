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

/// Writes a float64 the way encoding/json does, so bm25 ranks compare equal
/// to the Go binary's bytes.
pub fn writeFloat(w: *Io.Writer, v: f64) !void {
    const abs: f64 = @abs(v);
    if (abs != 0 and (abs < 1e-6 or abs >= 1e21)) {
        var buf: [512]u8 = undefined;
        const dec = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return w.print("{d}", .{v});
        return writeExponential(w, dec);
    }
    return w.print("{d}", .{v});
}

/// Re-renders a shortest decimal such as "-0.0000015" or "1000000000000000000000"
/// as Go's exponential form: mantissa digits, then e, the sign and the
/// unpadded exponent.
fn writeExponential(w: *Io.Writer, dec: []const u8) !void {
    var body = dec;
    if (body.len > 0 and body[0] == '-') {
        try w.writeByte('-');
        body = body[1..];
    }
    const dot = std.mem.indexOfScalar(u8, body, '.');
    const ip = if (dot) |d| body[0..d] else body;
    const fp = if (dot) |d| body[d + 1 ..] else body[0..0];

    var digits_buf: [512]u8 = undefined;
    if (ip.len + fp.len > digits_buf.len) return w.writeAll(dec);
    @memcpy(digits_buf[0..ip.len], ip);
    @memcpy(digits_buf[ip.len .. ip.len + fp.len], fp);
    var digits = digits_buf[0 .. ip.len + fp.len];
    var start: usize = 0;
    while (start < digits.len and digits[start] == '0') start += 1;
    if (start == digits.len) return w.writeAll(if (dec[0] == '-') "-0" else "0");
    digits = digits[start..];
    // The exponent is the decimal point's offset from the first digit, which
    // trailing zeros cancel out: compute it before stripping them.
    const exp: i64 = @as(i64, @intCast(digits.len)) - @as(i64, @intCast(fp.len)) - 1;
    var end = digits.len;
    while (end > 1 and digits[end - 1] == '0') end -= 1;
    const mant = digits[0..end];

    try w.writeByte(mant[0]);
    if (mant.len > 1) {
        try w.writeByte('.');
        try w.writeAll(mant[1..]);
    }
    try w.writeByte('e');
    try w.writeByte(if (exp < 0) '-' else '+');
    var e: u64 = @intCast(if (exp < 0) -exp else exp);
    var ebuf: [4]u8 = undefined;
    var n = ebuf.len;
    while (true) {
        n -= 1;
        ebuf[n] = @intCast('0' + @as(u8, @intCast(e % 10)));
        e /= 10;
        if (e == 0) break;
    }
    try w.writeAll(ebuf[n..]);
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

    /// Emits a float64 exactly like Go's encoding/json: the shortest
    /// round-trip decimal, switching to exponential form when |v| < 1e-6 or
    /// |v| >= 1e21, with the exponent unpadded (Go rewrites e-09 to e-9).
    pub fn float(self: *Obj, name: []const u8, value: f64) !void {
        try self.key(name);
        try writeFloat(self.w, value);
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

/// Emits a parsed JSON value with object keys sorted, matching Go's map
/// marshaling of decoded documents.
pub fn writeValue(a: std.mem.Allocator, w: *Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f),
        .number_string => |n| try w.writeAll(n),
        .string => |sv| try writeString(w, sv),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(a, w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            const keys = try a.dupe([]const u8, obj.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.less);
            try w.writeByte('{');
            for (keys, 0..) |key, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(w, key);
                try w.writeByte(':');
                try writeValue(a, w, obj.get(key).?);
            }
            try w.writeByte('}');
        },
    }
}

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
        // A hostile 1e300 must not take the server down: clamp instead.
        .float => |x| std.math.lossyCast(i64, x),
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

test "floats use Go's decimal or exponential form" {
    var bw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bw.deinit();
    var o = try Obj.init(&bw.writer);
    try o.float("rank", -0.000001);
    try o.float("tiny", -1.5e-7);
    try o.float("big", 1e21);
    try o.float("plain", 12.5);
    try o.float("zero", 0);
    try o.end();
    try std.testing.expectEqualStrings(
        "{\"rank\":-0.000001,\"tiny\":-1.5e-7,\"big\":1e+21,\"plain\":12.5,\"zero\":0}",
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
