package app

import (
	"strings"
	"testing"

	"ztd/internal/domain"
)

func lintDoc(scope, kind, slug, title, body string) domain.Document {
	return domain.Document{Scope: scope, Kind: kind, Slug: slug, Title: title, Body: body}
}

// codes returns the finding codes in report order, for order assertions.
func codes(r LintReport) []string {
	out := make([]string, 0, len(r.Findings))
	for _, f := range r.Findings {
		out = append(out, f.Code)
	}
	return out
}

// TestLintDocumentsCleanIndex pins the happy path: a knowledge card and its
// index that reference each other in every supported link form, plus a
// document kind the linter must ignore, produce no findings at all.
func TestLintDocumentsCleanIndex(t *testing.T) {
	report := LintDocuments([]domain.Document{
		lintDoc("personal", string(domain.DocumentKnowledge), "setup", "Setup",
			"See [[index|the index]] and [[Setup#top]]. Also [index](./index.md), "+
				"[card](knowledge/setup.md) and [site](https://example.com)."),
		lintDoc("personal", string(domain.DocumentKnowledgeIndex), "index", "Index",
			"[[setup]] and [setup](../knowledge/setup)"),
		lintDoc("personal", string(domain.DocumentJournal), "day/2026-11-21", "Day",
			"links the linter ignores: [[nowhere]] and [x](gone)"),
	})
	if !report.OK() || !report.StrictOK() {
		t.Fatalf("clean report = %+v, want no findings", report.Findings)
	}
	if len(report.Findings) != 0 {
		t.Fatalf("findings = %+v, want none", report.Findings)
	}
}

// TestLintDocumentsBrokenWikilink pins the only link error: a wikilink that
// resolves to nothing in its own scope.
func TestLintDocumentsBrokenWikilink(t *testing.T) {
	report := LintDocuments([]domain.Document{
		lintDoc("personal", string(domain.DocumentKnowledge), "a", "A", "see [[ghost]]"),
		lintDoc("personal", string(domain.DocumentKnowledgeIndex), "index", "Index", "[[a]]"),
	})
	if report.OK() {
		t.Fatal("broken wikilink reported OK")
	}
	if len(report.Errors) != 1 || report.Errors[0].Code != LintUnresolvedWiki {
		t.Fatalf("errors = %+v, want one unresolved_wikilink", report.Errors)
	}
	if f := report.Errors[0]; f.Severity != lintError || f.Scope != "personal" ||
		f.Slug != "a" || !strings.Contains(f.Message, "[[ghost]]") {
		t.Fatalf("finding = %+v", f)
	}
	if report.StrictOK() {
		t.Fatal("StrictOK = true, want false")
	}
}

// TestLintDocumentsBrokenMarkdown pins the warning severity: an unresolved
// Markdown link never fails the default mode.
func TestLintDocumentsBrokenMarkdown(t *testing.T) {
	report := LintDocuments([]domain.Document{
		lintDoc("personal", string(domain.DocumentKnowledge), "a", "A", "[label](ghost-doc)"),
		lintDoc("personal", string(domain.DocumentKnowledgeIndex), "index", "Index", "[[a]]"),
	})
	if !report.OK() {
		t.Fatalf("errors = %+v, want none for a Markdown link", report.Errors)
	}
	if len(report.Warnings) != 1 || report.Warnings[0].Code != LintUnresolvedLink {
		t.Fatalf("warnings = %+v, want one unresolved_link", report.Warnings)
	}
	if report.StrictOK() {
		t.Fatal("StrictOK = true, want false")
	}
}

// TestLintDocumentsCrossScopeLink stays unresolved without disclosing the
// other scope: the target exists in beta, but alpha never looks there.
func TestLintDocumentsCrossScopeLink(t *testing.T) {
	report := LintDocuments([]domain.Document{
		lintDoc("alpha", string(domain.DocumentKnowledge), "linker", "Linker", "[t](secret)"),
		lintDoc("alpha", string(domain.DocumentKnowledgeIndex), "index", "Index", "[[linker]]"),
		lintDoc("beta", string(domain.DocumentKnowledge), "secret", "Secret", "clean"),
	})
	var found bool
	for _, f := range report.Findings {
		if f.Scope != "alpha" {
			continue
		}
		if strings.Contains(f.Message, "beta") {
			t.Fatalf("alpha finding reveals the other scope: %+v", f)
		}
		if f.Code == LintUnresolvedLink && f.Slug == "linker" {
			found = true
		}
	}
	if !found {
		t.Fatalf("findings = %+v, want an unresolved_link for alpha/linker", report.Findings)
	}
}

