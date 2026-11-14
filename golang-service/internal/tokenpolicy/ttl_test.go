package tokenpolicy

import (
	"testing"
	"time"
)

func TestTTL(t *testing.T) {
	tests := []struct {
		name      string
		requested int32
		want      time.Duration
		wantErr   bool
	}{
		{"zero uses default, never infinite", 0, DefaultTTL, false},
		{"minimum allowed", 60, time.Minute, false},
		{"what the Python API sends today", 3600, time.Hour, false},
		{"negative is refused", -1, 0, true},
		{"below minimum is refused", 59, 0, true},
		{"above maximum is refused", 3601, 0, true},
		{"huge value is refused", 2147483647, 0, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := TTL(tc.requested)
			if (err != nil) != tc.wantErr {
				t.Fatalf("TTL(%d) error = %v, wantErr %v", tc.requested, err, tc.wantErr)
			}
			if got != tc.want {
				t.Fatalf("TTL(%d) = %v, want %v", tc.requested, got, tc.want)
			}
			if err == nil && got <= 0 {
				t.Fatalf("TTL(%d) returned a non-expiring lifetime", tc.requested)
			}
		})
	}
}
