// Package mmds provides a client for Firecracker's MicroVM Metadata Service (MMDS).
// MMDS provides a way to pass configuration data to VMs via a link-local HTTP endpoint.
package mmds

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const (
	// DefaultMMDSAddress is the link-local address for MMDS
	DefaultMMDSAddress = "http://169.254.169.254"
	// MetadataPath is the path to fireteact metadata
	MetadataPath = "/latest/meta-data/fireteact"
)

// Client is an MMDS client for fetching VM metadata.
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// Metadata represents the fireteact configuration passed via MMDS.
type Metadata struct {
	// GiteaInstanceURL is the URL of the Gitea instance
	GiteaInstanceURL string `json:"gitea_instance_url"`
	// RegistrationToken is the one-time token for runner registration
	RegistrationToken string `json:"registration_token"`
	// RunnerName is the name for this runner
	RunnerName string `json:"runner_name"`
	// RunnerLabels are the labels for this runner (comma-separated)
	RunnerLabels string `json:"runner_labels"`
	// RunnerGroup is the optional runner group
	RunnerGroup string `json:"runner_group,omitempty"`
	// PoolName is the pool this runner belongs to
	PoolName string `json:"pool_name"`
	// RunnerID is the unique identifier for this runner
	RunnerID string `json:"runner_id"`
}

// Option is a functional option for configuring the MMDS client.
type Option func(*Client)

// WithBaseURL sets a custom base URL for the MMDS client.
func WithBaseURL(url string) Option {
	return func(c *Client) {
		c.baseURL = url
	}
}

// WithTimeout sets a custom timeout for HTTP requests.
func WithTimeout(timeout time.Duration) Option {
	return func(c *Client) {
		c.httpClient.Timeout = timeout
	}
}

// NewClient creates a new MMDS client.
func NewClient(opts ...Option) *Client {
	c := &Client{
		baseURL: DefaultMMDSAddress,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}

	for _, opt := range opts {
		opt(c)
	}

	return c
}

// GetMetadata fetches the fireteact metadata from MMDS.
func (c *Client) GetMetadata(ctx context.Context) (*Metadata, error) {
	url := c.baseURL + MetadataPath

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	// MMDS requires Accept header for JSON response
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch metadata: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("MMDS returned status %d: %s", resp.StatusCode, string(body))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	var metadata Metadata
	if err := json.Unmarshal(body, &metadata); err != nil {
		return nil, fmt.Errorf("failed to parse metadata: %w", err)
	}

	// Validate required fields
	if metadata.GiteaInstanceURL == "" {
		return nil, fmt.Errorf("missing required field: gitea_instance_url")
	}
	if metadata.RegistrationToken == "" {
		return nil, fmt.Errorf("missing required field: registration_token")
	}
	if metadata.RunnerName == "" {
		return nil, fmt.Errorf("missing required field: runner_name")
	}

	return &metadata, nil
}

// WaitForMetadata retries fetching metadata until successful or context is cancelled.
// This is useful during VM boot when MMDS may not be immediately available.
func (c *Client) WaitForMetadata(ctx context.Context, retryInterval time.Duration) (*Metadata, error) {
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
			metadata, err := c.GetMetadata(ctx)
			if err == nil {
				return metadata, nil
			}

			// Wait before retrying
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(retryInterval):
				// Continue retrying
			}
		}
	}
}
