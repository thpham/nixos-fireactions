// Package runner manages the act_runner lifecycle inside a Firecracker VM.
// It handles registration with Gitea, starting the runner daemon, and
// graceful shutdown when the job completes.
package runner

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/sirupsen/logrus"
	"github.com/thpham/fireteact/runner/mmds"
)

const (
	// DefaultActRunnerPath is the default path to act_runner binary
	DefaultActRunnerPath = "/usr/local/bin/act_runner"
	// DefaultWorkDir is the default working directory for act_runner
	DefaultWorkDir = "/opt/act_runner"
	// DefaultConfigPath is the default path to act_runner config
	DefaultConfigPath = "/etc/act_runner/config.yaml"
	// DefaultRunnerFile is where act_runner stores its registration state
	DefaultRunnerFile = "/opt/act_runner/.runner"
	// DefaultOwner is the default user to run act_runner as
	DefaultOwner = "runner"
	// DefaultGroup is the default group to run act_runner as
	DefaultGroup = "docker"
)

// Runner manages the act_runner process lifecycle.
type Runner struct {
	actRunnerPath string
	workDir       string
	configPath    string
	runnerFile    string
	owner         string
	group         string
	stdout        io.Writer
	stderr        io.Writer
	log           *logrus.Logger
}

// Option is a functional option for configuring the Runner.
type Option func(*Runner)

// WithActRunnerPath sets the path to the act_runner binary.
func WithActRunnerPath(path string) Option {
	return func(r *Runner) {
		r.actRunnerPath = path
	}
}

// WithWorkDir sets the working directory for act_runner.
func WithWorkDir(dir string) Option {
	return func(r *Runner) {
		r.workDir = dir
	}
}

// WithConfigPath sets the path to act_runner config file.
func WithConfigPath(path string) Option {
	return func(r *Runner) {
		r.configPath = path
	}
}

// WithOwner sets the user to run act_runner as.
func WithOwner(owner string) Option {
	return func(r *Runner) {
		r.owner = owner
	}
}

// WithGroup sets the group to run act_runner as.
func WithGroup(group string) Option {
	return func(r *Runner) {
		r.group = group
	}
}

// WithStdout sets the stdout writer for act_runner output.
func WithStdout(w io.Writer) Option {
	return func(r *Runner) {
		r.stdout = w
	}
}

// WithStderr sets the stderr writer for act_runner output.
func WithStderr(w io.Writer) Option {
	return func(r *Runner) {
		r.stderr = w
	}
}

// WithLogger sets the logger for the runner.
func WithLogger(log *logrus.Logger) Option {
	return func(r *Runner) {
		r.log = log
	}
}

// New creates a new Runner with the given options.
func New(opts ...Option) *Runner {
	r := &Runner{
		actRunnerPath: DefaultActRunnerPath,
		workDir:       DefaultWorkDir,
		configPath:    DefaultConfigPath,
		runnerFile:    DefaultRunnerFile,
		owner:         DefaultOwner,
		group:         DefaultGroup,
		stdout:        os.Stdout,
		stderr:        os.Stderr,
		log:           logrus.New(),
	}

	for _, opt := range opts {
		opt(r)
	}

	return r
}

// Register registers the runner with Gitea using the provided metadata.
func (r *Runner) Register(ctx context.Context, metadata *mmds.Metadata) error {
	r.log.WithFields(logrus.Fields{
		"instance":    metadata.GiteaInstanceURL,
		"runner_name": metadata.RunnerName,
		"labels":      metadata.RunnerLabels,
	}).Info("Registering runner with Gitea")

	// Ensure working directory exists
	if err := os.MkdirAll(r.workDir, 0755); err != nil {
		return fmt.Errorf("failed to create work directory: %w", err)
	}

	// Build registration command
	args := []string{
		"register",
		"--no-interactive",
		"--instance", metadata.GiteaInstanceURL,
		"--token", metadata.RegistrationToken,
		"--name", metadata.RunnerName,
	}

	if metadata.RunnerLabels != "" {
		args = append(args, "--labels", metadata.RunnerLabels)
	}

	cmd := exec.CommandContext(ctx, r.actRunnerPath, args...)
	cmd.Dir = r.workDir
	cmd.Stdout = r.stdout
	cmd.Stderr = r.stderr

	// Set up credentials to run as specified user/group
	if err := r.setCredentials(cmd); err != nil {
		return fmt.Errorf("failed to set credentials: %w", err)
	}

	// Set environment
	cmd.Env = r.buildEnv()

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("registration failed: %w", err)
	}

	r.log.Info("Runner registered successfully")
	return nil
}

