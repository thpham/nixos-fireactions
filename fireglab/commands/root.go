// Package commands provides the CLI commands for fireglab.
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
	Use:   "fireglab",
	Short: "GitLab CI runner orchestrator using Firecracker microVMs",
	Long: `Fireglab manages ephemeral GitLab CI runners in isolated Firecracker
microVMs with auto-scaling pool management. It uses GitLab's new runner
authentication token model (glrt-* tokens) via the POST /user/runners API.

When run without a subcommand, fireglab starts the orchestrator server.
Use 'fireglab runner' inside a VM to start the runner agent.`,
	Version: fmt.Sprintf("%s (commit: %s, built: %s)", Version, Commit, Date),
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
