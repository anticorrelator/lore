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

// prefsPath returns the absolute path to the TUI preferences file.
func prefsPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".lore", "config", "tui.json")
}

// LoadPrefs reads TUI preferences from ~/.lore/config/tui.json, then checks
// the LORE_TUI_LAYOUT env var for an override. Returns LayoutLeftRight default
// when the file is missing or unreadable.
func LoadPrefs() Prefs {
	p := Prefs{Layout: LayoutLeftRight}

	data, err := os.ReadFile(prefsPath())
	if err == nil {
		_ = json.Unmarshal(data, &p)
	}

	// Env var override
	if env := os.Getenv("LORE_TUI_LAYOUT"); env != "" {
		switch LayoutMode(env) {
		case LayoutLeftRight, LayoutTopBottom:
			p.Layout = LayoutMode(env)
		}
	}

	// Normalize unknown values to default
	if p.Layout != LayoutLeftRight && p.Layout != LayoutTopBottom {
		p.Layout = LayoutLeftRight
	}

	return p
}

// SavePrefs writes TUI preferences to ~/.lore/config/tui.json, creating the
// directory if needed.
func SavePrefs(p Prefs) error {
	path := prefsPath()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal prefs: %w", err)
	}
	return os.WriteFile(path, append(data, '\n'), 0644)
}
