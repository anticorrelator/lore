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

// ErrLoreDisabled is returned by Load() when the current directory IS inside a
// git repository but `lore resolve` failed because the lore agent integration
// is disabled in unified settings. The
// onboarding view distinguishes this from ErrNoRepo so users get actionable
// guidance ("run `lore agent enable`") instead of the misleading
// "navigate to a git repo" message.
var ErrLoreDisabled = errors.New("lore agent integration is disabled")

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

// loreDisabled returns true when the lore agent integration has been turned
// off via `lore agent disable` (or the equivalent settings-modal toggle). Used
// by Load() to distinguish "lore disabled" from "not in a git repo" so the
// onboarding view can show the right guidance. The check is filesystem-only
// (no shell-out) and reads `$LORE_DATA_DIR/config/settings.json`.
// Missing/unreadable file → false (treat as not-disabled; the original
// ErrNoRepo path applies).
func loreDisabled() bool {
	raw, err := os.ReadFile(SettingsPath())
	if err != nil {
		return false
	}
	var doc struct {
		Harnesses map[string]struct {
			Enabled *bool `json:"enabled"`
		} `json:"harnesses"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return false
	}
	if len(doc.Harnesses) == 0 {
		return false
	}
	for _, block := range doc.Harnesses {
		if block.Enabled == nil || *block.Enabled {
			return false
		}
	}
	return true
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
		// `lore resolve` failed. Two distinct causes the onboarding flow
		// must distinguish:
		//   * lore agent integration disabled — actionable: run
		//     `lore agent enable`. The user IS in a usable git repo;
		//     the previous "navigate to a git repo" message was wrong.
		//   * not inside a git repo (or any other reason resolve failed) —
		//     keep the existing onboarding behavior.
		if gitOK && loreDisabled() {
			return Config{ProjectDir: projectDir}, ErrLoreDisabled
		}
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

// NormalizeProjectDir resolves dir to a physical absolute path so it can be
// byte-compared against a request's prefer_project_dir (which the enqueue writer
// resolves the same way). It applies filepath.Abs then filepath.EvalSymlinks,
// falling back to the Abs form when symlink resolution errors — a path that does
// not resolve still yields a stable comparable string. Config.ProjectDir itself
// is left untouched; the TUI still spawns sessions with the original cwd. macOS
// /tmp→/private/tmp and worktree symlinks match correctly from both Go and bash
// once both sides resolve physically.
func NormalizeProjectDir(dir string) string {
	abs, err := filepath.Abs(dir)
	if err != nil {
		abs = dir
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return abs
	}
	return resolved
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

// Prefs holds user preferences persisted to unified settings.
type Prefs struct {
	Layout LayoutMode `json:"layout"`
}

// prefsPath returns the old TUI preferences path. Kept only for callers/tests
// that need to locate stale files; runtime reads do not consult it.
func prefsPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".lore", "config", "tui.json")
}

// LoadPrefs reads TUI preferences. Resolution order:
//  1. LORE_TUI_LAYOUT env var.
//  2. Unified settings.json `tui.layout`.
//  3. Built-in default LayoutTopBottom.
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

	// Env var override (highest precedence).
	if env := os.Getenv("LORE_TUI_LAYOUT"); env != "" {
		switch LayoutMode(env) {
		case LayoutLeftRight, LayoutTopBottom:
			layout = LayoutMode(env)
		}
	}

	// Normalize unknown / empty values to default.
	if layout != LayoutLeftRight && layout != LayoutTopBottom {
		layout = LayoutTopBottom
	}

	return Prefs{Layout: layout}
}

// SavePrefs writes TUI preferences via the unified settings loader
// (SettingsPatch on `tui.layout`). The old ~/.lore/config/tui.json file is no
// longer written or read. Routing through SettingsPatch ensures the write
// composes with concurrent bash/Python writers via the shared flock contract.
func SavePrefs(p Prefs) error {
	if err := SettingsPatch("tui.layout", string(p.Layout)); err != nil {
		return fmt.Errorf("save tui prefs: %w", err)
	}
	return nil
}

// ClaudeConfig holds flags applied to every `claude` CLI invocation spawned
// by lore (TUI spec panel and batch scripts). Persisted to
// the claude-code harness slot in unified settings.
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
