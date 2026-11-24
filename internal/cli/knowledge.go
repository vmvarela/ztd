package cli

import (
	"context"
	"flag"
	"io"
	"os"
	"ztd/internal/app"
	"ztd/internal/domain"
)

func (c *CLI) knowledge(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: knowledge search|read|save|related [flags]")
	}
	fs := flag.NewFlagSet("knowledge "+args[0], flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	slug := fs.String("slug", "", "page slug")
	query := fs.String("query", "", "search words")
	limit := fs.Int("limit", 10, "maximum hits")
	title := fs.String("title", "", "title")
	body := fs.String("body", "", "Markdown body")
	file := fs.String("file", "", "Markdown file")
	project := fs.String("project", "", "project ID")
	expected := fs.Int64("expected", 0, "0 creates; current revision updates")
	status := fs.String("status", "draft", "draft|verified|superseded")
	var sources stringList
	fs.Var(&sources, "source", "source reference (repeatable)")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("unexpected positional arguments")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	var out any
	switch args[0] {
	case "search":
		out, err = svc.SearchKnowledge(ctx, b, app.KnowledgeQuery{Query: *query, Project: domain.ProjectID(*project), Limit: *limit})
	case "read":
		out, err = svc.ReadKnowledge(ctx, b, domain.ScopeID(*scope), *slug)
	case "related":
		out, err = svc.RelatedKnowledge(ctx, b, domain.ScopeID(*scope), *slug)
	case "save":
		if *file != "" {
			if *body != "" {
				return domain.Invalid("choose body or file")
			}
			data, e := os.ReadFile(*file)
			if e != nil {
				return e
			}
			*body = string(data)
		}
		cmd := app.DocumentCmd{Binding: b, Slug: *slug, Title: *title, Body: *body, Sources: sources, Expected: domain.Revision(*expected), Status: domain.DocumentStatus(*status)}
		if *project != "" {
			id := domain.ProjectID(*project)
			cmd.ProjectID = &id
		}
		out, err = svc.SaveKnowledge(ctx, cmd)
	default:
		return domain.Invalid("unknown knowledge command %q", args[0])
	}
	if err != nil {
		return err
	}
	c.succeed("knowledge "+args[0], out)
	return nil
}

func (c *CLI) planShow(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("plan show", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "daily", "daily|weekly")
	period := fs.String("period", "", "period")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.Repo.ReadPlan(ctx, b, domain.PlanKind(*kind), *period)
	if err != nil {
		return err
	}
	c.succeed("plan show", out)
	return nil
}

func (c *CLI) reviewPage(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("review "+args[0], flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "required scope")
	kind := fs.String("kind", "daily", "review kind")
	period := fs.String("period", "", "period")
	outcomes := fs.String("outcomes", "", "outcomes")
	coverage := fs.String("coverage", "", "what was checked")
	key := fs.String("key", "", "retry key")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	var out any
	if args[0] == "show" {
		out, err = svc.Repo.ReadReview(ctx, b, *kind, *period)
	} else {
		if *key == "" {
			*key = newKey("review")
		}
		out, err = svc.Repo.RecordReview(ctx, app.ReviewCmd{Binding: b, Key: *key, Kind: *kind, Period: *period, Outcomes: *outcomes, Coverage: *coverage, Complete: true}, svc.Now())
	}
	if err != nil {
		return err
	}
	c.succeed("review "+args[0], out)
	return nil
}

func (c *CLI) settings(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("settings", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	zone := fs.String("timezone", "", "IANA timezone, e.g. Europe/Madrid")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	var out domain.Settings
	if *zone == "" {
		out, err = svc.Repo.Settings(ctx)
	} else {
		out, err = svc.Repo.SetTimezone(ctx, *zone)
	}
	if err != nil {
		return err
	}
	c.succeed("settings", out)
	return nil
}
