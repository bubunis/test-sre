package tokenpolicy

import (
	"errors"
	"strings"
)

// MaxEmailLength is the longest valid address (RFC 5321).
const MaxEmailLength = 254

// ValidateEmail refuses requests that can't be for a real user: empty, too
// long, or without an "@". The API checks the user exists in the database;
// this stops anything that reaches the gRPC port directly from storing junk.
func ValidateEmail(email string) error {
	if len(email) < 3 || len(email) > MaxEmailLength {
		return errors.New("user_email must be 3 to 254 characters")
	}
	if strings.Count(email, "@") != 1 || strings.HasPrefix(email, "@") || strings.HasSuffix(email, "@") {
		return errors.New("user_email is not an email address")
	}
	if strings.ContainsAny(email, " \t\r\n") {
		return errors.New("user_email must not contain whitespace")
	}
	return nil
}
