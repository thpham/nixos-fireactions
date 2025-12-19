// Package gitlab provides a client for interacting with the GitLab Runners API.
package gitlab

import "time"

// CreateRunnerRequest represents the request body for POST /api/v4/user/runners
type CreateRunnerRequest struct {
	// RunnerType is the scope of the runner: "instance_type", "group_type", or "project_type"
	RunnerType string `json:"runner_type"`

	// GroupID is required for group_type runners
	GroupID int `json:"group_id,omitempty"`

	// ProjectID is required for project_type runners
	ProjectID int `json:"project_id,omitempty"`

	// Description is a human-readable description of the runner
	Description string `json:"description,omitempty"`

	// Paused indicates whether the runner should be paused after creation
	Paused bool `json:"paused,omitempty"`

	// Locked indicates whether the runner is locked to current project/group
	Locked bool `json:"locked,omitempty"`

	// RunUntagged indicates whether the runner can pick jobs without tags
	RunUntagged bool `json:"run_untagged,omitempty"`

	// TagList is a comma-separated list of tags for the runner
	TagList string `json:"tag_list,omitempty"`

	// AccessLevel determines which jobs the runner can pick
	// "not_protected" - runner can pick jobs from any branch
	// "ref_protected" - runner can only pick jobs from protected branches
	AccessLevel string `json:"access_level,omitempty"`

	// MaximumTimeout is the maximum job execution time in seconds
	MaximumTimeout int `json:"maximum_timeout,omitempty"`

	// MaintenanceNote is an optional note (max 1024 characters)
	MaintenanceNote string `json:"maintenance_note,omitempty"`
}

// CreateRunnerResponse represents the response from POST /api/v4/user/runners
type CreateRunnerResponse struct {
	// ID is the unique identifier of the created runner
	ID int `json:"id"`

	// Token is the runner authentication token (glrt-* prefix)
	// This value is only returned once and cannot be retrieved again
	Token string `json:"token"`

	// TokenExpiresAt is when the token expires (null if no expiration)
	TokenExpiresAt *time.Time `json:"token_expires_at"`
}

// Runner represents a registered runner in GitLab
type Runner struct {
	ID             int        `json:"id"`
	Description    string     `json:"description"`
	IPAddress      string     `json:"ip_address"`
	Active         bool       `json:"active"`
	Paused         bool       `json:"paused"`
	IsShared       bool       `json:"is_shared"`
	RunnerType     string     `json:"runner_type"`
	Name           string     `json:"name"`
	Online         bool       `json:"online"`
	Status         string     `json:"status"` // "online", "offline", "stale", "never_contacted"
	TagList        []string   `json:"tag_list"`
	RunUntagged    bool       `json:"run_untagged"`
	Locked         bool       `json:"locked"`
	MaximumTimeout int        `json:"maximum_timeout"`
	AccessLevel    string     `json:"access_level"`
	Version        string     `json:"version"`
	Revision       string     `json:"revision"`
	Platform       string     `json:"platform"`
	Architecture   string     `json:"architecture"`
	ContactedAt    *time.Time `json:"contacted_at"`
	CreatedAt      *time.Time `json:"created_at"`
}

// RunnerDetails represents detailed information about a runner
type RunnerDetails struct {
	Runner
	Projects []struct {
		ID                int    `json:"id"`
		Name              string `json:"name"`
		NameWithNamespace string `json:"name_with_namespace"`
		Path              string `json:"path"`
		PathWithNamespace string `json:"path_with_namespace"`
	} `json:"projects"`
	Groups []struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
		Path string `json:"path"`
	} `json:"groups"`
}

// ErrorResponse represents an error response from the GitLab API
type ErrorResponse struct {
	Message string `json:"message"`
	Error   string `json:"error"`
}

// Job represents a GitLab CI job
type Job struct {
	ID         int       `json:"id"`
	Status     string    `json:"status"`
	Stage      string    `json:"stage"`
	Name       string    `json:"name"`
	Ref        string    `json:"ref"`
	CreatedAt  time.Time `json:"created_at"`
	StartedAt  time.Time `json:"started_at,omitempty"`
	FinishedAt time.Time `json:"finished_at,omitempty"`
	Duration   float64   `json:"duration,omitempty"`
	Pipeline   struct {
		ID        int    `json:"id"`
		ProjectID int    `json:"project_id"`
		Ref       string `json:"ref"`
		Sha       string `json:"sha"`
		Status    string `json:"status"`
	} `json:"pipeline"`
	TagList []string `json:"tag_list"`
	Runner  *Runner  `json:"runner,omitempty"`
}
