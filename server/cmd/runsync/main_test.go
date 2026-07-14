package main

import "testing"

func TestValidateLocationPolicy(t *testing.T) {
	tests := []struct {
		policy   string
		decimals int
		valid    bool
	}{
		{policy: "hidden", decimals: -1, valid: true},
		{policy: "precise", decimals: -1, valid: true},
		{policy: "rounded", decimals: 3, valid: true},
		{policy: "rounded", decimals: -1, valid: false},
		{policy: "rounded", decimals: 7, valid: false},
		{policy: "precise", decimals: 3, valid: false},
		{policy: "unknown", decimals: -1, valid: false},
	}
	for _, test := range tests {
		t.Run(test.policy, func(t *testing.T) {
			value, err := validateLocationPolicy(test.policy, test.decimals)
			if (err == nil) != test.valid {
				t.Fatalf("value=%v err=%v", value, err)
			}
			if test.valid && test.policy == "rounded" && (value == nil || *value != int16(test.decimals)) {
				t.Fatalf("decimals=%v", value)
			}
		})
	}
}
