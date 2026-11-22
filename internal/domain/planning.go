package domain

import "time"

type ProfileKind string

const (
	PersonalProfile   ProfileKind = "personal"
	WorkClientProfile ProfileKind = "work_client"
)

type Profile struct {
	ID         ProfileID   `json:"id"`
	Name       string      `json:"name"`
	Kind       ProfileKind `json:"kind"`
	OwnerActor ActorID     `json:"owner_actor_id"`
	Timezone   string      `json:"timezone"`
	Status     string      `json:"status"`
	Scopes     []ScopeID   `json:"scopes"`
}

type PlanKind string

const (
	DailyPlan  PlanKind = "daily"
	WeeklyPlan PlanKind = "weekly"
)

type PlanStatus string

const (
	OpenPlan      PlanStatus = "open"
	CommittedPlan PlanStatus = "committed"
)

type PlanRole string

const (
	MITRole     PlanRole = "mit"
	BigRockRole PlanRole = "big_rock"
	BatchRole   PlanRole = "batch"
)

type PlanItem struct {
	WorkItemID WorkItemID `json:"work_item_id"`
	Role       PlanRole   `json:"role"`
	Position   int        `json:"position"`
}

type Plan struct {
	ID        PlanID     `json:"id"`
	Profile   ProfileID  `json:"profile"`
	Kind      PlanKind   `json:"kind"`
	Period    string     `json:"period"`
	Status    PlanStatus `json:"status"`
	Revision  Revision   `json:"revision"`
	Items     []PlanItem `json:"items,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
}

type DailyLimitOverride struct {
	ID        string    `json:"id"`
	Actor     ActorID   `json:"actor_id"`
	LocalDate string    `json:"local_date"`
	Rule      string    `json:"rule"`
	Reason    string    `json:"reason"`
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
}

type CalendarReviewAssertion struct {
	ID        string    `json:"id"`
	Profile   ProfileID `json:"profile_id"`
	Actor     ActorID   `json:"actor_id"`
	LocalDate string    `json:"local_date"`
	Statement string    `json:"statement"`
	CreatedAt time.Time `json:"created_at"`
}

type Goal struct {
	ID        string    `json:"id"`
	Profile   ProfileID `json:"profile_id"`
	Kind      string    `json:"kind"`
	StartOn   string    `json:"start_on"`
	EndOn     string    `json:"end_on,omitempty"`
	Statement string    `json:"statement"`
	Status    string    `json:"status"`
}
