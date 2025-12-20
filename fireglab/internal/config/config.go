// Package config provides configuration loading and validation for fireglab.
package config

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config represents the main fireglab configuration.
type Config struct {
	Server     ServerConfig     `yaml:"server"`
	GitLab     GitLabConfig     `yaml:"gitlab"`
	LogLevel   string           `yaml:"logLevel"`
	Pools      []PoolConfig     `yaml:"pools"`
	Containerd ContainerdConfig `yaml:"containerd"`
	CNI        CNIConfig        `yaml:"cni"`
}

// ServerConfig holds HTTP server settings.
type ServerConfig struct {
	Address        string `yaml:"address"`
	MetricsAddress string `yaml:"metricsAddress"`
}

// GitLabConfig holds GitLab instance configuration.
// Uses the new runner authentication token model (glrt-* tokens)
// via POST /api/v4/user/runners API.
type GitLabConfig struct {
	InstanceURL     string `yaml:"instanceURL"`
	AccessToken     string `yaml:"accessToken"`     // PAT with create_runner scope
	AccessTokenFile string `yaml:"accessTokenFile"` // Alternative: read token from file

	// Runner type determines the scope of runner registration
	// - "instance_type": Instance-wide runners (requires admin access)
	// - "group_type": Group-level runners (requires Owner role on group)
	// - "project_type": Project-level runners (requires Maintainer role on project)
	RunnerType string `yaml:"runnerType"`

	// GroupID is required when RunnerType is "group_type"
	GroupID int `yaml:"groupId"`

	// ProjectID is required when RunnerType is "project_type"
	ProjectID int `yaml:"projectId"`
}

// PoolConfig defines a runner pool.
type PoolConfig struct {
	Name        string            `yaml:"name"`
	MaxRunners  int               `yaml:"maxRunners"`
	MinRunners  int               `yaml:"minRunners"`
	Runner      RunnerConfig      `yaml:"runner"`
	Firecracker FirecrackerConfig `yaml:"firecracker"`
}

// RunnerConfig holds runner-specific settings.
type RunnerConfig struct {
	Name            string   `yaml:"name"`
	Description     string   `yaml:"description"`
	Tags            []string `yaml:"tags"`
	RunUntagged     bool     `yaml:"runUntagged"`
	Locked          bool     `yaml:"locked"`
	AccessLevel     string   `yaml:"accessLevel"` // "not_protected" or "ref_protected"
	MaximumTimeout  int      `yaml:"maximumTimeout"`
	Image           string   `yaml:"image"`
	ImagePullPolicy string   `yaml:"imagePullPolicy"`
}

// FirecrackerConfig holds VM resource settings.
type FirecrackerConfig struct {
	BinaryPath string                 `yaml:"binaryPath"`
	MemSizeMib int                    `yaml:"memSizeMib"`
	VcpuCount  int                    `yaml:"vcpuCount"`
	KernelArgs string                 `yaml:"kernelArgs"`
	KernelPath string                 `yaml:"kernelPath"`
	Metadata   map[string]interface{} `yaml:"metadata"`
}

// ContainerdConfig holds containerd connection settings.
// Note: Images are stored in per-pool namespaces (using pool name as namespace)
// for resource isolation between pools.
type ContainerdConfig struct {
	Address     string `yaml:"address"`
	Snapshotter string `yaml:"snapshotter"`
}

// CNIConfig holds CNI plugin settings.
type CNIConfig struct {
	ConfDir string `yaml:"confDir"`
	BinDir  string `yaml:"binDir"`
}

// Load reads configuration from a YAML file.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	// Expand environment variables in the config
	expanded := os.ExpandEnv(string(data))

	var cfg Config
	if err := yaml.Unmarshal([]byte(expanded), &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	// Apply defaults
	cfg.applyDefaults()

	// Load access token from file if specified
	if cfg.GitLab.AccessTokenFile != "" && cfg.GitLab.AccessToken == "" {
		token, err := os.ReadFile(cfg.GitLab.AccessTokenFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read access token file: %w", err)
		}
		cfg.GitLab.AccessToken = strings.TrimSpace(string(token))
	}

	// Validate configuration
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	return &cfg, nil
}

