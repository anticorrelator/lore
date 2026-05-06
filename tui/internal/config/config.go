package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ErrNoRepo is returned by Load() when the current directory is not inside a
// git repository and no env override or .lore.config provides a knowledge dir.
// The returned Config will have ProjectDir set but KnowledgeDir and WorkDir empty.
var ErrNoRepo = errors.New("not inside a git repository")

// Config holds application-wide configuration resolved at startup.
type Config struct {
	KnowledgeDir   string // absolute path from `lore resolve`
	WorkDir        string // KnowledgeDir + "/_work"
	ProjectDir     string // CWD when TUI was started (the project root)
	RepoIdentifier string // normalized repo id, e.g. "github.com/owner/repo" or "local/name"
}

// insideGitRepo returns true when the cwd is inside a git work tree.
func insideGitRepo() bool {
	err := exec.Command("git", "rev-parse", "--is-inside-work-tree").Run()
	return err == nil
}

// Load runs `lore resolve` to discover the knowledge directory and returns
// a Config. This runs synchronously at startup before the TUI starts.
//
// When the cwd is not inside a git repository and no env override or
// .lore.config file provides a knowledge dir, Load returns
// (Config{ProjectDir: cwd}, ErrNoRepo). Callers can use errors.Is to detect
// this case and show an onboarding view.
func Load() (Config, error) {
	projectDir, err := os.Getwd()
	if err != nil {
		return Config{}, fmt.Errorf("failed to get working directory: %w", err)
	}

	gitOK := insideGitRepo()

	out, err := exec.Command("lore", "resolve").Output()
	if err != nil {
		// lore resolve failed — treat as no-repo regardless of git status.
		return Config{ProjectDir: projectDir}, ErrNoRepo
	}

	kdir := strings.TrimSpace(string(out))
	if kdir == "" {
		return Config{}, fmt.Errorf("lore resolve returned an empty path")
	}

	// If git check failed but lore resolve returned a local fallback path,
	// treat as no-repo. A non-local path means an env override or .lore.config
	// hit — proceed normally in that case.
	if !gitOK && strings.Contains(kdir, "/repos/local/") {
		return Config{ProjectDir: projectDir}, ErrNoRepo
	}

	return Config{
		KnowledgeDir:   kdir,
		WorkDir:        filepath.Join(kdir, "_work"),
		ProjectDir:     projectDir,
		RepoIdentifier: repoIdentifier(kdir),
	}, nil
}

// repoIdentifier derives a normalized repo identifier from the knowledge dir.
// It strips the "<data-root>/repos/" prefix, falling back to filepath.Base.
func repoIdentifier(kdir string) string {
	dataRoot := os.Getenv("LORE_DATA_DIR")
	if dataRoot == "" {
		home, _ := os.UserHomeDir()
		dataRoot = filepath.Join(home, ".lore")
	}
	prefix := filepath.Join(dataRoot, "repos") + string(filepath.Separator)
	if strings.HasPrefix(kdir, prefix) {
		return strings.TrimPrefix(kdir, prefix)
	}
	return filepath.Base(kdir)
}

// LayoutMode controls the split-pane orientation.
type LayoutMode string

const (
	LayoutLeftRight LayoutMode = "left-right"
	LayoutTopBottom LayoutMode = "top-bottom"
)

// Prefs holds user preferences persisted to ~/.lore/config/tui.json.
type Prefs struct {
	Layout LayoutMode `json:"layout"`
}

// prefsPath returns the absolute path to the legacy TUI preferences file
// (~/.lore/config/tui.json). Read-only fallback during the D4 deprecation
// window — new writes route through SettingsPatch into the unified
// settings.json under `tui.layout`.
func prefsPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".lore", "config", "tui.json")
}

// LoadPrefs reads TUI preferences. Resolution order (mirrors the unified-file
// pattern at scripts/lib.sh:615-655):
//  1. LORE_TUI_LAYOUT env var.
//  2. Unified settings.json `tui.layout`.
//  3. Legacy ~/.lore/config/tui.json (deprecation-window fallback per D4).
//  4. Built-in default LayoutLeftRight.
//
// Bash counterpart: there is no bash reader for tui.layout (the TUI is the
// only consumer); the unified loader is the cross-stack contract this
// reader composes against.
func LoadPrefs() Prefs {
	var layout LayoutMode

	// Unified settings.json (primary).
	if raw, present, _ := SettingsGet("tui.layout"); present {
		var v string
		if err := json.Unmarshal([]byte(raw), &v); err == nil {
			layout = LayoutMode(v)
		}
	}

	// Legacy tui.json (fallback when unified is absent or returned empty).
	if layout == "" {
		if data, err := os.ReadFile(prefsPath()); err == nil {
			var legacy Prefs
			if err := json.Unmarshal(data, &legacy); err == nil {
				layout = legacy.Layout
			}
		}
	}

	// Env var override (highest precedence).
	if env := os.Getenv("LORE_TUI_LAYOUT"); env != "" {
		switch LayoutMode(env) {
		case LayoutLeftRight, LayoutTopBottom:
			layout = LayoutMode(env)
		}
	}

	// Normalize unknown / empty values to default.
	if layout != LayoutLeftRight && layout != LayoutTopBottom {
		layout = LayoutLeftRight
	}

	return Prefs{Layout: layout}
}

// SavePrefs writes TUI preferences via the unified settings loader
// (SettingsPatch on `tui.layout`). The legacy ~/.lore/config/tui.json file is
// no longer written; LoadPrefs continues to read it as a deprecation-window
// fallback for one release. Routing through SettingsPatch ensures the write
// composes with concurrent bash/Python writers via the shared flock contract.
func SavePrefs(p Prefs) error {
	if err := SettingsPatch("tui.layout", string(p.Layout)); err != nil {
		return fmt.Errorf("save tui prefs: %w", err)
	}
	return nil
}

// ClaudeConfig holds flags applied to every `claude` CLI invocation spawned
// by lore (TUI spec panel and batch scripts). Persisted to
// ~/.lore/config/claude.json and shared with the shell scripts via
// load_claude_args in lib.sh.
type ClaudeConfig struct {
	Args []string `json:"args"`
}

// DefaultClaudeArgs is returned when no config file or env override exists.
// Keeping this as a function (not a var) prevents callers from mutating the
// shared slice.
func DefaultClaudeArgs() []string {
	return []string{"--dangerously-skip-permissions"}
}

// LoadClaudeConfig is a deprecated alias for LoadHarnessArgs("claude-code").
// Kept for one release so unmigrated callers continue to work; new callers
// should use LoadHarnessArgs(framework) or LoadHarnessConfig(framework) so
// they resolve args for the active framework rather than always reading the
// claude-code slot. See scripts/lib.sh load_claude_args for the bash-side
// equivalent deprecation shim.
//
// Deprecated: Use LoadHarnessArgs or LoadHarnessConfig.
func LoadClaudeConfig() ClaudeConfig {
	return ClaudeConfig{Args: LoadHarnessArgs("claude-code")}
}
