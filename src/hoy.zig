const std = @import("std");
const Store = @import("store.zig").Store;
const platform = @import("platform.zig");

/// A single day's MIT: one line of inline-markdown-stripped text and the
/// task id embedded in it, when present. Both strings live in the allocator
/// that built the owning `Day`.
pub const Mit = struct {
    text: []const u8,
    task_id: ?[]const u8,
};

/// The rendered "today" view: label, active goal and the daily plan with its
/// MITs. Every string lives in the allocator passed to `load`; `goal_path`
/// points at the canonical `goals/active.md` location of `goal`.
pub const Day = struct {
    label: []const u8,
    goal: ?[]const u8,
    goal_path: []const u8,
    plan_path: ?[]const u8,
    mits: []Mit,
};

/// Reads the pieces of "today" from the store. Absent goal or plan files are
/// not errors: the corresponding field stays null (or empty for `mits`).
pub fn load(io: std.Io, a: std.mem.Allocator, store: *Store, today: platform.Date) !Day {
    _ = io;
    const label = try dateLabel(a, today);
    errdefer a.free(label);
    const goal_path = try a.dupe(u8, "goals/active.md");
    errdefer a.free(goal_path);

    var goal: ?[]const u8 = null;
    errdefer if (goal) |g| a.free(g);
    if (try store.readOptional(goal_path)) |text| {
        defer store.alloc.free(text); // store.read allocates with store.alloc
        goal = parseGoal(a, text);
    }

    var date_buf: [10]u8 = undefined;
    var path_buf: [32]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "plans/daily/{s}.md", .{today.format(&date_buf)}) catch unreachable;
    var plan_path: ?[]const u8 = null;
    errdefer if (plan_path) |p| a.free(p);
    var mits: []Mit = &.{};
    if (try store.readOptional(rel)) |text| {
        defer store.alloc.free(text);
        plan_path = try a.dupe(u8, rel);
        // parseMits either succeeds with nothing fallible after it or fails
        // with `mits` still empty, so no errdefer is needed here.
        mits = try parseMits(a, text);
    }

    return .{ .label = label, .goal = goal, .goal_path = goal_path, .plan_path = plan_path, .mits = mits };
}

/// `"miércoles 18 de noviembre"`: Spanish weekday (0 = Monday) and month names.
pub fn dateLabel(a: std.mem.Allocator, today: platform.Date) ![]const u8 {
    const weekdays = [_][]const u8{ "lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo" };
    const months = [_][]const u8{ "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre" };
    return std.fmt.allocPrint(a, "{s} {d} de {s}", .{ weekdays[today.weekday()], today.day, months[today.month - 1] });
}

/// The first `- Resultado deseado:` line's text, stripped, or null when the
/// goal file carries no such line (or the allocator fails).
pub fn parseGoal(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const marker = "- Resultado deseado:";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, marker)) continue;
        const rest = std.mem.trim(u8, trimmed[marker.len..], " \t");
        if (rest.len == 0) return null;
        return stripInline(a, rest) catch return null;
    }
    return null;
}

/// The `## MITs` section of a daily plan: numbered entries only, one line per
/// entry (wrapped continuation lines are dropped), markdown stripped.
pub fn parseMits(a: std.mem.Allocator, text: []const u8) ![]Mit {
    var out: std.ArrayList(Mit) = .empty;
    errdefer {
        for (out.items) |m| {
            a.free(m.text);
            if (m.task_id) |id| a.free(id);
        }
        out.deinit(a);
    }

    var in_section = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!in_section) {
            if (std.mem.startsWith(u8, trimmed, "## MITs")) in_section = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "## ")) break;

        const body = entryBody(trimmed) orelse continue;
        const stripped = try stripInline(a, body);
        defer a.free(stripped);
        const view = dropTrailingColon(std.mem.trim(u8, stripped, " \t\r"));

        var mit: Mit = .{ .text = try a.dupe(u8, view), .task_id = null };
        errdefer a.free(mit.text);
        mit.task_id = try taskId(a, view);
        errdefer if (mit.task_id) |id| a.free(id);
        try out.append(a, mit);
    }
    return out.toOwnedSlice(a);
}

