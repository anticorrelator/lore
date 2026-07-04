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
//     user → harness default for resolve_model_for_role; env → runtime
//     harness markers → built-in default for resolve_active_framework).
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
	"sort"
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

// LoreRepoDir resolves the lore repo root by following the
// ~/.lore/scripts -> <repo>/scripts symlink that install.sh creates. This
// matches the bash convention where lib.sh treats $LORE_LIB_DIR/.. as the
// repo root. Exposed so the host TUI can locate adapters/* files
// (settings.schema.json, capabilities.json) and scripts/agent-toggle/* for
// the settings configurator.
func LoreRepoDir() (string, error) {
	return loreRepoDir()
}

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
	DisplayName    string            `json:"display_name"`
	Binary         string            `json:"binary"`
	InstallPaths   map[string]string `json:"install_paths"`
	TUILaunchFlags map[string]string `json:"tui_launch_flags"`
	ModelRouting   modelRouting      `json:"model_routing"`
}

// modelRouting is the per-framework model-routing block. Tiers is the ordered
// auditor-model alias list the TUI's tier-cycle key walks; each alias must be
// valid harness `--model` input for that framework.
type modelRouting struct {
	Tiers []string `json:"tiers"`
}

// LoadModelRoutingTiers returns the ordered model_routing.tiers alias list
// for a framework from adapters/capabilities.json. Returns nil (no error)
// when the framework has no tiers declared — callers MUST treat an empty list
// as "tier cycling unavailable on this framework", never route to a default
// list (see feedback_dont_reintroduce_defaults). Errors only on unreadable
// capabilities.json or an unknown framework id.
func LoadModelRoutingTiers(framework string) ([]string, error) {
	if framework == "" {
		return nil, fmt.Errorf("load_model_routing_tiers requires a framework")
	}
	caps, err := loadCapabilitiesFile()
	if err != nil {
		return nil, err
	}
	prof, ok := caps.Frameworks[framework]
	if !ok {
		return nil, fmt.Errorf("unknown framework %q (not present in adapters/capabilities.json)", framework)
	}
	return prof.ModelRouting.Tiers, nil
}

// capabilitiesFile is the top-level shape of adapters/capabilities.json.
type capabilitiesFile struct {
	Frameworks map[string]capabilitiesProfile `json:"frameworks"`
}

