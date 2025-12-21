package commands

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
	"github.com/thpham/fireglab/runner"
	"github.com/thpham/fireglab/runner/mmds"
)

var (
	runnerLogLevel      string
	runnerRetryWait     time.Duration
	runnerGitLabPath    string
	runnerWorkDir       string
	runnerConfigPath    string
	runnerOwner         string
	runnerGroup         string
	runnerExecutor      string
	runnerSingleJobMode bool
)

// runnerCmd represents the runner command for VM mode
var runnerCmd = &cobra.Command{
	Use:   "runner",
	Short: "Start the runner agent inside a Firecracker VM",
	Long: `Start the runner agent inside a Firecracker microVM. This command should
only be run inside a VM spawned by the fireglab orchestrator.

The runner agent:
1. Fetches configuration from MMDS (Firecracker metadata service)
2. Registers gitlab-runner with the GitLab instance using the glrt-* token
3. Starts gitlab-runner daemon to process jobs
4. Handles graceful shutdown when job completes

The VM will be terminated after the runner exits.`,
	RunE: runRunner,
}

func init() {
	rootCmd.AddCommand(runnerCmd)

	// Flags
	runnerCmd.Flags().StringVarP(&runnerLogLevel, "log-level", "l", "info", "Log level (debug, info, warn, error)")
	runnerCmd.Flags().DurationVar(&runnerRetryWait, "retry-wait", 2*time.Second, "Wait time between MMDS fetch retries")
	runnerCmd.Flags().StringVar(&runnerGitLabPath, "gitlab-runner", runner.DefaultGitLabRunnerPath, "Path to gitlab-runner binary")
	runnerCmd.Flags().StringVar(&runnerWorkDir, "work-dir", runner.DefaultWorkDir, "Working directory for gitlab-runner")
	runnerCmd.Flags().StringVar(&runnerConfigPath, "config", runner.DefaultConfigPath, "Path to gitlab-runner config file")
	runnerCmd.Flags().StringVar(&runnerOwner, "owner", runner.DefaultOwner, "User to run gitlab-runner as")
	runnerCmd.Flags().StringVar(&runnerGroup, "group", runner.DefaultGroup, "Group to run gitlab-runner as")
	runnerCmd.Flags().StringVar(&runnerExecutor, "executor", runner.DefaultExecutor, "Executor type (shell, docker)")
	runnerCmd.Flags().BoolVar(&runnerSingleJobMode, "single-job", true, "Run in single-job mode (exit after one job)")
}

func runRunner(cmd *cobra.Command, args []string) error {
	// Setup logging
	log := logrus.New()
	log.SetFormatter(&logrus.TextFormatter{
		FullTimestamp: true,
	})

	level, err := logrus.ParseLevel(runnerLogLevel)
	if err != nil {
		log.Warnf("Invalid log level '%s', defaulting to 'info'", runnerLogLevel)
		level = logrus.InfoLevel
	}
	log.SetLevel(level)

	log.Infof("Starting fireglab runner %s", Version)
	log.Info("This command should only be run inside a Firecracker VM")

	// Create context with cancellation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Setup signal handling for graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		log.Infof("Received signal %v, initiating shutdown...", sig)
		cancel()
	}()

	// Create MMDS client
	mmdsClient := mmds.NewClient()

	// Fetch metadata from MMDS (with retries during boot)
	log.Info("Fetching configuration from MMDS...")
	metadata, err := mmdsClient.WaitForMetadata(ctx, runnerRetryWait)
	if err != nil {
		log.Errorf("Failed to fetch metadata from MMDS: %v", err)
		return err
	}

	log.WithFields(logrus.Fields{
		"gitlab_url":       metadata.GitLabInstanceURL,
		"runner_name":      metadata.RunnerName,
		"tags":             metadata.RunnerTags,
		"pool":             metadata.PoolName,
		"gitlab_runner_id": metadata.GitLabRunnerID,
	}).Info("Retrieved runner configuration from MMDS")

	// Create runner
	r := runner.New(
		runner.WithGitLabRunnerPath(runnerGitLabPath),
		runner.WithWorkDir(runnerWorkDir),
		runner.WithConfigPath(runnerConfigPath),
		runner.WithOwner(runnerOwner),
		runner.WithGroup(runnerGroup),
		runner.WithExecutor(runnerExecutor),
		runner.WithStdout(os.Stdout),
		runner.WithStderr(os.Stderr),
		runner.WithLogger(log),
	)

	// Run the runner daemon
	log.Info("Starting gitlab-runner daemon...")
	if runnerSingleJobMode {
		// Use run-single for ephemeral mode (one job, then exit)
		// run-single takes all parameters via CLI, no registration needed
		// This avoids creating duplicate system_ids (one from register, one from run-single)
		if err := r.RunOnce(ctx, metadata); err != nil {
			log.Errorf("Runner error: %v", err)
			return err
		}
	} else {
		// Standard run mode requires registration to create config.toml
		// The runner was already created via POST /api/v4/user/runners by the host
		// We're just registering locally with the glrt-* token
		log.Info("Registering runner with GitLab...")
		if err := r.Register(ctx, metadata); err != nil {
			log.Errorf("Failed to register runner: %v", err)
			return err
		}
		if err := r.Run(ctx); err != nil {
			log.Errorf("Runner error: %v", err)
			return err
		}
	}

	// Cleanup local files
	// Note: The actual GitLab runner deletion (DELETE /api/v4/runners/:id)
	// is handled by the host orchestrator when it detects the VM has exited
	log.Info("Runner completed, cleaning up...")
	if err := r.Cleanup(); err != nil {
		log.Warnf("Cleanup error: %v", err)
	}

	log.Info("fireglab runner shutdown complete")
	return nil
}
