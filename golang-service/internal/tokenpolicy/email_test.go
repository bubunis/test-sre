package tokenpolicy

import (
	"strings"
	"testing"
)

func TestValidateEmail(t *testing.T) {
	ok := []string{"alice@example.com", "a@b"}
	bad := []string{"", "ab", "no-at-sign", "@example.com", "alice@", "a@b@c",
		"alice @example.com", strings.Repeat("a", 250) + "@x.com"}
	for _, e := range ok {
		if err := ValidateEmail(e); err != nil {
			t.Errorf("ValidateEmail(%q) = %v, want nil", e, err)
		}
	}
	for _, e := range bad {
		if err := ValidateEmail(e); err == nil {
			t.Errorf("ValidateEmail(%q) = nil, want an error", e)
		}
	}
}
