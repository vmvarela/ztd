package legacy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ztd/internal/domain"
)

func fixtureExportPath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(fixtureRoot(t), "agent-export.json")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("fixture export: %v", err)
	}
	return path
}

// loadFixtureExport parses the committed export and returns it as the base
// for mutation cases.
func loadFixtureExport(t *testing.T) *AgentExport {
	t.Helper()
	doc, err := ParseAgentExport(fixtureExportPath(t))
	if err != nil {
		t.Fatalf("ParseAgentExport(fixture): %v", err)
	}
	return doc
}

// writeExport marshals doc into a temp file and parses it. An empty want
// family asserts success; otherwise the error must carry that family.
func parseMutated(t *testing.T, doc *AgentExport, want domain.Family) {
	t.Helper()
	b, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	path := filepath.Join(t.TempDir(), "export.json")
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseAgentExport(path); want == "" {
		if err != nil {
			t.Fatalf("ParseAgentExport: %v", err)
		}
		return
	} else if !domain.Of(err, want) {
		t.Fatalf("error = %v, want family %s", err, want)
	}
}

func TestParseAgentExportFixture(t *testing.T) {
	path := fixtureExportPath(t)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	doc, err := ParseAgentExport(path)
	if err != nil {
		t.Fatalf("ParseAgentExport: %v", err)
	}

	// Reading must not touch the source file.
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("ParseAgentExport modified the export file")
	}

	if doc.Format != "ztd-agent-export" || doc.Version != 2 {
		t.Errorf("header = %s/%d", doc.Format, doc.Version)
	}
	if len(doc.Scopes) != 1 || doc.Scopes[0].ID != "work" {
		t.Errorf("scopes = %+v", doc.Scopes)
	}
	if len(doc.Assignments) != 1 {
		t.Fatalf("assignments = %d, want 1", len(doc.Assignments))
	}
	a := doc.Assignments[0]
	if a.ID != "A-20261119-001" || a.ScopeID != "work" || a.Status != "open" || a.Rev != 2 {
		t.Errorf("assignment = %+v", a)
	}
	if a.Objective == nil || *a.Objective != "prove the importer" {
		t.Errorf("objective = %v", a.Objective)
	}
	if len(doc.Checkpoints) != 1 {
		t.Fatalf("checkpoints = %d, want 1", len(doc.Checkpoints))
	}
	c := doc.Checkpoints[0]
	if c.ID != "C-20261119-001" || c.AssignmentID != a.ID || c.Kind != "progress" || c.Rev != 2 {
		t.Errorf("checkpoint = %+v", c)
	}
	if len(doc.Operations) != 1 {
		t.Fatalf("operations = %d, want 1", len(doc.Operations))
	}
	op := doc.Operations[0]
	if op.Key != "fixture-op-1" || op.ResultJSON != `{"ok":true}` {
		t.Errorf("operation = %+v", op)
	}
	if len(doc.Knowledge) != 1 {
		t.Fatalf("knowledge = %d, want 1", len(doc.Knowledge))
	}
	k := doc.Knowledge[0]
	if k.ID != "K-20261119-001" || k.Scope != "work" || k.Kind != "decision" || k.Rev != 1 {
		t.Errorf("knowledge = %+v", k)
	}
	if k.Text != "the importer is read-only" || k.Source == nil || *k.Source != "spec" {
		t.Errorf("knowledge text/source = %+v", k)
	}
}

func TestParseAgentExportAccepts(t *testing.T) {
	t.Run("uppercase digest", func(t *testing.T) {
		doc := loadFixtureExport(t)
		doc.Operations[0].RequestSHA256 = strings.ToUpper(doc.Operations[0].RequestSHA256)
		parseMutated(t, doc, "")
	})

	t.Run("version 1 without knowledge", func(t *testing.T) {
		doc := loadFixtureExport(t)
		doc.Version = 1
		doc.Knowledge = nil
		parseMutated(t, doc, "")
	})

	t.Run("empty version 2 document", func(t *testing.T) {
		parseMutated(t, &AgentExport{Format: "ztd-agent-export", Version: 2}, "")
	})
}

