package domain

import "time"

// ScopeKind is the closed, generic vocabulary for a scope. It carries no
// provider or product name: scopes are user configuration, not constants.
type ScopeKind string

const (
	ScopeKindPersonal   ScopeKind = "personal"
	ScopeKindWork       ScopeKind = "work"
	ScopeKindClient     ScopeKind = "client"
	ScopeKindOpensource ScopeKind = "opensource"
)

// Scope is one user-declared authorization boundary. Every capture, work
// item, source and project belongs to exactly one scope.
type Scope struct {
	ID        ScopeID   `json:"id"`
	Name      string    `json:"name"`
	Kind      ScopeKind `json:"kind"`
	CreatedAt time.Time `json:"created_at"`
}
