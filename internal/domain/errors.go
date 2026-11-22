package domain

import (
	"errors"
	"fmt"
)

type Family string

const (
	InvalidInput             Family = "invalid_input"
	InvalidTransition        Family = "invalid_transition"
	NotFound                 Family = "not_found"
	ScopeDenied              Family = "scope_denied"
	HumanDecisionRequired    Family = "human_decision_required"
	RulesAcknowledgement     Family = "rules_acknowledgement_required"
	StaleRevision            Family = "stale_revision"
	IdempotencyConflict      Family = "idempotency_conflict"
	FocusConflict            Family = "focus_conflict"
	SourceCoverageIncomplete Family = "source_coverage_incomplete"
	ExternalOutcomeUnknown   Family = "external_outcome_unknown"
	UnsupportedFormat        Family = "unsupported_format"
	DestinationNotEmpty      Family = "destination_not_empty"
	DBBusy                   Family = "db_busy"
	DBIncompatible           Family = "db_incompatible"
	IOError                  Family = "io_error"
	PendingTransaction       Family = "pending_transaction"
	Conflict                 Family = "conflict"
)

type Error struct {
	Family Family `json:"family"`
	Detail string `json:"detail"`
}

func (e *Error) Error() string { return string(e.Family) + ": " + e.Detail }

func NewError(f Family, format string, args ...any) *Error {
	return &Error{Family: f, Detail: fmt.Sprintf(format, args...)}
}

func Invalid(format string, args ...any) *Error {
	return NewError(InvalidInput, format, args...)
}

func Of(err error, family Family) bool {
	var target *Error
	return errors.As(err, &target) && target.Family == family
}

func FamilyOf(err error) Family {
	var target *Error
	if errors.As(err, &target) {
		return target.Family
	}
	return IOError
}
