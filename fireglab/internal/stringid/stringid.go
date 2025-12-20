// Package stringid provides unique string ID generation.
package stringid

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strconv"
)

const (
	// IDLength is the byte length used to generate IDs (results in 2x hex chars).
	IDLength = 12
)

// New returns a new unique string ID.
// The ID is a 24-character hex string that cannot be parsed as an integer,
// making it safe for use in filenames and identifiers.
func New() string {
	b := make([]byte, IDLength)
	for {
		if _, err := rand.Read(b); err != nil {
			panic(err)
		}

		id := hex.EncodeToString(b)
		// Ensure the ID is not parseable as an integer (contains letters)
		_, err := strconv.ParseInt(id, 10, 64)
		if err == nil {
			continue
		}

		return id
	}
}

// Short returns a shorter 8-character ID.
func Short() string {
	b := make([]byte, 4)
	for {
		if _, err := rand.Read(b); err != nil {
			panic(err)
		}
		id := hex.EncodeToString(b)
		_, err := strconv.ParseInt(id, 10, 64)
		if err == nil {
			continue
		}
		return id
	}
}

// GenerateVMID generates a unique VM identifier for a runner.
// Format: {pool}-{id}
func GenerateVMID(poolName string) string {
	return fmt.Sprintf("%s-%s", poolName, Short())
}

// GenerateRunnerName generates a unique runner name.
// Format: fireglab-{pool}-{id}
func GenerateRunnerName(poolName string) string {
	return fmt.Sprintf("fireglab-%s-%s", poolName, Short())
}

// GenerateSystemID generates a unique system ID for distinguishing
// multiple runner instances using the same authentication token.
// This is used by GitLab to track individual runner machines.
func GenerateSystemID() string {
	return fmt.Sprintf("s_%s", New())
}
