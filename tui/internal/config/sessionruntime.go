package config

import (
	"encoding/json"
	"fmt"
	"os"
	"os/user"
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

// LoginDir is the per-login session supervisor's state directory, outside every
// knowledge store: <data dir>/session-runtime, or session-runtimes/<name> for a
// named runtime, where the data dir is LORE_DATA_DIR or ~/.lore. It matches
// login_dir in scripts/session_runtime.py.
func LoginDir() string {
	data := os.Getenv("LORE_DATA_DIR")
	if data == "" {
		home := os.Getenv("HOME")
		if home == "" {
			if u, err := user.Current(); err == nil {
				home = u.HomeDir
			}
		}
		data = filepath.Join(home, ".lore")
	}
	if name := mustSessionRuntime(); name != "" {
		return filepath.Join(data, "session-runtimes", name)
	}
	return filepath.Join(data, "session-runtime")
}

// SupervisorTmuxTmpdir returns the TMUX_TMPDIR the login's session supervisor
// recorded in supervisor.json, which is the one its store hosts' tmux server
// lives under. recorded is false when there is no readable record or it names
// none, and the caller keeps its own TMUX_TMPDIR. A record of null or "" means
// the supervisor ran with TMUX_TMPDIR unset: recorded is true and dir is "".
// This is what `lore session attach` applies (attach_environment in
// scripts/session-managed.py).
func SupervisorTmuxTmpdir() (dir string, recorded bool) {
	data, err := os.ReadFile(filepath.Join(LoginDir(), "supervisor.json"))
	if err != nil {
		return "", false
	}
	var record map[string]json.RawMessage
	if json.Unmarshal(data, &record) != nil {
		return "", false
	}
	raw, ok := record["tmux_tmpdir"]
	if !ok {
		return "", false
	}
	var value *string
	if json.Unmarshal(raw, &value) != nil {
		return "", false
	}
	if value == nil {
		return "", true
	}
	return *value, true
}
