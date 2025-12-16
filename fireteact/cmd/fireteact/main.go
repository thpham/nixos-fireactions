// Package main provides the entry point for the fireteact application.
//
// fireteact has two modes:
//   - Orchestrator (default): Manages Gitea Actions runners in Firecracker microVMs
//   - Runner: Agent that runs inside a VM to bootstrap act_runner
//
// Usage:
//
//	fireteact [serve]    - Start the orchestrator server (host mode)
//	fireteact runner     - Start the runner agent (VM mode)
package main

import (
	"github.com/thpham/fireteact/commands"
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
