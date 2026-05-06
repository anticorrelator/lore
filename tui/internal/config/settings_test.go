package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
)

// settingsTestEnv stages an isolated LORE_DATA_DIR with a config/ subdir.
// Returns the data dir and the resolved settings.json path.
func settingsTestEnv(t *testing.T) (dataDir, settingsPath string) {
	t.Helper()
	dataDir = t.TempDir()
	if err := os.MkdirAll(filepath.Join(dataDir, "config"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LORE_DATA_DIR", dataDir)
	return dataDir, filepath.Join(dataDir, "config", "settings.json")
}

func writeSettings(t *testing.T, settingsPath, body string) {
	t.Helper()
	if err := os.WriteFile(settingsPath, []byte(body), 0644); err != nil {
		t.Fatalf("write %s: %v", settingsPath, err)
	}
}

func TestSettingsPath_HonorsLoreDataDir(t *testing.T) {
	dataDir, want := settingsTestEnv(t)
	got := SettingsPath()
	if got != want {
		t.Errorf("SettingsPath() = %q, want %q (LORE_DATA_DIR=%s)", got, want, dataDir)
	}
}

func TestSettingsGet_Absent_ReturnsEmptyAndFalse(t *testing.T) {
	settingsTestEnv(t)
	// No settings.json on disk.
	raw, present, err := SettingsGet("active_framework")
	if err != nil {
		t.Fatalf("SettingsGet: %v", err)
	}
	if present {
		t.Errorf("present = true on missing file, want false")
	}
	if raw != "" {
		t.Errorf("raw = %q, want empty string on absence", raw)
	}
}

func TestSettingsGet_Present_NonNullValue(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{"version":1,"active_framework":"opencode"}`)

	raw, present, err := SettingsGet("active_framework")
	if err != nil {
		t.Fatalf("SettingsGet: %v", err)
	}
	if !present {
		t.Fatal("present = false, want true")
	}
	if raw != `"opencode"` {
		t.Errorf("raw = %q, want %q", raw, `"opencode"`)
	}
}

// Absent vs explicit null — the load-bearing distinction the bash side
// surfaces via empty stdout vs "null", and the Python side via key-not-in-section
// vs `is None`. The Go side returns ("", false) on absence and ("null", true)
// on explicit JSON null.
func TestSettingsGet_AbsentVsNull(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{"version":1,"roles":{"lead":null}}`)

	// Absent key → present=false.
	raw, present, err := SettingsGet("roles.worker")
	if err != nil {
		t.Fatalf("SettingsGet absent: %v", err)
	}
	if present || raw != "" {
		t.Errorf("absent: got (%q, %v), want (\"\", false)", raw, present)
	}

	// Explicit null → present=true with raw "null".
	raw, present, err = SettingsGet("roles.lead")
	if err != nil {
		t.Fatalf("SettingsGet null: %v", err)
	}
	if !present || raw != "null" {
		t.Errorf("explicit null: got (%q, %v), want (\"null\", true)", raw, present)
	}
}

// Dot-paths with dashes (claude-code) must round-trip through both Get
// and Patch. This is the bash side's `_path_to_array` parity invariant
// (scripts/settings.sh:71-78).
func TestSettingsGet_DotPathWithDashes(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{
		"version": 1,
		"harnesses": {
			"claude-code": {
				"args": ["--dangerously-skip-permissions"]
			}
		}
	}`)

	raw, present, err := SettingsGet("harnesses.claude-code.args")
	if err != nil {
		t.Fatalf("SettingsGet: %v", err)
	}
	if !present {
		t.Fatal("present = false, want true")
	}
	var got []string
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("decode args: %v", err)
	}
	if len(got) != 1 || got[0] != "--dangerously-skip-permissions" {
		t.Errorf("got %v, want [--dangerously-skip-permissions]", got)
	}
}

func TestSettingsGet_RejectsEmptyPath(t *testing.T) {
	settingsTestEnv(t)
	_, _, err := SettingsGet("")
	if err == nil {
		t.Fatal("expected error for empty path, got nil")
	}
}

func TestSettingsGet_MalformedJSON_ReturnsSettingsError(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `not even close to JSON`)

	_, _, err := SettingsGet("active_framework")
	if err == nil {
		t.Fatal("expected SettingsError for malformed JSON, got nil")
	}
	if _, ok := err.(*SettingsError); !ok {
		t.Errorf("error type = %T, want *SettingsError; err = %v", err, err)
	}
}

func TestSettingsSection_AbsentReturnsEmptyObject(t *testing.T) {
	settingsTestEnv(t)
	got, err := SettingsSection("tui")
	if err != nil {
		t.Fatalf("SettingsSection: %v", err)
	}
	if string(got) != "{}" {
		t.Errorf("got %s, want {} on missing file", got)
	}
}

func TestSettingsSection_Present(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{"version":1,"tui":{"layout":"top-bottom"}}`)

	got, err := SettingsSection("tui")
	if err != nil {
		t.Fatalf("SettingsSection: %v", err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(got, &parsed); err != nil {
		t.Fatalf("decode section: %v", err)
	}
	if parsed["layout"] != "top-bottom" {
		t.Errorf("layout = %v, want top-bottom", parsed["layout"])
	}
}

func TestSettingsPatch_CreatesFileIfAbsent(t *testing.T) {
	_, p := settingsTestEnv(t)
	if _, err := os.Stat(p); err == nil {
		t.Fatal("settings.json should not exist before Patch")
	}

	if err := SettingsPatch("active_framework", "opencode"); err != nil {
		t.Fatalf("SettingsPatch: %v", err)
	}

	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if doc["active_framework"] != "opencode" {
		t.Errorf("active_framework = %v, want opencode", doc["active_framework"])
	}
}

// Atomic write: the settings.json file must never be observed half-written.
// Verified indirectly by checking that Patch produces a file containing
// valid JSON even when called repeatedly (no temp files left behind).
func TestSettingsPatch_AtomicWriteLeavesNoTempFiles(t *testing.T) {
	dataDir, p := settingsTestEnv(t)
	configDir := filepath.Join(dataDir, "config")

	for i := 0; i < 5; i++ {
		if err := SettingsPatch("active_framework", "claude-code"); err != nil {
			t.Fatalf("SettingsPatch %d: %v", i, err)
		}
	}

	// settings.json must exist and parse.
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}

	// No `.settings.*.tmp` files should be left behind.
	entries, err := os.ReadDir(configDir)
	if err != nil {
		t.Fatalf("readdir %s: %v", configDir, err)
	}
	for _, e := range entries {
		name := e.Name()
		if name == "settings.json" || name == ".settings.lock" {
			continue
		}
		t.Errorf("unexpected leftover file in %s: %s", configDir, name)
	}
}

// Patch on one path must preserve unrelated keys verbatim — this is the D5a
// "byte-for-byte preservation" contract.
func TestSettingsPatch_PreservesUnrelatedKeys(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{
		"version": 1,
		"active_framework": "claude-code",
		"capability_overrides": {"stop_hook": "full"},
		"roles": {"lead": "opus", "default": "sonnet"}
	}`)

	if err := SettingsPatch("roles.lead", "haiku"); err != nil {
		t.Fatalf("SettingsPatch: %v", err)
	}

	data, _ := os.ReadFile(p)
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// Mutated key landed.
	roles := doc["roles"].(map[string]any)
	if roles["lead"] != "haiku" {
		t.Errorf("lead = %v, want haiku", roles["lead"])
	}
	// Unrelated keys preserved.
	if roles["default"] != "sonnet" {
		t.Errorf("roles.default mutated unexpectedly: %v", roles["default"])
	}
	if doc["active_framework"] != "claude-code" {
		t.Errorf("active_framework mutated unexpectedly: %v", doc["active_framework"])
	}
	caps := doc["capability_overrides"].(map[string]any)
	if caps["stop_hook"] != "full" {
		t.Errorf("capability_overrides mutated unexpectedly: %v", caps)
	}
}

// Patch with a non-object intermediate must error rather than silently
// destroy unrelated data — mirrors lore_settings.py _set_dot_path safety.
func TestSettingsPatch_RejectsNonObjectIntermediate(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{"version":1,"roles":"not-an-object"}`)

	err := SettingsPatch("roles.lead", "opus")
	if err == nil {
		t.Fatal("expected error patching through non-object intermediate, got nil")
	}
}

