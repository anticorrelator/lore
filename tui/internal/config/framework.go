// Package config helpers in this file are the Go side of a dual-implementation
// contract with scripts/lib.sh. Every exported function below names its bash
// counterpart in its docblock; both sides must round-trip identically against
// the same on-disk inputs (LORE_DATA_DIR/config/{framework,harness-args}.json,
// adapters/capabilities.json, adapters/roles.json, .lore.config in the
// project tree). The dual surface exists because lore is invoked from both
// shell scripts (skills, hooks, install) and the Go TUI; divergence between
// the two would let a config change land for one harness path and silently
// not for the other.
//
// Parity rules:
//  1. Resolution precedence MUST match byte-for-byte (env → per-repo →
//     user → harness default for resolve_model_for_role; env → user →
//     built-in default for resolve_active_framework).
//  2. Closed-set rejection MUST match: an unknown framework, role, or kind
//     errors out, never routes to a default. Silent defaults are an explicit
//     anti-pattern (see feedback_dont_reintroduce_defaults in lore memory).
//  3. The `unsupported` literal in adapters/capabilities.json install_paths
//     is a first-class return value, not an error: bash returns it on stdout
//     with exit 0; Go returns ("", false, nil). Both forms encode the same
//     "no native equivalent on this harness" semantic.
//  4. T11's adapters/README.md is the canonical contract document; this
//     file's docblocks are the implementation-side mirrors.
package config

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// HarnessInstallKind enumerates the closed set of installation surfaces lore
// can target on a harness. New kinds MUST be added here, in scripts/lib.sh
// resolve_harness_install_path's case statement, and in
// adapters/capabilities.json install_paths blocks together. Going through
// this list is what tests/frameworks/install.bats validates for parity
// between bash and Go.
var HarnessInstallKinds = []string{
	"instructions",
	"skills",
	"agents",
	"settings",
	"teams",
	"ephemeral_plans",
	"mcp_servers",
}

// UnsupportedSentinel is the literal stored in adapters/capabilities.json
// install_paths to mark a kind that has no equivalent on the active harness
// (e.g., codex teams). Mirrors the bash sentinel returned by
// resolve_harness_install_path.
const UnsupportedSentinel = "unsupported"

// loreRepoDir resolves the lore repo root by following the
// ~/.lore/scripts -> <repo>/scripts symlink that install.sh creates. This
// matches the bash convention where lib.sh treats $LORE_LIB_DIR/.. as the
// repo root.
func loreRepoDir() (string, error) {
	dataRoot := os.Getenv("LORE_DATA_DIR")
	if dataRoot == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home: %w", err)
		}
		dataRoot = filepath.Join(home, ".lore")
	}
	scripts := filepath.Join(dataRoot, "scripts")
	target, err := filepath.EvalSymlinks(scripts)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", scripts, err)
	}
	return filepath.Dir(target), nil
}

// frameworkConfigPath returns the user-config framework.json path.
func frameworkConfigPath() string {
	dataRoot := os.Getenv("LORE_DATA_DIR")
	if dataRoot == "" {
		home, _ := os.UserHomeDir()
		dataRoot = filepath.Join(home, ".lore")
	}
	return filepath.Join(dataRoot, "config", "framework.json")
}

// userFrameworkConfig is the on-disk shape written by install.sh and read by
// the Go-side helpers. Mirrors the schema documented at install.sh:212.
type userFrameworkConfig struct {
	Version             int               `json:"version"`
	Framework           string            `json:"framework"`
	CapabilityOverrides map[string]string `json:"capability_overrides"`
	Roles               map[string]string `json:"roles"`
}

func loadUserFrameworkConfig() userFrameworkConfig {
	var cfg userFrameworkConfig
	data, err := os.ReadFile(frameworkConfigPath())
	if err != nil {
		return cfg
	}
	_ = json.Unmarshal(data, &cfg)
	return cfg
}

// capabilitiesProfile is the slice of adapters/capabilities.json that the
// install_paths and resolver helpers touch. Other framework fields are
// ignored here.
type capabilitiesProfile struct {
	DisplayName  string            `json:"display_name"`
	InstallPaths map[string]string `json:"install_paths"`
}

