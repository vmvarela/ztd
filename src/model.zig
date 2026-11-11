const std = @import("std");

pub const Status = enum {
    open,
    done,

    pub fn mark(self: Status) []const u8 {
        return switch (self) {
            .open => " ",
            .done => "x",
        };
    }
};

pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

pub const Task = struct {
    status: Status,
    id: []const u8,
    title: []const u8,
    fields: std.ArrayList(Field) = .empty,
    list: []const u8 = "",

    pub fn get(self: *const Task, key: []const u8) ?[]const u8 {
        for (self.fields.items) |f| {
            if (std.mem.eql(u8, f.key, key)) return f.value;
        }
        return null;
    }

    pub fn has(self: *const Task, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn set(self: *Task, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.key, key)) {
                f.value = try alloc.dupe(u8, value);
                return;
            }
        }
        try self.fields.append(alloc, .{
            .key = try alloc.dupe(u8, key),
            .value = try alloc.dupe(u8, value),
        });
    }

    pub fn unset(self: *Task, key: []const u8) bool {
        var i: usize = 0;
        while (i < self.fields.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.fields.items[i].key, key)) {
                _ = self.fields.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn render(self: *const Task, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "- [");
        try out.append(alloc, self.status.mark()[0]);
        try out.appendSlice(alloc, "] ");
        try out.appendSlice(alloc, self.id);
        try out.appendSlice(alloc, " | ");
        try appendEscaped(&out, alloc, self.title);
        for (self.fields.items) |f| {
            try out.appendSlice(alloc, " | ");
            try appendEscaped(&out, alloc, f.key);
            try out.appendSlice(alloc, ": ");
            try appendEscaped(&out, alloc, f.value);
        }
        return out.toOwnedSlice(alloc);
    }
};

pub const ParseError = error{
    MalformedTask,
    InvalidId,
    OutOfMemory,
};

pub fn validId(id: []const u8) bool {
    if (id.len < 14) return false;
    if (!std.mem.startsWith(u8, id, "T-")) return false;
    if (id[10] != '-') return false;
    for (id[2..10]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    if (id.len == 11) return false;
    for (id[11..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isEscaped(s: []const u8, i: usize) bool {
    var n: usize = 0;
    var j = i;
    while (j > 0 and s[j - 1] == '\\') : (j -= 1) n += 1;
    return n % 2 == 1;
}

fn findSeparator(s: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 <= s.len) : (i += 1) {
        if (s[i] == ' ' and s[i + 1] == '|' and s[i + 2] == ' ' and !isEscaped(s, i + 1)) {
            return i;
        }
    }
    return null;
}

fn appendUnescaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '|') {
            try out.append(alloc, '|');
            i += 1;
        } else {
            try out.append(alloc, s[i]);
        }
    }
}

fn appendEscaped(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        if (c == '|') {
            try out.appendSlice(alloc, "\\|");
        } else {
            try out.append(alloc, c);
        }
    }
}

pub fn parseLine(alloc: std.mem.Allocator, line_in: []const u8) ParseError!?Task {
    const line = std.mem.trimEnd(u8, line_in, "\r\n");
    if (line.len == 0) return null;
    if (!std.mem.startsWith(u8, line, "- [")) return null;
    if (line.len < 7 or line[4] != ']' or line[5] != ' ') return error.MalformedTask;
    const status: Status = switch (line[3]) {
        ' ' => .open,
        'x', 'X' => .done,
        else => return error.MalformedTask,
    };
    const rest = line[6..];
    const sep = findSeparator(rest) orelse return error.MalformedTask;
    const id = std.mem.trim(u8, rest[0..sep], " ");
    if (!validId(id)) return error.InvalidId;

    var title: std.ArrayList(u8) = .empty;
    errdefer title.deinit(alloc);
    var fields: std.ArrayList(Field) = .empty;
    errdefer {
        for (fields.items) |f| {
            alloc.free(f.key);
            alloc.free(f.value);
        }
        fields.deinit(alloc);
    }

    const body = rest[sep + 3 ..];
    var cursor: usize = 0;
    var first = true;
    while (true) {
        const rel = findSeparator(body[cursor..]);
        const end = if (rel) |r| cursor + r else body.len;
        const segment = body[cursor..end];
        if (first) {
            try appendUnescaped(&title, alloc, segment);
            first = false;
        } else if (std.mem.indexOf(u8, segment, ": ")) |c| {
            const key = segment[0..c];
            const value = segment[c + 2 ..];
            if (key.len == 0) {
                try title.appendSlice(alloc, " | ");
                try appendUnescaped(&title, alloc, segment);
            } else {
                var kb: std.ArrayList(u8) = .empty;
                defer kb.deinit(alloc);
                try appendUnescaped(&kb, alloc, key);
                var vb: std.ArrayList(u8) = .empty;
                defer vb.deinit(alloc);
                try appendUnescaped(&vb, alloc, value);
                for (fields.items) |existing| {
                    if (std.mem.eql(u8, existing.key, kb.items)) return error.MalformedTask;
                }
                try fields.append(alloc, .{
                    .key = try kb.toOwnedSlice(alloc),
                    .value = try vb.toOwnedSlice(alloc),
                });
            }
        } else {
            try title.appendSlice(alloc, " | ");
            try appendUnescaped(&title, alloc, segment);
        }
        if (rel == null) break;
        cursor = end + 3;
    }

    return .{
        .status = status,
        .id = try alloc.dupe(u8, id),
        .title = try title.toOwnedSlice(alloc),
        .fields = fields,
    };
}

pub fn parseIdDate(id: []const u8) ?struct { year: u16, month: u8, day: u8 } {
    if (!validId(id)) return null;
    const y = std.fmt.parseInt(u16, id[2..6], 10) catch return null;
    const m = std.fmt.parseInt(u8, id[6..8], 10) catch return null;
    const d = std.fmt.parseInt(u8, id[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return .{ .year = y, .month = m, .day = d };
}

test "round trip" {
    const alloc = std.testing.allocator;
    const line = "- [ ] T-20261111-001 | Título con \\| pipe | contexto: trabajo | cliente: acme | capturada: 2026-11-11";
    var task = (try parseLine(alloc, line)).?;
    defer {
        alloc.free(task.id);
        alloc.free(task.title);
        for (task.fields.items) |f| {
            alloc.free(f.key);
            alloc.free(f.value);
        }
        task.fields.deinit(alloc);
    }
    try std.testing.expectEqualStrings("T-20261111-001", task.id);
    try std.testing.expectEqualStrings("Título con | pipe", task.title);
    try std.testing.expectEqualStrings("trabajo", task.get("contexto").?);
    const rendered = try task.render(alloc);
    defer alloc.free(rendered);
    var again = (try parseLine(alloc, rendered)).?;
    defer {
        alloc.free(again.id);
        alloc.free(again.title);
        for (again.fields.items) |f| {
            alloc.free(f.key);
            alloc.free(f.value);
        }
        again.fields.deinit(alloc);
    }
    try std.testing.expectEqualStrings(task.id, again.id);
    try std.testing.expectEqualStrings(task.title, again.title);
    try std.testing.expectEqual(task.fields.items.len, again.fields.items.len);
}

test "duplicate field is malformed" {
    const line = "- [ ] T-20261111-001 | Title | contexto: trabajo | contexto: personal";
    try std.testing.expectError(error.MalformedTask, parseLine(std.testing.allocator, line));
}
