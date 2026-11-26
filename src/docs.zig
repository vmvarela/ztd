//! Pure document helpers: link extraction, link resolution and lint rules.
//! Mirrors internal/app/document_links.go and document_lint.go.

const std = @import("std");
const jsonw = @import("json.zig");
const domain = @import("domain.zig");

pub const Link = struct { raw: []const u8, target: []const u8, by_title: bool };

fn isFence(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~");
}

/// Blanks fenced blocks and inline code spans, keeping line structure.
fn stripCode(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    const w = &aw.writer;
    var in_fence = false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (isFence(line)) {
            in_fence = !in_fence;
            try w.writeByte('\n');
            continue;
        }
        if (in_fence) {
            try w.writeByte('\n');
            continue;
        }
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '`') {
                if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |j| {
                    try w.writeByte(' ');
                    i = j + 1;
                    continue;
                }
            }
            try w.writeByte(line[i]);
            i += 1;
        }
        try w.writeByte('\n');
    }
    return aw.written();
}

/// Store-relative form of a Markdown or wikilink target.
pub fn normalizeTarget(t0: []const u8) []const u8 {
    var t = std.mem.trim(u8, t0, " \t\n\r\x0b\x0c");
    if (t.len > 0 and t[0] == '<') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '>') t = t[0 .. t.len - 1];
    if (std.mem.indexOfAny(u8, t, "#?")) |i| t = t[0..i];
    if (std.mem.startsWith(u8, t, "./")) t = t[2..];
    if (std.mem.startsWith(u8, t, "/")) t = t[1..];
    if (std.mem.endsWith(u8, t, ".md")) t = t[0 .. t.len - 3];
    if (std.mem.startsWith(u8, t, "../knowledge/")) {
        t = t["../knowledge/".len..];
    } else if (std.mem.startsWith(u8, t, "knowledge/")) {
        t = t["knowledge/".len..];
    }
    return std.mem.trim(u8, t, " \t\n\r\x0b\x0c");
}

fn hasScheme(raw: []const u8) bool {
    if (raw.len == 0 or !std.ascii.isAlphabetic(raw[0])) return false;
    for (raw[1..]) |ch| {
        if (ch == ':') return true;
        if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '.' or ch == '-')) return false;
    }
    return false;
}

fn append(list: *std.ArrayList(Link), a: std.mem.Allocator, l: Link) !void {
    try list.append(a, l);
}

/// Every wikilink first, then every Markdown link, in order of appearance.
pub fn documentLinks(a: std.mem.Allocator, body: []const u8) ![]const Link {
    const stripped = try stripCode(a, body);
    var out: std.ArrayList(Link) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, stripped, i, "[[")) |open| {
        const close = std.mem.indexOfPos(u8, stripped, open + 2, "]]") orelse break;
        const inner = stripped[open + 2 .. close];
        i = close + 2;
        const raw = if (std.mem.indexOfScalar(u8, inner, '|')) |p| inner[0..p] else inner;
        const target = normalizeTarget(raw);
        if (target.len == 0) continue;
        try append(&out, a, .{ .raw = raw, .target = target, .by_title = true });
    }
    i = 0;
    while (std.mem.indexOfPos(u8, stripped, i, "](")) |close_bracket| {
        const open_paren = close_bracket + 1;
        const close_paren = std.mem.indexOfScalarPos(u8, stripped, open_paren + 1, ')') orelse break;
        i = close_paren + 1;
        // Find the '[' that opens this label; a ']' or newline ends the search.
        var k = close_bracket;
        var open_bracket: ?usize = null;
        while (k > 0) {
            k -= 1;
            const ch = stripped[k];
            if (ch == '[') {
                open_bracket = k;
                break;
            }
            if (ch == ']' or ch == '\n') break;
        }
        const open = open_bracket orelse continue;
        if (open > 0 and stripped[open - 1] == '!') continue; // an image
        const inner = stripped[open_paren + 1 .. close_paren];
        const trimmed = std.mem.trim(u8, inner, " \t\n\r\x0b\x0c");
        if (trimmed.len == 0) continue;
        const space = std.mem.indexOfAny(u8, trimmed, " \t\n\r\x0b\x0c") orelse trimmed.len;
        const raw = trimmed[0..space];
        if (hasScheme(raw)) continue;
        const target = normalizeTarget(raw);
        if (target.len == 0) continue;
        try append(&out, a, .{ .raw = raw, .target = target, .by_title = false });
    }
    return out.items;
}

