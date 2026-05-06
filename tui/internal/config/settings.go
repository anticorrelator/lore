// Package config: settings.go is the Go mirror of the unified user-settings
// loader at scripts/settings.sh and scripts/lore_settings.py (D5/D5a). The
// three loaders share a parity contract so a value written by one is visible
// to the others byte-for-byte (modulo JSON serializer formatting), and a key
// missing from the unified file falls back to the legacy fragmented file in
// every stack identically.
//
// Read contract (D5):
//   - Get(path) returns the raw JSON-encoded value at the dot-separated path,
//     or ("", false, nil) when the key is absent. The bool return ("present")
//     distinguishes absence from explicit JSON null — mirrors the absent-vs-null
//     surface scripts/settings.sh's cmd_get exposes via empty stdout vs "null".
//   - Section(name) returns the named top-level object as a json.RawMessage,
//     or ("{}", nil) when the section is absent. Always returns a JSON object
//     literal so callers can json.Unmarshal into a struct without nil checks.
//   - Path() returns the resolved settings.json absolute path.
//   - Fallbacks() returns the deterministic snapshot of "<file>::<key>" pairs
//     whose unified key is absent and whose legacy fragmented file is on disk.
//     Order is stable so `lore doctor` can diff against prior runs.
//
// Write contract (D5a):
//   - Patch(path, value) acquires an exclusive flock on the same lock file
//     scripts/settings.sh and scripts/lore_settings.py use
//     (<data_dir>/config/.settings.lock), reads the full document, modifies
//     only the targeted dot-path (creating intermediate objects as needed),
//     and writes back atomically via os.Rename. Concurrent writers compose:
//     two parallel patches against different paths both land — neither
//     overwrites the other.
//
// Failure handling:
//   - Missing settings.json is NOT an error: Get returns ("", false, nil),
//     Section returns ("{}", nil), Fallbacks reports every legacy pair as
//     missing-from-unified. Mirrors the bash and Python loaders.
//   - Malformed JSON is a hard error with an actionable message naming
//     `lore doctor`.
//
// Closed-set rejection lives one layer up (resolve_active_framework /
// resolve_model_for_role); this loader is a typed accessor, not a validator.
//
// Bash counterparts in scripts/settings.sh: cmd_get, cmd_section, cmd_path,
// cmd_patch, cmd_fallbacks. Python counterparts in scripts/lore_settings.py:
// get, section, path, set, fallbacks.
package config

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
)

// SettingsError is returned when settings.json is unreadable or malformed.
// Mirrors scripts/lore_settings.py SettingsError.
type SettingsError struct{ msg string }

func (e *SettingsError) Error() string { return e.msg }

// settingsFallbackPair lists "<legacy_file>::<unified_dot_path>" rows reported
// by Fallbacks() when the unified key is absent and the fragmented file is on
// disk. Mirrors the table in scripts/settings.sh cmd_fallbacks (the bash side
// is the canonical list because lore doctor consumes settings.sh fallbacks
// directly; the Go list exists so Go-only callers see the same snapshot).
// Each row encodes (unified_dot_path, legacy_file_basename, legacy_jq_key).
type settingsFallbackPair struct {
	unifiedPath  string
	legacyFile   string
	legacyKey    string // "<all>" marks files read whole rather than by single key
	legacyAtRoot bool   // true → legacy file lives at $LORE_DATA_DIR/, not $LORE_DATA_DIR/config/
}

var settingsFallbackTable = []settingsFallbackPair{
	{"active_framework", "framework.json", "framework", false},
	{"capability_overrides", "framework.json", "capability_overrides", false},
	{"roles", "framework.json", "roles", false},
	{"harnesses", "harness-args.json", "harnesses", false},
	{"agent.enabled", "agent.json", "enabled", false},
	{"obsidian.vault_path", "obsidian.json", "vault_path", false},
	{"obsidian.repo_path", "obsidian.json", "repo_path", false},
	{"ceremonies", "ceremonies.json", "<all>", true},
}

// settingsDataDir returns LORE_DATA_DIR or ~/.lore. Mirrors _data_dir in
// scripts/lore_settings.py and the LORE_DATA_DIR resolution at the top of
// scripts/settings.sh.
func settingsDataDir() string {
	if env := os.Getenv("LORE_DATA_DIR"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".lore")
}

func settingsConfigDir() string {
	return filepath.Join(settingsDataDir(), "config")
}

// SettingsPath returns the resolved absolute path to settings.json.
// Bash counterpart: scripts/settings.sh cmd_path.
func SettingsPath() string {
	return filepath.Join(settingsConfigDir(), "settings.json")
}

func settingsLockPath() string {
	return filepath.Join(settingsConfigDir(), ".settings.lock")
}

