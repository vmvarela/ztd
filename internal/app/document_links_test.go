package app

import (
	"strings"
	"testing"

	"ztd/internal/domain"
)

func relDoc(scope, kind, slug, title, body string) domain.Document {
	return domain.Document{Scope: scope, Kind: kind, Slug: slug, Title: title, Body: body}
}

func linkShape(l DocumentLink) string {
	if l.ByTitle {
		return "wiki:" + l.Target
	}
	return "md:" + l.Target
}

// TestDocumentLinksForms pins every supported link form and the exclusions:
// wikilinks with a label or an anchor, Markdown links, images, external URLs
// and code — prose only, never examples.
func TestDocumentLinksForms(t *testing.T) {
	body := "See [[target]], [[target|label]] and [[other#anchor]].\n" +
		"Also [label](./other.md) and [site](https://example.com).\n" +
		"An image ![alt](pic.png) and inline `[[ghost]]` stay out.\n" +
		"```\n[[fenced]]\n```\n"
	got := DocumentLinks(body)
	var shapes []string
	for _, l := range got {
		shapes = append(shapes, linkShape(l))
	}
	want := "wiki:target wiki:target wiki:other md:other"
	if strings.Join(shapes, " ") != want {
		t.Fatalf("links = %v, want %s", shapes, want)
	}
	// The raw target keeps the form as written, before normalization.
	if got[1].Raw != "target" || got[3].Raw != "./other.md" {
		t.Fatalf("raw targets = %q / %q, want target and ./other.md", got[1].Raw, got[3].Raw)
	}
	if got[0].ByTitle != true || got[3].ByTitle != false {
		t.Fatalf("ByTitle flags = %v/%v, want wiki then md", got[0].ByTitle, got[3].ByTitle)
	}
	if len(DocumentLinks("`[x](gone)` only code")) != 0 {
		t.Fatal("a code-only body must yield no links")
	}
}

// TestNormalizeDocumentTarget pins the store-relative rendering shared by
// lint and related: fragments, queries, angle brackets, ./ and / prefixes,
// .md suffixes and the knowledge/ prefix all disappear.
func TestNormalizeDocumentTarget(t *testing.T) {
	cases := map[string]string{
		"setup":              "setup",
		"./setup.md":         "setup",
		"/setup":             "setup",
		"knowledge/setup":    "setup",
		"../knowledge/setup": "setup",
		"setup#anchor":       "setup",
		"setup?x=1":          "setup",
		"<setup.md>":         "setup",
		"  setup  ":          "setup",
		"komorebi/setup":     "komorebi/setup",
		"knowledge/a/b.md":   "a/b",
		"   ":                "",
		"#only-fragment":     "",
		"./":                 "",
		"knowledge/":         "",
	}
	for in, want := range cases {
		if got := NormalizeDocumentTarget(in); got != want {
			t.Errorf("NormalizeDocumentTarget(%q) = %q, want %q", in, got, want)
		}
	}
}

// relationShape renders one relation as kind/slug lines for order assertions.
func relationShape(docs []domain.Document) string {
	out := make([]string, 0, len(docs))
	for _, d := range docs {
		out = append(out, d.Kind+"/"+d.Slug)
	}
	return strings.Join(out, ",")
}

// relatedFixture is one scope of linked documents plus a foreign scope that
// links into it: the card points at the index, the index and two other
// documents point back at the card, and the foreign document must stay
// invisible.
func relatedFixture() (docs []domain.Document, source domain.Document) {
	docs = []domain.Document{
		relDoc("personal", "knowledge", "setup", "Setup",
			"See [[index|the index]], [[setup]] again and [tips](./tips.md)."),
		relDoc("personal", "knowledge_index", "index", "Index",
			"[[setup]] and [[tips|Tips card]]"),
		relDoc("personal", "knowledge", "tips", "Tips", "[setup](knowledge/setup.md)"),
		relDoc("personal", "journal", "day/2026-11-21", "Day", "configured [[setup]] today"),
		relDoc("personal", "knowledge", "lonely", "Lonely", "points at [[Setup]] by title"),
		relDoc("beta", "knowledge", "secret", "Secret", "crosses into [[setup]]"),
	}
	return docs, docs[0]
}

// TestRelatedDocuments pins the relation contract: outlinks and backlinks
// resolve inside the source's own scope, the source never lists itself as a
// backlink, cross-scope links stay unresolved, and the order is by kind then
// slug whatever order the documents arrive in.
func TestRelatedDocuments(t *testing.T) {
	docs, source := relatedFixture()
	rel := RelatedDocuments(docs, source)

	if got, want := relationShape(rel.Outlinks),
		"knowledge/setup,knowledge/tips,knowledge_index/index"; got != want {
		t.Fatalf("outlinks = %s, want %s (a self-link stays a resolved target)", got, want)
	}
	if got, want := relationShape(rel.Backlinks),
		"journal/day/2026-11-21,knowledge/lonely,knowledge/tips,knowledge_index/index"; got != want {
		t.Fatalf("backlinks = %s, want %s: slug, unique title and index links, no source, no beta", got, want)
	}
	if rel.Source.Slug != "setup" || rel.Outlinks == nil || rel.Backlinks == nil {
		t.Fatalf("relation = %+v, want the source and both lists non-nil", rel)
	}
	for _, d := range rel.Backlinks {
		if sameDocument(d, source) {
			t.Fatalf("source listed as its own backlink: %+v", d)
		}
		if d.Scope != "personal" {
			t.Fatalf("cross-scope backlink leaked: %+v", d)
		}
	}

	// The foreign document linking into the scope resolves nothing: a source
	// in beta sees no outlinks and no backlinks from personal.
	foreign := docs[len(docs)-1]
	foreignRel := RelatedDocuments(docs, foreign)
	if len(foreignRel.Outlinks) != 0 || len(foreignRel.Backlinks) != 0 {
		t.Fatalf("cross-scope relation = %+v, want both lists empty", foreignRel)
	}

	// Input order never changes the output, and a duplicated link appears
	// once.
	reversed := make([]domain.Document, len(docs))
	for i, d := range docs {
		reversed[len(docs)-1-i] = d
	}
	again := RelatedDocuments(reversed, source)
	if relationShape(again.Outlinks) != relationShape(rel.Outlinks) ||
		relationShape(again.Backlinks) != relationShape(rel.Backlinks) {
		t.Fatalf("reversed input changed the order: %+v vs %+v", again, rel)
	}
	duplicated := append([]domain.Document{}, docs...)
	duplicated[0].Body += " once more [[tips]] and [[index]]"
	third := RelatedDocuments(duplicated, source)
	if relationShape(third.Outlinks) != relationShape(rel.Outlinks) {
		t.Fatalf("duplicate links = %s, want the deduplicated %s",
			relationShape(third.Outlinks), relationShape(rel.Outlinks))
	}
}