// capabilitiesFile is the top-level shape of adapters/capabilities.json.
type capabilitiesFile struct {
	Frameworks map[string]capabilitiesProfile `json:"frameworks"`
}

func loadCapabilitiesFile() (capabilitiesFile, error) {
	repo, err := loreRepoDir()
	if err != nil {
		return capabilitiesFile{}, err
	}
	path := filepath.Join(repo, "adapters", "capabilities.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return capabilitiesFile{}, fmt.Errorf("read %s: %w", path, err)
	}
	var c capabilitiesFile
	if err := json.Unmarshal(data, &c); err != nil {
		return capabilitiesFile{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return c, nil
}

// ResolveActiveFramework returns the active harness framework name, mirroring
// resolve_active_framework in scripts/lib.sh. Precedence:
//  1. LORE_FRAMEWORK env var (validated against capabilities.json frameworks).
//  2. ~/.lore/config/framework.json `.framework`.
//  3. Built-in default "claude-code".
//
// Unknown framework names from any source are rejected with an error rather
// than silently routing to a default.
func ResolveActiveFramework() (string, error) {
	candidate := ""
	source := ""
	if env := os.Getenv("LORE_FRAMEWORK"); env != "" {
		candidate = env
		source = "env LORE_FRAMEWORK"
	} else {
		cfg := loadUserFrameworkConfig()
		if cfg.Framework != "" {
			candidate = cfg.Framework
			source = frameworkConfigPath()
		}
	}
	if candidate == "" {
		candidate = "claude-code"
		source = "built-in default"
	}

	caps, err := loadCapabilitiesFile()
	if err != nil {
		// Soft-fail validation when capabilities.json is unreadable; the bash
		// side does the same. Returning candidate without validation matches
		// bash behavior when jq is unavailable.
		return candidate, nil
	}
	if _, ok := caps.Frameworks[candidate]; !ok {
		return "", fmt.Errorf("unknown framework %q (from %s); not present in adapters/capabilities.json", candidate, source)
	}
	return candidate, nil
}

// ResolveHarnessInstallPath mirrors scripts/lib.sh resolve_harness_install_path.
// Returns:
//   - (path, true, nil) when the kind has an absolute path on the active harness.
//     $HOME / ${HOME} references are expanded.
//   - ("", false, nil) when the active harness explicitly marks the kind
//     unsupported (capabilities.json install_paths.<kind> == "unsupported").
//   - ("", false, error) when the kind is not in the closed set, or the
//     active framework has no install_paths block, or capabilities.json is
//     unreadable.
func ResolveHarnessInstallPath(kind string) (string, bool, error) {
	if kind == "" {
		return "", false, fmt.Errorf("resolve_harness_install_path requires a kind")
	}
	allowed := false
	for _, k := range HarnessInstallKinds {
		if k == kind {
			allowed = true
			break
		}
	}
	if !allowed {
		return "", false, fmt.Errorf("unknown kind %q (allowed: %s)", kind, strings.Join(HarnessInstallKinds, ", "))
	}

	caps, err := loadCapabilitiesFile()
	if err != nil {
		return "", false, err
	}
	active, err := ResolveActiveFramework()
	if err != nil {
		return "", false, err
	}
	prof, ok := caps.Frameworks[active]
	if !ok || prof.InstallPaths == nil {
		return "", false, fmt.Errorf("no install_paths block for framework %q", active)
	}
	raw, ok := prof.InstallPaths[kind]
	if !ok || raw == "" {
		return "", false, fmt.Errorf("no install_paths.%s defined for framework %q", kind, active)
	}
	if raw == UnsupportedSentinel {
		return "", false, nil
	}

	home, _ := os.UserHomeDir()
	expanded := strings.ReplaceAll(raw, "${HOME}", home)
	expanded = strings.ReplaceAll(expanded, "$HOME", home)
	return expanded, true, nil
}

// HarnessPathOrEmpty is the convenience wrapper around ResolveHarnessInstallPath
// for the dominant call shape: "give me the path, or an empty string if this
// harness has no surface for X".
//
// Returns:
//   - the resolved absolute path when the kind is supported on the active harness.
//   - "" when the kind is unsupported (capabilities.json install_paths.<kind> ==
//     "unsupported") OR when the lookup fails for any reason (unknown kind,
//     missing capabilities.json, no install_paths block, no framework config).
//
// Errors are deliberately collapsed into the empty string because callers of
// this form treat both "unsupported" and "config not yet present" as the same
// "no path here" signal. Callers that need to distinguish those states must
// use ResolveHarnessInstallPath directly and inspect the (supported, error)
// pair.
//
// Mirrors scripts/lib.sh harness_path_or_empty (T71). See adapters/README.md
// for the dual-impl contract row.
func HarnessPathOrEmpty(kind string) string {
	path, _, err := ResolveHarnessInstallPath(kind)
	if err != nil {
		return ""
	}
	return path
}

// HarnessDisplayName returns the human-readable display name for a framework
// id (e.g. "Claude Code", "OpenCode", "Codex"). Looks up
// adapters/capabilities.json `.frameworks[<id>].display_name`. Falls back
// to the framework id verbatim when the file is unreadable or the
// display_name field is missing — never errors. Used by user-facing TUI
// surfaces (modal prose, status badges) where a missing JSON file should
// not block rendering.
//
// Pass an empty string to resolve the active framework's display name
// (delegates to ResolveActiveFramework, falling back to "claude-code"
// when resolution fails).
func HarnessDisplayName(id string) string {
	if id == "" {
		active, err := ResolveActiveFramework()
		if err != nil {
			id = "claude-code"
		} else {
			id = active
		}
	}
	caps, err := loadCapabilitiesFile()
	if err != nil {
		return id
	}
	if prof, ok := caps.Frameworks[id]; ok && prof.DisplayName != "" {
		return prof.DisplayName
	}
	return id
}

// ResolveAgentTemplate mirrors scripts/lib.sh resolve_agent_template. Returns
// the absolute path to <lore-repo>/agents/<name>.md, with all symlinks in the
// prefix resolved. Errors when name is empty or the template file does not
// exist on disk.
func ResolveAgentTemplate(name string) (string, error) {
	if name == "" {
		return "", fmt.Errorf("resolve_agent_template requires a template name")
	}
	repo, err := loreRepoDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(repo, "agents", name+".md")
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("agent template %q not found at %s", name, path)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("resolve symlinks for %s: %w", path, err)
	}
	return resolved, nil
}

// HarnessArgsConfig is the per-harness slice of harness-args.json: the args
// to prepend to every CLI invocation of that harness's binary. Mirrors the
// `[<harness>].args` shape written by scripts/lib.sh
// migrate_claude_args_to_harness_args.
type HarnessArgsConfig struct {
	Args []string `json:"args"`
}

// harnessArgsFile is the on-disk shape of $LORE_DATA_DIR/config/harness-args.json.
// The Frameworks map is keyed by framework name (claude-code, opencode, codex).
// _deprecated_legacy_source records the migration source when present.
type harnessArgsFile struct {
	Version                 int                          `json:"version"`
	DeprecatedLegacySource  string                       `json:"_deprecated_legacy_source,omitempty"`
	Frameworks              map[string]HarnessArgsConfig `json:"-"`
}

// UnmarshalJSON pulls the version + deprecation marker out and routes every
// other top-level key into Frameworks. This matches the bash side, which
// reads `[<framework>].args` directly.
func (h *harnessArgsFile) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	h.Frameworks = map[string]HarnessArgsConfig{}
	for k, v := range raw {
		switch k {
		case "version":
			_ = json.Unmarshal(v, &h.Version)
		case "_deprecated_legacy_source":
			_ = json.Unmarshal(v, &h.DeprecatedLegacySource)
		default:
			var cfg HarnessArgsConfig
			if err := json.Unmarshal(v, &cfg); err == nil {
				h.Frameworks[k] = cfg
			}
		}
	}
	return nil
}

