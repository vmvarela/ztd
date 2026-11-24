package app

import (
	"sort"
	"strings"

	"ztd/internal/domain"
)

// Severity of one LintFinding: errors fail every mode, warnings only fail
// --strict.
const (
	lintError   = "error"
	lintWarning = "warning"
)

// Finding codes, stable so callers and tests can match on them.
const (
	LintEmptyTitle      = "empty_title"
	LintEmptyBody       = "empty_body"
	LintUnresolvedWiki  = "unresolved_wikilink"
	LintUnresolvedLink  = "unresolved_link"
	LintOrphanKnowledge = "orphan_knowledge"
	LintMissingIndex    = "missing_index"
)

// LintFinding is one deterministic problem in one document (or one scope for
// the index-coverage rules). The message never names a scope other than the
// document's own, so a cross-scope target stays unrevealed.
type LintFinding struct {
	Scope    string `json:"scope"`
	Kind     string `json:"kind"`
	Slug     string `json:"slug"`
	Severity string `json:"severity"`
	Code     string `json:"code"`
	Message  string `json:"message"`
}

// LintReport is the outcome of LintDocuments: Errors and Warnings are the
// severity partitions of Findings, and every list is sorted by scope, kind,
// slug, code and message.
type LintReport struct {
	Errors   []LintFinding `json:"errors"`
	Warnings []LintFinding `json:"warnings"`
	Findings []LintFinding `json:"findings"`
}

// OK reports whether the report has no errors.
func (r LintReport) OK() bool { return len(r.Errors) == 0 }

// StrictOK reports whether the report has no findings at all.
func (r LintReport) StrictOK() bool { return len(r.Findings) == 0 }

// lintDocLinks extracts every wikilink and Markdown link from one body and
// reports the ones that resolve to nothing in the scope. It returns the
// slugs the body references, so the index pass can mark them as covered.
// Extraction itself lives in DocumentLinks, shared with doc related.
func lintDocLinks(d domain.Document, l scopeLinks) (map[string]bool, []LintFinding) {
	referenced := map[string]bool{}
	var findings []LintFinding
	report := func(code, message string) {
		findings = append(findings, LintFinding{
			Scope: d.Scope, Kind: d.Kind, Slug: d.Slug,
			Severity: lintWarning, Code: code, Message: message,
		})
	}
	for _, link := range DocumentLinks(d.Body) {
		slug, ok := l.resolve(link.Target, link.ByTitle)
		if ok {
			referenced[slug] = true
			continue
		}
		if link.ByTitle {
			findings = append(findings, LintFinding{
				Scope: d.Scope, Kind: d.Kind, Slug: d.Slug,
				Severity: lintError, Code: LintUnresolvedWiki,
				Message: "unresolved wikilink [[" + link.Target + "]]",
			})
			continue
		}
		report(LintUnresolvedLink, "unresolved markdown link to "+link.Raw)
	}
	return referenced, findings
}

// LintDocuments checks the knowledge and knowledge_index documents of every
// scope in docs: empty titles and bodies plus unresolved wikilinks are
// errors; unresolved Markdown links, knowledge documents no index references
// and scopes without an index are warnings. It is deterministic and touches
// nothing outside docs.
func LintDocuments(docs []domain.Document) LintReport {
	byScope := map[string][]domain.Document{}
	for _, d := range docs {
		byScope[d.Scope] = append(byScope[d.Scope], d)
	}
	var findings []LintFinding
	for scope, group := range byScope {
		findings = append(findings, lintScope(scope, group)...)
	}
	sort.Slice(findings, func(i, j int) bool {
		a, b := findings[i], findings[j]
		switch {
		case a.Scope != b.Scope:
			return a.Scope < b.Scope
		case a.Kind != b.Kind:
			return a.Kind < b.Kind
		case a.Slug != b.Slug:
			return a.Slug < b.Slug
		case a.Code != b.Code:
			return a.Code < b.Code
		default:
			return a.Message < b.Message
		}
	})
	report := LintReport{
		Errors: []LintFinding{}, Warnings: []LintFinding{}, Findings: findings,
	}
	for _, f := range findings {
		if f.Severity == lintError {
			report.Errors = append(report.Errors, f)
		} else {
			report.Warnings = append(report.Warnings, f)
		}
	}
	return report
}

// lintScope applies every rule to one scope's documents. Only knowledge and
// knowledge_index documents are inspected.
func lintScope(scope string, docs []domain.Document) []LintFinding {
	links := newScopeLinks(docs)
	var findings []LintFinding
	referenced := map[string]bool{}
	var knowledge, indexes []domain.Document
	for _, d := range docs {
		switch domain.DocumentKind(d.Kind) {
		case domain.DocumentKnowledge:
			knowledge = append(knowledge, d)
		case domain.DocumentKnowledgeIndex:
			indexes = append(indexes, d)
		default:
			continue
		}
		empty := func(code, field string) {
			findings = append(findings, LintFinding{
				Scope: d.Scope, Kind: d.Kind, Slug: d.Slug,
				Severity: lintError, Code: code, Message: field + " is empty",
			})
		}
		if strings.TrimSpace(d.Title) == "" {
			empty(LintEmptyTitle, "title")
		}
		if strings.TrimSpace(d.Body) == "" {
			empty(LintEmptyBody, "body")
		}
		refs, linkFindings := lintDocLinks(d, links)
		findings = append(findings, linkFindings...)
		if d.Kind == string(domain.DocumentKnowledgeIndex) {
			for slug := range refs {
				referenced[slug] = true
			}
		}
	}
	return findings
}