pub const ScopeLinks = struct {
    slugs: std.StringHashMap(void),
    titles: std.StringHashMap([]const u8),

    pub fn init(a: std.mem.Allocator, docs: []const domain.Document) !ScopeLinks {
        var counts = std.StringHashMap(usize).init(a);
        var l = ScopeLinks{
            .slugs = std.StringHashMap(void).init(a),
            .titles = std.StringHashMap([]const u8).init(a),
        };
        for (docs) |d| {
            try l.slugs.put(d.slug, {});
            const n = counts.get(d.title) orelse 0;
            try counts.put(d.title, n + 1);
        }
        for (docs) |d| {
            if (d.title.len > 0 and (counts.get(d.title) orelse 0) == 1) {
                try l.titles.put(d.title, d.slug);
            }
        }
        return l;
    }

    pub fn resolve(self: ScopeLinks, target: []const u8, by_title: bool) ?[]const u8 {
        if (self.slugs.contains(target)) return target;
        if (by_title) return self.titles.get(target);
        return null;
    }
};

pub const Relations = struct {
    source: domain.Document,
    outlinks: []const domain.Document,
    backlinks: []const domain.Document,
};

fn sameDocument(a: domain.Document, b: domain.Document) bool {
    return std.mem.eql(u8, a.scope, b.scope) and
        std.mem.eql(u8, a.kind, b.kind) and
        std.mem.eql(u8, a.slug, b.slug);
}

fn lessDoc(_: void, a: domain.Document, b: domain.Document) bool {
    const k = std.mem.order(u8, a.kind, b.kind);
    if (k != .eq) return k == .lt;
    return std.mem.order(u8, a.slug, b.slug) == .lt;
}

pub fn relatedDocuments(a: std.mem.Allocator, docs: []const domain.Document, source: domain.Document) !Relations {
    var in_scope: std.ArrayList(domain.Document) = .empty;
    for (docs) |d| {
        if (std.mem.eql(u8, d.scope, source.scope)) try in_scope.append(a, d);
    }
    std.mem.sort(domain.Document, in_scope.items, {}, lessDoc);
    const links = try ScopeLinks.init(a, in_scope.items);

    var targets = std.StringHashMap(void).init(a);
    for (try documentLinks(a, source.body)) |l| {
        if (links.resolve(l.target, l.by_title)) |slug| try targets.put(slug, {});
    }
    var outlinks: std.ArrayList(domain.Document) = .empty;
    var backlinks: std.ArrayList(domain.Document) = .empty;
    for (in_scope.items) |d| {
        if (targets.contains(d.slug)) try outlinks.append(a, d);
        if (sameDocument(d, source)) continue;
        for (try documentLinks(a, d.body)) |l| {
            const slug = links.resolve(l.target, l.by_title) orelse continue;
            if (std.mem.eql(u8, slug, source.slug)) {
                try backlinks.append(a, d);
                break;
            }
        }
    }
    return .{ .source = source, .outlinks = outlinks.items, .backlinks = backlinks.items };
}

// ------------------------------------------------------------------- lint

pub const lint_error = "error";
pub const lint_warning = "warning";
pub const lint_empty_title = "empty_title";
pub const lint_empty_body = "empty_body";
pub const lint_unresolved_wiki = "unresolved_wikilink";
pub const lint_unresolved_link = "unresolved_link";
pub const lint_orphan_knowledge = "orphan_knowledge";
pub const lint_missing_index = "missing_index";