// loadSettingsDocument reads settings.json into a generic map. Missing file →
// empty map (not an error); malformed → SettingsError. Mirrors
// scripts/lore_settings.py _load_document.
func loadSettingsDocument() (map[string]any, error) {
	p := SettingsPath()
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{}, nil
		}
		return nil, err
	}
	var doc any
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, &SettingsError{
			msg: fmt.Sprintf("invalid JSON in %s: %v — run `lore doctor` to diagnose", p, err),
		}
	}
	m, ok := doc.(map[string]any)
	if !ok {
		return nil, &SettingsError{
			msg: fmt.Sprintf("invalid JSON in %s: top-level value is not an object", p),
		}
	}
	return m, nil
}

// resolveSettingsDotPath walks a dot-separated path through nested map[string]any.
// Returns (value, true) on hit, (nil, false) on absence at any segment.
// Explicit JSON null is represented as (nil, true) so callers can disambiguate
// absence from an explicit null. Mirrors _resolve_dot_path in
// scripts/lore_settings.py and the recursive has_path walk in
// scripts/settings.sh cmd_get.
func resolveSettingsDotPath(doc map[string]any, dotPath string) (any, bool) {
	if dotPath == "" {
		return nil, false
	}
	segments := strings.Split(dotPath, ".")
	var node any = doc
	for _, segment := range segments {
		m, ok := node.(map[string]any)
		if !ok {
			return nil, false
		}
		v, present := m[segment]
		if !present {
			return nil, false
		}
		node = v
	}
	return node, true
}

// SettingsGet reads the value at a dot-separated path and returns it as the
// raw JSON-encoded literal (e.g. `"opus"`, `["--flag"]`, `42`, `null`). The
// `present` bool distinguishes absence from explicit JSON null — mirrors the
// bash side's "empty stdout vs 'null'" surface and the Python side's
// `is None` vs `key not in section()` disambiguation.
//
// Returns ("", false, nil) when:
//   - settings.json is missing entirely (the loader treats absence as "all
//     keys missing", same as bash and Python),
//   - the key is absent at any segment of the dot-path.
//
// Bash counterpart: scripts/settings.sh cmd_get. Python counterpart:
// scripts/lore_settings.py get.
func SettingsGet(dotPath string) (raw string, present bool, err error) {
	if dotPath == "" {
		return "", false, fmt.Errorf("SettingsGet requires a path")
	}
	doc, err := loadSettingsDocument()
	if err != nil {
		return "", false, err
	}
	v, ok := resolveSettingsDotPath(doc, dotPath)
	if !ok {
		return "", false, nil
	}
	out, err := json.Marshal(v)
	if err != nil {
		return "", false, fmt.Errorf("re-encode %s: %w", dotPath, err)
	}
	return string(out), true, nil
}

// SettingsSection returns the named top-level object as a json.RawMessage.
// Always returns a JSON object literal: "{}" when the section is absent, or
// the section's raw bytes when present. A non-object top-level value is
// treated as absence (returns "{}") rather than an error so callers can
// fall through to fragmented-file fallback during the deprecation window —
// mirrors scripts/lore_settings.py section.
//
// Bash counterpart: scripts/settings.sh cmd_section.
func SettingsSection(name string) (json.RawMessage, error) {
	if name == "" {
		return nil, fmt.Errorf("SettingsSection requires a section name")
	}
	doc, err := loadSettingsDocument()
	if err != nil {
		return nil, err
	}
	v, ok := doc[name]
	if !ok {
		return json.RawMessage("{}"), nil
	}
	if _, isObj := v.(map[string]any); !isObj {
		return json.RawMessage("{}"), nil
	}
	out, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("re-encode section %s: %w", name, err)
	}
	return json.RawMessage(out), nil
}

// SettingsFallbacks returns a deterministic snapshot of "<legacy_file>::<key>"
// pairs whose unified key is absent at the documented dot-path AND whose
// legacy fragmented file currently exists on disk. Order is stable so
// `lore doctor` can diff against prior runs.
//
// The return shape matches the bash cmd_fallbacks output (one
// "<file>::<key>" string per legacy pair); callers that need the structured
// pair can split on "::". Empty slice means every legacy reader has been
// migrated.
//
// Bash counterpart: scripts/settings.sh cmd_fallbacks. Python counterpart:
// scripts/lore_settings.py fallbacks.
func SettingsFallbacks() ([]string, error) {
	doc, err := loadSettingsDocument()
	if err != nil {
		return nil, err
	}
	dataDir := settingsDataDir()

	var out []string
	for _, row := range settingsFallbackTable {
		// Skip if the unified key is present (no fallback needed).
		if _, ok := resolveSettingsDotPath(doc, row.unifiedPath); ok {
			continue
		}
		var legacyPath string
		if row.legacyAtRoot {
			legacyPath = filepath.Join(dataDir, row.legacyFile)
		} else {
			legacyPath = filepath.Join(dataDir, "config", row.legacyFile)
		}
		if _, statErr := os.Stat(legacyPath); statErr != nil {
			continue
		}
		out = append(out, row.legacyFile+"::"+row.legacyKey)
	}
	return out, nil
}

