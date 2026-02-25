package config

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Config holds application-wide configuration resolved at startup.
type Config struct {
	KnowledgeDir string // absolute path from `lore resolve`
	WorkDir      string // KnowledgeDir + "/_work"
	ProjectDir   string // CWD when TUI was started (the project root)
}

// Load runs `lore resolve` to discover the knowledge directory and returns
// a Config. This runs synchronously at startup before the TUI starts.
func Load() (Config, error) {
	projectDir, err := os.Getwd()
	if err != nil {
		return Config{}, fmt.Errorf("failed to get working directory: %w", err)
	}

	out, err := exec.Command("lore", "resolve").Output()
	if err != nil {
		return Config{}, fmt.Errorf("failed to resolve knowledge directory: %w\n\nMake sure `lore` is installed and the current directory is inside a tracked repository.", err)
	}

	kdir := strings.TrimSpace(string(out))
	if kdir == "" {
		return Config{}, fmt.Errorf("lore resolve returned an empty path")
	}

	return Config{
		KnowledgeDir: kdir,
		WorkDir:      filepath.Join(kdir, "_work"),
		ProjectDir:   projectDir,
	}, nil
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
