package domain

import "time"

type ProcessingState string

const (
	Pending   ProcessingState = "pending"
	Processed ProcessingState = "processed"
	Discarded ProcessingState = "discarded"
	Deferred  ProcessingState = "deferred"
)

type OutcomeKind string

const (
	OutcomeWorkItems OutcomeKind = "work_items"
	OutcomeReference OutcomeKind = "reference"
	OutcomeImmediate OutcomeKind = "immediate"
	OutcomeDiscard   OutcomeKind = "discard"
	OutcomeDefer     OutcomeKind = "defer"
)

type Capture struct {
	ID               CaptureID       `json:"id"`
	Scope            ScopeID         `json:"scope"`
	SourceID         string          `json:"source_id"`
	ExternalID       *string         `json:"external_id,omitempty"`
	ExternalRevision *string         `json:"external_revision,omitempty"`
	OriginalText     string          `json:"original_text"`
	ContentHash      string          `json:"content_hash"`
	SourceURI        *string         `json:"source_uri,omitempty"`
	OccurredAt       *time.Time      `json:"occurred_at,omitempty"`
	CapturedAt       time.Time       `json:"captured_at"`
	State            ProcessingState `json:"processing_state"`
	Outcome          *Outcome        `json:"processing_outcome,omitempty"`
	ReviewAfter      *time.Time      `json:"review_after,omitempty"`
	Revision         Revision        `json:"revision"`
}

type Outcome struct {
	DocumentID     string      `json:"document_id,omitempty"`
	Kind           OutcomeKind `json:"kind"`
	Titles         []string    `json:"titles,omitempty"`
	ProjectID      *ProjectID  `json:"project_id,omitempty"`
	AreaID         *AreaID     `json:"area_id,omitempty"`
	ContextID      *ContextID  `json:"context_id,omitempty"`
	WaitingOn      string      `json:"waiting_on,omitempty"`
	ReviewAfter    *time.Time  `json:"review_after,omitempty"`
	Reason         string      `json:"reason,omitempty"`
	ResultEvidence string      `json:"result_evidence,omitempty"`
}

func (c Capture) Due(now time.Time) bool {
	if c.State != Deferred || c.ReviewAfter == nil {
		return false
	}
	return !c.ReviewAfter.After(now)
}
