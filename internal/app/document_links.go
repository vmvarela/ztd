package app

import (
	"regexp"
	"sort"
	"strings"

	"ztd/internal/domain"
)

// wikilinkPattern matches [[target]], [[target|label]] and [[target#anchor]];
// the target is whatever sits inside the brackets.
var wikilinkPattern = regexp.MustCompile(`\[\[([^\[\]]+)\]\]`)

// markdownLinkPattern matches [label](target) and ![alt](src); group 1 is the
// image bang, group 2 the parenthesised target (possibly with a title).
var markdownLinkPattern = regexp.MustCompile(`(!?)\[[^\]]*\]\(([^)]*)\)`)

// codeSpanPattern matches inline `code` spans; a code sample that looks like
// a link is not a link.
var codeSpanPattern = regexp.MustCompile("`[^`\n]*`")

// linkPattern matches a URL scheme at the start of a target: links to the
// outside world are not document references.
var linkPattern = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.-]*:`)

// stripCode blanks out fenced blocks and inline code spans so examples never
// lint as wikilinks or Markdown links. Lines are kept so the link patterns
// still see the same document structure.
func stripCode(body string) string {
	var b strings.Builder
	inFence := false
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			inFence = !inFence
			b.WriteByte('\n')
			continue
		}
		if inFence {
			b.WriteByte('\n')
			continue
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return codeSpanPattern.ReplaceAllString(b.String(), " ")
}

// NormalizeDocumentTarget renders a Markdown or wikilink target store-relative
// so it can be compared with document slugs: no angle brackets, fragment or
// query, no leading ./ or /, no .md suffix and no knowledge/ prefix. It never
// resolves against the linking page's directory.
func NormalizeDocumentTarget(t string) string {
	t = strings.TrimSpace(t)
	t = strings.TrimPrefix(t, "<")
	t = strings.TrimSuffix(t, ">")
	if i := strings.IndexAny(t, "#?"); i >= 0 {
		t = t[:i]
	}
	t = strings.TrimPrefix(t, "./")
	t = strings.TrimPrefix(t, "/")
	t = strings.TrimSuffix(t, ".md")
	t = strings.TrimPrefix(t, "../knowledge/")
	t = strings.TrimPrefix(t, "knowledge/")
	return strings.TrimSpace(t)
}

// DocumentLink is one reference extracted from a document body. Raw is the
// target as written, Target is NormalizeDocumentTarget(Raw), and ByTitle marks
// a wikilink, whose target may also match a unique document title.
type DocumentLink struct {
	Raw     string `json:"raw"`
	Target  string `json:"target"`
	ByTitle bool   `json:"by_title"`
}

// DocumentLinks extracts every wikilink and Markdown document link from a
// body, in the order they appear. Code spans and fences are ignored, images
// and external Markdown URLs are not document references, and a target that
// normalizes to nothing is dropped — exactly the rules doc lint applies.
func DocumentLinks(body string) []DocumentLink {
	stripped := stripCode(body)
	out := []DocumentLink{}
	for _, m := range wikilinkPattern.FindAllStringSubmatch(stripped, -1) {
		raw := m[1]
		if i := strings.IndexByte(raw, '|'); i >= 0 {
			raw = raw[:i]
		}
		target := NormalizeDocumentTarget(raw)
		if target == "" {
			continue
		}
		out = append(out, DocumentLink{Raw: raw, Target: target, ByTitle: true})
	}
	for _, m := range markdownLinkPattern.FindAllStringSubmatch(stripped, -1) {
		if m[1] == "!" { // an image is not a document link
			continue
		}
		fields := strings.Fields(m[2])
		if len(fields) == 0 {
			continue
		}
		raw := fields[0]
		if linkPattern.MatchString(raw) {
			continue
		}
		target := NormalizeDocumentTarget(raw)
		if target == "" {
			continue
		}
		out = append(out, DocumentLink{Raw: raw, Target: target})
	}
	return out
}

// scopeLinks resolves targets inside one scope only: a target that exists
// only in another scope is simply unresolved.
type scopeLinks struct {
	slugs map[string]bool
	// titles maps a title to its slug, only while the title is unique in the
	// scope; an ambiguous title resolves nothing.
	titles map[string]string
}

func newScopeLinks(docs []domain.Document) scopeLinks {
	l := scopeLinks{slugs: map[string]bool{}, titles: map[string]string{}}
	counts := map[string]int{}
	for _, d := range docs {
		l.slugs[d.Slug] = true
		counts[d.Title]++
	}
	for _, d := range docs {
		if counts[d.Title] == 1 && d.Title != "" {
			l.titles[d.Title] = d.Slug
		}
	}
	return l
}

// resolve matches a normalized target against the scope's slugs, and against
// unique titles when the link is a wikilink.
func (l scopeLinks) resolve(target string, byTitle bool) (string, bool) {
	if l.slugs[target] {
		return target, true
	}
	if byTitle {
		if slug, ok := l.titles[target]; ok {
			return slug, true
		}
	}
	return "", false
}

// DocumentRelations is the link neighbourhood of one source document.
// Outlinks and Backlinks are deduplicated and ordered by kind then slug.
type DocumentRelations struct {
	Source    domain.Document   `json:"source"`
	Outlinks  []domain.Document `json:"outlinks"`
	Backlinks []domain.Document `json:"backlinks"`
}

// RelatedDocuments resolves the source document's links against docs, which
// must hold the source's own scope: a target that exists only in another
// scope stays unresolved and is never disclosed. Outlinks are the in-scope
// documents the source links to; backlinks are the in-scope documents whose
// links resolve to the source's slug (or its unique title through a
// wikilink), excluding the source itself.
func RelatedDocuments(docs []domain.Document, source domain.Document) DocumentRelations {
	inScope := make([]domain.Document, 0, len(docs))
	for _, d := range docs {
		if d.Scope == source.Scope {
			inScope = append(inScope, d)
		}
	}
	sort.SliceStable(inScope, func(i, j int) bool {
		if inScope[i].Kind != inScope[j].Kind {
			return inScope[i].Kind < inScope[j].Kind
		}
		return inScope[i].Slug < inScope[j].Slug
	})
	links := newScopeLinks(inScope)

	targets := map[string]bool{}
	for _, l := range DocumentLinks(source.Body) {
		if slug, ok := links.resolve(l.Target, l.ByTitle); ok {
			targets[slug] = true
		}
	}
	rel := DocumentRelations{
		Source:    source,
		Outlinks:  []domain.Document{},
		Backlinks: []domain.Document{},
	}
	for _, d := range inScope {
		if targets[d.Slug] {
			rel.Outlinks = append(rel.Outlinks, d)
		}
		if sameDocument(d, source) {
			continue
		}
		for _, l := range DocumentLinks(d.Body) {
			if slug, ok := links.resolve(l.Target, l.ByTitle); ok && slug == source.Slug {
				rel.Backlinks = append(rel.Backlinks, d)
				break
			}
		}
	}
	return rel
}

// sameDocument reports whether two documents are the same row: the identity
// is (scope, kind, slug), because an in-memory document may lack its id.
func sameDocument(a, b domain.Document) bool {
	return a.Scope == b.Scope && a.Kind == b.Kind && a.Slug == b.Slug
}
