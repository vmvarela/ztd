package legacy

import "time"

type Field struct {
	Key   string
	Value string
}

type Task struct {
	ID         string
	Title      string
	List       string
	Checkbox   string
	Fields     []Field
	Original   string
	SourcePath string
	Line       int
	Issues     []string
}

func (t Task) Field(key string) string {
	for _, f := range t.Fields {
		if f.Key == key {
			return f.Value
		}
	}
	return ""
}

type Context struct {
	Name string
}

type Project struct {
	ID             string
	Context        string
	Client         string
	Status         string
	DesiredOutcome string
	SourcePath     string
	Original       string
}

type Plan struct {
	Kind       string // daily | weekly
	Period     string
	SourcePath string
	IDs        []string
	MITs       []string
	BigRocks   []string
}

type Routine struct {
	ID              string
	Kind            string
	Cadence         string
	LastCompletedAt *time.Time
	Original        string
	SourcePath      string
}

type Issue struct {
	Entity   string
	ID       string
	Detail   string
	Original string
}

type Config struct {
	Format     int      `json:"format"`
	RequireFor []string `json:"-"`
	ClientOnly []string `json:"-"`
}

type Store struct {
	Root      string
	Config    Config
	Contexts  []Context
	Tasks     []Task
	Projects  []Project
	Plans     []Plan
	Routines  []Routine
	Documents map[string][]byte
	Issues    []Issue
}

type AgentExport struct {
	Format      string            `json:"format"`
	Version     int               `json:"version"`
	Scopes      []AgentScope      `json:"scopes"`
	Assignments []AgentAssignment `json:"assignments"`
	Checkpoints []AgentCheckpoint `json:"checkpoints"`
	Operations  []AgentOperation  `json:"operations"`
	Knowledge   []AgentKnowledge  `json:"knowledge"`
}

type AgentScope struct {
	ID string `json:"id"`
}

type AgentAssignment struct {
	ID          string  `json:"id"`
	ScopeID     string  `json:"scope_id"`
	Request     string  `json:"request"`
	Objective   *string `json:"objective"`
	Constraints *string `json:"constraints"`
	Project     *string `json:"project"`
	Status      string  `json:"status"`
	Rev         int     `json:"rev"`
	CreatedAt   string  `json:"created_at"`
	UpdatedAt   string  `json:"updated_at"`
}

type AgentCheckpoint struct {
	ID           string  `json:"id"`
	AssignmentID string  `json:"assignment_id"`
	Kind         string  `json:"kind"`
	Result       string  `json:"result"`
	Evidence     *string `json:"evidence"`
	NextAction   *string `json:"next_action"`
	Rev          int     `json:"rev"`
	CreatedAt    string  `json:"created_at"`
}

type AgentOperation struct {
	Key           string `json:"key"`
	RequestSHA256 string `json:"request_sha256"`
	ResultJSON    string `json:"result_json"`
	CreatedAt     string `json:"created_at"`
}

type AgentKnowledge struct {
	ID        string  `json:"id"`
	Scope     string  `json:"scope"`
	Kind      string  `json:"kind"`
	Text      string  `json:"text"`
	Source    *string `json:"source"`
	Rev       int     `json:"rev"`
	CreatedAt string  `json:"created_at"`
}