/// Removes `**`, `__` and backticks, and rewrites `[label](url)` to `label`.
/// Everything else passes through untouched. Always allocates: callers free
/// the result with the same allocator, so input slices are never returned.
pub fn stripInline(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        // `[label](url)` → `label`; a bracket that never closes passes through.
        if (text[i] == '[') blk: {
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse break :blk;
            if (close + 1 >= text.len or text[close + 1] != '(') break :blk;
            const end = std.mem.indexOfScalarPos(u8, text, close + 2, ')') orelse break :blk;
            try out.appendSlice(a, text[i + 1 .. close]);
            i = end + 1;
            continue;
        }
        if ((text[i] == '*' or text[i] == '_') and i + 1 < text.len and text[i + 1] == text[i]) {
            i += 2;
            continue;
        }
        if (text[i] == '`') {
            i += 1;
            continue;
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// The line without its number marker (`1. `), trimmed. Null for continuation
/// lines and for decimals like `3.5 h`.
fn entryBody(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == 0 or i >= line.len or line[i] != '.') return null;
    // A space (or the bold markers) after the dot keeps decimals like "3.5 h"
    // out of the entry match.
    if (i + 1 < line.len and line[i + 1] != ' ' and line[i + 1] != '\t' and line[i + 1] != '*') return null;
    return std.mem.trim(u8, line[i + 1 ..], " \t");
}

fn dropTrailingColon(s: []const u8) []const u8 {
    if (s.len == 0 or s[s.len - 1] != ':') return s;
    return std.mem.trim(u8, s[0 .. s.len - 1], " \t");
}

/// The first `T-` + 8 digits + `-` + 3 digits id in `s`, allocated, or null.
fn taskId(a: std.mem.Allocator, s: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i + 14 <= s.len) : (i += 1) {
        if (s[i] != 'T' or s[i + 1] != '-') continue;
        if (!isDigits(s[i + 2 .. i + 10]) or s[i + 10] != '-' or !isDigits(s[i + 11 .. i + 14])) continue;
        // Reject a longer run: `T-20261030-0034` is not a valid id.
        if (i + 14 < s.len and isDigit(s[i + 14])) continue;
        return try a.dupe(u8, s[i .. i + 14]);
    }
    return null;
}

fn isDigits(s: []const u8) bool {
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Test-only: every string in a `Day` was allocated with `a`.
fn freeDay(a: std.mem.Allocator, day: Day) void {
    a.free(day.label);
    if (day.goal) |g| a.free(g);
    a.free(day.goal_path);
    if (day.plan_path) |p| a.free(p);
    for (day.mits) |m| {
        a.free(m.text);
        if (m.task_id) |id| a.free(id);
    }
    a.free(day.mits);
}

test "load fills the day from the store and never fails on absence" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);

    // Raw reads free with the store's allocator while `load` returns memory
    // from `a`; an arena-backed store makes a wrong-allocator free panic.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var store = try Store.open(io, arena.allocator(), path_buf[0..n]);
    defer store.deinit();

    const today = try platform.parseDate("2026-11-18");

    const absent = try load(io, a, &store, today);
    defer freeDay(a, absent);
    try std.testing.expectEqualStrings("miércoles 18 de noviembre", absent.label);
    try std.testing.expectEqual(@as(?[]const u8, null), absent.goal);
    try std.testing.expectEqualStrings("goals/active.md", absent.goal_path);
    try std.testing.expectEqual(@as(?[]const u8, null), absent.plan_path);
    try std.testing.expectEqual(@as(usize, 0), absent.mits.len);

    try store.dir.createDirPath(io, "goals");
    try store.dir.createDirPath(io, "plans/daily");
    try store.writeAtomic("goals/active.md",
        \\# Meta activa
        \\
        \\- Resultado deseado: calmar el estrés con una rutina cotidiana sencilla.
    );
    try store.writeAtomic("plans/daily/2026-11-18.md",
        \\# Día 2026-11-18
        \\
        \\## MITs (1–3 en total)
        \\
        \\1. **Trabajo — T-20261118-001:** revisar el PR.
    );

    const day = try load(io, a, &store, today);
    defer freeDay(a, day);
    try std.testing.expectEqualStrings("miércoles 18 de noviembre", day.label);
    try std.testing.expectEqualStrings("calmar el estrés con una rutina cotidiana sencilla.", day.goal.?);
    try std.testing.expectEqualStrings("goals/active.md", day.goal_path);
    try std.testing.expectEqualStrings("plans/daily/2026-11-18.md", day.plan_path.?);
    try std.testing.expectEqual(@as(usize, 1), day.mits.len);
    try std.testing.expectEqualStrings("Trabajo — T-20261118-001: revisar el PR.", day.mits[0].text);
    try std.testing.expectEqualStrings("T-20261118-001", day.mits[0].task_id.?);
}

