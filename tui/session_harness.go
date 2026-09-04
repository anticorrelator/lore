package main

// sessionHarness returns the runtime identity stamped at process start or
// restored during adoption. The launch preference applies only to future
// sessions; missing legacy metadata must not authorize harness-specific input.
func (m model) sessionHarness(slug string) string {
	return m.localSessions[slug].harness
}
