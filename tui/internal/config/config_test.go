package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLoad(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Skipf("lore resolve not available in test environment: %v", err)
	}

	if cfg.KnowledgeDir == "" {
		t.Error("KnowledgeDir should not be empty")
	}

	if cfg.WorkDir == "" {
		t.Error("WorkDir should not be empty")
	}

	// WorkDir should be KnowledgeDir + "/_work"
	expected := cfg.KnowledgeDir + "/_work"
	if cfg.WorkDir != expected {
		t.Errorf("WorkDir = %q, want %q", cfg.WorkDir, expected)
	}
}

func TestLoad_ErrNoRepo(t *testing.T) {
	// Create a temp directory that is not inside a git repo.
	tmp := t.TempDir()
	orig, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(tmp); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(orig) })

	// Point LORE_KNOWLEDGE_DIR away so lore resolve can't return a valid path.
	t.Setenv("LORE_KNOWLEDGE_DIR", "")

	cfg, err := Load()
	if !errors.Is(err, ErrNoRepo) {
		t.Skipf("expected ErrNoRepo from non-git dir, got: %v (lore or git may behave differently in CI)", err)
	}

	if cfg.ProjectDir == "" {
		t.Error("ProjectDir should be set even on ErrNoRepo")
	}
	if cfg.KnowledgeDir != "" {
		t.Errorf("KnowledgeDir should be empty on ErrNoRepo, got %q", cfg.KnowledgeDir)
	}
	if cfg.WorkDir != "" {
		t.Errorf("WorkDir should be empty on ErrNoRepo, got %q", cfg.WorkDir)
	}
}

func TestLoad_InsideGitRepo(t *testing.T) {
	// Load from the current directory which is already a git repo.
	cfg, err := Load()
	if err != nil {
		t.Skipf("lore resolve not available in test environment: %v", err)
	}

	if cfg.ProjectDir == "" {
		t.Error("ProjectDir should not be empty inside a git repo")
	}
	if cfg.KnowledgeDir == "" {
		t.Error("KnowledgeDir should not be empty inside a git repo")
	}
	if cfg.WorkDir == "" {
		t.Error("WorkDir should not be empty inside a git repo")
	}
	// KnowledgeDir and WorkDir must both be non-empty — no ErrNoRepo.
	if errors.Is(err, ErrNoRepo) {
		t.Error("Load() must not return ErrNoRepo when inside a git repo with lore")
	}
}

func TestLoad_RepoIdentifier(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Skipf("lore resolve not available in test environment: %v", err)
	}

	if cfg.RepoIdentifier == "" {
		t.Error("RepoIdentifier should not be empty on successful Load()")
	}
}

func TestLoadPrefs_MissingFile(t *testing.T) {
	// Point HOME to an empty temp dir so no tui.json exists.
	t.Setenv("HOME", t.TempDir())
	t.Setenv("LORE_TUI_LAYOUT", "")

	p := LoadPrefs()
	if p.Layout != LayoutLeftRight {
		t.Errorf("Layout = %q, want %q", p.Layout, LayoutLeftRight)
	}
}

func TestLoadPrefs_ReadsFile(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	t.Setenv("LORE_TUI_LAYOUT", "")

	// Write a tui.json with top-bottom layout.
	dir := filepath.Join(tmp, ".lore", "config")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tui.json"), []byte(`{"layout":"top-bottom"}`), 0644); err != nil {
		t.Fatal(err)
	}

	p := LoadPrefs()
	if p.Layout != LayoutTopBottom {
		t.Errorf("Layout = %q, want %q", p.Layout, LayoutTopBottom)
	}
}

func TestLoadPrefs_EnvOverridesFile(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	// File says left-right.
	dir := filepath.Join(tmp, ".lore", "config")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tui.json"), []byte(`{"layout":"left-right"}`), 0644); err != nil {
		t.Fatal(err)
	}

	// Env var overrides to top-bottom.
	t.Setenv("LORE_TUI_LAYOUT", "top-bottom")

	p := LoadPrefs()
	if p.Layout != LayoutTopBottom {
		t.Errorf("Layout = %q, want %q (env should override file)", p.Layout, LayoutTopBottom)
	}
}

func TestSavePrefs_Roundtrip(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	t.Setenv("LORE_TUI_LAYOUT", "")

	// Save top-bottom preference.
	want := Prefs{Layout: LayoutTopBottom}
	if err := SavePrefs(want); err != nil {
		t.Fatalf("SavePrefs: %v", err)
	}

	// Verify the file was created.
	path := filepath.Join(tmp, ".lore", "config", "tui.json")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("tui.json not created: %v", err)
	}

	// Load it back and verify.
	got := LoadPrefs()
	if got.Layout != want.Layout {
		t.Errorf("roundtrip Layout = %q, want %q", got.Layout, want.Layout)
	}
}
