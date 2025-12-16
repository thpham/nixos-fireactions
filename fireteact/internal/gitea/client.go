// Package gitea provides a client for interacting with the Gitea Actions API.
package gitea

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/sirupsen/logrus"
)

// Client handles communication with the Gitea API.
type Client struct {
	instanceURL string
	apiToken    string
	httpClient  *http.Client
	log         *logrus.Logger
	// Runner scope configuration
	runnerScope string
	runnerOwner string
	runnerRepo  string
}

// RegistrationToken represents a runner registration token from Gitea.
type RegistrationToken struct {
	Token string `json:"token"`
}

// Runner represents a registered runner in Gitea.
type Runner struct {
	ID          int64    `json:"id"`
	Name        string   `json:"name"`
	Status      string   `json:"status"`
	Busy        bool     `json:"busy"`
	Labels      []string `json:"labels"`
	Version     string   `json:"version"`
	LastContact string   `json:"last_contact,omitempty"`
}

// Job represents a Gitea Actions job.
type Job struct {
	ID         int64     `json:"id"`
	RunID      int64     `json:"run_id"`
	Name       string    `json:"name"`
	Status     string    `json:"status"`
	Labels     []string  `json:"labels"`
	CreatedAt  time.Time `json:"created_at"`
	StartedAt  time.Time `json:"started_at,omitempty"`
	FinishedAt time.Time `json:"finished_at,omitempty"`
}

// NewClient creates a new Gitea API client.
func NewClient(instanceURL, apiToken, runnerScope, runnerOwner, runnerRepo string, log *logrus.Logger) (*Client, error) {
	if instanceURL == "" {
		return nil, fmt.Errorf("instance URL is required")
	}
	if apiToken == "" {
		return nil, fmt.Errorf("API token is required")
	}

	// Normalize instance URL (remove trailing slash)
	instanceURL = strings.TrimSuffix(instanceURL, "/")

	return &Client{
		instanceURL: instanceURL,
		apiToken:    apiToken,
		runnerScope: runnerScope,
		runnerOwner: runnerOwner,
		runnerRepo:  runnerRepo,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		log: log,
	}, nil
}

// GetRegistrationToken requests a new runner registration token from Gitea.
// This token is used by act_runner to register itself with the Gitea instance.
// Each call returns a fresh token for a new runner.
func (c *Client) GetRegistrationToken(ctx context.Context) (string, error) {
	endpoint := c.getRegistrationTokenEndpoint()

	c.log.WithField("endpoint", endpoint).Debug("Requesting registration token from Gitea")

	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "token "+c.apiToken)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to request registration token: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("failed to get registration token: status %d, body: %s", resp.StatusCode, string(body))
	}

	var token RegistrationToken
	if err := json.Unmarshal(body, &token); err != nil {
		return "", fmt.Errorf("failed to parse registration token response: %w", err)
	}

	if token.Token == "" {
		return "", fmt.Errorf("empty registration token received")
	}

	c.log.Debug("Successfully obtained registration token")
	return token.Token, nil
}

// DeleteRunner removes a runner from Gitea by its ID.
func (c *Client) DeleteRunner(ctx context.Context, runnerID int64) error {
	endpoint := c.getRunnerEndpoint(runnerID)

	c.log.WithFields(logrus.Fields{
		"runner_id": runnerID,
		"endpoint":  endpoint,
	}).Debug("Deleting runner from Gitea")

	req, err := http.NewRequestWithContext(ctx, "DELETE", endpoint, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "token "+c.apiToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to delete runner: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to delete runner: status %d, body: %s", resp.StatusCode, string(body))
	}

	c.log.WithField("runner_id", runnerID).Info("Runner deleted from Gitea")
	return nil
}

// ListRunners returns all runners registered with Gitea.
func (c *Client) ListRunners(ctx context.Context) ([]Runner, error) {
	endpoint := c.getRunnersListEndpoint()

	c.log.WithField("endpoint", endpoint).Debug("Listing runners from Gitea")

	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "token "+c.apiToken)
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
		return nil, fmt.Errorf("failed to parse runners response: %w", err)
	}

	return runners, nil
}

// GetInstanceURL returns the Gitea instance URL.
func (c *Client) GetInstanceURL() string {
	return c.instanceURL
}

// GetPendingJobs retrieves pending jobs that match the given labels.
// Note: This is a placeholder - the actual implementation depends on Gitea's API.
func (c *Client) GetPendingJobs(ctx context.Context, labels []string) ([]Job, error) {
	// TODO: Implement actual Gitea API call
	c.log.Debug("GetPendingJobs called - placeholder implementation")
	return []Job{}, nil
}

