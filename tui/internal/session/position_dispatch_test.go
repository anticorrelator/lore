package session

import (
	"encoding/json"
	"testing"
)

func TestPositionContextIsPreservedWithoutTextFallback(t *testing.T) {
	for _, input := range []string{`{"position_preparation":{}}`, `{"position_dispatch":null,"prompt":"shadow"}`} {
		req := Request{ExtraContext: json.RawMessage(input)}
		if string(req.PositionContext()) != input {
			t.Fatal("lost structured position marker")
		}
	}
	legacy := Request{ExtraContext: json.RawMessage(`{"dispatch_guidance":"legacy payload"}`)}
	if legacy.PositionContext() != nil || legacy.ExtraContextText() != "legacy payload" {
		t.Fatal("legacy changed")
	}
}