// LoadCapabilitiesFrameworks returns the sorted list of framework ids declared
// in adapters/capabilities.json at the supplied path. Exposed so the host TUI
// can enumerate the tui_launch_framework closed-set for the settings configurator
// without duplicating the parse logic.
func LoadCapabilitiesFrameworks(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var c capabilitiesFile
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	out := make([]string, 0, len(c.Frameworks))
	for k := range c.Frameworks {
		out = append(out, k)
	}
	sort.Strings(out)
	return out, nil
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

func runtimeFrameworkHint() string {
	if os.Getenv("LORE_DATA_DIR") != "" {
		return ""
	}
	if os.Getenv("CLAUDECODE") == "1" || os.Getenv("CLAUDE_CODE_SESSION_ID") != "" || os.Getenv("CLAUDE_CODE_TEAM_NAME") != "" {
		return "claude-code"
	}
	if os.Getenv("CODEX_SHELL") == "1" || os.Getenv("CODEX_THREAD_ID") != "" {
		return "codex"
	}
	if os.Getenv("OPENCODE_CLIENT") != "" || os.Getenv("OPENCODE_SESSION_ID") != "" {
		return "opencode"
	}
	return ""
}

// ResolveActiveFramework returns the current process harness framework name,
// mirroring resolve_active_framework in scripts/lib.sh. Precedence:
//  1. LORE_FRAMEWORK env var (validated against capabilities.json frameworks).
//  2. Runtime harness environment markers (when LORE_DATA_DIR is not redirected).
//  3. Built-in default "claude-code".
//
// Deliberately does NOT read settings.json. The stored TUI launch preference
// lives at `tui_launch_framework` and is consumed by ResolveTUILaunchFramework
// for TUI-spawned sessions only.
//
// Unknown framework names from any source are rejected with an error rather
// than silently routing to a default.
func ResolveActiveFramework() (string, error) {
	candidate := ""
	source := ""
	if env := os.Getenv("LORE_FRAMEWORK"); env != "" {
		candidate = env
		source = "env LORE_FRAMEWORK"
	} else if runtime := runtimeFrameworkHint(); runtime != "" {
		candidate = runtime
		source = "runtime harness environment"
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

// ResolveTUILaunchFramework returns the framework the TUI should spawn for
// chat/spec/followup sessions. This is a TUI-only preference; shell helpers
// must use ResolveActiveFramework instead.
//
// Reads settings.json `tui_launch_framework`, then defaults to "claude-code".
// Unknown configured values are rejected.
func ResolveTUILaunchFramework() (string, error) {
	candidate := ""
	source := ""
	if raw, present, _ := SettingsGet("tui_launch_framework"); present {
		var v string
		if err := json.Unmarshal([]byte(raw), &v); err == nil && v != "" {
			candidate = v
			source = SettingsPath() + "::tui_launch_framework"
		}
	}
	if candidate == "" {
		candidate = "claude-code"
		source = "built-in default"
	}
	caps, err := loadCapabilitiesFile()
	if err != nil {
		return candidate, nil
	}
	if _, ok := caps.Frameworks[candidate]; !ok {
		return "", fmt.Errorf("unknown TUI launch framework %q (from %s); not present in adapters/capabilities.json", candidate, source)
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

// HarnessBinary returns the executable name to spawn for a framework id
// (e.g. "claude", "opencode", "codex"). Looks up
// adapters/capabilities.json `.frameworks[<id>].binary`.
//
// Pass an empty string to resolve the active framework's binary
// (delegates to ResolveActiveFramework).
//
// Errors when the framework id is unknown, capabilities.json is unreadable,
// or the resolved profile has no `binary` field. Unlike HarnessDisplayName,
// this does NOT silently fall back to the framework id — the binary is
// load-bearing for exec.Command and a wrong value would spawn the wrong
// (or no) process. Callers MUST handle the error.
//
// Bash counterpart: framework-status.sh / framework-doctor.sh both inline
// `jq -r '.frameworks[<fw>].binary // ""' adapters/capabilities.json`;
// there is no shared lib.sh helper as of T10.
func HarnessBinary(id string) (string, error) {
	if id == "" {
		active, err := ResolveActiveFramework()
		if err != nil {
			return "", fmt.Errorf("resolve active framework: %w", err)
		}
		id = active
	}
	caps, err := loadCapabilitiesFile()
	if err != nil {
		return "", err
	}
	prof, ok := caps.Frameworks[id]
	if !ok {
		return "", fmt.Errorf("unknown framework %q (not present in adapters/capabilities.json)", id)
	}
	if prof.Binary == "" {
		return "", fmt.Errorf("framework %q has no binary field in adapters/capabilities.json", id)
	}
	return prof.Binary, nil
}

// TUILaunchFlagKinds enumerates the closed set of TUI-injected concerns that
// the orchestration adapter resolves to a per-harness CLI flag spelling. New
// kinds MUST be added here and to every framework's tui_launch_flags block in
// adapters/capabilities.json together. The kind set is read by both the Go
// helpers below and adapters/agents/<harness>.sh `system_prompt_flag` /
// `settings_override_flag` subcommands; parity is asserted in
// tests/frameworks/adapters.bats (T63 coverage).
//
// Note: skip_permissions is NOT in this set — it routes through
// LoadHarnessConfig().Args (~/.lore/config/harness-args.json), not through the
// per-concern capability gate. See adapters/agents/README.md
// §"TUI Launch Concerns" for the routing-contract rationale (the three
// concerns are deliberately not treated uniformly).
var TUILaunchFlagKinds = []string{
	"append_system_prompt",
	"inline_settings_override",
}

// resolveTUILaunchFlag is the shared lookup used by HarnessSystemPromptFlag and
// HarnessSettingsOverrideFlag. Returns:
//   - (flag, true, nil) when the framework profile names a flag spelling for
//     the kind (e.g., "--append-system-prompt").
//   - ("", false, nil) when the framework explicitly marks the kind
//     unsupported (capabilities.json tui_launch_flags.<kind> == "unsupported"),
//     mirroring ResolveHarnessInstallPath's tri-state contract. Callers MUST
//     skip the flag injection entirely on this signal — substituting a
//     different flag would cause the harness to error on an unknown flag.
//   - ("", false, error) when the kind is not in TUILaunchFlagKinds, the
//     framework id is unknown, or capabilities.json is unreadable. Both
//     concerns are load-bearing — silent fallback to a default would either
//     inject the wrong flag (settings) or crash followup-mode (system
//     prompt) — so unknown framework MUST error rather than route to a
//     default. See conventions:dual-impl-load-bearing-vs-display-fallback.
func resolveTUILaunchFlag(framework, kind string) (string, bool, error) {
	if kind == "" {
		return "", false, fmt.Errorf("resolve_tui_launch_flag requires a kind")
	}
	allowed := false
	for _, k := range TUILaunchFlagKinds {
		if k == kind {
			allowed = true
			break
		}
	}
	if !allowed {
		return "", false, fmt.Errorf("unknown tui_launch_flag kind %q (allowed: %s)", kind, strings.Join(TUILaunchFlagKinds, ", "))
	}

	if framework == "" {
		active, err := ResolveActiveFramework()
		if err != nil {
			return "", false, fmt.Errorf("resolve active framework: %w", err)
		}
		framework = active
	}

	caps, err := loadCapabilitiesFile()
	if err != nil {
		return "", false, err
	}
	prof, ok := caps.Frameworks[framework]
	if !ok {
		return "", false, fmt.Errorf("unknown framework %q (not present in adapters/capabilities.json)", framework)
	}
	if prof.TUILaunchFlags == nil {
		return "", false, fmt.Errorf("framework %q has no tui_launch_flags block in adapters/capabilities.json", framework)
	}
	raw, ok := prof.TUILaunchFlags[kind]
	if !ok || raw == "" {
		return "", false, fmt.Errorf("no tui_launch_flags.%s defined for framework %q", kind, framework)
	}
	if raw == UnsupportedSentinel {
		return "", false, nil
	}
	return raw, true, nil
}

// HarnessSystemPromptFlag returns the harness-native CLI flag spelling for
// appending text to the session system prompt (Claude Code's
// `--append-system-prompt`). Used by the TUI's followup-discuss launch path
// at tui/internal/work/specpanel.go to inject prior-finding context.
//
// Pass "" to resolve the active framework's flag.
//
// Returns:
//   - (flag, true, nil): inject `<flag> <text>` before the positional prompt.
//   - ("", false, nil): the harness has no equivalent flag; the TUI MUST skip
//     the entire append_system_prompt injection block — substituting a
//     different flag would crash the harness on an unknown CLI argument.
//   - ("", false, error): unknown framework or unreadable capabilities.json.
//     Load-bearing: callers MUST handle the error, NOT silently fall back to
//     a Claude Code default (which would crash opencode/codex).
//
// Bash counterpart: adapters/agents/<harness>.sh `system_prompt_flag`
// subcommand. See adapters/agents/README.md §"TUI Launch Concerns" for the
// per-harness flag spelling and degraded-mode contract.
func HarnessSystemPromptFlag(framework string) (string, bool, error) {
	return resolveTUILaunchFlag(framework, "append_system_prompt")
}

// HarnessSettingsOverrideFlag returns the harness-native CLI flag spelling
// for inline session-scoped settings overrides (Claude Code's
// `--settings <json>`). Used by the TUI launch path at
// tui/internal/work/specpanel.go to pin per-session settings without
// modifying the user's settings file.
//
// Pass "" to resolve the active framework's flag.
//
// Returns:
//   - (flag, true, nil): inject `<flag> <json>` into args.
//   - ("", false, nil): the harness has no equivalent flag; the TUI MUST skip
//     the injection entirely (NOT pass an empty/dummy flag — opencode and
//     codex error on unknown CLI flags).
//   - ("", false, error): unknown framework or unreadable capabilities.json.
//     Load-bearing — see HarnessSystemPromptFlag for the rationale.
//
// Bash counterpart: adapters/agents/<harness>.sh `settings_override_flag`
// subcommand.
func HarnessSettingsOverrideFlag(framework string) (string, bool, error) {
	return resolveTUILaunchFlag(framework, "inline_settings_override")
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
	Version                int                          `json:"version"`
	DeprecatedLegacySource string                       `json:"_deprecated_legacy_source,omitempty"`
	Frameworks             map[string]HarnessArgsConfig `json:"-"`
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

// MigrateClaudeArgsToHarnessArgs is retained as a compatibility no-op.
// Runtime settings no longer migrate or read legacy claude.json /
// harness-args.json files; harness args come from settings.json or
// LORE_HARNESS_ARGS only.
func MigrateClaudeArgsToHarnessArgs() error {
	return nil
}

// LoadHarnessArgs mirrors scripts/lib.sh load_harness_args. Returns the args
// to prepend to every harness CLI invocation for the named harness. When
// harness == "" the active framework is used.
//
// Resolution order matches the bash precedence:
//  1. LORE_HARNESS_ARGS env var (JSON array, applies to whichever harness).
//  2. Unified settings.json `.harnesses.<harness>.args`.
//  3. Built-in default: --dangerously-skip-permissions for claude-code,
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
	// Unified settings.json (primary): harnesses.<harness>.args.
	if raw, present, _ := SettingsGet("harnesses." + harness + ".args"); present {
		var args []string
		if err := json.Unmarshal([]byte(raw), &args); err == nil && args != nil {
			return args
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
// Resolution order (mirrors the bash side byte-for-byte; D3b overlay
// inserted between env+per-repo and the top-level user config):
//  1. Env var LORE_MODEL_<ROLE_UPPER> (e.g., LORE_MODEL_LEAD=opus).
//  2. Per-repo .lore.config `model_for_<role>=<model>` (walk-up from cwd).
//  3. Unified settings.json `.harnesses.<active>.roles.<role>` (D3b overlay
//     — applies to the active harness only).
//  4. Unified `.harnesses.<active>.roles.default` (overlay's own default).
//
// Closed-set rejection applies identically to the overlay layer and the
// top-level layer: an unknown role id stored under
// `harnesses.<active>.roles` is the same error class as an unknown role in
// the query (bash D3b parity per scripts/lib.sh:964-985). Errors when no
// binding resolves at any level OR when role is not in the closed set in
// adapters/roles.json.
func ResolveModelForRole(role string) (string, error) {
	if role == "" {
		return "", fmt.Errorf("resolve_model_for_role requires a role name")
	}

	// Closed-set validation. Soft-fails when adapters/roles.json is unreadable
	// (matches bash behavior when jq is unavailable / file missing).
	validRoles, validRolesErr := loadRoleIDs()
	if validRolesErr == nil {
		if _, ok := validRoles[role]; !ok {
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

	// Resolve active harness once for the overlay layer.
	active, _ := ResolveActiveFramework()

	// D3b closed-set rejection at the overlay layer: any unknown role id
	// stored under `harnesses.<active>.roles` is rejected immediately, same
	// error class as an unknown role in the *query* above. Without this guard
	// a misconfigured overlay would silently never be consulted (per
	// scripts/lib.sh:964-985).
	if active != "" && validRolesErr == nil {
		raw, present, _ := SettingsGet("harnesses." + active + ".roles")
		if present {
			var overlay map[string]any
			if err := json.Unmarshal([]byte(raw), &overlay); err == nil {
				for k := range overlay {
					if _, ok := validRoles[k]; !ok {
						return "", fmt.Errorf("unknown role %q in harnesses.%s.roles (not in adapters/roles.json)", k, active)
					}
				}
			}
		}
	}

	// 3. Unified settings.json `.harnesses.<active>.roles.<role>` (D3b overlay).
	if active != "" {
		if v := readSettingsRoleString("harnesses." + active + ".roles." + role); v != "" {
			return v, nil
		}
	}

	// 4. Unified `.harnesses.<active>.roles.default`.
	if active != "" {
		if v := readSettingsRoleString("harnesses." + active + ".roles.default"); v != "" {
			return v, nil
		}
	}

	return "", fmt.Errorf("no model binding for role %q (no env var, no per-repo .lore.config, no harnesses.<active>.roles.%s or harnesses.<active>.roles.default in settings.json)", role, role)
}

// readSettingsRoleString reads a string-valued role binding from the unified
// settings file. Returns "" when the path is absent OR the value is not a
// non-empty JSON string. The empty-string-is-absence collapse mirrors the
// bash side's `// empty` jq filter (scripts/lib.sh:993-1010): an explicit
// empty string is treated as fall-through, not as a binding, because its
// semantics are ambiguous (suppress vs. use-default) and the schema's
// $defs/role_value rejects empty strings at validation time.
func readSettingsRoleString(dotPath string) string {
	raw, present, err := SettingsGet(dotPath)
	if err != nil || !present {
		return ""
	}
	var v string
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return ""
	}
	return v
}