// setSettingsDotPath assigns value at dot_path inside doc, creating
// intermediate objects as needed. Errors when an intermediate segment exists
// but is not a map — mirrors scripts/lore_settings.py _set_dot_path so
// overwriting a non-object intermediate cannot silently destroy unrelated
// data.
func setSettingsDotPath(doc map[string]any, dotPath string, value any) error {
	if dotPath == "" {
		return fmt.Errorf("SettingsPatch: empty path")
	}
	segments := strings.Split(dotPath, ".")
	node := doc
	for i, segment := range segments[:len(segments)-1] {
		next, exists := node[segment]
		if !exists {
			child := map[string]any{}
			node[segment] = child
			node = child
			continue
		}
		child, ok := next.(map[string]any)
		if !ok {
			return fmt.Errorf(
				"SettingsPatch: cannot descend into non-object at %q (path: %s, segment %d)",
				segment, dotPath, i,
			)
		}
		node = child
	}
	node[segments[len(segments)-1]] = value
	return nil
}

// settingsLockMutex is an in-process mutex layered atop the cross-process
// flock so concurrent goroutines in the same TUI process serialize before
// touching the lock file (Linux's fcntl(LOCK_EX) is per-process; without
// this, two goroutines in the same process could both believe they hold
// the lock).
var settingsLockMutex sync.Mutex

// SettingsPatch implements the D5a write contract: lock-protected
// read-modify-write with atomic rename. Acquires an exclusive flock on
// <data_dir>/config/.settings.lock — the same lock file the bash and Python
// loaders use, so a Go writer and a bash writer composing different sections
// of settings.json never overwrite each other.
//
// `value` is encoded via encoding/json and written verbatim at the dot-path,
// creating intermediate objects as needed. Unrelated keys, sections, and
// keys this writer doesn't recognize are preserved verbatim.
//
// Bash counterpart: scripts/settings.sh cmd_patch. Python counterpart:
// scripts/lore_settings.py set.
func SettingsPatch(dotPath string, value any) error {
	if dotPath == "" {
		return fmt.Errorf("SettingsPatch requires a path")
	}
	configDir := settingsConfigDir()
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("create %s: %w", configDir, err)
	}

	settingsLockMutex.Lock()
	defer settingsLockMutex.Unlock()

	lockPath := settingsLockPath()
	lockFD, err := os.OpenFile(lockPath, os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return fmt.Errorf("open lock %s: %w", lockPath, err)
	}
	defer lockFD.Close()

	if err := syscall.Flock(int(lockFD.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("acquire flock on %s: %w", lockPath, err)
	}
	defer syscall.Flock(int(lockFD.Fd()), syscall.LOCK_UN)

	// Read fresh under the lock so concurrent writers compose.
	doc := map[string]any{}
	settingsPath := SettingsPath()
	if data, readErr := os.ReadFile(settingsPath); readErr == nil {
		var parsed any
		if err := json.Unmarshal(data, &parsed); err != nil {
			return &SettingsError{
				msg: fmt.Sprintf("invalid JSON in %s: %v — run `lore doctor` to diagnose", settingsPath, err),
			}
		}
		m, ok := parsed.(map[string]any)
		if !ok {
			return &SettingsError{
				msg: fmt.Sprintf("invalid JSON in %s: top-level value is not an object", settingsPath),
			}
		}
		doc = m
	} else if !os.IsNotExist(readErr) {
		return fmt.Errorf("read %s: %w", settingsPath, readErr)
	}

	// Round-trip the caller's value through encoding/json so the on-disk
	// shape matches what a Python or bash writer would produce for the same
	// logical value (e.g. []string → JSON array, json.RawMessage → its
	// embedded literal).
	encoded, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("marshal value for %s: %w", dotPath, err)
	}
	var roundtrip any
	if err := json.Unmarshal(encoded, &roundtrip); err != nil {
		return fmt.Errorf("re-decode value for %s: %w", dotPath, err)
	}
	if err := setSettingsDotPath(doc, dotPath, roundtrip); err != nil {
		return err
	}

	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal settings doc: %w", err)
	}
	out = append(out, '\n')

	tmp, err := os.CreateTemp(configDir, ".settings.*.tmp")
	if err != nil {
		return fmt.Errorf("create tempfile in %s: %w", configDir, err)
	}
	tmpPath := tmp.Name()
	cleanup := func() {
		_ = os.Remove(tmpPath)
	}
	if _, err := io.WriteString(tmp, string(out)); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("write tempfile %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("close tempfile %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, settingsPath); err != nil {
		cleanup()
		return fmt.Errorf("rename %s -> %s: %w", tmpPath, settingsPath, err)
	}
	return nil
}