pub const Finding = struct {
    scope: []const u8,
    kind: []const u8,
    slug: []const u8,
    severity: []const u8,
    code: []const u8,
    message: []const u8,
};

pub const Report = struct {
    errors: []const Finding,
    warnings: []const Finding,
    findings: []const Finding,
};

fn lessFinding(_: void, a: Finding, b: Finding) bool {
    inline for (.{ "scope", "kind", "slug", "code", "message" }) |f| {
        const o = std.mem.order(u8, @field(a, f), @field(b, f));
        if (o != .eq) return o == .lt;
    }
    return false;
}

fn emptyField(f: []const u8) []const u8 {
    return if (std.mem.eql(u8, f, "title")) "title is empty" else "body is empty";
}

fn lintScope(a: std.mem.Allocator, scope: []const u8, docs: []const domain.Document) ![]Finding {
    const links = try ScopeLinks.init(a, docs);
    var findings: std.ArrayList(Finding) = .empty;
    var referenced = std.StringHashMap(void).init(a);
    var knowledge: std.ArrayList(domain.Document) = .empty;
    var indexes: std.ArrayList(domain.Document) = .empty;
    for (docs) |d| {
        const is_knowledge = std.mem.eql(u8, d.kind, "knowledge");
        const is_index = std.mem.eql(u8, d.kind, "knowledge_index");
        if (!is_knowledge and !is_index) continue;
        if (is_knowledge) try knowledge.append(a, d) else try indexes.append(a, d);
        if (std.mem.trim(u8, d.title, " \t\n\r\x0b\x0c").len == 0) {
            try findings.append(a, .{ .scope = d.scope, .kind = d.kind, .slug = d.slug, .severity = lint_error, .code = lint_empty_title, .message = "title is empty" });
        }
        if (std.mem.trim(u8, d.body, " \t\n\r\x0b\x0c").len == 0) {
            try findings.append(a, .{ .scope = d.scope, .kind = d.kind, .slug = d.slug, .severity = lint_error, .code = lint_empty_body, .message = "body is empty" });
        }
        for (try documentLinks(a, d.body)) |link| {
            if (links.resolve(link.target, link.by_title)) |slug| {
                if (is_index) try referenced.put(slug, {});
                continue;
            }
            if (link.by_title) {
                try findings.append(a, .{
                    .scope = d.scope,
                    .kind = d.kind,
                    .slug = d.slug,
                    .severity = lint_error,
                    .code = lint_unresolved_wiki,
                    .message = try std.fmt.allocPrint(a, "unresolved wikilink [[{s}]]", .{link.target}),
                });
            } else {
                try findings.append(a, .{
                    .scope = d.scope,
                    .kind = d.kind,
                    .slug = d.slug,
                    .severity = lint_warning,
                    .code = lint_unresolved_link,
                    .message = try std.fmt.allocPrint(a, "unresolved markdown link to {s}", .{link.raw}),
                });
            }
        }
    }
    if (knowledge.items.len > 0 and indexes.items.len == 0) {
        try findings.append(a, .{
            .scope = scope,
            .kind = "knowledge_index",
            .slug = "",
            .severity = lint_warning,
            .code = lint_missing_index,
            .message = "scope has knowledge documents but no knowledge_index",
        });
    }
    if (indexes.items.len > 0) {
        for (knowledge.items) |d| {
            if (!referenced.contains(d.slug)) {
                try findings.append(a, .{
                    .scope = d.scope,
                    .kind = d.kind,
                    .slug = d.slug,
                    .severity = lint_warning,
                    .code = lint_orphan_knowledge,
                    .message = "knowledge document is not referenced by any knowledge_index",
                });
            }
        }
    }
    return findings.items;
}

