package commands

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
	"github.com/thpham/fireglab/internal/config"
	"github.com/thpham/fireglab/internal/server"
)

var (
	configPath string
)

// serveCmd represents the serve command (default when no subcommand is given)
var serveCmd = &cobra.Command{
	Use:   "serve",
	Short: "Start the fireglab orchestrator server",
	Long: `Start the fireglab orchestrator server which manages Firecracker VMs
running GitLab CI runners. This is the main mode of operation on the host.

The server provides:
- HTTP API for managing pools and runners
- Prometheus metrics endpoint
- Auto-scaling pool management
- VM lifecycle management
- Dynamic runner creation via GitLab API (POST /user/runners)`,
	RunE: runServe,
}

func init() {
	rootCmd.AddCommand(serveCmd)

	// Also make serve the default command when no subcommand is given
	rootCmd.RunE = runServe

	// Add flags
	serveCmd.Flags().StringVarP(&configPath, "config", "c", "/etc/fireglab/config.yaml", "Path to configuration file")
	rootCmd.Flags().StringVarP(&configPath, "config", "c", "/etc/fireglab/config.yaml", "Path to configuration file")
}

func runServe(cmd *cobra.Command, args []string) error {
	// Setup logging
	log := logrus.New()
	log.SetFormatter(&logrus.TextFormatter{
		FullTimestamp: true,
	})

	// Load configuration
	cfg, err := config.Load(configPath)
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Set log level from config
	level, err := logrus.ParseLevel(cfg.LogLevel)
	if err != nil {
		log.Warnf("Invalid log level '%s', defaulting to 'info'", cfg.LogLevel)
		level = logrus.InfoLevel
	}
	log.SetLevel(level)

	log.Infof("Starting fireglab %s", Version)
	log.Infof("Loaded configuration from %s", configPath)
	log.Infof("GitLab instance: %s", cfg.GitLab.InstanceURL)
	log.Infof("Runner type: %s", cfg.GitLab.RunnerType)
	log.Infof("Configured pools: %d", len(cfg.Pools))

	// Create context with cancellation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		log.Infof("Received signal %v, initiating shutdown...", sig)
		cancel()
	}()

	// Create and start the server
	srv, err := server.New(cfg, log)
	if err != nil {
		log.Fatalf("Failed to create server: %v", err)
	}

	// Run the server (blocks until context is cancelled)
	if err := srv.Run(ctx); err != nil {
		log.Errorf("Server error: %v", err)
		return err
	}

	log.Info("fireglab shutdown complete")
	return nil
}
