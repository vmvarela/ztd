package app

import (
	"context"
	"testing"

	"ztd/internal/domain"
)

func testBinding() domain.ScopeBinding {
	return domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}
}

func TestValidateContextCmd(t *testing.T) {
	cases := []struct {
		name string
		cmd  ContextCmd
		want bool
	}{
		{"valid", ContextCmd{Binding: testBinding(), Name: "familia"}, true},
		{"blank name", ContextCmd{Binding: testBinding(), Name: "  "}, false},
		{"missing name", ContextCmd{Binding: testBinding()}, false},
		{"empty binding", ContextCmd{Name: "familia"}, false},
	}
	for _, tc := range cases {
		if err := ValidateContextCmd(tc.cmd); (err == nil) != tc.want {
			t.Errorf("%s: ValidateContextCmd = %v, want ok=%v", tc.name, err, tc.want)
		}
	}
}

func TestValidateDocumentCmd(t *testing.T) {
	base := func() DocumentCmd {
		return DocumentCmd{
			Binding: testBinding(), Kind: domain.DocumentKnowledge, Slug: "a/b-c_1.md",
			Title: "Title", Body: "Body", Status: domain.DocumentDraft,
		}
	}
	cases := []struct {
		name   string
		mutate func(*DocumentCmd)
		want   bool
	}{
		{"valid", func(c *DocumentCmd) {}, true},
		{"path-ish slug", func(c *DocumentCmd) { c.Slug = "knowledge/index" }, true},
		{"unknown kind", func(c *DocumentCmd) { c.Kind = "wiki" }, false},
		{"empty kind", func(c *DocumentCmd) { c.Kind = "" }, false},
		{"unknown status", func(c *DocumentCmd) { c.Status = "published" }, false},
		{"empty status", func(c *DocumentCmd) { c.Status = "" }, false},
		{"empty slug", func(c *DocumentCmd) { c.Slug = "" }, false},
		{"slug with space", func(c *DocumentCmd) { c.Slug = "two words" }, false},
		{"slug with colon", func(c *DocumentCmd) { c.Slug = "a:b" }, false},
		{"blank title", func(c *DocumentCmd) { c.Title = " " }, false},
		{"blank body", func(c *DocumentCmd) { c.Body = "" }, false},
		{"negative expected", func(c *DocumentCmd) { c.Expected = -1 }, false},
		{"empty binding", func(c *DocumentCmd) { c.Binding = domain.ScopeBinding{} }, false},
		{"draft-only draft", func(c *DocumentCmd) { c.DraftOnly = true }, true},
		{"draft-only verified", func(c *DocumentCmd) {
			c.DraftOnly = true
			c.Status = domain.DocumentVerified
		}, false},
		{"draft-only superseded", func(c *DocumentCmd) {
			c.DraftOnly = true
			c.Status = domain.DocumentSuperseded
		}, false},
	}
	for _, tc := range cases {
		cmd := base()
		tc.mutate(&cmd)
		if err := ValidateDocumentCmd(cmd); (err == nil) != tc.want {
			t.Errorf("%s: ValidateDocumentCmd = %v, want ok=%v", tc.name, err, tc.want)
		}
	}
}

func TestValidateProjectCmd(t *testing.T) {
	base := func() ProjectCmd {
		return ProjectCmd{Binding: testBinding(), ID: "opensource/ztd", Status: "active"}
	}
	cases := []struct {
		name   string
		mutate func(*ProjectCmd)
		want   bool
	}{
		{"valid", func(c *ProjectCmd) {}, true},
		{"with repository", func(c *ProjectCmd) {
			c.RepoURL = "https://example.com/ztd.git"
			c.ClonePath = "/home/me/ztd"
		}, true},
		{"empty id", func(c *ProjectCmd) { c.ID = "  " }, false},
		{"unknown status", func(c *ProjectCmd) { c.Status = "doing" }, false},
		{"empty status", func(c *ProjectCmd) { c.Status = "" }, false},
		{"relative clone path", func(c *ProjectCmd) { c.ClonePath = "ztd" }, false},
		{"nested clone path", func(c *ProjectCmd) { c.ClonePath = "/a/../b" }, false},
		{"trailing dotdot", func(c *ProjectCmd) { c.ClonePath = "/a/b/.." }, false},
		{"dotdot not a segment", func(c *ProjectCmd) { c.ClonePath = "/a/..b/c" }, true},
		{"credentials in url", func(c *ProjectCmd) { c.RepoURL = "https://u:p@example.com/x" }, false},
		{"userinfo in url", func(c *ProjectCmd) { c.RepoURL = "https://u@example.com/x" }, false},
		{"empty repo url", func(c *ProjectCmd) { c.RepoURL = "" }, true},
		{"empty binding", func(c *ProjectCmd) { c.Binding = domain.ScopeBinding{} }, false},
	}
	for _, tc := range cases {
		cmd := base()
		tc.mutate(&cmd)
		if err := ValidateProjectCmd(cmd); (err == nil) != tc.want {
			t.Errorf("%s: ValidateProjectCmd = %v, want ok=%v", tc.name, err, tc.want)
		}
	}
}

// TestServiceValidatesBeforeRepo proves the wrappers reject bad input without
// ever calling the repository: a nil repository would panic on a real call.
func TestServiceValidatesBeforeRepo(t *testing.T) {
	svc := &Service{Repo: nil}
	ctx := context.Background()
	b := testBinding()

	if _, err := svc.AddContext(ctx, ContextCmd{Binding: b, Name: " "}); !domain.Of(err, domain.InvalidInput) {
		t.Errorf("AddContext blank name = %v, want invalid_input", err)
	}
	if _, err := svc.PutDocument(ctx, DocumentCmd{Binding: b, Kind: "wiki", Slug: "s", Title: "t", Body: "b", Status: domain.DocumentDraft}); !domain.Of(err, domain.InvalidInput) {
		t.Errorf("PutDocument bad kind = %v, want invalid_input", err)
	}
	if _, err := svc.PutDocument(ctx, DocumentCmd{Binding: b, Scope: "outside", Kind: domain.DocumentKnowledge, Slug: "s", Title: "t", Body: "b", Status: domain.DocumentDraft}); !domain.Of(err, domain.ScopeDenied) {
		t.Errorf("PutDocument unbound scope = %v, want scope_denied", err)
	}
	if _, err := svc.AddProject(ctx, ProjectCmd{Binding: b, ID: "x", Status: "doing"}); !domain.Of(err, domain.InvalidInput) {
		t.Errorf("AddProject bad status = %v, want invalid_input", err)
	}
	if _, err := svc.ListContexts(ctx, domain.ScopeBinding{}); !domain.Of(err, domain.InvalidInput) {
		t.Errorf("ListContexts empty binding = %v, want invalid_input", err)
	}
	if _, err := svc.ListDocuments(ctx, b, "wiki"); !domain.Of(err, domain.InvalidInput) {
		t.Errorf("ListDocuments bad kind = %v, want invalid_input", err)
	}
	if _, err := svc.GetProject(ctx, b, " "); !domain.Of(err, domain.InvalidInput) {
		t.Errorf("GetProject blank id = %v, want invalid_input", err)
	}
}