// Run starts the act_runner daemon and blocks until it exits.
// This should be called after Register.
func (r *Runner) Run(ctx context.Context) error {
	r.log.Info("Starting act_runner daemon")

	args := []string{"daemon"}

	// Add config file if it exists
	if _, err := os.Stat(r.configPath); err == nil {
		args = append(args, "-c", r.configPath)
	}

	cmd := exec.CommandContext(ctx, r.actRunnerPath, args...)
	cmd.Dir = r.workDir
	cmd.Stdout = r.stdout
	cmd.Stderr = r.stderr

	// Set up credentials to run as specified user/group
	if err := r.setCredentials(cmd); err != nil {
		return fmt.Errorf("failed to set credentials: %w", err)
	}

	// Set environment
	cmd.Env = r.buildEnv()

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start daemon: %w", err)
	}

	r.log.WithField("pid", cmd.Process.Pid).Info("act_runner daemon started")

	// Wait for the process to exit
	err := cmd.Wait()

	if ctx.Err() != nil {
		// Context was cancelled (shutdown signal)
		r.log.Info("act_runner stopped due to shutdown signal")
		return nil
	}

	if err != nil {
		// Check if it's a normal exit (job completed)
		if exitErr, ok := err.(*exec.ExitError); ok {
			r.log.WithField("exit_code", exitErr.ExitCode()).Info("act_runner exited")
			// Exit code 0 or terminated by signal is normal for job completion
			if exitErr.ExitCode() == 0 {
				return nil
			}
		}
		return fmt.Errorf("daemon exited with error: %w", err)
	}

	r.log.Info("act_runner daemon exited normally")
	return nil
}

// setCredentials sets up the command to run as the specified user/group.
func (r *Runner) setCredentials(cmd *exec.Cmd) error {
	// Look up user
	u, err := user.Lookup(r.owner)
	if err != nil {
		return fmt.Errorf("failed to lookup user %s: %w", r.owner, err)
	}

	uid, err := strconv.ParseUint(u.Uid, 10, 32)
	if err != nil {
		return fmt.Errorf("invalid uid: %w", err)
	}

	gid, err := strconv.ParseUint(u.Gid, 10, 32)
	if err != nil {
		return fmt.Errorf("invalid gid: %w", err)
	}

	// Look up group if different from user's primary group
	if r.group != "" {
		g, err := user.LookupGroup(r.group)
		if err != nil {
			return fmt.Errorf("failed to lookup group %s: %w", r.group, err)
		}
		gid, err = strconv.ParseUint(g.Gid, 10, 32)
		if err != nil {
			return fmt.Errorf("invalid gid: %w", err)
		}
	}

	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{
			Uid: uint32(uid),
			Gid: uint32(gid),
		},
	}

	return nil
}

// buildEnv builds the environment variables for act_runner.
func (r *Runner) buildEnv() []string {
	// Look up user for HOME directory
	u, err := user.Lookup(r.owner)
	home := r.workDir
	if err == nil {
		home = u.HomeDir
	}

	// Get PATH from current environment or use sensible default
	path := os.Getenv("PATH")
	if path == "" {
		path = "/usr/local/bin:/usr/bin:/bin"
	}

	// Ensure /usr/local/bin is in PATH for act_runner
	if !strings.Contains(path, "/usr/local/bin") {
		path = "/usr/local/bin:" + path
	}

	return []string{
		"PATH=" + path,
		"HOME=" + home,
		"USER=" + r.owner,
		"DOCKER_HOST=unix:///var/run/docker.sock",
	}
}

// GenerateConfig generates a basic act_runner config file.
func (r *Runner) GenerateConfig() error {
	configDir := filepath.Dir(r.configPath)
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	config := `# act_runner configuration
# Generated by fireteact runner

log:
  level: info

runner:
  file: ` + r.runnerFile + `
  capacity: 1
  timeout: 3h
  insecure: false
  fetch_timeout: 5s
  fetch_interval: 2s

cache:
  enabled: true
  dir: ` + filepath.Join(r.workDir, "cache") + `

container:
  network: bridge
  privileged: false
  options: ""
  valid_volumes: []
`

	if err := os.WriteFile(r.configPath, []byte(config), 0644); err != nil {
		return fmt.Errorf("failed to write config: %w", err)
	}

	r.log.WithField("path", r.configPath).Info("Generated act_runner config")
	return nil
}

// Cleanup removes runner registration files.
func (r *Runner) Cleanup() error {
	// Remove runner file (deregistration happens automatically when runner disconnects)
	if err := os.Remove(r.runnerFile); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove runner file: %w", err)
	}
	return nil
}