// applyDefaults sets default values for unspecified configuration options.
func (c *Config) applyDefaults() {
	if c.Server.Address == "" {
		c.Server.Address = "0.0.0.0:8084" // Different from fireactions (8080) and fireteact (8082)
	}
	if c.Server.MetricsAddress == "" {
		c.Server.MetricsAddress = "127.0.0.1:8085" // Different from fireactions (8081) and fireteact (8083)
	}
	if c.LogLevel == "" {
		c.LogLevel = "info"
	}
	if c.GitLab.RunnerType == "" {
		c.GitLab.RunnerType = "group_type"
	}
	if c.Containerd.Address == "" {
		c.Containerd.Address = "/run/containerd/containerd.sock"
	}
	if c.Containerd.Snapshotter == "" {
		c.Containerd.Snapshotter = "devmapper"
	}
	if c.CNI.ConfDir == "" {
		c.CNI.ConfDir = "/etc/cni/net.d"
	}
	if c.CNI.BinDir == "" {
		c.CNI.BinDir = "/opt/cni/bin"
	}

	// Pool defaults
	for i := range c.Pools {
		pool := &c.Pools[i]
		if pool.MaxRunners == 0 {
			pool.MaxRunners = 10
		}
		if pool.MinRunners == 0 {
			pool.MinRunners = 1
		}
		if pool.Runner.ImagePullPolicy == "" {
			pool.Runner.ImagePullPolicy = "IfNotPresent"
		}
		if pool.Runner.AccessLevel == "" {
			pool.Runner.AccessLevel = "not_protected"
		}
		if pool.Firecracker.MemSizeMib == 0 {
			pool.Firecracker.MemSizeMib = 2048
		}
		if pool.Firecracker.VcpuCount == 0 {
			pool.Firecracker.VcpuCount = 2
		}
		if pool.Firecracker.KernelArgs == "" {
			pool.Firecracker.KernelArgs = "console=ttyS0 reboot=k panic=1 pci=off"
		}
	}
}

// validate checks that the configuration is valid.
func (c *Config) validate() error {
	if c.GitLab.InstanceURL == "" {
		return fmt.Errorf("gitlab.instanceURL is required")
	}
	if c.GitLab.AccessToken == "" {
		return fmt.Errorf("gitlab.accessToken or gitlab.accessTokenFile is required")
	}

	// Validate runner type and required fields
	switch c.GitLab.RunnerType {
	case "instance_type":
		// No additional fields required, but user needs admin access
	case "group_type":
		if c.GitLab.GroupID == 0 {
			return fmt.Errorf("gitlab.groupId is required for group_type runners")
		}
	case "project_type":
		if c.GitLab.ProjectID == 0 {
			return fmt.Errorf("gitlab.projectId is required for project_type runners")
		}
	default:
		return fmt.Errorf("gitlab.runnerType must be 'instance_type', 'group_type', or 'project_type'")
	}

	if len(c.Pools) == 0 {
		return fmt.Errorf("at least one pool must be configured")
	}

	for i, pool := range c.Pools {
		if pool.Name == "" {
			return fmt.Errorf("pool[%d].name is required", i)
		}
		if pool.Runner.Image == "" {
			return fmt.Errorf("pool[%d].runner.image is required", i)
		}
		if pool.MinRunners > pool.MaxRunners {
			return fmt.Errorf("pool[%d].minRunners cannot be greater than maxRunners", i)
		}
		// Validate access level
		if pool.Runner.AccessLevel != "" &&
			pool.Runner.AccessLevel != "not_protected" &&
			pool.Runner.AccessLevel != "ref_protected" {
			return fmt.Errorf("pool[%d].runner.accessLevel must be 'not_protected' or 'ref_protected'", i)
		}
	}

	return nil
}

// GetAccessToken returns the access token for GitLab API calls.
func (c *Config) GetAccessToken() string {
	return c.GitLab.AccessToken
}
