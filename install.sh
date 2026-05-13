#!/usr/bin/env bash
# install.sh — Set up lore for Claude Code
# Usage: bash install.sh [--uninstall] [--dry-run] [--framework <name>]
#
# --framework selects the harness whose install paths and capability profile
# Lore should target. Supported values: claude-code (default), opencode, codex.
# The selection is persisted as the TUI launch preference at
# $LORE_DATA_DIR/config/settings.json::tui_launch_framework. Runtime shell
# helpers do not read this value; they use process-local harness markers or
# LORE_FRAMEWORK. Re-running install with a different --framework rewrites the
# TUI preference while preserving harness-local role bindings and capability
# overrides previously edited by the user.
set -euo pipefail

# --- Resolve paths ---
LORE_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LORE_DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
CLAUDE_DIR="$HOME/.claude"

# D4 phase-3 cleanup gate: install.sh deletes legacy fragmented
# files only when settings.json's `version` is at-or-above this constant AND
# the deterministic fallback audit (lore doctor's aggregator) is empty. Bump
# this in lockstep with adapters/settings.schema.json's `version` field when a
# breaking shape change ships — see plan D4 phase 3.
LORE_SETTINGS_CLEANUP_VERSION=1

# --- Parse flags ---
UNINSTALL=false
DRY_RUN=false
FRAMEWORK="claude-code"

# Supported framework allowlist is sourced from adapters/capabilities.json
# (single source of truth per D3a). Hardcoding the keyset here would let
# install.sh accept a framework that capabilities.json rejects (or vice
# versa); reading once prevents that drift class.
_caps_file="$LORE_REPO_DIR/adapters/capabilities.json"
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: install.sh requires jq on PATH (used to read $_caps_file)" >&2
  exit 1
fi
if [ ! -f "$_caps_file" ]; then
  echo "Error: capabilities file not found: $_caps_file" >&2
  exit 1
fi
SUPPORTED_FRAMEWORKS=()
while IFS= read -r _fw; do
  [ -n "$_fw" ] && SUPPORTED_FRAMEWORKS+=("$_fw")
