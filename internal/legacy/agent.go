package legacy

import (
	"encoding/json"
	"os"
	"regexp"

	"ztd/internal/domain"
)

// requestSHA256Pattern accepts exactly 64 hex digits in either case. The
// export stores lowercase; uppercase is accepted and never rewritten, and any
// non-hex character is rejected.
var requestSHA256Pattern = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

// ParseAgentExport reads a legacy agent-continuity export. Only the
// "ztd-agent-export" format in version 1 or 2 is accepted; every structural
// or referential inconsistency is rejected with domain.Invalid. A read failure
// (missing or unreadable file) is an IOError. Nothing is written.
func ParseAgentExport(path string) (*AgentExport, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, domain.NewError(domain.IOError, "agent export %s: %v", path, err)
	}
	var doc AgentExport
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, domain.Invalid("agent export: invalid JSON: %v", err)
	}
	if err := validateAgentExport(&doc); err != nil {
		return nil, err
	}
	return &doc, nil
}

// validateAgentExport enforces the invariants the legacy restore path also
// checks: unique ids everywhere, assignments bound to a known scope with a
// valid status and rev >= 1, checkpoints bound to their parent with kind
// progress|done and rev in [2, parent.Rev] (unique per assignment), each
// assignment's rev equal to 1 plus its checkpoint count, operations with a
// unique key, a 64-hex request_sha256 and a valid result_json, and knowledge
// only in version 2 with a known scope, kind fact|decision|constraint|
// procedure and rev exactly 1.
func validateAgentExport(doc *AgentExport) error {
	if doc.Format != "ztd-agent-export" {
		return domain.Invalid("agent export: unsupported format %q", doc.Format)
	}
	if doc.Version != 1 && doc.Version != 2 {
		return domain.Invalid("agent export: unsupported version %d", doc.Version)
	}

	scopes := make(map[string]bool, len(doc.Scopes))
	for _, s := range doc.Scopes {
		if s.ID == "" {
			return domain.Invalid("agent export: empty scope id")
		}
		if scopes[s.ID] {
			return domain.Invalid("agent export: duplicate scope %q", s.ID)
		}
		scopes[s.ID] = true
	}

	assignments := make(map[string]AgentAssignment, len(doc.Assignments))
	for _, a := range doc.Assignments {
		if a.ID == "" {
			return domain.Invalid("agent export: empty assignment id")
		}
		if _, dup := assignments[a.ID]; dup {
			return domain.Invalid("agent export: duplicate assignment %q", a.ID)
		}
		if !scopes[a.ScopeID] {
			return domain.Invalid("agent export: assignment %q references unknown scope %q", a.ID, a.ScopeID)
		}
		switch a.Status {
		case "open", "done", "cancelled":
		default:
			return domain.Invalid("agent export: assignment %q has invalid status %q", a.ID, a.Status)
		}
		if a.Rev < 1 {
			return domain.Invalid("agent export: assignment %q has rev %d", a.ID, a.Rev)
		}
		assignments[a.ID] = a
	}

	checkpointIDs := make(map[string]bool, len(doc.Checkpoints))
	revSeen := make(map[string]map[int]bool, len(doc.Assignments))
	checkpointCount := make(map[string]int, len(doc.Assignments))
	for _, c := range doc.Checkpoints {
		if c.ID == "" {
			return domain.Invalid("agent export: empty checkpoint id")
		}
		if checkpointIDs[c.ID] {
			return domain.Invalid("agent export: duplicate checkpoint %q", c.ID)
		}
		checkpointIDs[c.ID] = true
		parent, ok := assignments[c.AssignmentID]
		if !ok {
			return domain.Invalid("agent export: checkpoint %q references unknown assignment %q", c.ID, c.AssignmentID)
		}
		switch c.Kind {
		case "progress", "done":
		default:
			return domain.Invalid("agent export: checkpoint %q has invalid kind %q", c.ID, c.Kind)
		}
		if c.Rev < 2 || c.Rev > parent.Rev {
			return domain.Invalid("agent export: checkpoint %q rev %d outside [2, %d]", c.ID, c.Rev, parent.Rev)
		}
		if revSeen[c.AssignmentID] == nil {
			revSeen[c.AssignmentID] = map[int]bool{}
		}
		if revSeen[c.AssignmentID][c.Rev] {
			return domain.Invalid("agent export: duplicate checkpoint rev %d on assignment %q", c.Rev, c.AssignmentID)
		}
		revSeen[c.AssignmentID][c.Rev] = true
		checkpointCount[c.AssignmentID]++
	}
	for _, a := range doc.Assignments {
		if a.Rev != 1+checkpointCount[a.ID] {
			return domain.Invalid("agent export: assignment %q rev %d does not equal 1 + %d checkpoints", a.ID, a.Rev, checkpointCount[a.ID])
		}
	}

	opKeys := make(map[string]bool, len(doc.Operations))
	for _, op := range doc.Operations {
		if op.Key == "" {
			return domain.Invalid("agent export: empty operation key")
		}
		if opKeys[op.Key] {
			return domain.Invalid("agent export: duplicate operation key %q", op.Key)
		}
		opKeys[op.Key] = true
		if !requestSHA256Pattern.MatchString(op.RequestSHA256) {
			return domain.Invalid("agent export: operation %q has invalid request_sha256", op.Key)
		}
		if !json.Valid([]byte(op.ResultJSON)) {
			return domain.Invalid("agent export: operation %q has invalid result_json", op.Key)
		}
	}

	if doc.Version == 1 && len(doc.Knowledge) > 0 {
		return domain.Invalid("agent export: version-1 document carries knowledge")
	}
	knowledgeIDs := make(map[string]bool, len(doc.Knowledge))
	for _, k := range doc.Knowledge {
		if k.ID == "" {
			return domain.Invalid("agent export: empty knowledge id")
		}
		if knowledgeIDs[k.ID] {
			return domain.Invalid("agent export: duplicate knowledge %q", k.ID)
		}
		knowledgeIDs[k.ID] = true
		if !scopes[k.Scope] {
			return domain.Invalid("agent export: knowledge %q references unknown scope %q", k.ID, k.Scope)
		}
		switch k.Kind {
		case "fact", "decision", "constraint", "procedure":
		default:
			return domain.Invalid("agent export: knowledge %q has invalid kind %q", k.ID, k.Kind)
		}
		if k.Rev != 1 {
			return domain.Invalid("agent export: knowledge %q has rev %d, want 1", k.ID, k.Rev)
		}
	}
	return nil
}
