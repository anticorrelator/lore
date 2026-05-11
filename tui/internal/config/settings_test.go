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
	raw, present, err := SettingsGet("tui_launch_framework")
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
	writeSettings(t, p, `{"version":1,"tui_launch_framework":"opencode"}`)

	raw, present, err := SettingsGet("tui_launch_framework")
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

	_, _, err := SettingsGet("tui_launch_framework")
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

	if err := SettingsPatch("tui_launch_framework", "opencode"); err != nil {
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
	if doc["tui_launch_framework"] != "opencode" {
		t.Errorf("tui_launch_framework = %v, want opencode", doc["tui_launch_framework"])
	}
}

// Atomic write: the settings.json file must never be observed half-written.
// Verified indirectly by checking that Patch produces a file containing
// valid JSON even when called repeatedly (no temp files left behind).
func TestSettingsPatch_AtomicWriteLeavesNoTempFiles(t *testing.T) {
	dataDir, p := settingsTestEnv(t)
	configDir := filepath.Join(dataDir, "config")

	for i := 0; i < 5; i++ {
		if err := SettingsPatch("tui_launch_framework", "claude-code"); err != nil {
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
		"tui_launch_framework": "claude-code",
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
	if doc["tui_launch_framework"] != "claude-code" {
		t.Errorf("tui_launch_framework mutated unexpectedly: %v", doc["tui_launch_framework"])
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
	keys := []string{"tui_launch_framework", "capability_overrides.stop_hook", "roles.lead", "tui.layout"}
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
	if doc["tui_launch_framework"] != "opencode" {
		t.Errorf("tui_launch_framework = %v, want opencode", doc["tui_launch_framework"])
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

// SettingsDelete round-trip: patch a key, delete it, observe absent.
// The D9 unset gesture round-trips set → unset → absent so an explicitly
// unset overlay restores inheritance. Uses `claude-code` to exercise the
// kebab-case path the bash side handles via the path-array form (avoiding
// jq's `claude` minus `code` parse).
func TestSettingsDelete_RoundTripPatchDeleteAbsent(t *testing.T) {
	settingsTestEnv(t)

	if err := SettingsPatch("harnesses.claude-code.roles.lead", "opus"); err != nil {
		t.Fatalf("SettingsPatch: %v", err)
	}
	raw, present, err := SettingsGet("harnesses.claude-code.roles.lead")
	if err != nil || !present || raw != `"opus"` {
		t.Fatalf("after patch: present=%v raw=%q err=%v", present, raw, err)
	}

	if err := SettingsDelete("harnesses.claude-code.roles.lead"); err != nil {
		t.Fatalf("SettingsDelete: %v", err)
	}
	raw, present, err = SettingsGet("harnesses.claude-code.roles.lead")
	if err != nil {
		t.Fatalf("SettingsGet after delete: %v", err)
	}
	if present || raw != "" {
		t.Errorf("after delete: got (%q, %v), want (\"\", false)", raw, present)
	}
}

// No parent pruning: deleting a leaf must leave the parent object present
// (even if empty) so the configurator can distinguish absent from
// explicit-empty per D9. Three-pronged assertion:
//
//  1. Parent stays present and empty after the only child is deleted.
//  2. Sibling under the same parent survives a peer delete (catches a
//     bug where delete inadvertently rewrites the parent map).
//  3. Grandparent's other child (here: harnesses.claude-code.args) is
//     unchanged in value (catches a bug where the rewrite rewrote a
//     larger subtree than just the leaf parent).
func TestSettingsDelete_NoParentPruning(t *testing.T) {
	_, p := settingsTestEnv(t)

	// Stage two siblings under harnesses.claude-code.roles plus a peer
	// (.args) under the grandparent harnesses.claude-code.
	if err := SettingsPatch("harnesses.claude-code.args", []string{"--flag"}); err != nil {
		t.Fatalf("SettingsPatch args: %v", err)
	}
	if err := SettingsPatch("harnesses.claude-code.roles.lead", "opus"); err != nil {
		t.Fatalf("SettingsPatch lead: %v", err)
	}
	if err := SettingsPatch("harnesses.claude-code.roles.worker", "sonnet"); err != nil {
		t.Fatalf("SettingsPatch worker: %v", err)
	}

	if err := SettingsDelete("harnesses.claude-code.roles.lead"); err != nil {
		t.Fatalf("SettingsDelete: %v", err)
	}

	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	harnesses, ok := doc["harnesses"].(map[string]any)
	if !ok {
		t.Fatalf("harnesses missing or not an object: %v", doc["harnesses"])
	}
	cc, ok := harnesses["claude-code"].(map[string]any)
	if !ok {
		t.Fatalf("harnesses.claude-code missing or not an object: %v", harnesses["claude-code"])
	}

	// Assertion 1: parent stays present.
	roles, ok := cc["roles"].(map[string]any)
	if !ok {
		t.Fatalf("harnesses.claude-code.roles missing or not an object: %v", cc["roles"])
	}
	// Assertion 2: sibling under same parent survives.
	if roles["worker"] != "sonnet" {
		t.Errorf("sibling roles.worker should survive peer delete, got %v", roles["worker"])
	}
	if _, present := roles["lead"]; present {
		t.Errorf("roles.lead should be absent after delete")
	}
	// Assertion 3: grandparent's other child unchanged.
	args, ok := cc["args"].([]any)
	if !ok {
		t.Fatalf("harnesses.claude-code.args missing or not an array: %v", cc["args"])
	}
	if len(args) != 1 || args[0] != "--flag" {
		t.Errorf("grandparent's peer .args mutated unexpectedly: got %v, want [--flag]", args)
	}

	// Round-trip absent: a second delete on the now-absent path must be
	// a strict no-op — no write, no mtime bump.
	beforeStat, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat before second delete: %v", err)
	}
	if err := SettingsDelete("harnesses.claude-code.roles.lead"); err != nil {
		t.Fatalf("second SettingsDelete (idempotent): %v", err)
	}
	afterStat, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat after second delete: %v", err)
	}
	if !afterStat.ModTime().Equal(beforeStat.ModTime()) {
		t.Errorf("mtime bumped on absent-path second delete: before=%v after=%v",
			beforeStat.ModTime(), afterStat.ModTime())
	}
}

// Absent-path delete is byte-identical: no rename, no reformatting, no
// whitespace change. The contract says "an absent delete writes nothing"
// — verified by capturing the file's bytes before and after the call.
// This is what makes SettingsDelete safe to invoke speculatively when
// the configurator's tab navigation lands on an absent overlay field.
func TestSettingsDelete_AbsentIsByteIdentical(t *testing.T) {
	_, p := settingsTestEnv(t)

	// Stage a file with deliberately non-canonical formatting (a foreign
	// writer's whitespace) — if SettingsDelete on an absent key
	// re-marshals via MarshalIndent it will trample this layout.
	original := "{\n\"version\": 1,\n  \"tui_launch_framework\":\"opencode\"\n}\n"
	writeSettings(t, p, original)

	if err := SettingsDelete("nonexistent.path"); err != nil {
		t.Fatalf("SettingsDelete absent: %v", err)
	}

	after, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read after: %v", err)
	}
	if string(after) != original {
		t.Errorf("file mutated on absent-delete: got %q, want %q", string(after), original)
	}
}

// Missing settings.json → SettingsDelete is a no-op (does not create the
// file). Mirrors the bash side's `[[ -f $SETTINGS_FILE ]] || return 0`.
func TestSettingsDelete_MissingFileIsNoOp(t *testing.T) {
	_, p := settingsTestEnv(t)
	if _, err := os.Stat(p); err == nil {
		t.Fatal("settings.json should not exist before Delete")
	}

	if err := SettingsDelete("anything.at.all"); err != nil {
		t.Fatalf("SettingsDelete on missing file: %v", err)
	}
	if _, err := os.Stat(p); err == nil {
		t.Errorf("SettingsDelete on missing file must not create %s", p)
	}
}

// Idempotent repeated delete: a second delete of the same path is a no-op.
func TestSettingsDelete_IdempotentRepeated(t *testing.T) {
	settingsTestEnv(t)

	if err := SettingsPatch("roles.lead", "opus"); err != nil {
		t.Fatalf("SettingsPatch: %v", err)
	}
	if err := SettingsDelete("roles.lead"); err != nil {
		t.Fatalf("first SettingsDelete: %v", err)
	}
	if err := SettingsDelete("roles.lead"); err != nil {
		t.Fatalf("second SettingsDelete (idempotent no-op): %v", err)
	}
	raw, present, err := SettingsGet("roles.lead")
	if err != nil || present || raw != "" {
		t.Errorf("after two deletes: got (%q, %v) err=%v, want (\"\", false, nil)", raw, present, err)
	}
}

func TestSettingsDelete_RejectsEmptyPath(t *testing.T) {
	settingsTestEnv(t)
	if err := SettingsDelete(""); err == nil {
		t.Fatal("expected error for empty path, got nil")
	}
}

// Malformed JSON on disk → SettingsError; file untouched. The configurator
// must surface the parse error rather than overwrite the user's file.
func TestSettingsDelete_MalformedJSON_ReturnsSettingsError(t *testing.T) {
	_, p := settingsTestEnv(t)
	const malformed = `not even close to JSON`
	writeSettings(t, p, malformed)

	err := SettingsDelete("roles.lead")
	if err == nil {
		t.Fatal("expected SettingsError for malformed JSON, got nil")
	}
	if _, ok := err.(*SettingsError); !ok {
		t.Errorf("error type = %T, want *SettingsError; err = %v", err, err)
	}
	after, _ := os.ReadFile(p)
	if string(after) != malformed {
		t.Errorf("file mutated on parse failure: got %q, want %q", string(after), malformed)
	}
}

// Non-object intermediate must error rather than silently destroy the
// scalar — mirrors SettingsPatch's safety on the same path shape.
func TestSettingsDelete_RejectsNonObjectIntermediate(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{"version":1,"roles":"not-an-object"}`)

	err := SettingsDelete("roles.lead")
	if err == nil {
		t.Fatal("expected error deleting through non-object intermediate, got nil")
	}
	data, _ := os.ReadFile(p)
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if doc["roles"] != "not-an-object" {
		t.Errorf("roles mutated unexpectedly: %v", doc["roles"])
	}
}

// Delete of a key whose value is explicit JSON null still removes the key.
// SettingsDelete treats present-key uniformly regardless of leaf value.
func TestSettingsDelete_ExplicitNullValue(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{"version":1,"roles":{"lead":null,"default":"sonnet"}}`)

	if err := SettingsDelete("roles.lead"); err != nil {
		t.Fatalf("SettingsDelete: %v", err)
	}
	raw, present, err := SettingsGet("roles.lead")
	if err != nil || present || raw != "" {
		t.Errorf("after delete of null: got (%q, %v) err=%v, want (\"\", false, nil)", raw, present, err)
	}
	raw, present, err = SettingsGet("roles.default")
	if err != nil || !present || raw != `"sonnet"` {
		t.Errorf("sibling roles.default lost: got (%q, %v) err=%v", raw, present, err)
	}
}

// Delete on one path preserves unrelated keys verbatim.
func TestSettingsDelete_PreservesUnrelatedKeys(t *testing.T) {
	_, p := settingsTestEnv(t)
	writeSettings(t, p, `{
		"version": 1,
		"tui_launch_framework": "claude-code",
		"capability_overrides": {"stop_hook": "full"},
		"roles": {"lead": "opus", "default": "sonnet"}
	}`)

	if err := SettingsDelete("roles.lead"); err != nil {
		t.Fatalf("SettingsDelete: %v", err)
	}

	data, _ := os.ReadFile(p)
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if doc["tui_launch_framework"] != "claude-code" {
		t.Errorf("tui_launch_framework mutated: %v", doc["tui_launch_framework"])
	}
	roles := doc["roles"].(map[string]any)
	if _, present := roles["lead"]; present {
		t.Errorf("roles.lead should be absent")
	}
	if roles["default"] != "sonnet" {
		t.Errorf("roles.default mutated: %v", roles["default"])
	}
	caps := doc["capability_overrides"].(map[string]any)
	if caps["stop_hook"] != "full" {
		t.Errorf("capability_overrides.stop_hook mutated: %v", caps["stop_hook"])
	}
}

func TestSettingsFallbacks_IgnoresLegacyFilesWhenUnifiedAbsent(t *testing.T) {
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
	if len(got) != 0 {
		t.Fatalf("legacy fallback rows should be disabled, got %v", got)
	}
}

func TestSettingsFallbacks_OmitsRowsCoveredByUnified(t *testing.T) {
	dataDir, p := settingsTestEnv(t)
	configDir := filepath.Join(dataDir, "config")
	// Stage settings.json that covers tui_launch_framework.
	writeSettings(t, p, `{"version":1,"tui_launch_framework":"opencode"}`)
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
	if len(got) != 0 {
		t.Fatalf("legacy fallback rows should be disabled, got %v", got)
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