// In-process concurrency: parallel goroutines patching different paths
// must both land. The cross-process flock is layered atop a sync.Mutex
// so two goroutines in the same process serialize correctly.
func TestSettingsPatch_ConcurrentDifferentPaths(t *testing.T) {
	_, p := settingsTestEnv(t)

	var wg sync.WaitGroup
	keys := []string{"active_framework", "capability_overrides.stop_hook", "roles.lead", "tui.layout"}
	values := []string{"opencode", "full", "opus", "top-bottom"}
	wg.Add(len(keys))
	for i := range keys {
		go func(k, v string) {
			defer wg.Done()
			if err := SettingsPatch(k, v); err != nil {
				t.Errorf("SettingsPatch(%s, %s): %v", k, v, err)
			}
		}(keys[i], values[i])
	}
	wg.Wait()

	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if doc["active_framework"] != "opencode" {
		t.Errorf("active_framework = %v, want opencode", doc["active_framework"])
	}
	caps := doc["capability_overrides"].(map[string]any)
	if caps["stop_hook"] != "full" {
		t.Errorf("capability_overrides.stop_hook = %v, want full", caps["stop_hook"])
	}
	roles := doc["roles"].(map[string]any)
	if roles["lead"] != "opus" {
		t.Errorf("roles.lead = %v, want opus", roles["lead"])
	}
	tui := doc["tui"].(map[string]any)
	if tui["layout"] != "top-bottom" {
		t.Errorf("tui.layout = %v, want top-bottom", tui["layout"])
	}
}