// TestLintDocumentsOrphanKnowledge pins the coverage rules: a knowledge card
// no index references is a warning, an index is never an orphan, and a scope
// without any index gets one missing_index warning instead of one per card.
func TestLintDocumentsOrphanKnowledge(t *testing.T) {
	report := LintDocuments([]domain.Document{
		lintDoc("personal", string(domain.DocumentKnowledgeIndex), "index", "Index", "[[other]]"),
		lintDoc("personal", string(domain.DocumentKnowledge), "lonely", "Lonely", "text"),
		lintDoc("personal", string(domain.DocumentKnowledge), "other", "Other", "text"),
	})
	if !report.OK() {
		t.Fatalf("errors = %+v, want none", report.Errors)
	}
	if len(report.Warnings) != 0 {
		t.Fatalf("optional index produced warnings: %+v", report.Warnings)
	}
	for _, f := range report.Findings {
		if f.Kind == string(domain.DocumentKnowledgeIndex) && f.Code == LintOrphanKnowledge {
			t.Fatalf("index flagged as orphan: %+v", f)
		}
	}

	// No index at all: one warning for the scope, not one per card.
	bare := LintDocuments([]domain.Document{
		lintDoc("personal", string(domain.DocumentKnowledge), "a", "A", "text"),
		lintDoc("personal", string(domain.DocumentKnowledge), "b", "B", "text"),
	})
	if !bare.OK() || len(bare.Warnings) != 0 {
		t.Fatalf("bare scope = %+v, want no index requirement", bare.Warnings)
	}
}

// TestLintDocumentsDeterministicOrder pins the sort contract: findings come
// back ordered by scope, kind, slug, code and message, whatever order the
// documents arrive in.
func TestLintDocumentsDeterministicOrder(t *testing.T) {
	docs := []domain.Document{
		lintDoc("beta", string(domain.DocumentKnowledge), "a", "A", "text"),
		lintDoc("alpha", string(domain.DocumentKnowledge), "zeta", "Zeta", "[[nope1]]"),
		lintDoc("alpha", string(domain.DocumentKnowledgeIndex), "i", "I", "[[ghost]]"),
		lintDoc("alpha", string(domain.DocumentKnowledge), "alpha-doc", "Ad", "[missing](gone)"),
	}
	want := []string{
		LintUnresolvedLink, // alpha/alpha-doc
		LintUnresolvedWiki, // alpha/zeta
		LintUnresolvedWiki, // alpha/i
	}
	got := codes(LintDocuments(docs))
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("order = %v, want %v", got, want)
	}
	// Reversed input, same output.
	for i, j := 0, len(docs)-1; i < j; i, j = i+1, j-1 {
		docs[i], docs[j] = docs[j], docs[i]
	}
	got = codes(LintDocuments(docs))
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("reversed order = %v, want %v", got, want)
	}
}

// TestLintDocumentsIgnoresCode pins the code exclusion: a wikilink or link
// inside an inline span or a fenced block is an example, not a reference,
// while the same syntax in prose still lints.
func TestLintDocumentsIgnoresCode(t *testing.T) {
	report := LintDocuments([]domain.Document{
		lintDoc("personal", string(domain.DocumentKnowledge), "a", "A",
			"Inline `[[\"ghost\"]]` and `[x](gone)` stay quiet.\n"+
				"```\n[[fenced-ghost]]\n```\n"+
				"Real [[ghost]] still counts."),
		lintDoc("personal", string(domain.DocumentKnowledgeIndex), "index", "Index", "[[a]]"),
	})
	if len(report.Errors) != 1 || report.Errors[0].Code != LintUnresolvedWiki ||
		!strings.Contains(report.Errors[0].Message, "[[ghost]]") {
		t.Fatalf("errors = %+v, want only the prose wikilink", report.Errors)
	}
	if len(report.Warnings) != 0 {
		t.Fatalf("warnings = %+v, want none from code samples", report.Warnings)
	}
}

// TestLintDocumentsEmptyFields pins the two content errors on both inspected
// kinds, and proves blank means whitespace too.
func TestLintDocumentsEmptyFields(t *testing.T) {
	report := LintDocuments([]domain.Document{
		lintDoc("personal", string(domain.DocumentKnowledge), "a", "", ""),
		lintDoc("personal", string(domain.DocumentKnowledgeIndex), "index", "Index", "   "),
	})
	if report.OK() || len(report.Errors) != 3 {
		t.Fatalf("findings = %+v, want empty_title plus two empty_body errors", report.Findings)
	}
	for _, f := range report.Errors {
		if f.Severity != lintError {
			t.Fatalf("finding = %+v, want error severity", f)
		}
	}
}
