// Package stringid provides unique string ID generation.
package stringid

import (
	"crypto/rand"
	"encoding/hex"
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
