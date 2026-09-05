package session

// InterruptCurrentTurnCapability means this runtime consumes expiring,
// exact-session interrupt requests and persists ESC attempt outcomes.
const InterruptCurrentTurnCapability = "interrupt-current-turn-v1"

func RuntimeCapabilities() []string {
	return []string{InterruptCurrentTurnCapability}
}
