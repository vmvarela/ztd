package domain

import "time"

// DocumentKind is the closed vocabulary of documents: the records the Markdown
// skills used to keep as files, now rows owned by one scope.
type DocumentKind string

const (
	DocumentKnowledge      DocumentKind = "knowledge"
	DocumentKnowledgeIndex DocumentKind = "knowledge_index"
	DocumentProjectNote    DocumentKind = "project_note"
	DocumentPlanDaily      DocumentKind = "plan_daily"
	DocumentPlanWeekly     DocumentKind = "plan_weekly"
	DocumentReview         DocumentKind = "review"
	DocumentJournal        DocumentKind = "journal"
	DocumentCalendar       DocumentKind = "calendar"
	DocumentAdoption       DocumentKind = "adoption"
	DocumentPassion        DocumentKind = "passion"
	DocumentRoutine        DocumentKind = "routine"
)

// DocumentStatus is the verification state of one document.
type DocumentStatus string

const (
	DocumentDraft      DocumentStatus = "draft"
	DocumentVerified   DocumentStatus = "verified"
	DocumentSuperseded DocumentStatus = "superseded"
)

// Document is one Markdown-shaped record identified by (scope, kind, slug).
type Document struct {
	ID        string         `json:"id"`
	Scope     string         `json:"scope"`
	Kind      string         `json:"kind"`
	Slug      string         `json:"slug"`
	Title     string         `json:"title"`
	Body      string         `json:"body"`
	Status    DocumentStatus `json:"status"`
	Sources   []string       `json:"sources,omitempty"`
	ProjectID *ProjectID     `json:"project_id,omitempty"`
	Revision  Revision       `json:"revision"`
	CreatedAt time.Time      `json:"created_at"`
	UpdatedAt time.Time      `json:"updated_at"`
}

// ValidDocumentKind reports whether k is one of the eleven document kinds.
func ValidDocumentKind(k DocumentKind) bool {
	switch k {
	case DocumentKnowledge, DocumentKnowledgeIndex, DocumentProjectNote,
		DocumentPlanDaily, DocumentPlanWeekly, DocumentReview, DocumentJournal,
		DocumentCalendar, DocumentAdoption, DocumentPassion, DocumentRoutine:
		return true
	}
	return false
}

// ValidDocumentStatus reports whether s is one of the three document states.
func ValidDocumentStatus(s DocumentStatus) bool {
	switch s {
	case DocumentDraft, DocumentVerified, DocumentSuperseded:
		return true
	}
	return false
}
