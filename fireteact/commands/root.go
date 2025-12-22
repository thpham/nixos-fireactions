// Package commands provides the CLI commands for fireteact.
package commands

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var (
	// Version information (set via ldflags)
	Version = "dev"
	Commit  = "unknown"
	Date    = "unknown"
)

// rootCmd represents the base command when called without any subcommands
var rootCmd = &cobra.Command{
	Use:   "fireteact",
	Short: "Gitea Actions runner orchestrator using Firecracker microVMs",
	Long: `Fireteact manages ephemeral Gitea Actions runners in isolated Firecracker
microVMs with auto-scaling pool management. It's the Gitea equivalent of
fireactions for GitHub Actions.

When run without a subcommand, fireteact starts the orchestrator server.
Use 'fireteact runner' inside a VM to start the runner agent.`,
	Version: fmt.Sprintf("%s (commit: %s, built: %s)", Version, Commit, Date),
	// Don't print usage on errors - we handle errors with proper logging
	SilenceUsage: true,
	// Don't print errors twice - we log them ourselves
	SilenceErrors: true,
}

// Execute adds all child commands to the root command and sets flags appropriately.
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

// SetVersionInfo sets the version information for the CLI.
func SetVersionInfo(version, commit, date string) {
	Version = version
	Commit = commit
	Date = date
	rootCmd.Version = fmt.Sprintf("%s (commit: %s, built: %s)", version, commit, date)
}

func init() {
	// Global flags can be added here if needed
}
