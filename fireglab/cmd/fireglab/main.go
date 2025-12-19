// Package main provides the entry point for the fireglab application.
//
// fireglab has two modes:
//   - Orchestrator (default): Manages GitLab CI runners in Firecracker microVMs
//   - Runner: Agent that runs inside a VM to bootstrap gitlab-runner
//
// Usage:
//
//	fireglab [serve]    - Start the orchestrator server (host mode)
//	fireglab runner     - Start the runner agent (VM mode)
package main

import (
	"github.com/thpham/fireglab/commands"
)

var (
	// Version information (set via ldflags)
	Version = "dev"
	Commit  = "unknown"
	Date    = "unknown"
)

func main() {
	commands.SetVersionInfo(Version, Commit, Date)
	commands.Execute()
}