func TestParseAgentExportRejects(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*AgentExport)
	}{
		{"wrong format", func(d *AgentExport) { d.Format = "ztd-markdown" }},
		{"version 0", func(d *AgentExport) { d.Version = 0 }},
		{"version 3", func(d *AgentExport) { d.Version = 3 }},
		{"duplicate scope", func(d *AgentExport) { d.Scopes = append(d.Scopes, d.Scopes[0]) }},
		{"empty scope id", func(d *AgentExport) { d.Scopes[0].ID = "" }},
		{"assignment unknown scope", func(d *AgentExport) { d.Assignments[0].ScopeID = "ghost" }},
		{"assignment empty id", func(d *AgentExport) { d.Assignments[0].ID = "" }},
		{"assignment duplicate id", func(d *AgentExport) {
			d.Assignments = append(d.Assignments, d.Assignments[0])
		}},
		{"assignment bad status", func(d *AgentExport) { d.Assignments[0].Status = "paused" }},
		{"assignment rev 0", func(d *AgentExport) { d.Assignments[0].Rev = 0 }},
		{"assignment rev mismatch", func(d *AgentExport) { d.Assignments[0].Rev = 3 }},
		{"checkpoint unknown parent", func(d *AgentExport) { d.Checkpoints[0].AssignmentID = "A-none" }},
		{"checkpoint empty id", func(d *AgentExport) { d.Checkpoints[0].ID = "" }},
		{"checkpoint bad kind", func(d *AgentExport) { d.Checkpoints[0].Kind = "verify" }},
		{"checkpoint rev below range", func(d *AgentExport) { d.Checkpoints[0].Rev = 1 }},
		{"checkpoint rev above parent", func(d *AgentExport) { d.Checkpoints[0].Rev = 3 }},
		{"duplicate checkpoint id", func(d *AgentExport) {
			d.Checkpoints = append(d.Checkpoints, d.Checkpoints[0])
		}},
		{"duplicate checkpoint rev in assignment", func(d *AgentExport) {
			clone := d.Checkpoints[0]
			clone.ID = "C-20261119-002"
			d.Checkpoints = append(d.Checkpoints, clone)
		}},
		{"duplicate operation key", func(d *AgentExport) {
			d.Operations = append(d.Operations, d.Operations[0])
		}},
		{"short digest", func(d *AgentExport) { d.Operations[0].RequestSHA256 = "abc" }},
		{"non-hex digest", func(d *AgentExport) {
			d.Operations[0].RequestSHA256 = strings.Repeat("g", 64)
		}},
		{"invalid result_json", func(d *AgentExport) { d.Operations[0].ResultJSON = "not json" }},
		{"knowledge in version 1", func(d *AgentExport) { d.Version = 1 }},
		{"duplicate knowledge id", func(d *AgentExport) {
			d.Knowledge = append(d.Knowledge, d.Knowledge[0])
		}},
		{"knowledge unknown scope", func(d *AgentExport) { d.Knowledge[0].Scope = "ghost" }},
		{"knowledge bad kind", func(d *AgentExport) { d.Knowledge[0].Kind = "hint" }},
		{"knowledge rev 2", func(d *AgentExport) { d.Knowledge[0].Rev = 2 }},
		{"empty knowledge id", func(d *AgentExport) { d.Knowledge[0].ID = "" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doc := loadFixtureExport(t)
			tc.mutate(doc)
			parseMutated(t, doc, domain.InvalidInput)
		})
	}

	t.Run("malformed JSON", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "export.json")
		if err := os.WriteFile(path, []byte(`{"format":"ztd-agent-export"`), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := ParseAgentExport(path)
		if !domain.Of(err, domain.InvalidInput) {
			t.Fatalf("error = %v, want InvalidInput", err)
		}
	})

	t.Run("missing file", func(t *testing.T) {
		_, err := ParseAgentExport(filepath.Join(t.TempDir(), "absent.json"))
		if !domain.Of(err, domain.IOError) {
			t.Fatalf("error = %v, want IOError", err)
		}
	})
}
