package gitlab

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/sirupsen/logrus"
)

// Client handles communication with the GitLab API.
type Client struct {
	instanceURL string
	accessToken string
	httpClient  *http.Client
	log         *logrus.Logger

	// Runner configuration
	runnerType string
	groupID    int
	projectID  int
}

// NewClient creates a new GitLab API client.
func NewClient(instanceURL, accessToken, runnerType string, groupID, projectID int, log *logrus.Logger) (*Client, error) {
	if instanceURL == "" {
		return nil, fmt.Errorf("instance URL is required")
	}
	if accessToken == "" {
		return nil, fmt.Errorf("access token is required")
	}

	// Normalize instance URL (remove trailing slash)
	instanceURL = strings.TrimSuffix(instanceURL, "/")

	return &Client{
		instanceURL: instanceURL,
		accessToken: accessToken,
		runnerType:  runnerType,
		groupID:     groupID,
		projectID:   projectID,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		log: log,
	}, nil
}

// CreateRunner creates a new runner via POST /api/v4/user/runners
// This is the new runner creation workflow introduced in GitLab 15.11.
// Returns the runner ID and authentication token (glrt-* prefix).
// IMPORTANT: The token is only returned once and cannot be retrieved again.
func (c *Client) CreateRunner(ctx context.Context, description string, tags []string, opts RunnerOptions) (*CreateRunnerResponse, error) {
	endpoint := fmt.Sprintf("%s/api/v4/user/runners", c.instanceURL)

	// Build request body
	req := CreateRunnerRequest{
		RunnerType:      c.runnerType,
		Description:     description,
		RunUntagged:     opts.RunUntagged,
		Locked:          opts.Locked,
		AccessLevel:     opts.AccessLevel,
		MaximumTimeout:  opts.MaximumTimeout,
		Paused:          opts.Paused,
		MaintenanceNote: opts.MaintenanceNote,
	}

	// Set scope-specific fields
	if c.runnerType == "group_type" {
		req.GroupID = c.groupID
	} else if c.runnerType == "project_type" {
		req.ProjectID = c.projectID
	}

	// Convert tags to comma-separated string
	if len(tags) > 0 {
		req.TagList = strings.Join(tags, ",")
	}

	c.log.WithFields(logrus.Fields{
		"endpoint":    endpoint,
		"runner_type": c.runnerType,
		"description": description,
		"tags":        tags,
	}).Debug("Creating runner via GitLab API")

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	httpReq.Header.Set("PRIVATE-TOKEN", c.accessToken)
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("failed to create runner: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		var errResp ErrorResponse
		if err := json.Unmarshal(respBody, &errResp); err == nil && (errResp.Message != "" || errResp.Error != "") {
			return nil, fmt.Errorf("failed to create runner: %s (status %d)", errResp.Message+errResp.Error, resp.StatusCode)
		}
		return nil, fmt.Errorf("failed to create runner: status %d, body: %s", resp.StatusCode, string(respBody))
	}

	var result CreateRunnerResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if result.Token == "" {
		return nil, fmt.Errorf("empty token received from GitLab")
	}

	c.log.WithFields(logrus.Fields{
		"runner_id": result.ID,
	}).Info("Successfully created runner in GitLab")

	return &result, nil
}

// RunnerOptions contains optional parameters for runner creation
type RunnerOptions struct {
	RunUntagged     bool
	Locked          bool
	AccessLevel     string
	MaximumTimeout  int
	Paused          bool
	MaintenanceNote string
}

// DeleteRunner removes a runner by its ID via DELETE /api/v4/runners/:id
func (c *Client) DeleteRunner(ctx context.Context, runnerID int) error {
	endpoint := fmt.Sprintf("%s/api/v4/runners/%d", c.instanceURL, runnerID)

	c.log.WithFields(logrus.Fields{
		"runner_id": runnerID,
		"endpoint":  endpoint,
	}).Debug("Deleting runner from GitLab")

	req, err := http.NewRequestWithContext(ctx, "DELETE", endpoint, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("PRIVATE-TOKEN", c.accessToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to delete runner: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to delete runner: status %d, body: %s", resp.StatusCode, string(body))
	}

	c.log.WithField("runner_id", runnerID).Info("Runner deleted from GitLab")
	return nil
}

// DeleteRunnerByToken removes a runner using its authentication token
// via DELETE /api/v4/runners with token in body
func (c *Client) DeleteRunnerByToken(ctx context.Context, token string) error {
	endpoint := fmt.Sprintf("%s/api/v4/runners", c.instanceURL)

	c.log.WithField("endpoint", endpoint).Debug("Deleting runner by token from GitLab")

	body := fmt.Sprintf(`{"token":"%s"}`, token)
	req, err := http.NewRequestWithContext(ctx, "DELETE", endpoint, strings.NewReader(body))
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to delete runner: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to delete runner: status %d, body: %s", resp.StatusCode, string(respBody))
	}

	c.log.Info("Runner deleted from GitLab by token")
	return nil
}

// GetRunner retrieves runner details by ID via GET /api/v4/runners/:id
func (c *Client) GetRunner(ctx context.Context, runnerID int) (*RunnerDetails, error) {
	endpoint := fmt.Sprintf("%s/api/v4/runners/%d", c.instanceURL, runnerID)

	c.log.WithFields(logrus.Fields{
		"runner_id": runnerID,
		"endpoint":  endpoint,
	}).Debug("Getting runner details from GitLab")

	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("PRIVATE-TOKEN", c.accessToken)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to get runner: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("failed to get runner: status %d, body: %s", resp.StatusCode, string(body))
	}

	var runner RunnerDetails
	if err := json.Unmarshal(body, &runner); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	return &runner, nil
}

// ListRunners returns all runners accessible to the current user
func (c *Client) ListRunners(ctx context.Context) ([]Runner, error) {
	endpoint := fmt.Sprintf("%s/api/v4/runners", c.instanceURL)

	c.log.WithField("endpoint", endpoint).Debug("Listing runners from GitLab")

	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("PRIVATE-TOKEN", c.accessToken)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to list runners: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("failed to list runners: status %d, body: %s", resp.StatusCode, string(body))
	}

	var runners []Runner
	if err := json.Unmarshal(body, &runners); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	c.log.WithField("runner_count", len(runners)).Debug("Listed runners from GitLab")
	return runners, nil
}

// GetInstanceURL returns the GitLab instance URL.
func (c *Client) GetInstanceURL() string {
	return c.instanceURL
}

// GetRunnerType returns the configured runner type.
func (c *Client) GetRunnerType() string {
	return c.runnerType
}