func harnessArgsPath() string {
	dataRoot := os.Getenv("LORE_DATA_DIR")
	if dataRoot == "" {
		home, _ := os.UserHomeDir()
		dataRoot = filepath.Join(home, ".lore")
	}
	return filepath.Join(dataRoot, "config", "harness-args.json")
}

func legacyClaudeArgsPath() string {
	dataRoot := os.Getenv("LORE_DATA_DIR")
	if dataRoot == "" {
		home, _ := os.UserHomeDir()
		dataRoot = filepath.Join(home, ".lore")
	}
	return filepath.Join(dataRoot, "config", "claude.json")
}

// MigrateClaudeArgsToHarnessArgs mirrors scripts/lib.sh
// migrate_claude_args_to_harness_args. One-shot: when harness-args.json is
// absent and legacy claude.json has a valid `.args` array, write a new
// harness-args.json with the legacy args under the `claude-code` key and
// stamp the migration source into _deprecated_legacy_source. Idempotent —
// returns nil silently when the new file already exists, the legacy file
// is missing, or the legacy file has no array .args. The legacy file is
// left in place per the "deprecation note for one release" contract.
func MigrateClaudeArgsToHarnessArgs() error {
	newFile := harnessArgsPath()
	legacyFile := legacyClaudeArgsPath()

	if _, err := os.Stat(newFile); err == nil {
		return nil // already migrated
	}
	legacyData, err := os.ReadFile(legacyFile)
	if err != nil {
		return nil // no legacy file → nothing to migrate
	}
	var legacy ClaudeConfig
	if err := json.Unmarshal(legacyData, &legacy); err != nil || legacy.Args == nil {
		return nil // malformed → don't touch
	}

	if err := os.MkdirAll(filepath.Dir(newFile), 0755); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(newFile), err)
	}
	out := map[string]any{
		"version":                   1,
		"_deprecated_legacy_source": legacyFile,
		"claude-code":               HarnessArgsConfig{Args: legacy.Args},
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal harness-args: %w", err)
	}
	tmp := newFile + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0644); err != nil {
		return fmt.Errorf("write %s: %w", tmp, err)
	}
	return os.Rename(tmp, newFile)
}