// GetQueueDepth returns an estimate of pending jobs in the queue.
// This can be used for auto-scaling decisions.
func (c *Client) GetQueueDepth(ctx context.Context, labels []string) (int, error) {
	// TODO: Implement using Gitea API or metrics
	c.log.Debug("GetQueueDepth called - placeholder implementation")
	return 0, nil
}

// GenerateCloudInitUserData generates cloud-init user-data for configuring act_runner inside a VM.
func (c *Client) GenerateCloudInitUserData(registrationToken string, runnerLabels []string, poolName string) string {
	labelsStr := strings.Join(runnerLabels, ",")

	return fmt.Sprintf(`#cloud-config
# Fireteact Gitea Actions Runner Configuration
# Auto-generated by fireteact orchestrator

write_files:
  - path: /etc/environment.d/act_runner.conf
    content: |
      GITEA_INSTANCE_URL=%s
      GITEA_RUNNER_LABELS=%s
    permissions: '0644'

  - path: /run/secrets/gitea-runner-token
    content: |
      %s
    permissions: '0600'

  - path: /etc/act_runner/config.yaml
    content: |
      log:
        level: info
      runner:
        file: /opt/act_runner/.runner
        capacity: 1
        timeout: 3h
        insecure: false
        fetch_timeout: 5s
        fetch_interval: 2s
      cache:
        enabled: true
        dir: /opt/act_runner/cache
      container:
        network: bridge
        privileged: false
        options: ""
        valid_volumes: []
    permissions: '0644'

  - path: /etc/systemd/system/act_runner.service
    content: |
      [Unit]
      Description=Gitea Actions Runner
      After=network-online.target docker.service
      Wants=network-online.target

      [Service]
      Type=simple
      WorkingDirectory=/opt/act_runner
      EnvironmentFile=/etc/environment.d/act_runner.conf
      ExecStartPre=/bin/bash -c '/usr/local/bin/act_runner register --no-interactive --instance "$GITEA_INSTANCE_URL" --token "$(cat /run/secrets/gitea-runner-token)" --name "$(hostname)" --labels "$GITEA_RUNNER_LABELS"'
      ExecStart=/usr/local/bin/act_runner daemon -c /etc/act_runner/config.yaml
      Restart=no

      [Install]
      WantedBy=multi-user.target
    permissions: '0644'

runcmd:
  - |
    RUNNER_ID=$(curl -s --fail http://169.254.169.254/latest/meta-data/fireteact/runner_id 2>/dev/null || echo "%s-runner")
    hostnamectl set-hostname "fireteact-$RUNNER_ID"
  - mkdir -p /opt/act_runner
  - systemctl daemon-reload
  - systemctl enable act_runner
  - systemctl start act_runner
`, c.instanceURL, labelsStr, registrationToken, poolName)
}

// getRegistrationTokenEndpoint returns the API endpoint for getting registration tokens.
func (c *Client) getRegistrationTokenEndpoint() string {
	switch c.runnerScope {
	case "org":
		return fmt.Sprintf("%s/api/v1/orgs/%s/actions/runners/registration-token", c.instanceURL, c.runnerOwner)
	case "repo":
		return fmt.Sprintf("%s/api/v1/repos/%s/%s/actions/runners/registration-token", c.instanceURL, c.runnerOwner, c.runnerRepo)
	default: // "instance"
		return fmt.Sprintf("%s/api/v1/admin/runners/registration-token", c.instanceURL)
	}
}

// getRunnersListEndpoint returns the API endpoint for listing runners.
func (c *Client) getRunnersListEndpoint() string {
	switch c.runnerScope {
	case "org":
		return fmt.Sprintf("%s/api/v1/orgs/%s/actions/runners", c.instanceURL, c.runnerOwner)
	case "repo":
		return fmt.Sprintf("%s/api/v1/repos/%s/%s/actions/runners", c.instanceURL, c.runnerOwner, c.runnerRepo)
	default: // "instance"
		return fmt.Sprintf("%s/api/v1/admin/runners", c.instanceURL)
	}
}

// getRunnerEndpoint returns the API endpoint for a specific runner.
func (c *Client) getRunnerEndpoint(runnerID int64) string {
	switch c.runnerScope {
	case "org":
		return fmt.Sprintf("%s/api/v1/orgs/%s/actions/runners/%d", c.instanceURL, c.runnerOwner, runnerID)
	case "repo":
		return fmt.Sprintf("%s/api/v1/repos/%s/%s/actions/runners/%d", c.instanceURL, c.runnerOwner, c.runnerRepo, runnerID)
	default: // "instance"
		return fmt.Sprintf("%s/api/v1/admin/runners/%d", c.instanceURL, runnerID)
	}
}