test "parseMits reads the numbered entries of the MITs section" {
    const a = std.testing.allocator;
    const plan =
        \\# Día 2026-11-18
        \\
        \\## MITs (1–3 en total)
        \\
        \\1. **Trabajo — T-20261030-003 (DEVOPS-995): completado.** El PR 2760 se mergeó a las
        \\   07:07 (commit `ed0a1c8`) con CI en verde, y la tarea quedó cerrada.
        \\2. **Salud — T-20261118-002:**
        \\
        \\## Tareas pequeñas agrupadas
        \\
        \\- no es un MIT
    ;
    const mits = try parseMits(a, plan);
    defer {
        for (mits) |m| {
            a.free(m.text);
            if (m.task_id) |id| a.free(id);
        }
        a.free(mits);
    }
    try std.testing.expectEqual(@as(usize, 2), mits.len);
    try std.testing.expectEqualStrings(
        "Trabajo — T-20261030-003 (DEVOPS-995): completado. El PR 2760 se mergeó a las",
        mits[0].text,
    );
    try std.testing.expectEqualStrings("T-20261030-003", mits[0].task_id.?);
    try std.testing.expectEqualStrings("Salud — T-20261118-002", mits[1].text);
    try std.testing.expectEqualStrings("T-20261118-002", mits[1].task_id.?);
}

test "parseMits without a MITs heading is empty" {
    const a = std.testing.allocator;
    const mits = try parseMits(a, "# Día\n\n## Agenda\n\n1. suelto\n");
    defer a.free(mits);
    try std.testing.expectEqual(@as(usize, 0), mits.len);
}

test "parseGoal reads the Resultado deseado line" {
    const a = std.testing.allocator;
    const goal_file =
        \\# Meta activa
        \\
        \\- Resultado deseado: calmar el estrés con una rutina cotidiana sencilla y sostenible.
        \\- Por qué importa: cuidar la salud física y mental.
    ;
    const goal = parseGoal(a, goal_file).?;
    defer a.free(goal);
    try std.testing.expectEqualStrings("calmar el estrés con una rutina cotidiana sencilla y sostenible.", goal);

    try std.testing.expectEqual(@as(?[]const u8, null), parseGoal(a, "# Meta activa\n\nsin resultado.\n"));
}

test "stripInline removes markers and rewrites links" {
    const a = std.testing.allocator;
    const got = try stripInline(a, "**hola** con `código` y [enlace](https://example.com/x)");
    defer a.free(got);
    try std.testing.expectEqualStrings("hola con código y enlace", got);
}

test "dateLabel renders the Spanish weekday and month" {
    const a = std.testing.allocator;
    const label = try dateLabel(a, try platform.parseDate("2026-11-18"));
    defer a.free(label);
    try std.testing.expectEqualStrings("miércoles 18 de noviembre", label);
}
