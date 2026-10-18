package session

import (
	"fmt"
	"time"
)

// Generation names one launch of a session: the harness's own session id, or
// else the request id, or else the tmux session name, followed by the request
// id and the launch's start time in whole seconds. A zero start time yields the
// identity alone. The pane is told this value at launch and the host derives it
// again from its registry row, which stores the start time to the second, so
// both must truncate the same way; scripts/session_target.py generation()
// computes it from a registry row and tests/fixtures/session-generation-vectors.json
// pins the two together.
func Generation(sessionID, requestID, tmuxName string, started time.Time) string {
	identity := sessionID
	if identity == "" {
		identity = requestID
	}
	if identity == "" {
		identity = tmuxName
	}
	if started.IsZero() {
		return identity
	}
	return fmt.Sprintf("%s/%s/%d", identity, requestID, started.Unix())
}
