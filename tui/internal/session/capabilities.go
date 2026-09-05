package session

const InterruptCurrentTurnCapability = "interrupt-current-turn-v1"
const PositionPreparationCapability = "position-preparation-v1"

// RuntimeCapabilities describes the executing binary, not its source checkout.
func RuntimeCapabilities() []string {
	return []string{InterruptCurrentTurnCapability, PositionPreparationCapability}
}
