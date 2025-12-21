// Package runner manages the gitlab-runner lifecycle inside a Firecracker VM.
// It handles registration with GitLab using the glrt-* token, starting the runner
// daemon, and graceful shutdown when the job completes.
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
	"github.com/thpham/fireglab/runner/mmds"
)

const (
	// DefaultGitLabRunnerPath is the default path to gitlab-runner binary
	DefaultGitLabRunnerPath = "/usr/local/bin/gitlab-runner"
	// DefaultWorkDir is the default working directory for gitlab-runner
	DefaultWorkDir = "/opt/gitlab-runner"
	// DefaultConfigPath is the default path to gitlab-runner config
	DefaultConfigPath = "/etc/gitlab-runner/config.toml"
	// DefaultOwner is the default user to run gitlab-runner as
	DefaultOwner = "runner"
	// DefaultGroup is the default group to run gitlab-runner as
	DefaultGroup = "docker"
	// DefaultExecutor is the default executor type for gitlab-runner
	DefaultExecutor = "shell"
)

// Runner manages the gitlab-runner process lifecycle.
type Runner struct {
	gitlabRunnerPath string
	workDir          string
	configPath       string
	owner            string
	group            string
	executor         string
	stdout           io.Writer
	stderr           io.Writer
	log              *logrus.Logger
}

// Option is a functional option for configuring the Runner.
type Option func(*Runner)

// WithGitLabRunnerPath sets the path to the gitlab-runner binary.
func WithGitLabRunnerPath(path string) Option {
	return func(r *Runner) {
		r.gitlabRunnerPath = path
	}
}

// WithWorkDir sets the working directory for gitlab-runner.
func WithWorkDir(dir string) Option {
	return func(r *Runner) {
		r.workDir = dir
	}
}

// WithConfigPath sets the path to gitlab-runner config file.
func WithConfigPath(path string) Option {
	return func(r *Runner) {
		r.configPath = path
	}
}

// WithOwner sets the user to run gitlab-runner as.
func WithOwner(owner string) Option {
	return func(r *Runner) {
		r.owner = owner
	}
}

// WithGroup sets the group to run gitlab-runner as.
func WithGroup(group string) Option {
	return func(r *Runner) {
		r.group = group
	}
}

// WithExecutor sets the executor type (shell, docker, etc).
func WithExecutor(executor string) Option {
	return func(r *Runner) {
		r.executor = executor
	}
}

// WithStdout sets the stdout writer for gitlab-runner output.
func WithStdout(w io.Writer) Option {
	return func(r *Runner) {
		r.stdout = w
	}
}

// WithStderr sets the stderr writer for gitlab-runner output.
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
		gitlabRunnerPath: DefaultGitLabRunnerPath,
		workDir:          DefaultWorkDir,
		configPath:       DefaultConfigPath,
		owner:            DefaultOwner,
		group:            DefaultGroup,
		executor:         DefaultExecutor,
		stdout:           os.Stdout,
		stderr:           os.Stderr,
		log:              logrus.New(),
	}

	for _, opt := range opts {
		opt(r)
	}

	return r
}

