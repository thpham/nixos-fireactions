package commands

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
	"github.com/thpham/fireteact/runner"
	"github.com/thpham/fireteact/runner/mmds"
)

var (
	runnerLogLevel    string
	runnerRetryWait   time.Duration
	runnerActPath     string
	runnerWorkDir     string
	runnerConfigPath  string
	runnerOwner       string
	runnerGroup       string
	runnerGenerateConfig bool
)

// runnerCmd represents the runner command for VM mode
var runnerCmd = &cobra.Command{
	Use:   "runner",
	Short: "Start the runner agent inside a Firecracker VM",
	Long: `Start the runner agent inside a Firecracker microVM. This command should
only be run inside a VM spawned by the fireteact orchestrator.

The runner agent:
1. Fetches configuration from MMDS (Firecracker metadata service)
2. Registers act_runner with the Gitea instance
3. Starts act_runner daemon to process jobs
4. Handles graceful shutdown when job completes

The VM will be terminated after the runner exits.`,
	RunE: runRunner,
}

func init() {
	rootCmd.AddCommand(runnerCmd)

	// Flags
	runnerCmd.Flags().StringVarP(&runnerLogLevel, "log-level", "l", "info", "Log level (debug, info, warn, error)")
	runnerCmd.Flags().DurationVar(&runnerRetryWait, "retry-wait", 2*time.Second, "Wait time between MMDS fetch retries")
	runnerCmd.Flags().StringVar(&runnerActPath, "act-runner", runner.DefaultActRunnerPath, "Path to act_runner binary")
	runnerCmd.Flags().StringVar(&runnerWorkDir, "work-dir", runner.DefaultWorkDir, "Working directory for act_runner")
	runnerCmd.Flags().StringVar(&runnerConfigPath, "config", runner.DefaultConfigPath, "Path to act_runner config file")
	runnerCmd.Flags().StringVar(&runnerOwner, "owner", runner.DefaultOwner, "User to run act_runner as")
	runnerCmd.Flags().StringVar(&runnerGroup, "group", runner.DefaultGroup, "Group to run act_runner as")
	runnerCmd.Flags().BoolVar(&runnerGenerateConfig, "generate-config", true, "Generate act_runner config if not exists")
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

	log.Infof("Starting fireteact runner %s", Version)
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
		"gitea_url":   metadata.GiteaInstanceURL,
		"runner_name": metadata.RunnerName,
		"labels":      metadata.RunnerLabels,
		"pool":        metadata.PoolName,
	}).Info("Retrieved runner configuration from MMDS")

	// Create runner
	r := runner.New(
		runner.WithActRunnerPath(runnerActPath),
		runner.WithWorkDir(runnerWorkDir),
		runner.WithConfigPath(runnerConfigPath),
		runner.WithOwner(runnerOwner),
		runner.WithGroup(runnerGroup),
		runner.WithStdout(os.Stdout),
		runner.WithStderr(os.Stderr),
		runner.WithLogger(log),
	)

	// Generate config if requested and doesn't exist
	if runnerGenerateConfig {
		if _, err := os.Stat(runnerConfigPath); os.IsNotExist(err) {
			if err := r.GenerateConfig(); err != nil {
				log.Errorf("Failed to generate config: %v", err)
				return err
			}
		}
	}

	// Register with Gitea
	log.Info("Registering runner with Gitea...")
	if err := r.Register(ctx, metadata); err != nil {
		log.Errorf("Failed to register runner: %v", err)
		return err
	}

	// Run the runner daemon
	log.Info("Starting act_runner daemon...")
	if err := r.Run(ctx); err != nil {
		log.Errorf("Runner error: %v", err)
		return err
	}

	// Cleanup
	log.Info("Runner completed, cleaning up...")
	if err := r.Cleanup(); err != nil {
		log.Warnf("Cleanup error: %v", err)
	}

	log.Info("fireteact runner shutdown complete")
	return nil
}