pub fn lintDocuments(a: std.mem.Allocator, docs: []const domain.Document) !Report {
    var by_scope = std.StringHashMap(std.ArrayList(domain.Document)).init(a);
    for (docs) |d| {
        const entry = try by_scope.getOrPut(d.scope);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, d);
    }
    var all: std.ArrayList(Finding) = .empty;
    var it = by_scope.valueIterator();
    while (it.next()) |group| {
        for (try lintScope(a, group.items[0].scope, group.items)) |f| {
            try all.append(a, f);
        }
    }
    std.mem.sort(Finding, all.items, {}, lessFinding);
    var errors: std.ArrayList(Finding) = .empty;
    var warnings: std.ArrayList(Finding) = .empty;
    for (all.items) |f| {
        if (std.mem.eql(u8, f.severity, lint_error)) {
            try errors.append(a, f);
        } else {
            try warnings.append(a, f);
        }
    }
    return .{ .errors = errors.items, .warnings = warnings.items, .findings = all.items };
}

// ----------------------------------------------------------------- output

pub fn writeFinding(o: *jsonw.Obj, f: Finding) !void {
    try o.str("scope", f.scope);
    try o.str("kind", f.kind);
    try o.str("slug", f.slug);
    try o.str("severity", f.severity);
    try o.str("code", f.code);
    try o.str("message", f.message);
}

fn writeFindings(o: *jsonw.Obj, name: []const u8, items: []const Finding) !void {
    var arr = try o.arr(name);
    for (items) |f| {
        var item = try arr.obj();
        try writeFinding(&item, f);
        try item.end();
    }
    try arr.end();
}

pub fn writeReport(o: *jsonw.Obj, r: Report) !void {
    try writeFindings(o, "errors", r.errors);
    try writeFindings(o, "warnings", r.warnings);
    try writeFindings(o, "findings", r.findings);
}

pub fn writeRelations(o: *jsonw.Obj, r: Relations) !void {
    var src = try o.obj("source");
    try r.source.write(&src);
    try src.end();
    inline for (.{ .{ "outlinks", r.outlinks }, .{ "backlinks", r.backlinks } }) |pair| {
        var arr = try o.arr(pair[0]);
        for (pair[1]) |d| {
            var item = try arr.obj();
            try d.write(&item);
            try item.end();
        }
        try arr.end();
    }
}

test "links and lint on a small corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = [_]domain.Document{
        .{ .id = "doc:p:knowledge_index:knowledge/index", .scope = "p", .kind = "knowledge_index", .slug = "knowledge/index", .title = "Index", .body = "- [[architecture]]\n- [notes](notes/db.md)\n", .status = "draft", .revision = 1, .created_at = "2026-01-01T00:00:00Z", .updated_at = "2026-01-01T00:00:00Z" },
        .{ .id = "doc:p:knowledge:architecture", .scope = "p", .kind = "knowledge", .slug = "architecture", .title = "Architecture", .body = "See [db](notes/db.md) and `[[not-a-link]]`.", .status = "draft", .revision = 1, .created_at = "2026-01-01T00:00:00Z", .updated_at = "2026-01-01T00:00:00Z" },
        .{ .id = "doc:p:knowledge:notes/db", .scope = "p", .kind = "knowledge", .slug = "notes/db", .title = "DB notes", .body = "[[Architecture]]", .status = "draft", .revision = 1, .created_at = "2026-01-01T00:00:00Z", .updated_at = "2026-01-01T00:00:00Z" },
    };
    const links = try documentLinks(a, docs[1].body);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("notes/db.md", links[0].raw);
    try std.testing.expectEqualStrings("notes/db", links[0].target);

    const rel = try relatedDocuments(a, &docs, docs[1]);
    try std.testing.expectEqual(@as(usize, 1), rel.outlinks.len);
    try std.testing.expectEqual(@as(usize, 2), rel.backlinks.len);

    const report = try lintDocuments(a, &docs);
    try std.testing.expectEqual(@as(usize, 0), report.errors.len);
    try std.testing.expectEqual(@as(usize, 0), report.warnings.len);
}
