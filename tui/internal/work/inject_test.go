package work

import "testing"

// TestUnsafePayloadReason pins the narrowed unsafe-payload predicate (lead
// decision on D4): the bracketed-paste terminator is always refused, a line
// break is refused only when bracketed-paste mode is off, and a multiline body
// is accepted when bracketed (the probes verified all three harnesses hold a
// bracketed multiline paste as one composer entry).
func TestUnsafePayloadReason(t *testing.T) {
	term := "hi\x1b[201~there"
	cases := []struct {
		name      string
		body      string
		bracketed bool
		refuse    bool
	}{
		{"plain accepted bracketed", "reply text", true, false},
		{"plain accepted unbracketed", "reply text", false, false},
		{"multiline accepted bracketed", "line one\nline two", true, false},
		{"multiline refused unbracketed", "line one\nline two", false, true},
		{"carriage-return refused unbracketed", "line one\rline two", false, true},
		{"terminator refused bracketed", term, true, true},
		{"terminator refused unbracketed", term, false, true},
		{"empty accepted", "", true, false},
	}
	for _, c := range cases {
		reason := unsafePayloadReason([]byte(c.body), c.bracketed)
		if (reason != "") != c.refuse {
			t.Errorf("%s: unsafePayloadReason(%q, bracketed=%v) = %q, want refuse=%v",
				c.name, c.body, c.bracketed, reason, c.refuse)
		}
	}
}
