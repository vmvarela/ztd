package domain

import (
	"regexp"
	"strings"
	"time"
)

type (
	ScopeID     string
	ProfileID   string
	ActorID     string
	ContextID   string
	AreaID      string
	ProjectID   string
	CaptureID   string
	WorkItemID  string
	PlanID      string
	RoutineID   string
	ReviewID    string
	FocusID     string
	KnowledgeID string
)

type Revision int64

func (r Revision) Next() Revision { return r + 1 }

var taskIDPattern = regexp.MustCompile(`^T-\d{8}-\d{3,}$`)

func ValidTaskID(s string) bool { return taskIDPattern.MatchString(s) }

// ScopeBinding is frozen for a session by the host. Model arguments cannot widen it.
type ScopeBinding struct {
	Profile ProfileID `json:"profile"`
	Actor   ActorID   `json:"actor"`
	Scopes  []ScopeID `json:"scopes"`
}

func (b ScopeBinding) Allows(s ScopeID) bool {
	for _, allowed := range b.Scopes {
		if allowed == s {
			return true
		}
	}
	return false
}

func (b ScopeBinding) Validate() error {
	if strings.TrimSpace(string(b.Profile)) == "" {
		return Invalid("profile is required")
	}
	if strings.TrimSpace(string(b.Actor)) == "" {
		return Invalid("actor is required")
	}
	if len(b.Scopes) == 0 {
		return Invalid("at least one scope is required")
	}
	return nil
}

func NowUTC() time.Time { return time.Now().UTC().Truncate(time.Second) }

func FormatDate(t time.Time) string { return t.UTC().Format("2006-01-02") }