done < <(jq -r '.frameworks | keys[]' "$_caps_file" 2>/dev/null | sort)
if [ ${#SUPPORTED_FRAMEWORKS[@]} -eq 0 ]; then
  echo "Error: no frameworks registered in $_caps_file" >&2
  exit 1
fi
unset _fw _caps_file

i=0
args=("$@")
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
    --dry-run)   DRY_RUN=true ;;
    --framework)
      i=$((i + 1))
      if [ $i -ge ${#args[@]} ]; then
        echo "Error: --framework requires a value (one of: ${SUPPORTED_FRAMEWORKS[*]})" >&2
        exit 1
      fi
      FRAMEWORK="${args[$i]}"
      ;;
    --framework=*)
      FRAMEWORK="${arg#--framework=}"
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
  i=$((i + 1))
done

# Validate framework selection against the closed support set
_fw_valid=false
for _fw in "${SUPPORTED_FRAMEWORKS[@]}"; do
  if [ "$_fw" = "$FRAMEWORK" ]; then _fw_valid=true; break; fi
done
if ! $_fw_valid; then
  echo "Error: unknown framework '$FRAMEWORK' (supported: ${SUPPORTED_FRAMEWORKS[*]})" >&2
  exit 1
fi
unset _fw _fw_valid

# --- Helpers ---
info()  { echo "  [lore] $*"; }
dry()   { if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi; }

# Source lib.sh so install.sh can call resolve_harness_install_path and
# friends. lib.sh is in the repo's scripts/ dir; install-time calls pass the
# target framework explicitly so path/capability reads do not depend on an
# ambient LORE_FRAMEWORK override.
# shellcheck source=scripts/lib.sh
source "$LORE_REPO_DIR/scripts/lib.sh"

# resolve_install_path <kind> [framework]
# Wrap resolve_harness_install_path so that it (a) honors the install-time
# --framework flag without depending on a persisted TUI launch preference
# being updated, (b) prints a degraded notice and returns "unsupported"
# rather than failing when a kind is not wired for the active harness,
# and (c) shells out cleanly under set -e (the bare resolve_*
# helper exits non-zero on unknown kinds, which would abort the install).
resolve_install_path() {
  local kind="$1"
  local fw="${2:-$FRAMEWORK}"
  local path
  if path=$(resolve_harness_install_path "$kind" "$fw" 2>/dev/null); then
    printf '%s\n' "$path"
  else
    printf '%s\n' "unsupported"
  fi
}

# =========================================================================
#  UNINSTALL
# =========================================================================
if $UNINSTALL; then
  echo "Uninstalling lore..."

  # Remove skill + agent symlinks at every supported harness install path.
  # The active framework determines which path was originally written, but
  # we walk all three on uninstall so a user who switched frameworks mid-
  # session does not leave dangling symlinks.
  for fw in "${SUPPORTED_FRAMEWORKS[@]}"; do
    skills_dir=$(resolve_install_path skills "$fw")
    if [ "$skills_dir" != "unsupported" ] && [ -d "$skills_dir" ]; then
      for skill_dir in "$LORE_REPO_DIR"/skills/*/; do
        skill_name="$(basename "$skill_dir")"
        target="$skills_dir/$skill_name"
        if [ -L "$target" ] || [ -e "$target" ]; then
          info "Removing skill symlink: $target"
          dry rm -rf "$target"
        fi
      done
    fi
    agents_dir=$(resolve_install_path agents "$fw")
    if [ "$agents_dir" != "unsupported" ] && [ -d "$agents_dir" ]; then
      for agent_file in "$LORE_REPO_DIR"/agents/*.md; do
        agent_name="$(basename "$agent_file")"
        target="$agents_dir/$agent_name"
        if [ -L "$target" ]; then
          info "Removing agent symlink: $target"
          dry rm -f "$target"
        fi
      done
    fi
  done

  # Remove CLI symlink
  if [ -L "$HOME/.local/bin/lore" ]; then
    info "Removing CLI symlink: $HOME/.local/bin/lore"
    dry rm -f "$HOME/.local/bin/lore"
  fi

  # Remove TUI binary
  if [ -f "$HOME/.local/bin/lore-tui" ]; then
    info "Removing TUI binary: $HOME/.local/bin/lore-tui"
    dry rm -f "$HOME/.local/bin/lore-tui"
  fi

  # Remove scripts symlink
  if [ -L "$LORE_DATA_DIR/scripts" ]; then
    info "Removing scripts symlink: $LORE_DATA_DIR/scripts"
    dry rm -f "$LORE_DATA_DIR/scripts"
  fi

  # Remove claude-md symlink
  if [ -L "$LORE_DATA_DIR/claude-md" ]; then
    info "Removing claude-md symlink: $LORE_DATA_DIR/claude-md"
    dry rm -f "$LORE_DATA_DIR/claude-md"
  fi

  # Remove lore hooks/permissions via per-harness adapter (T25/T26/T27/T28).
  # Walk every supported framework's adapter so a user who switched
  # frameworks mid-session does not leave dangling lore content in
  # another harness's settings file. Dispatch shape (cli|plugin-symlink|
  # unsupported) is owned by `resolve_permission_adapter` in lib.sh —
  # install.sh consumes the result generically rather than re-encoding
  # the per-framework decision in a `case` here.
  for fw in "${SUPPORTED_FRAMEWORKS[@]}"; do
    if ! adapter_record=$(resolve_permission_adapter "$fw" 2>/dev/null); then
      continue
    fi
    case "$adapter_record" in
      cli:*)
        fw_adapter="${adapter_record#cli:}"
        if [ -x "$fw_adapter" ]; then
          adapter_rel="${fw_adapter#$LORE_REPO_DIR/}"
          info "Removing lore hooks via $adapter_rel uninstall"
          if ! $DRY_RUN; then
            bash "$fw_adapter" uninstall --framework "$fw" || true
          fi
        fi
        ;;
      plugin-symlink:*)
        rest="${adapter_record#plugin-symlink:}"
        # rest is "<src>:<dst>"; the destination may legitimately be empty
        # if $HOME ever expands oddly, so split on the last colon to keep
        # paths with embedded colons (none today) survivable.
        plugin_dst="${rest##*:}"
        if [ -L "$plugin_dst" ] || [ -e "$plugin_dst" ]; then
          info "Removing $fw plugin symlink: $plugin_dst"
          dry rm -f "$plugin_dst"
        fi
        ;;
      unsupported)
        # Framework wired at the SUPPORTED_FRAMEWORKS layer but with no
        # permission adapter — nothing to remove. Silent on uninstall;
        # the install path emits the visible degradation notice.
        :
        ;;
    esac
  done

  echo ""
  echo "Lore hooks and symlinks removed."
  echo "Data directory preserved at: $LORE_DATA_DIR"
  echo "To remove data: rm -rf $LORE_DATA_DIR"
  exit 0
fi

# =========================================================================
#  INSTALL
# =========================================================================
echo "Installing lore..."
echo "  Repo:      $LORE_REPO_DIR"
echo "  Data:      $LORE_DATA_DIR"
echo "  Claude:    $CLAUDE_DIR"
echo "  Framework: $FRAMEWORK"
echo ""

# --- 1. Create data directory ---
info "Creating data directory"
dry mkdir -p "$LORE_DATA_DIR/repos"
dry mkdir -p "$LORE_DATA_DIR/.install-state"

# --- 1a. Migrate fragmented config -> unified settings.json (D4 phase 1) ---
# Create-only: this block runs only when ~/.lore/config/settings.json is
# absent. The unified file ships from adapters/settings.template.json; values
# read from legacy fragmented files overlay onto the
# template, then a single atomic write produces settings.json. Migration
# provenance lives in ~/.lore/.install-state/migration.json — settings.json
# itself stays clean against the strict doctor schema (additionalProperties:
# false at root rejects _deprecated_legacy_source).
#
# `agent.json::symlink_manifest` is NOT migrated here — D6 splits it out to
# ~/.lore/.install-state/symlinks.json (handled in step 1b).
SETTINGS_TEMPLATE="$LORE_REPO_DIR/adapters/settings.template.json"
SETTINGS_FILE="$LORE_DATA_DIR/config/settings.json"
MIGRATION_PROVENANCE="$LORE_DATA_DIR/.install-state/migration.json"
dry mkdir -p "$LORE_DATA_DIR/config"
if [ ! -f "$SETTINGS_TEMPLATE" ]; then
  info "Skipping settings migration — template missing at $SETTINGS_TEMPLATE"
elif [ -f "$SETTINGS_FILE" ]; then
  info "settings.json already exists, skipping create-only migration"
else
  info "Migrating fragmented config -> $SETTINGS_FILE"
  if ! $DRY_RUN; then
    LORE_DATA_DIR="$LORE_DATA_DIR" \
    SETTINGS_TEMPLATE="$SETTINGS_TEMPLATE" \
    SETTINGS_FILE="$SETTINGS_FILE" \
    MIGRATION_PROVENANCE="$MIGRATION_PROVENANCE" \
    python3 - <<'PYEOF'
import datetime
import json
import os
import sys
import tempfile

data_dir = os.environ["LORE_DATA_DIR"]
template_path = os.environ["SETTINGS_TEMPLATE"]
settings_path = os.environ["SETTINGS_FILE"]
provenance_path = os.environ["MIGRATION_PROVENANCE"]

config_dir = os.path.join(data_dir, "config")

# (legacy_filename_relative_to_data_dir, overlay_function)
# Each overlay reads its legacy file (when present and parseable) and mutates
# the document in place. Skip on absence (template defaults stand). Surface
# errors and skip on malformed JSON without aborting the whole install.
legacy_specs = [
    "config/agent.json",
    "config/capture-config.json",
    "config/framework.json",
    "config/harness-args.json",
    "config/obsidian.json",
    "config/tui.json",
]


def load_legacy(rel_path):
    abs_path = os.path.join(data_dir, rel_path)
    if not os.path.exists(abs_path):
        return None
    try:
        with open(abs_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(
            f"  [warn] failed to read {abs_path}: {exc} — skipping",
            file=sys.stderr,
        )
        return None


with open(template_path, "r", encoding="utf-8") as f:
    doc = json.load(f)

sources = []


def mark(rel_path):
    if rel_path not in sources:
        sources.append(rel_path)


def fan_to_harnesses(doc, key, value):
    """Set harnesses.<fw>.<key> = value for every existing harness block."""
    harnesses = dict(doc.get("harnesses", {}))
    for fw, block in list(harnesses.items()):
        if not isinstance(block, dict):
            continue
        new_block = dict(block)
        new_block[key] = value
        harnesses[fw] = new_block
    doc["harnesses"] = harnesses


# agent.json -> per-harness `harnesses.<fw>.enabled`. The legacy global
# `agent.enabled` flag is fanned uniformly across every framework declared
# in the (already-migrated) `harnesses` block. `agent.last_changed` is
# dropped — no consumer beyond a status-display string, and filesystem
# mtimes serve the same role.
#
# Two sources can carry the legacy value: the fragmented `config/agent.json`
# file, or a stale `agent.enabled` key in the unified document from a prior
# install that ran the now-retired migration. Read both; the unified-doc
# value wins on conflict (it represents the most recent toggle).
legacy_agent_enabled = None
agent_doc = load_legacy("config/agent.json")
if isinstance(agent_doc, dict) and "enabled" in agent_doc:
    legacy_agent_enabled = bool(agent_doc["enabled"])
    mark("config/agent.json")

stale_unified_agent = doc.get("agent")
if isinstance(stale_unified_agent, dict) and "enabled" in stale_unified_agent:
    legacy_agent_enabled = bool(stale_unified_agent["enabled"])
# Always strip the deprecated top-level `agent` block — the schema no
# longer accepts it and the unified loaders reject unknown keys.
if "agent" in doc:
    del doc["agent"]

if legacy_agent_enabled is not None:
    harnesses = dict(doc.get("harnesses", {}))
    # Fan to every framework that already has a block (post-harness-args
    # migration). For frameworks not yet in the doc, install.sh's later
    # template merge will fill in defaults; we don't synthesize an empty
    # block here just to attach `enabled`.
    for fw, block in list(harnesses.items()):
        if not isinstance(block, dict):
            continue
        # Only set when absent to avoid clobbering a per-harness override
        # that may already have been written by harness-toggle in a
        # previous run.
        if "enabled" not in block:
            new_block = dict(block)
            new_block["enabled"] = legacy_agent_enabled
            harnesses[fw] = new_block
    doc["harnesses"] = harnesses

# capture-config.json -> capture.{core, structural_signals, adaptive}
capture_doc = load_legacy("config/capture-config.json")
if isinstance(capture_doc, dict):
    capture_block = dict(doc.get("capture", {}))
    for key in ("core", "structural_signals"):
        if isinstance(capture_doc.get(key), dict):
            capture_block[key] = capture_doc[key]
    if "adaptive" in capture_doc:
        capture_block["adaptive"] = bool(capture_doc["adaptive"])
    doc["capture"] = capture_block
    mark("config/capture-config.json")

# framework.json -> {tui_launch_framework, harnesses.<fw>.roles, capability_overrides}
framework_doc = load_legacy("config/framework.json")
if isinstance(framework_doc, dict):
    if isinstance(framework_doc.get("framework"), str):
        doc["tui_launch_framework"] = framework_doc["framework"]
    if isinstance(framework_doc.get("roles"), dict):
        fan_to_harnesses(doc, "roles", framework_doc["roles"])
        doc.pop("roles", None)
    if isinstance(framework_doc.get("capability_overrides"), dict):
        doc["capability_overrides"] = framework_doc["capability_overrides"]
    mark("config/framework.json")

# harness-args.json -> harnesses.<name>.args (preserve other harness keys)
harness_args_doc = load_legacy("config/harness-args.json")
if isinstance(harness_args_doc, dict):
    harnesses = dict(doc.get("harnesses", {}))
    for fw, fw_block in harness_args_doc.items():
        # Skip provenance/version metadata fields from the legacy shape.
        if fw in ("version", "_deprecated_legacy_source"):
            continue
        if isinstance(fw_block, dict) and isinstance(fw_block.get("args"), list):
            existing = dict(harnesses.get(fw, {}))
            existing["args"] = list(fw_block["args"])
            harnesses[fw] = existing
    doc["harnesses"] = harnesses
    mark("config/harness-args.json")

# obsidian.json -> obsidian.vaults["<kb-key>"] = { enabled, vault_path }
#
# kb-key is the legacy `repo_path` with the `<data_dir>/repos/` prefix stripped
# (i.e. `resolve-repo.sh` output without the LORE_DATA_DIR-anchored prefix).
# This matches the identifier the install-base enumeration uses and survives
# LORE_DATA_DIR moves. A legacy file lacking either `vault_path` or `repo_path`
# is dropped on the floor — the legacy shape couldn't address a KB without
# both, and the keyed shape can't either.
obsidian_doc = load_legacy("config/obsidian.json")
if isinstance(obsidian_doc, dict):
    legacy_vault = obsidian_doc.get("vault_path")
    legacy_repo  = obsidian_doc.get("repo_path")
    if (
        isinstance(legacy_vault, str) and legacy_vault
        and isinstance(legacy_repo, str) and legacy_repo
    ):
        repos_prefix = os.path.join(data_dir, "repos") + os.sep
        if legacy_repo.startswith(repos_prefix):
            kb_key = legacy_repo[len(repos_prefix):]
            if kb_key:
                obsidian_block = dict(doc.get("obsidian", {}))
                vaults = dict(obsidian_block.get("vaults", {}))
                entry = dict(vaults.get(kb_key, {}))
                entry.setdefault("enabled", True)
                entry["vault_path"] = legacy_vault
                vaults[kb_key] = entry
                obsidian_block["vaults"] = vaults
                doc["obsidian"] = obsidian_block
                mark("config/obsidian.json")

# tui.json -> tui.layout
tui_doc = load_legacy("config/tui.json")
if isinstance(tui_doc, dict):
    tui_block = dict(doc.get("tui", {}))
    if isinstance(tui_doc.get("layout"), str):
        tui_block["layout"] = tui_doc["layout"]
    doc["tui"] = tui_block
    mark("config/tui.json")

# Atomic write: tmp file in same dir, then rename.
fd, tmp_path = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=config_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp_path, settings_path)
except OSError:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    raise

# Provenance lives outside settings.json (D7 strict-schema invariant —
# additionalProperties:false at root would reject _deprecated_legacy_source).
provenance_dir = os.path.dirname(provenance_path)
os.makedirs(provenance_dir, exist_ok=True)
provenance = {
    "schema_version": 1,
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    ),
    "sources": sources,
}
fd, tmp_path = tempfile.mkstemp(
    prefix=".migration.", suffix=".tmp", dir=provenance_dir
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(provenance, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, provenance_path)
except OSError:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    raise

print(f"  [lore] migration sources: {sources}", file=sys.stderr)
PYEOF
  fi
fi

# Retired 2026-05: the old probabilistic settlement settings were no longer
# wired into hook adapters. Keep the open audit work item as the source for any
# future trigger config, and prune the stale user-facing section from existing
# unified settings files.
if [ -f "$SETTINGS_FILE" ]; then
  info "Pruning retired settlement settings from $SETTINGS_FILE"
  if ! $DRY_RUN; then
    SETTINGS_FILE="$SETTINGS_FILE" python3 - <<'PYEOF'
import json
import os
import tempfile

settings_path = os.environ["SETTINGS_FILE"]
with open(settings_path, "r", encoding="utf-8") as f:
    doc = json.load(f)

if isinstance(doc, dict) and "settlement" in doc:
    doc.pop("settlement", None)
    config_dir = os.path.dirname(settings_path)
    fd, tmp_path = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=config_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp_path, settings_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
PYEOF
  fi
fi

# --- 1b. Split agent.json::symlink_manifest -> .install-state/symlinks.json (D6) ---
# Co-ownership: install reads-and-merges into the install-state file; it must
# never blindly overwrite a non-empty manifest (agent-toggle disable writes
# its own snapshot, which install must preserve verbatim). The split runs
# only when the legacy agent.json still carries a symlink_manifest (the
# pre-D6 shape); after agent-toggle has been run on the new path this block
# is a no-op.
SYMLINKS_STATE="$LORE_DATA_DIR/.install-state/symlinks.json"
LEGACY_AGENT_JSON="$LORE_DATA_DIR/config/agent.json"
if [ -f "$LEGACY_AGENT_JSON" ] && jq -e '.symlink_manifest | type == "array"' "$LEGACY_AGENT_JSON" >/dev/null 2>&1; then
  info "Splitting agent.json::symlink_manifest -> $SYMLINKS_STATE"
  if ! $DRY_RUN; then
    LEGACY_AGENT_JSON="$LEGACY_AGENT_JSON" \
    SYMLINKS_STATE="$SYMLINKS_STATE" \
    python3 - <<'PYEOF'
import json
import os
import sys
import tempfile

legacy = os.environ["LEGACY_AGENT_JSON"]
state_path = os.environ["SYMLINKS_STATE"]
state_dir = os.path.dirname(state_path)

# Read the legacy manifest, if present.
legacy_manifest = []
try:
    with open(legacy, "r", encoding="utf-8") as f:
        legacy_doc = json.load(f)
    if isinstance(legacy_doc.get("symlink_manifest"), list):
        legacy_manifest = legacy_doc["symlink_manifest"]
except (OSError, json.JSONDecodeError, ValueError) as exc:
    print(f"  [warn] failed to read {legacy}: {exc} — skipping split", file=sys.stderr)
    sys.exit(0)

if not legacy_manifest:
    sys.exit(0)

# Read existing state file, if any. Co-ownership rule: install merges,
# never clobbers — entries already present (typically agent-toggle's
# disable-state snapshots) are preserved by `link_path`.
existing = []
if os.path.exists(state_path):
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            existing_doc = json.load(f)
        if isinstance(existing_doc.get("symlink_manifest"), list):
            existing = existing_doc["symlink_manifest"]
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(
            f"  [warn] failed to read {state_path}: {exc} — overwriting",
            file=sys.stderr,
        )
        existing = []

if existing:
    print(
        f"  [lore] {state_path} already populated ({len(existing)} entries) — preserving",
        file=sys.stderr,
    )
    sys.exit(0)

os.makedirs(state_dir, exist_ok=True)
fd, tmp_path = tempfile.mkstemp(prefix=".symlinks.", suffix=".tmp", dir=state_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"schema_version": 1, "symlink_manifest": legacy_manifest}, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, state_path)
except OSError:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    raise
PYEOF
  fi
fi

# --- 1c. Delete vestigial settings.json.smoke-bak (D4 prep) ---
SMOKE_BAK="$LORE_DATA_DIR/config/settings.json.smoke-bak"
if [ -f "$SMOKE_BAK" ]; then
  info "Removing vestigial $SMOKE_BAK"
  dry rm -f "$SMOKE_BAK"
fi

# --- 1d. Create default capture-config.json (idempotent) ---
dry mkdir -p "$LORE_DATA_DIR/config"
if [ ! -f "$LORE_DATA_DIR/config/capture-config.json" ]; then
  info "Creating default capture-config.json"
  if ! $DRY_RUN; then
    cat > "$LORE_DATA_DIR/config/capture-config.json" <<'CONFIGEOF'
{
  "core": {
    "novelty_threshold": -1.0,
    "region_window": 5,
    "max_candidates": 5,
    "max_phrases": 15,
    "min_tool_uses": 5,
    "max_tool_uses": 10
  },
  "structural_signals": {
    "investigation_window": 10,
    "iterative_debug_window": 15,
    "test_fix_window": 20,
    "synthesis_char_threshold": 500,
    "synthesis_tool_threshold": 5,
    "file_context_window": 10,
    "debug_context_window": 10,
    "debug_context_chars": 800
  },
  "adaptive": false
}
CONFIGEOF
  fi
else
  info "capture-config.json already exists, skipping"
fi

# --- 1c. Persist TUI launch framework + harness-local role defaults ---
# settings.json is the authoritative user config. Re-running install with a
# different --framework value updates the TUI launch preference in settings.json
# and seeds only that harness's missing role bindings. Runtime shell commands
# spawned by a harness resolve that harness from process-local markers or
# LORE_FRAMEWORK; they must not read the TUI preference as global process truth.
#
# - `tui_launch_framework` is rewritten on every install so re-running with a
#   different --framework value updates the TUI-launched harness.
# - `capability_overrides` and harness-local `roles` are seeded only when
#   missing; user edits are preserved. Per-role bindings are harness-aware:
#   claude-code defaults every role to "opus", codex defaults every role to
#   "gpt-5.5-high", and opencode splits reasoning roles to "anthropic/opus"
#   and technical roles to "openai/gpt-5.5".
# - The role-id keyset is derived from `adapters/roles.json` (T3's closed
#   registry) rather than hardcoded here, so adding a role to the registry
#   automatically seeds it on the next install.
# - Capability profiles ship as static data in adapters/capabilities.json;
#   capability_overrides in settings.json are ad-hoc opt-ins that downstream
#   readers layer on top of the static profile.
info "Persisting unified settings config (tui_launch_framework=$FRAMEWORK)"
if ! $DRY_RUN; then
  FRAMEWORK="$FRAMEWORK" LORE_REPO_DIR="$LORE_REPO_DIR" \
    python3 - "$LORE_DATA_DIR/config/settings.json" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
framework = os.environ["FRAMEWORK"]
repo_dir = os.environ["LORE_REPO_DIR"]

# Derive the role-id keyset from adapters/roles.json (T3 closed registry).
# This is the parity hardening from T72 — adding a role to roles.json
# automatically seeds it here, and resolve_model_for_role's closed-set
# rejection (T6) cannot diverge from install.sh's seed dict.
roles_path = os.path.join(repo_dir, "adapters", "roles.json")
with open(roles_path) as f:
    roles_data = json.load(f)
if framework == "claude-code":
    default_roles = {r["id"]: "opus" for r in roles_data["roles"]}
elif framework == "codex":
    default_roles = {r["id"]: "gpt-5.5-high" for r in roles_data["roles"]}
else:
    reasoning_roles = {"lead", "researcher", "judge", "summarizer", "advisor", "default"}
    default_roles = {
        r["id"]: ("anthropic/opus" if r["id"] in reasoning_roles else "openai/gpt-5.5")
        for r in roles_data["roles"]
    }

if os.path.exists(path):
    with open(path, "r") as f:
        cfg = json.load(f)
else:
    cfg = {}

cfg["version"] = 1
cfg["tui_launch_framework"] = framework

# Preserve user-edited overrides; only seed when key is absent.
if "capability_overrides" not in cfg or not isinstance(cfg.get("capability_overrides"), dict):
    cfg["capability_overrides"] = {}

harnesses = cfg.get("harnesses") if isinstance(cfg.get("harnesses"), dict) else {}
harness_block = harnesses.get(framework) if isinstance(harnesses.get(framework), dict) else {}
existing_roles = harness_block.get("roles") if isinstance(harness_block.get("roles"), dict) else {}
merged_roles = dict(default_roles)
merged_roles.update(existing_roles)  # user values win for keys that exist
harness_block["roles"] = merged_roles
if "args" not in harness_block:
    harness_block["args"] = ["--dangerously-skip-permissions"] if framework == "claude-code" else []
harnesses[framework] = harness_block
cfg["harnesses"] = harnesses
if isinstance(cfg.get("tui"), dict):
    cfg["tui"].pop("launch_framework", None)
cfg.pop("active_framework", None)
cfg.pop("framework", None)
cfg.pop("roles", None)

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
fi

# --- 2. Create/update stable scripts symlink ---
info "Linking scripts -> $LORE_REPO_DIR/scripts"
dry ln -sfn "$LORE_REPO_DIR/scripts" "$LORE_DATA_DIR/scripts"

# --- 2b. Create/update stable claude-md symlink ---
info "Linking claude-md -> $LORE_REPO_DIR/claude-md"
dry ln -sfn "$LORE_REPO_DIR/claude-md" "$LORE_DATA_DIR/claude-md"

# --- 3. Install CLI to PATH ---
info "Installing CLI to ~/.local/bin/lore"
dry mkdir -p "$HOME/.local/bin"
dry ln -sf "$LORE_REPO_DIR/cli/lore" "$HOME/.local/bin/lore"

# Check if ~/.local/bin is on PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  echo ""
  echo "  [warning] ~/.local/bin is not on your PATH."
  echo "  Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

# --- 3b. Build and install TUI ---
if command -v go >/dev/null 2>&1; then
  info "Building TUI"
  if ! $DRY_RUN; then
    (cd "$LORE_REPO_DIR/tui" && go build -o "$HOME/.local/bin/lore-tui" .)
  else
    echo "  [dry-run] (cd $LORE_REPO_DIR/tui && go build -o ~/.local/bin/lore-tui .)"
  fi
else
  info "Skipping TUI build — go not found on PATH"
fi

# --- 4. Symlink skills (per-harness target via resolve_harness_install_path) ---
SKILLS_DIR=$(resolve_install_path skills)
if [ "$SKILLS_DIR" = "unsupported" ]; then
  info "Skipping skill symlinks — framework=$FRAMEWORK has no skills install path"
else
  dry mkdir -p "$SKILLS_DIR"
  for skill_dir in "$LORE_REPO_DIR"/skills/*/; do
    skill_name="$(basename "$skill_dir")"
    target="$SKILLS_DIR/$skill_name"
    # Remove existing target (symlink, file, or directory)
    if [ -L "$target" ] || [ -e "$target" ]; then
      dry rm -rf "$target"
    fi
    info "Linking skill: $skill_name -> $target"
    dry ln -s "$skill_dir" "$target"
  done
fi

# --- 4b. Symlink agents (per-harness target via resolve_harness_install_path) ---
# Note: the canonical agents/*.md format is Claude-flavored markdown.
# claude-code reads them natively; opencode reads .md agent files
# from ~/.claude/agents (Claude-compatible discovery); codex's native
# agent format is TOML so the .md symlinks land in ~/.codex/agents/
# but are NOT auto-loaded as native Codex subagents — orchestration
# adapter (T40) reads the canonical .md regardless of install location.
# A future task can convert canonical agents to a TOML emitter for codex.
AGENTS_DIR=$(resolve_install_path agents)
if [ "$AGENTS_DIR" = "unsupported" ]; then
  info "Skipping agent symlinks — framework=$FRAMEWORK has no agents install path"
else
  dry mkdir -p "$AGENTS_DIR"
  for agent_file in "$LORE_REPO_DIR"/agents/*.md; do
    [ -f "$agent_file" ] || continue
    agent_name="$(basename "$agent_file")"
    target="$AGENTS_DIR/$agent_name"
    if [ -L "$target" ] || [ -e "$target" ]; then
      dry rm -f "$target"
    fi
    info "Linking agent: $agent_name -> $target"
    dry ln -s "$agent_file" "$target"
  done
  if [ "$FRAMEWORK" = "codex" ]; then
    info "Note: codex reads TOML agents natively; .md symlinks installed for orchestration-adapter use"
  fi
fi

# --- 5. Inject hooks/permissions via per-harness adapter (T25/T26/T27/T28) ---
# Each harness ships a per-harness installer that owns its own
# settings/permissions schema and merge strategy. install.sh consults
# `resolve_permission_adapter` (lib.sh) for the dispatch shape and walks
# the result generically — the per-framework decision lives in one helper,
# not in a `case "$FRAMEWORK"` switch here. Today's adapters:
#   claude-code → adapters/hooks/claude-code.sh install (writes hooks
#                 into $HOME/.claude/settings.json; lore writes no
#                 permissions block today, so the adapter is hooks-only)
#   codex       → adapters/codex/hooks.sh install (writes hooks into
#                 $HOME/.codex/config.toml as TOML table-arrays;
#                 PreCompact + TaskCompleted-blocking degrade to the
#                 orchestration adapter per adapters/hooks/README.md)
#   opencode    → adapters/opencode/lore-hooks.ts is a session-time
#                 plugin loaded by OpenCode at startup from
#                 $HOME/.config/opencode/plugins/. Install-time work
#                 is a copy (or symlink) of the plugin file into that
#                 directory; no install subcommand exists because the
#                 plugin runtime owns dispatch.
# Harnesses with no permission adapter wired (resolve_permission_adapter
# returns `unsupported`, or install_paths.settings is `unsupported`)
# report `permission_hooks=none` and install.sh emits a documented
# degradation notice instead of writing.
#
# The capability triple (install_paths.settings,
# capabilities.permission_hooks.support, capabilities.permission_hooks.evidence)
# is composed into a tag string using the shared
# `degraded:partial|fallback|none|no-evidence|unverified-support(<level>)`
# vocabulary defined in
# conventions/capability-cells-in-adapters-capabilities-json-sho.md, so
# the install log classifies degradation identically to the MCP packaging
# step below and the assemble-instructions.sh dry-run report.
PERM_SUPPORT=$(framework_capability permission_hooks "$FRAMEWORK" 2>/dev/null || echo "none")
PERM_EVIDENCE=$(framework_capability_evidence permission_hooks "$FRAMEWORK" 2>/dev/null || true)
PERM_SETTINGS_PATH=$(resolve_install_path settings)
PERM_DEGRADE_TAG=""
case "$PERM_SUPPORT" in
  full) ;;
  partial|fallback) PERM_DEGRADE_TAG=" degraded:$PERM_SUPPORT" ;;
  none) PERM_DEGRADE_TAG=" degraded:none" ;;
  *) PERM_DEGRADE_TAG=" degraded:unverified-support($PERM_SUPPORT)" ;;
esac
if [ -z "$PERM_EVIDENCE" ] && [ "$PERM_SUPPORT" != "none" ]; then
  PERM_DEGRADE_TAG="$PERM_DEGRADE_TAG degraded:no-evidence"
fi
PERM_TRIPLE="support=$PERM_SUPPORT evidence=${PERM_EVIDENCE:-none}${PERM_DEGRADE_TAG}"

if ! PERM_ADAPTER_RECORD=$(resolve_permission_adapter "$FRAMEWORK" 2>/dev/null); then
  # resolve_permission_adapter rejects unknown frameworks with exit 1.
  # The install.sh validator above (line 47) already enforces the closed
  # SUPPORTED_FRAMEWORKS set, so reaching here is a contract drift between
  # install.sh's set and lib.sh's helper — surface it explicitly.
  info "Skipping hook configuration — resolve_permission_adapter rejected framework=$FRAMEWORK (settings=$PERM_SETTINGS_PATH $PERM_TRIPLE degraded:none)"
  PERM_ADAPTER_RECORD="unsupported"
fi
case "$PERM_ADAPTER_RECORD" in
  cli:*)
    HOOK_ADAPTER="${PERM_ADAPTER_RECORD#cli:}"
    HOOK_ADAPTER_REL="${HOOK_ADAPTER#$LORE_REPO_DIR/}"
    if [ -x "$HOOK_ADAPTER" ]; then
      info "Configuring hooks via $HOOK_ADAPTER_REL install ($PERM_TRIPLE)"
      if ! $DRY_RUN; then
        bash "$HOOK_ADAPTER" install
      fi
    else
      info "Skipping hook configuration — adapter missing at $HOOK_ADAPTER ($PERM_TRIPLE degraded:none)"
    fi
    ;;
  plugin-symlink:*)
    PLUGIN_REST="${PERM_ADAPTER_RECORD#plugin-symlink:}"
    PLUGIN_SRC="${PLUGIN_REST%%:*}"
    PLUGIN_DST="${PLUGIN_REST#*:}"
    PLUGIN_DIR="$(dirname "$PLUGIN_DST")"
    if [ -f "$PLUGIN_SRC" ]; then
      info "Linking $FRAMEWORK plugin: $PLUGIN_DST -> $PLUGIN_SRC ($PERM_TRIPLE)"
      dry mkdir -p "$PLUGIN_DIR"
      dry ln -sfn "$PLUGIN_SRC" "$PLUGIN_DST"
    else
      info "Skipping $FRAMEWORK plugin install — plugin source missing at $PLUGIN_SRC ($PERM_TRIPLE degraded:none)"
    fi
    ;;
  unsupported)
    info "Skipping hook configuration — no permission adapter wired for framework=$FRAMEWORK ($PERM_TRIPLE degraded:none)"
    ;;
esac

# --- 6. Assemble per-harness instruction file ---
# assemble-instructions.sh dispatches to the right target per
# resolve_harness_install_path: claude-code → ~/.claude/CLAUDE.md;
# opencode → ~/.config/opencode/AGENTS.md; codex → ~/.codex/AGENTS.md.
INSTRUCTIONS_TARGET=$(resolve_install_path instructions)
if [ "$INSTRUCTIONS_TARGET" = "unsupported" ]; then
  info "Skipping instruction-file assembly — framework=$FRAMEWORK has no instructions install path"
else
  info "Assembling instruction file: $INSTRUCTIONS_TARGET"
  if ! $DRY_RUN; then
    bash "$LORE_REPO_DIR/scripts/assemble-instructions.sh" --framework "$FRAMEWORK"
  fi
fi

# --- 6b. Package Lore-shipped MCP servers (T20) ---
# Lore today ships zero MCP servers, so this step is a no-op gate. The
# wiring exists so adding a server to adapters/mcp-servers.json
# automatically routes it to the right per-harness location:
#   claude-code → $HOME/.claude/settings.json `mcpServers` (JSON object)
#   opencode    → $HOME/.config/opencode/opencode.json `mcp` (JSON object)
#   codex       → $HOME/.codex/config.toml `[mcp_servers.<name>]` (TOML tables)
# A harness whose mcp_servers install path is "unsupported" reports
# `mcp=none` and skips packaging silently — install.sh treats absence as
# a stable degradation, not an error (D6: degradation is explicit and
# testable). The mcp capability cell's `support` and `evidence` fields
# from adapters/capabilities.json are surfaced alongside the path so the
# install log records the cross-harness MCP contract per harness:
# "support=full evidence=claude-code-mcp" for the reference baseline,
# "support=partial evidence=opencode-mcp" / "support=full evidence=codex-mcp"
# for the other harnesses. Per Phase 2 / D8 the path requires a non-empty
# evidence pointer; missing evidence on a non-`none` cell is reported as
# degraded:no-evidence rather than treated as a verified surface.
MCP_SERVERS_TARGET=$(resolve_install_path mcp_servers)
MCP_REGISTRY="$LORE_REPO_DIR/adapters/mcp-servers.json"
MCP_CAPABILITIES_FILE="$LORE_REPO_DIR/adapters/capabilities.json"
MCP_SUPPORT="unknown"
MCP_EVIDENCE=""
if [ -f "$MCP_CAPABILITIES_FILE" ] && command -v jq >/dev/null 2>&1; then
  MCP_SUPPORT=$(jq -r --arg fw "$FRAMEWORK" '.frameworks[$fw].capabilities.mcp.support // "unknown"' "$MCP_CAPABILITIES_FILE" 2>/dev/null)
  MCP_EVIDENCE=$(jq -r --arg fw "$FRAMEWORK" '.frameworks[$fw].capabilities.mcp.evidence // ""' "$MCP_CAPABILITIES_FILE" 2>/dev/null)
fi
if [ "$MCP_SERVERS_TARGET" = "unsupported" ]; then
  info "Skipping MCP server packaging — framework=$FRAMEWORK has mcp=none (no MCP install path; capability cell support=$MCP_SUPPORT)"
elif [ ! -f "$MCP_REGISTRY" ]; then
  info "Skipping MCP server packaging — adapters/mcp-servers.json not found (target would be: $MCP_SERVERS_TARGET)"
else
  MCP_SERVER_COUNT=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    print(len((data.get('servers') or {})))
except Exception:
    print(0)
" "$MCP_REGISTRY" 2>/dev/null || echo "0")
  # Compose a degradation tag mirroring assemble-instructions.sh --dry-run
  # so the install log and the dry-run report classify the surface
  # identically. `partial`/`fallback` are reported as degraded with the
  # support level; missing evidence on a non-`none` cell is reported
  # as degraded:no-evidence (Phase 2 D8 evidence-gating).
  MCP_DEGRADE_TAG=""
  case "$MCP_SUPPORT" in
    full) ;;
    partial|fallback) MCP_DEGRADE_TAG=" degraded:$MCP_SUPPORT" ;;
    none) MCP_DEGRADE_TAG=" degraded:none" ;;
    *) MCP_DEGRADE_TAG=" degraded:unverified-support($MCP_SUPPORT)" ;;
  esac
  if [ -z "$MCP_EVIDENCE" ] && [ "$MCP_SUPPORT" != "none" ]; then
    MCP_DEGRADE_TAG="$MCP_DEGRADE_TAG degraded:no-evidence"
  fi
  if [ "$MCP_SERVER_COUNT" -eq 0 ]; then
    # Registry is empty — the no-op is the correct end state; the
    # `would-be` line records the per-harness surface for operators
    # auditing the install without actually running the harness.
    info "MCP server packaging — registry empty (0 servers); target would be: $MCP_SERVERS_TARGET (support=$MCP_SUPPORT evidence=${MCP_EVIDENCE:-none}${MCP_DEGRADE_TAG})"
  else
    # The harness-format-specific writer is intentionally a follow-up:
    # adding a Lore-shipped MCP server is a future event, and the
    # writer's JSON-merge / TOML-write logic should land alongside
    # the first concrete server (so the merge contract is anchored
    # to a real input, not a hypothetical one). The packaging step
    # below preserves that follow-up boundary explicitly — it is
    # NOT an implementation gap on this task's scope, which is the
    # MCP packaging *contract* (where each harness reads, what
    # degradation each cell expresses), not the writer itself.
    info "Packaging $MCP_SERVER_COUNT MCP server(s) into $MCP_SERVERS_TARGET (support=$MCP_SUPPORT evidence=${MCP_EVIDENCE:-none}${MCP_DEGRADE_TAG})"
    info "  [follow-up] Per-harness MCP writer (JSON merge for claude-code/opencode, TOML write for codex) lands when Lore ships its first server; registry has $MCP_SERVER_COUNT entry/entries"
  fi
fi

# --- 7. Migrate old data ---
OLD_DATA_DIR="$HOME/.project-knowledge/repos"
if [ -d "$OLD_DATA_DIR" ] && [ -d "$LORE_DATA_DIR/repos" ]; then
  # Check if new repos dir is empty (no entries besides . and ..)
  if [ -z "$(ls -A "$LORE_DATA_DIR/repos" 2>/dev/null)" ]; then
    info "Migrating data from $OLD_DATA_DIR"
    dry cp -a "$OLD_DATA_DIR/." "$LORE_DATA_DIR/repos/"
  fi
fi

# --- 7b. Cleanup deletion of legacy fragmented files (D4 phase 3) ---
# Conditional + idempotent. Legacy files are deleted ONLY when
# all three gates pass:
#   1. ~/.lore/config/settings.json exists
#   2. its `.version` field is at-or-above $LORE_SETTINGS_CLEANUP_VERSION
#   3. the deterministic fallback audit (settings.sh fallbacks +
#      lore_settings.fallbacks() + Go snapshot) is empty across all stacks
# When any gate is open, leave the legacy files intact and emit an
# actionable warning naming the keys still falling back. Re-runs against
# already-cleaned state are silent no-ops.
if [ -f "$SETTINGS_FILE" ] && ! $DRY_RUN; then
  CLEANUP_VERSION_OK=false
  _settings_version=$(jq -r '.version // empty' "$SETTINGS_FILE" 2>/dev/null || echo "")
  if [ -n "$_settings_version" ] && [ "$_settings_version" -ge "$LORE_SETTINGS_CLEANUP_VERSION" ] 2>/dev/null; then
    CLEANUP_VERSION_OK=true
  fi

  # Aggregate fallback snapshots across stacks. Bash + Python today; Go
  # snapshot lands when T4's tui/internal/config/settings.go ships its
  # `Fallbacks()` accessor. Each pair is reported as "<file>::<key>".
  FALLBACK_PAIRS=""
  if [ -x "$LORE_REPO_DIR/scripts/settings.sh" ]; then
    _bash_pairs=$(LORE_DATA_DIR="$LORE_DATA_DIR" bash "$LORE_REPO_DIR/scripts/settings.sh" fallbacks 2>/dev/null || true)
    if [ -n "$_bash_pairs" ]; then
      FALLBACK_PAIRS="$_bash_pairs"
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    _py_pairs=$(LORE_DATA_DIR="$LORE_DATA_DIR" PYTHONPATH="$LORE_REPO_DIR/scripts" python3 -c "
import lore_settings
for f, k in lore_settings.fallbacks():
    print(f'{f}::{k}')
" 2>/dev/null || true)
    if [ -n "$_py_pairs" ]; then
      if [ -n "$FALLBACK_PAIRS" ]; then
        FALLBACK_PAIRS="$FALLBACK_PAIRS
$_py_pairs"
      else
        FALLBACK_PAIRS="$_py_pairs"
      fi
    fi
  fi
  # T4 Go snapshot: when tui/internal/config/settings.go exposes a fallbacks
  # accessor wired through lore-tui or a sibling CLI, aggregate it here.
  # TODO(T4): plumb the Go snapshot once the loader lands.

  if $CLEANUP_VERSION_OK && [ -z "$FALLBACK_PAIRS" ]; then
    info "Cleanup: deleting legacy fragmented files (settings.json.version=$_settings_version >= $LORE_SETTINGS_CLEANUP_VERSION, fallback audit empty)"
    for legacy in \
      "$LORE_DATA_DIR/ceremonies.json" \
      "$LORE_DATA_DIR/config/agent.json" \
      "$LORE_DATA_DIR/config/capture-config.json" \
      "$LORE_DATA_DIR/config/framework.json" \
      "$LORE_DATA_DIR/config/harness-args.json" \
      "$LORE_DATA_DIR/config/obsidian.json" \
      "$LORE_DATA_DIR/config/settlement-config.json" \
      "$LORE_DATA_DIR/config/tui.json"; do
      if [ -f "$legacy" ]; then
        info "  removing $legacy"
        rm -f "$legacy"
      fi
    done
  else
    if ! $CLEANUP_VERSION_OK; then
      info "Cleanup deferred: settings.json.version='${_settings_version:-unset}' < $LORE_SETTINGS_CLEANUP_VERSION (legacy files left intact)"
    fi
    if [ -n "$FALLBACK_PAIRS" ]; then
      info "Cleanup deferred: fallback audit non-empty — keys still falling back to legacy files:"
      printf '%s\n' "$FALLBACK_PAIRS" | sort -u | while IFS= read -r pair; do
        [ -n "$pair" ] && info "  $pair"
      done
      info "  Action: copy these values into $SETTINGS_FILE (or re-run install) to enable cleanup."
    fi
  fi
  unset _settings_version _bash_pairs _py_pairs FALLBACK_PAIRS CLEANUP_VERSION_OK
fi

# --- 8. Summary ---
echo ""
echo "Lore installed successfully."
echo ""
echo "  Data dir:    $LORE_DATA_DIR"
echo "  Scripts:     $LORE_DATA_DIR/scripts -> $LORE_REPO_DIR/scripts"
echo "  Claude-md:   $LORE_DATA_DIR/claude-md -> $LORE_REPO_DIR/claude-md"
echo "  Settings:    $LORE_DATA_DIR/config/settings.json (framework=$FRAMEWORK)"
echo "  CLI:         ~/.local/bin/lore -> $LORE_REPO_DIR/cli/lore"
if [ -f "$HOME/.local/bin/lore-tui" ]; then
  echo "  TUI:         ~/.local/bin/lore-tui (built)"
else
  echo "  TUI:         skipped (go not found)"
fi
# Resolve summary paths from the active framework's install_paths so the
# summary reflects what was actually written. claude-code resolves to
# $CLAUDE_DIR for skills/agents/settings/instructions today (preserving
# the original summary lines byte-for-byte); codex/opencode resolve to
# their own per-harness paths.
SUMMARY_SKILLS=$(resolve_install_path skills)
SUMMARY_AGENTS=$(resolve_install_path agents)
SUMMARY_SETTINGS=$(resolve_install_path settings)
SUMMARY_INSTRUCTIONS=$(resolve_install_path instructions)
echo "  Skills:      ${SUMMARY_SKILLS}/ ($(ls -d "$LORE_REPO_DIR"/skills/*/ 2>/dev/null | wc -l | tr -d ' ') linked)"
echo "  Agents:      ${SUMMARY_AGENTS}/ ($(ls "$LORE_REPO_DIR"/agents/*.md 2>/dev/null | wc -l | tr -d ' ') linked)"
if [ "$SUMMARY_SETTINGS" = "unsupported" ]; then
  echo "  Hooks:       (none — framework=$FRAMEWORK has no settings install path)"
else
  echo "  Hooks:       $SUMMARY_SETTINGS (updated)"
fi
if [ "$FRAMEWORK" = "claude-code" ]; then
  # Preserve the historical `CLAUDE.md:` summary label byte-for-byte
  # for claude-code. Non-claude-code harnesses use the generic
  # Instructions: label since their target file is named differently.
  echo "  CLAUDE.md:   $SUMMARY_INSTRUCTIONS (assembled)"
elif [ "$SUMMARY_INSTRUCTIONS" = "unsupported" ]; then
  echo "  Instructions: (none — framework=$FRAMEWORK has no instructions install path)"
else
  echo "  Instructions: $SUMMARY_INSTRUCTIONS (assembled)"
fi
echo ""
echo "To uninstall: bash $LORE_REPO_DIR/install.sh --uninstall"