// LoadHarnessArgs mirrors scripts/lib.sh load_harness_args. Returns the args
// to prepend to every harness CLI invocation for the named harness. When
// harness == "" the active framework is used.
//
// Resolution order matches the bash precedence:
//  1. LORE_HARNESS_ARGS env var (JSON array, applies to whichever harness).
//  2. LORE_CLAUDE_ARGS env var (legacy alias, only honored when harness is
//     claude-code).
//  3. $LORE_DATA_DIR/config/harness-args.json `[<harness>].args`.
//  4. $LORE_DATA_DIR/config/claude.json `.args` (legacy, only honored when
//     harness is claude-code; on-the-fly migration runs first).
//  5. Built-in default: --dangerously-skip-permissions for claude-code,
//     empty for any other harness.
func LoadHarnessArgs(harness string) []string {
	if harness == "" {
		fw, err := ResolveActiveFramework()
		if err != nil {
			return nil
		}
		harness = fw
	}

	if env := os.Getenv("LORE_HARNESS_ARGS"); env != "" {
		var args []string
		if err := json.Unmarshal([]byte(env), &args); err == nil {
			return args
		}
	}
	if harness == "claude-code" {
		if env := os.Getenv("LORE_CLAUDE_ARGS"); env != "" {
			var args []string
			if err := json.Unmarshal([]byte(env), &args); err == nil {
				return args
			}
		}
	}

	_ = MigrateClaudeArgsToHarnessArgs()

	if data, err := os.ReadFile(harnessArgsPath()); err == nil {
		var f harnessArgsFile
		if err := json.Unmarshal(data, &f); err == nil {
			if cfg, ok := f.Frameworks[harness]; ok && cfg.Args != nil {
				return cfg.Args
			}
		}
	}

	if harness == "claude-code" {
		if data, err := os.ReadFile(legacyClaudeArgsPath()); err == nil {
			var c ClaudeConfig
			if err := json.Unmarshal(data, &c); err == nil && c.Args != nil {
				return c.Args
			}
		}
	}

	if harness == "claude-code" {
		return DefaultClaudeArgs()
	}
	return nil
}

