package cli

import (
	"context"
	"flag"
	"io"
	"ztd/internal/app"
	"ztd/internal/domain"
)

func (c *CLI) task(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: task list|show|update|done|cancel [flags]")
	}
	fs := flag.NewFlagSet("task "+args[0], flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	id := fs.String("id", "", "task ID")
	state := fs.String("status", "", "task status")
	key := fs.String("key", "", "idempotency key")
	expected := fs.Int64("expected", 0, "current revision")
	title := fs.String("title", "", "title")
	waiting := fs.String("waiting-on", "", "dependency")
	resolution := fs.String("resolution", "", "result")
	project := fs.String("project", "", "project ID or empty to clear")
	contextID := fs.String("context", "", "context ID or empty to clear")
	due := fs.String("due-at", "", "RFC3339 or empty to clear")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() > 0 {
		*id = fs.Arg(0)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	var out any
	switch args[0] {
	case "list":
		rows, e := svc.ListWorkItemsFiltered(ctx, b, app.ListWorkItemsFilter{Project: domain.ProjectID(*project)})
		if e != nil {
			return e
		}
		tasks := []domain.Task{}
		for _, w := range rows {
			t := w.Task()
			if *state == "" || t.Status == *state {
				tasks = append(tasks, t)
			}
		}
		out = tasks
	case "show":
		w, cp, e := svc.Repo.GetWorkItemWithCheckpoint(ctx, b, domain.WorkItemID(*id))
		if e != nil {
			return e
		}
		out = struct {
			Task       domain.Task        `json:"task"`
			Checkpoint *domain.Checkpoint `json:"checkpoint,omitempty"`
		}{w.Task(), cp}
	case "update", "done", "cancel":
		if *key == "" {
			*key = newKey("task")
		}
		in := app.TaskUpdate{ID: domain.WorkItemID(*id), Key: *key, Expected: domain.Revision(*expected), Status: *state}
		if args[0] == "done" {
			in.Status = "completed"
		}
		if args[0] == "cancel" {
			in.Status = "cancelled"
		}
		fs.Visit(func(f *flag.Flag) {
			switch f.Name {
			case "title":
				in.Title = title
			case "waiting-on":
				in.WaitingOn = waiting
			case "resolution":
				in.Resolution = resolution
			case "project":
				v := domain.ProjectID(*project)
				in.ProjectID = &v
			case "context":
				v := domain.ContextID(*contextID)
				in.ContextID = &v
			case "due-at":
				in.DueAt = due
			}
		})
		out, err = svc.UpdateTask(ctx, b, in)
	default:
		return domain.Invalid("unknown task command")
	}
	if err != nil {
		return err
	}
	c.succeed("task "+args[0], out)
	return nil
}
