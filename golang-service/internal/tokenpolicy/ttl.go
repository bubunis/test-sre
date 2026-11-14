// Package tokenpolicy holds the server-side rules for issuing tokens.
// These rules apply whatever the caller asks for: the caller can never
// create a token that lives longer than MaxTTL, or one that never expires.
package tokenpolicy

import (
	"fmt"
	"time"
)

const (
	// DefaultTTL is used when the caller sends ttl_seconds = 0 (or omits it).
	DefaultTTL = 15 * time.Minute
	// MinTTL and MaxTTL bound any value the caller asks for.
	MinTTL = 1 * time.Minute
	MaxTTL = 1 * time.Hour
)

// TTL turns the caller's requested lifetime into the lifetime actually used.
// It never returns zero, so a token always expires.
func TTL(requestedSeconds int32) (time.Duration, error) {
	if requestedSeconds == 0 {
		return DefaultTTL, nil
	}
	ttl := time.Duration(requestedSeconds) * time.Second
	if ttl < MinTTL || ttl > MaxTTL {
		return 0, fmt.Errorf("ttl_seconds must be 0 (default %d) or between %d and %d",
			int(DefaultTTL.Seconds()), int(MinTTL.Seconds()), int(MaxTTL.Seconds()))
	}
	return ttl, nil
}