// Register registers the runner with GitLab using the provided metadata.
// The glrt-* token has already been created by the host orchestrator via
// POST /api/v4/user/runners - we just need to register with it.
func (r *Runner) Register(ctx context.Context, metadata *mmds.Metadata) error {
	r.log.WithFields(logrus.Fields{
		"instance":    metadata.GitLabInstanceURL,
		"runner_name": metadata.RunnerName,
		"tags":        metadata.RunnerTags,
		"runner_id":   metadata.GitLabRunnerID,
	}).Info("Registering runner with GitLab")

	// Ensure working directory exists
	if err := os.MkdirAll(r.workDir, 0755); err != nil {
		return fmt.Errorf("failed to create work directory: %w", err)
	}

	// Ensure config directory exists
	configDir := filepath.Dir(r.configPath)
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	// Remove any existing config to prevent duplicate [[runners]] entries on restart
	// gitlab-runner register appends to existing config, which causes issues if
	// the service restarts after a failed run attempt
	if err := os.Remove(r.configPath); err != nil && !os.IsNotExist(err) {
		r.log.Warnf("Failed to remove existing config file: %v", err)
	}

	// Build registration command
	// With the new runner authentication tokens (glrt-*), we use --token directly
	// The runner was already created via the API, so we just need to register locally
	args := []string{
		"register",
		"--non-interactive",
		"--url", metadata.GitLabInstanceURL,
		"--token", metadata.RunnerToken,
		"--name", metadata.RunnerName,
		"--executor", r.executor,
		"--config", r.configPath,
	}

	// Add builds directory
	buildsDir := filepath.Join(r.workDir, "builds")
	args = append(args, "--builds-dir", buildsDir)

	// Add cache directory
	cacheDir := filepath.Join(r.workDir, "cache")
	args = append(args, "--cache-dir", cacheDir)

	cmd := exec.CommandContext(ctx, r.gitlabRunnerPath, args...)
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

// Run starts the gitlab-runner daemon and blocks until it exits.
// This should be called after Register.
// The runner will continuously poll for jobs until stopped or the context is cancelled.
func (r *Runner) Run(ctx context.Context) error {
	r.log.Info("Starting gitlab-runner daemon (continuous mode)")

	// Use 'run' command which reads from config.toml
	// The runner will poll for jobs until the context is cancelled
	args := []string{
		"run",
		"--config", r.configPath,
	}

	cmd := exec.CommandContext(ctx, r.gitlabRunnerPath, args...)
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

	r.log.WithField("pid", cmd.Process.Pid).Info("gitlab-runner daemon started")

	// Wait for the process to exit
	err := cmd.Wait()

	if ctx.Err() != nil {
		// Context was cancelled (shutdown signal)
		r.log.Info("gitlab-runner stopped due to shutdown signal")
		return nil
	}

	if err != nil {
		// Check if it's a normal exit (job completed)
		if exitErr, ok := err.(*exec.ExitError); ok {
			r.log.WithField("exit_code", exitErr.ExitCode()).Info("gitlab-runner exited")
			// Exit code 0 is normal
			if exitErr.ExitCode() == 0 {
				return nil
			}
		}
		return fmt.Errorf("daemon exited with error: %w", err)
	}

	r.log.Info("gitlab-runner daemon exited normally")
	return nil
}

// RunOnce starts gitlab-runner to run exactly one job and then exit.
// Uses run-single command which processes one job and exits - true ephemeral behavior.
// Takes metadata directly since run-single doesn't need registration.
func (r *Runner) RunOnce(ctx context.Context, metadata *mmds.Metadata) error {
	r.log.Info("Starting gitlab-runner in single-job mode (run-single)")

	// Build directories
	buildsDir := filepath.Join(r.workDir, "builds")
	cacheDir := filepath.Join(r.workDir, "cache")

	// Use 'run-single' command which executes exactly one job and exits
	// This provides true ephemeral behavior without relying on external VM termination
	args := []string{
		"run-single",
		"--url", metadata.GitLabInstanceURL,
		"--token", metadata.RunnerToken,
		"--executor", r.executor,
		"--builds-dir", buildsDir,
		"--cache-dir", cacheDir,
	}

	// Add runner name if available
	if metadata.RunnerName != "" {
		args = append(args, "--name", metadata.RunnerName)
	}

	cmd := exec.CommandContext(ctx, r.gitlabRunnerPath, args...)
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
		return fmt.Errorf("failed to start runner: %w", err)
	}

	r.log.WithField("pid", cmd.Process.Pid).Info("gitlab-runner started (single-job mode)")

	// Wait for the process to exit
	err := cmd.Wait()

	if ctx.Err() != nil {
		r.log.Info("gitlab-runner stopped due to shutdown signal")
		return nil
	}

	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			r.log.WithField("exit_code", exitErr.ExitCode()).Info("gitlab-runner exited")
			if exitErr.ExitCode() == 0 {
				return nil
			}
		}
		return fmt.Errorf("runner exited with error: %w", err)
	}

	r.log.Info("gitlab-runner completed job and exited")
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

// buildEnv builds the environment variables for gitlab-runner.
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

	// Ensure /usr/local/bin is in PATH for gitlab-runner
	if !strings.Contains(path, "/usr/local/bin") {
		path = "/usr/local/bin:" + path
	}

	return []string{
		"PATH=" + path,
		"HOME=" + home,
		"USER=" + r.owner,
		"DOCKER_HOST=unix:///var/run/docker.sock",
		// GitLab runner specific environment
		"CI_SERVER_TLS_CA_FILE=",
	}
}

// Unregister removes the runner from GitLab.
// Note: With the new runner authentication tokens, the runner is deleted via
// the API by the host orchestrator when the VM exits. This method is provided
// for local cleanup but the actual GitLab-side deletion happens on the host.
func (r *Runner) Unregister(ctx context.Context, token string) error {
	r.log.Info("Unregistering runner from GitLab")

	args := []string{
		"unregister",
		"--token", token,
		"--config", r.configPath,
	}

	cmd := exec.CommandContext(ctx, r.gitlabRunnerPath, args...)
	cmd.Dir = r.workDir
	cmd.Stdout = r.stdout
	cmd.Stderr = r.stderr

	if err := r.setCredentials(cmd); err != nil {
		return fmt.Errorf("failed to set credentials: %w", err)
	}

	cmd.Env = r.buildEnv()

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("unregistration failed: %w", err)
	}

	r.log.Info("Runner unregistered successfully")
	return nil
}

// Cleanup removes runner configuration files.
func (r *Runner) Cleanup() error {
	// Remove config file
	if err := os.Remove(r.configPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove config file: %w", err)
	}
	return nil
}
