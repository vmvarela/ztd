package domain

import (
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// MaxSourceItemBytes bounds one captured item, matching manual capture.
	MaxSourceItemBytes = 64 * 1024
	// MaxSourceBatchItems bounds one reported batch so a single writer cannot
	// be held by an arbitrarily large transaction.
	MaxSourceBatchItems = 500
	// MaxSourceConfigItems bounds one user source configuration file.
	MaxSourceConfigItems = 200
)

type SourceKind string

const (
	SourceKindCapture  SourceKind = "capture"
	SourceKindCalendar SourceKind = "calendar"
)

type SourceConnector string

const (
	SourceConnectorManual    SourceConnector = "manual"
	SourceConnectorDirectory SourceConnector = "directory"
	SourceConnectorHostMCP   SourceConnector = "host_mcp"
)

type CoverageState string

const (
	CoverageUnknown    CoverageState = "unknown"
	CoverageUnverified CoverageState = "unverified"
	CoveragePartial    CoverageState = "partial"
	CoverageComplete   CoverageState = "complete"
	CoverageFailed     CoverageState = "failed"
)

// Source is one registered origin of captures: a manual entry point, a
// directory scan or a host-side MCP connector. Cursor and coverage describe
// how far retrieval has reliably reached; secrets are never part of it.
type Source struct {
	ID             string          `json:"id"`
	Name           string          `json:"name"`
	Scope          ScopeID         `json:"scope"`
	Kind           SourceKind      `json:"kind"`
	Connector      SourceConnector `json:"connector"`
	Provider       string          `json:"provider"`
	ConnectionRef  string          `json:"connection_ref"`
	NonSecretQuery string          `json:"non_secret_query"`
	Cadence        string          `json:"cadence"`
	AuthState      string          `json:"auth_state"`
	Coverage       CoverageState   `json:"coverage"`
	Cursor         string          `json:"cursor"`
	LastAttemptAt  *time.Time      `json:"last_attempt_at,omitempty"`
	LastSuccessAt  *time.Time      `json:"last_success_at,omitempty"`
	CreatedAt      time.Time       `json:"created_at"`
	UpdatedAt      time.Time       `json:"updated_at"`
}

// SourceRetrieval describes one retrieval window a batch was built from.
type SourceRetrieval struct {
	Window                string   `json:"window"`
	Cursor                string   `json:"cursor"`
	RequestedLimit        int      `json:"requested_limit"`
	ProviderReturnedLimit int      `json:"provider_returned_limit"`
	CompleteWindow        bool     `json:"complete_window"`
	Truncated             bool     `json:"truncated"`
	Failures              []string `json:"failures"`
}

// SourceItem is one external entry reported inside a batch. An external id,
// when set, always carries its revision so a changed revision is a new
// capture and an identical triple is the same capture.
type SourceItem struct {
	ExternalID              string     `json:"external_id"`
	ExternalRevision        string     `json:"external_revision"`
	OriginalText            string     `json:"original_text"`
	SourceURI               string     `json:"source_uri,omitempty"`
	OccurredAt              *time.Time `json:"occurred_at,omitempty"`
	ProviderMetadataSummary string     `json:"provider_metadata_summary,omitempty"`
}

// Validate checks the item-level rules: non-empty UTF-8 text within the size
// bound and an external id with its revision or neither.
func (i SourceItem) Validate() error {
	if strings.TrimSpace(i.OriginalText) == "" {
		return Invalid("source item text is required")
	}
	if len(i.OriginalText) > MaxSourceItemBytes {
		return Invalid("source item text exceeds %d bytes", MaxSourceItemBytes)
	}
	if !utf8.ValidString(i.OriginalText) {
		return Invalid("source item text must be valid UTF-8")
	}
	if (i.ExternalID == "") != (i.ExternalRevision == "") {
		return Invalid("external id and external revision must be provided together")
	}
	return nil
}

// SourceReview is the recorded outcome of one reported or observed batch for
// one source.
type SourceReview struct {
	ID         string          `json:"id"`
	SourceID   string          `json:"source_id"`
	BatchID    string          `json:"batch_id"`
	ResultKind string          `json:"result_kind"`
	Coverage   CoverageState   `json:"coverage"`
	Retrieval  SourceRetrieval `json:"retrieval"`
	CaptureIDs []CaptureID     `json:"capture_ids"`
	CreatedAt  time.Time       `json:"created_at"`
}

var sourceIDPattern = regexp.MustCompile(`^[a-z][a-z0-9_-]{1,63}$`)

// ValidSourceID reports whether id matches [a-z][a-z0-9_-]{1,63}.
func ValidSourceID(id string) bool { return sourceIDPattern.MatchString(id) }
