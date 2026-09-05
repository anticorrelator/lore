package session

// RuntimeCapabilities is compiled into the executing binary. Checkout metadata
// cannot assert support on behalf of an already-running process.
const PositionPreparationCapability = "position-preparation-v1"

func RuntimeCapabilities() []string { return []string{PositionPreparationCapability} }
