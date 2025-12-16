// Package config provides configuration loading and validation for fireteact.
package config

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config represents the main fireteact configuration.
type Config struct {
	Server     ServerConfig     `yaml:"server"`
	Gitea      GiteaConfig      `yaml:"gitea"`
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

// GiteaConfig holds Gitea instance configuration.
type GiteaConfig struct {
	InstanceURL  string `yaml:"instanceURL"`
	APIToken     string `yaml:"apiToken"`
	APITokenFile string `yaml:"apiTokenFile"`
	// Runner registration scope
	RunnerScope string `yaml:"runnerScope"` // "instance", "org", or "repo"
	RunnerOwner string `yaml:"runnerOwner"` // org or user name (for org/repo scope)
	RunnerRepo  string `yaml:"runnerRepo"`  // repo name (for repo scope)
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
	Labels          []string `yaml:"labels"`
	Image           string   `yaml:"image"`
	ImagePullPolicy string   `yaml:"imagePullPolicy"`
}

// FirecrackerConfig holds VM resource settings.
type FirecrackerConfig struct {
	MemSizeMib int               `yaml:"memSizeMib"`
	VcpuCount  int               `yaml:"vcpuCount"`
	KernelArgs string            `yaml:"kernelArgs"`
	KernelPath string            `yaml:"kernelPath"`
	Metadata   map[string]string `yaml:"metadata"`
}

// ContainerdConfig holds containerd connection settings.
type ContainerdConfig struct {
	Address     string `yaml:"address"`
	Namespace   string `yaml:"namespace"`
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

	// Load API token from file if specified
	if cfg.Gitea.APITokenFile != "" && cfg.Gitea.APIToken == "" {
		token, err := os.ReadFile(cfg.Gitea.APITokenFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read API token file: %w", err)
		}
		cfg.Gitea.APIToken = strings.TrimSpace(string(token))
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
		c.Server.Address = "0.0.0.0:8080"
	}
	if c.Server.MetricsAddress == "" {
		c.Server.MetricsAddress = "127.0.0.1:8081"
	}
	if c.LogLevel == "" {
		c.LogLevel = "info"
	}
	if c.Gitea.RunnerScope == "" {
		c.Gitea.RunnerScope = "instance"
	}
	if c.Containerd.Address == "" {
		c.Containerd.Address = "/run/containerd/containerd.sock"
	}
	if c.Containerd.Namespace == "" {
		c.Containerd.Namespace = "fireteact"
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
	if c.Gitea.InstanceURL == "" {
		return fmt.Errorf("gitea.instanceURL is required")
	}
	if c.Gitea.APIToken == "" {
		return fmt.Errorf("gitea.apiToken or gitea.apiTokenFile is required")
	}

	// Validate runner scope
	switch c.Gitea.RunnerScope {
	case "instance":
		// No additional fields required
	case "org":
		if c.Gitea.RunnerOwner == "" {
			return fmt.Errorf("gitea.runnerOwner is required for org scope")
		}
	case "repo":
		if c.Gitea.RunnerOwner == "" {
			return fmt.Errorf("gitea.runnerOwner is required for repo scope")
		}
		if c.Gitea.RunnerRepo == "" {
			return fmt.Errorf("gitea.runnerRepo is required for repo scope")
		}
	default:
		return fmt.Errorf("gitea.runnerScope must be 'instance', 'org', or 'repo'")
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
	}

	return nil
}

// GetAPIToken returns the API token for Gitea API calls.
func (c *Config) GetAPIToken() string {
	return c.Gitea.APIToken
}