// LoadHarnessConfig is a convenience wrapper that returns LoadHarnessArgs in
// the HarnessArgsConfig shape. It's the post-T10 replacement for
// LoadClaudeConfig in callers that want a struct.
func LoadHarnessConfig(harness string) HarnessArgsConfig {
	return HarnessArgsConfig{Args: LoadHarnessArgs(harness)}
}

// resolveModelForRole_perRepoConfig walks up from cwd looking for a
// .lore.config file (mirrors find_lore_config in scripts/lib.sh) and
// returns the value for `model_for_<role>=` if present.
func resolveModelForRole_perRepoConfig(role string) string {
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for {
		path := filepath.Join(dir, ".lore.config")
		if data, err := os.ReadFile(path); err == nil {
			scanner := bufio.NewScanner(strings.NewReader(string(data)))
			needle := "model_for_" + role + "="
			for scanner.Scan() {
				line := scanner.Text()
				trimmed := strings.TrimSpace(line)
				if trimmed == "" || strings.HasPrefix(trimmed, "#") {
					continue
				}
				if strings.HasPrefix(trimmed, needle) {
					return strings.TrimSpace(strings.TrimPrefix(trimmed, needle))
				}
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// rolesFile is the slice of adapters/roles.json the resolver needs to validate
// role ids against the closed set.
type rolesFile struct {
	Roles []struct {
		ID string `json:"id"`
	} `json:"roles"`
}

func loadRoleIDs() (map[string]struct{}, error) {
	repo, err := loreRepoDir()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(repo, "adapters", "roles.json"))
	if err != nil {
		return nil, err
	}
	var r rolesFile
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, err
	}
	out := map[string]struct{}{}
	for _, role := range r.Roles {
		out[role.ID] = struct{}{}
	}
	return out, nil
}

// ResolveModelForRole mirrors scripts/lib.sh resolve_model_for_role. Returns
// the model id for a role on the active framework. Validates against the
// closed role set in adapters/roles.json; rejects unknown roles with an
// error.
//
// Resolution order:
//  1. Env var LORE_MODEL_<ROLE_UPPER> (e.g., LORE_MODEL_LEAD=opus).
//  2. Per-repo .lore.config `model_for_<role>=<model>` (walk-up from cwd).
//  3. User config $LORE_DATA_DIR/config/framework.json `.roles.<role>`.
//  4. Same file's `.roles.default` (seeded to "sonnet" by install.sh).
//
// Errors when no binding resolves at any level OR when role is not in the
// closed set in adapters/roles.json.
func ResolveModelForRole(role string) (string, error) {
	if role == "" {
		return "", fmt.Errorf("resolve_model_for_role requires a role name")
	}

	// Closed-set validation. Soft-fails when adapters/roles.json is unreadable
	// (matches bash behavior when jq is unavailable / file missing).
	if ids, err := loadRoleIDs(); err == nil {
		if _, ok := ids[role]; !ok {
			return "", fmt.Errorf("unknown role %q (not in adapters/roles.json)", role)
		}
	}

	// 1. Env override.
	envVar := "LORE_MODEL_" + strings.ToUpper(role)
	if v := os.Getenv(envVar); v != "" {
		return v, nil
	}

	// 2. Per-repo .lore.config.
	if v := resolveModelForRole_perRepoConfig(role); v != "" {
		return v, nil
	}

	// 3 + 4. User framework.json: roles.<role>, then roles.default.
	cfg := loadUserFrameworkConfig()
	if v, ok := cfg.Roles[role]; ok && v != "" {
		return v, nil
	}
	if v, ok := cfg.Roles["default"]; ok && v != "" {
		return v, nil
	}

	return "", fmt.Errorf("no model binding for role %q (no env var, no per-repo .lore.config, no framework.json roles.%s or roles.default)", role, role)
}