// Patch with a JSON array value (the harnesses.<n>.args shape).
func TestSettingsPatch_ArrayValueRoundtrips(t *testing.T) {
	_, p := settingsTestEnv(t)
	args := []string{"--flag-a", "--flag-b"}
	if err := SettingsPatch("harnesses.claude-code.args", args); err != nil {
		t.Fatalf("SettingsPatch: %v", err)
	}

	raw, present, err := SettingsGet("harnesses.claude-code.args")
	if err != nil || !present {
		t.Fatalf("SettingsGet after patch: present=%v err=%v", present, err)
	}
	var got []string
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got) != 2 || got[0] != "--flag-a" || got[1] != "--flag-b" {
		t.Errorf("got %v, want %v", got, args)
	}
	_ = p
}

func TestSettingsFallbacks_ListsLegacyFilesWhenUnifiedAbsent(t *testing.T) {
	dataDir, _ := settingsTestEnv(t)
	configDir := filepath.Join(dataDir, "config")
	// Stage a legacy framework.json (no settings.json).
	if err := os.WriteFile(
		filepath.Join(configDir, "framework.json"),
		[]byte(`{"version":1,"framework":"claude-code"}`),
		0644,
	); err != nil {
		t.Fatal(err)
	}
	// Stage a legacy obsidian.json.
	if err := os.WriteFile(
		filepath.Join(configDir, "obsidian.json"),
		[]byte(`{"vault_path":"/tmp"}`),
		0644,
	); err != nil {
		t.Fatal(err)
	}

	got, err := SettingsFallbacks()
	if err != nil {
		t.Fatalf("SettingsFallbacks: %v", err)
	}
	want := map[string]bool{
		"framework.json::framework":            true,
		"framework.json::capability_overrides": true,
		"framework.json::roles":                true,
		"obsidian.json::vault_path":            true,
		"obsidian.json::repo_path":             true,
	}
	for _, row := range got {
		if !want[row] {
			t.Errorf("unexpected fallback row: %s", row)
		}
	}
	// Spot-check at least the framework rows are listed.
	gotSet := map[string]bool{}
	for _, row := range got {
		gotSet[row] = true
	}
	for w := range want {
		if !gotSet[w] {
			t.Errorf("missing expected fallback row: %s", w)
		}
	}
}

func TestSettingsFallbacks_OmitsRowsCoveredByUnified(t *testing.T) {
	dataDir, p := settingsTestEnv(t)
	configDir := filepath.Join(dataDir, "config")
	// Stage settings.json that covers active_framework.
	writeSettings(t, p, `{"version":1,"active_framework":"opencode"}`)
	// Stage a legacy framework.json that would otherwise be a fallback source.
	if err := os.WriteFile(
		filepath.Join(configDir, "framework.json"),
		[]byte(`{"version":1,"framework":"claude-code"}`),
		0644,
	); err != nil {
		t.Fatal(err)
	}

	got, err := SettingsFallbacks()
	if err != nil {
		t.Fatalf("SettingsFallbacks: %v", err)
	}
	for _, row := range got {
		if row == "framework.json::framework" {
			t.Errorf("framework.json::framework should NOT be in fallbacks (active_framework is covered)")
		}
	}
}

func TestSettingsFallbacks_DeterministicOrder(t *testing.T) {
	dataDir, _ := settingsTestEnv(t)
	configDir := filepath.Join(dataDir, "config")
	for _, f := range []string{"framework.json", "harness-args.json", "agent.json", "obsidian.json"} {
		if err := os.WriteFile(filepath.Join(configDir, f), []byte(`{}`), 0644); err != nil {
			t.Fatal(err)
		}
	}

	first, err := SettingsFallbacks()
	if err != nil {
		t.Fatalf("SettingsFallbacks first: %v", err)
	}
	second, err := SettingsFallbacks()
	if err != nil {
		t.Fatalf("SettingsFallbacks second: %v", err)
	}
	if len(first) != len(second) {
		t.Fatalf("len mismatch first=%d second=%d", len(first), len(second))
	}
	// Already deterministic via static table, but verify by comparing slices
	// rather than sorting (sorting would mask an order regression).
	for i := range first {
		if first[i] != second[i] {
			t.Errorf("order differs at %d: first=%q second=%q", i, first[i], second[i])
		}
	}
	// Sanity: the slice itself sorts to the same set on both runs.
	cp1 := append([]string{}, first...)
	cp2 := append([]string{}, second...)
	sort.Strings(cp1)
	sort.Strings(cp2)
	for i := range cp1 {
		if cp1[i] != cp2[i] {
			t.Errorf("set differs at %d: %q vs %q", i, cp1[i], cp2[i])
		}
	}
}
