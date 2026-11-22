package store

import (
	"fmt"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// TestCommitPlanMITLimit is table-driven over the daily MIT rule: 1..3 need no
// override, anything else needs a matching daily_limit_overrides(mit) row.
func TestCommitPlanMITLimit(t *testing.T) {
	const period = "2026-11-19"
	type overrideRow struct{ id, date string }
	cases := []struct {
		name       string
		mitCount   int
		overrideID string
		row        *overrideRow
		wantFamily domain.Family // empty means the commit must succeed
	}{
		{name: "one mit needs no override", mitCount: 1},
		{name: "three mits need no override", mitCount: 3},
		{name: "four mits without override are rejected", mitCount: 4, wantFamily: domain.RulesAcknowledgement},
		{name: "zero mits without override are rejected", mitCount: 0, wantFamily: domain.RulesAcknowledgement},
		{name: "four mits with a matching override row", mitCount: 4, row: &overrideRow{id: "ovr-a", date: period}},
		{name: "zero mits with a matching override id", mitCount: 0, overrideID: "ovr-b", row: &overrideRow{id: "ovr-b", date: period}},
		{name: "override for another local date does not apply", mitCount: 4, overrideID: "ovr-c",
			row: &overrideRow{id: "ovr-c", date: "2000-01-01"}, wantFamily: domain.InvalidInput},
		{name: "unknown override id does not apply", mitCount: 4, overrideID: "ovr-missing", wantFamily: domain.InvalidInput},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := newTestEnv(t)
			items := e.workItems(4, "mit")
			if tc.row != nil {
				e.mustExec(`INSERT INTO daily_limit_overrides (id, actor_id, local_date, rule, reason, created_by, created_at)
					VALUES (?, 'tester', ?, 'mit', 'test override', 'test', ?)`,
					tc.row.id, tc.row.date, fmtTime(e.now))
			}
			planItems := make([]domain.PlanItem, 0, tc.mitCount)
			for i := 0; i < tc.mitCount; i++ {
				planItems = append(planItems, domain.PlanItem{WorkItemID: items[i].ID, Role: domain.MITRole})
			}
			cmd := app.CommitPlanCmd{
				Binding: e.binding, Key: "plan-1", Kind: domain.DailyPlan,
				Period: period, Items: planItems, OverrideID: tc.overrideID,
			}
			before := e.counts()
			plan, err := e.s.CommitPlan(e.ctx(), cmd, e.now)
			if tc.wantFamily != "" {
				wantFamily(t, err, tc.wantFamily)
				if after := e.counts(); after != before {
					t.Fatalf("rejected commit wrote state: before %v after %v", before, after)
				}
				return
			}
			if err != nil {
				t.Fatalf("CommitPlan: %v", err)
			}
			if plan.Revision != 1 || plan.Status != domain.CommittedPlan {
				t.Fatalf("plan = revision %d status %s", plan.Revision, plan.Status)
			}
			if len(plan.Items) != tc.mitCount {
				t.Fatalf("plan has %d items, want %d", len(plan.Items), tc.mitCount)
			}
			for i, it := range plan.Items {
				if it.Position != i {
					t.Errorf("item %d position = %d", i, it.Position)
				}
			}
			if n := e.count(`SELECT count(*) FROM plans`); n != 1 {
				t.Fatalf("plans = %d, want 1", n)
			}
			if n := e.count(`SELECT count(*) FROM plan_items`); n != tc.mitCount {
				t.Fatalf("plan_items = %d, want %d", n, tc.mitCount)
			}
			if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'plan'`); n != 1 {
				t.Fatalf("plan history = %d, want 1", n)
			}
			// Identical retry replays the stored plan without further writes.
			replay, err := e.s.CommitPlan(e.ctx(), cmd, e.now.Add(time.Hour))
			if err != nil {
				t.Fatalf("replay: %v", err)
			}
			mustJSONEqual(t, plan, replay, "replayed plan")
			if n := e.count(`SELECT count(*) FROM idempotency_records WHERE command = 'commit_plan'`); n != 1 {
				t.Fatalf("commit_plan idempotency records = %d, want 1", n)
			}
		})
	}
}

func TestCommitPlanScopeAndRoleValidation(t *testing.T) {
	t.Run("cross-scope work item is rejected and nothing is written", func(t *testing.T) {
		e := newTestEnv(t)
		good := e.workItems(1, "g")
		e.mustExec(`INSERT INTO scopes (id, name, kind, created_at) VALUES ('other','other','personal',?)`, fmtTime(e.now))
		e.insertItem("T-19990303-001", "other", "foreign task", domain.Next, e.now)
		before := e.counts()
		_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
			Binding: e.binding, Key: "x1", Kind: domain.DailyPlan, Period: "2026-11-19",
			Items: []domain.PlanItem{
				{WorkItemID: good[0].ID, Role: domain.MITRole},
				{WorkItemID: "T-19990303-001", Role: domain.MITRole},
			},
		}, e.now)
		wantFamily(t, err, domain.ScopeDenied)
		if after := e.counts(); after != before {
			t.Fatalf("cross-scope commit wrote state: before %v after %v", before, after)
		}
	})

	t.Run("binding scope outside the profile is rejected", func(t *testing.T) {
		e := newTestEnv(t)
		good := e.workItems(1, "g")
		foreign := domain.ScopeBinding{
			Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"other"},
		}
		_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
			Binding: foreign, Key: "x2", Kind: domain.DailyPlan, Period: "2026-11-19",
			Items: []domain.PlanItem{{WorkItemID: good[0].ID, Role: domain.MITRole}},
		}, e.now)
		wantFamily(t, err, domain.ScopeDenied)
	})

	t.Run("unknown work item is not_found", func(t *testing.T) {
		e := newTestEnv(t)
		_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
			Binding: e.binding, Key: "x3", Kind: domain.DailyPlan, Period: "2026-11-19",
			Items: []domain.PlanItem{{WorkItemID: "T-19990909-999", Role: domain.MITRole}},
		}, e.now)
		wantFamily(t, err, domain.NotFound)
	})

	t.Run("duplicate and invalid roles are rejected", func(t *testing.T) {
		e := newTestEnv(t)
		items := e.workItems(2, "d")
		_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
			Binding: e.binding, Key: "x4", Kind: domain.DailyPlan, Period: "2026-11-19",
			Items: []domain.PlanItem{
				{WorkItemID: items[0].ID, Role: domain.MITRole},
				{WorkItemID: items[0].ID, Role: domain.BatchRole},
			},
		}, e.now)
		wantFamily(t, err, domain.InvalidInput)
		_, err = e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
			Binding: e.binding, Key: "x5", Kind: domain.DailyPlan, Period: "2026-11-19",
			Items: []domain.PlanItem{{WorkItemID: items[0].ID, Role: "goal"}},
		}, e.now)
		wantFamily(t, err, domain.InvalidInput)
	})

	t.Run("weekly accepts big_rock and batch but not mit", func(t *testing.T) {
		e := newTestEnv(t)
		items := e.workItems(2, "w")
		plan, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
			Binding: e.binding, Key: "x6", Kind: domain.WeeklyPlan, Period: "2026-W47",
			Items: []domain.PlanItem{
				{WorkItemID: items[0].ID, Role: domain.BigRockRole},
				{WorkItemID: items[1].ID, Role: domain.BatchRole},
			},
		}, e.now)
		if err != nil {
			t.Fatalf("weekly commit: %v", err)
		}
		if plan.Revision != 1 || plan.Kind != domain.WeeklyPlan || len(plan.Items) != 2 {
			t.Fatalf("weekly plan = %+v", plan)
		}
		// The plan now sits at revision 1; a wrong revision fails before role
		// validation, so pass the expected revision to reach the role check.
		_, err = e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
			Binding: e.binding, Key: "x7", Kind: domain.WeeklyPlan, Period: "2026-W47", Expected: 1,
			Items: []domain.PlanItem{{WorkItemID: items[0].ID, Role: domain.MITRole}},
		}, e.now)
		wantFamily(t, err, domain.InvalidInput)
		if n := e.count(`SELECT count(*) FROM plan_items`); n != 2 {
			t.Fatalf("plan_items after rejected commit = %d, want the original 2", n)
		}
	})
}

func TestPrepareBrief(t *testing.T) {
	e := newTestEnv(t)
	mitItems := e.workItems(2, "m")
	for i := 0; i < 10; i++ {
		e.insertItem(fmt.Sprintf("T-19990404-%03d", i), "personal",
			fmt.Sprintf("next item %d", i), domain.Next, e.now.Add(time.Duration(i+1)*time.Minute))
	}
	e.insertItem("T-19990404-100", "personal", "waiting a", domain.Waiting, e.now.Add(time.Minute))
	e.insertItem("T-19990404-101", "personal", "waiting b", domain.Waiting, e.now.Add(2*time.Minute))

	plan, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
		Binding: e.binding, Key: "pl", Kind: domain.DailyPlan, Period: "2026-11-19",
		Items: []domain.PlanItem{
			{WorkItemID: mitItems[0].ID, Role: domain.MITRole},
			{WorkItemID: mitItems[1].ID, Role: domain.MITRole},
		},
	}, e.now)
	if err != nil {
		t.Fatalf("CommitPlan: %v", err)
	}
	if plan.Revision != 1 {
		t.Fatalf("plan revision = %d", plan.Revision)
	}

	brief, err := e.s.Prepare(e.ctx(), e.binding, "2026-11-19")
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	if brief.Profile != "personal" || brief.Date != "2026-11-19" {
		t.Fatalf("brief identity = %+v", brief)
	}
	if brief.Plan == nil || brief.Plan.Revision != 1 || len(brief.Plan.Items) != 2 {
		t.Fatalf("brief plan = %+v", brief.Plan)
	}
	if len(brief.MITs) != 2 || brief.MITs[0].ID != mitItems[0].ID || brief.MITs[1].ID != mitItems[1].ID {
		t.Fatalf("MITs = %+v, want the two plan items in order", brief.MITs)
	}
	if len(brief.Next) != 10 {
		t.Fatalf("next = %d rows, want the capped 10", len(brief.Next))
	}
	if brief.Next[0].Title != "next item 9" {
		t.Fatalf("first next = %q, want the most recently updated", brief.Next[0].Title)
	}
	if len(brief.Waiting) != 2 {
		t.Fatalf("waiting = %d rows, want 2", len(brief.Waiting))
	}
	for _, w := range brief.Waiting {
		if w.WaitingOn == "" {
			t.Fatalf("waiting item %s has no waiting_on", w.ID)
		}
	}
	if len(brief.NeedsHuman) != 0 {
		t.Fatalf("NeedsHuman = %v, want empty in Pass 1", brief.NeedsHuman)
	}

	// Another date has no plan but the same visible lists.
	other, err := e.s.Prepare(e.ctx(), e.binding, "2026-11-20")
	if err != nil {
		t.Fatalf("Prepare other date: %v", err)
	}
	if other.Plan != nil || len(other.MITs) != 0 || len(other.Next) != 10 {
		t.Fatalf("other date brief = plan %v mits %d next %d", other.Plan, len(other.MITs), len(other.Next))
	}

	// An unknown profile is not_found instead of an invented brief.
	ghost := domain.ScopeBinding{Profile: "ghost", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}
	if _, err := e.s.Prepare(e.ctx(), ghost, "2026-11-19"); !domain.Of(err, domain.NotFound) {
		t.Fatalf("unknown profile: got %v, want not_found", err)
	}
}
