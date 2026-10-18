package config

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

const (
	SessionRuntimeEnv    = "LORE_SESSION_RUNTIME"
	productionTmuxServer = "lore-tui"
)

var sessionRuntimePattern = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)

func SessionRuntime() (string, error) {
	name := os.Getenv(SessionRuntimeEnv)
	if name == "" {
		return "", nil
	}
	if !sessionRuntimePattern.MatchString(name) {
		return "", fmt.Errorf("%s=%q is not a valid runtime name (want [a-z0-9-]{1,32})", SessionRuntimeEnv, name)
	}
	return name, nil
}

func mustSessionRuntime() string {
	name, err := SessionRuntime()
	if err != nil {
		// main refuses to start with an invalid value, so only a caller that
		// skipped that check gets here; falling back to the production server
		// would hand it the sessions this setting exists to keep apart.
		panic(err)
	}
	return name
}

// TmuxServer names the dedicated tmux server lore sessions live on, isolated
// from the user's default server so no user tmux.conf option can invalidate the
// screen-state contract the injection/peek stack was probed against.
func TmuxServer() string {
	if name := mustSessionRuntime(); name != "" {
		return productionTmuxServer + "-" + name
	}
	return productionTmuxServer
}

func SessionHostsDir(sessionsDir string) string {
	if name := mustSessionRuntime(); name != "" {
		return filepath.Join(sessionsDir, "runtimes", name, "hosts")
	}
	return filepath.Join(sessionsDir, "hosts")
}
