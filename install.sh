#!/usr/bin/env bash
# install.sh — Set up lore for Claude Code
# Usage: bash install.sh [--uninstall] [--dry-run] [--framework <name>]
#
# --framework selects the harness whose install paths and capability profile
# Lore should target. Supported values: claude-code (default), opencode, codex.
# The selection is persisted to $LORE_DATA_DIR/config/framework.json so that
# `cli/lore` and downstream scripts can resolve the active harness without
# re-passing the flag. Re-running install with a different --framework
# rewrites the persisted framework field while preserving role bindings and
# capability overrides previously edited by the user.
set -euo pipefail

# --- Resolve paths ---
LORE_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LORE_DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
CLAUDE_DIR="$HOME/.claude"

# --- Parse flags ---
UNINSTALL=false
DRY_RUN=false
FRAMEWORK="claude-code"
SUPPORTED_FRAMEWORKS=("claude-code" "opencode" "codex")
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
# friends. lib.sh is in the repo's scripts/ dir; LORE_DATA_DIR is honored
# by resolve_active_framework but install.sh sets LORE_FRAMEWORK on every
# resolve so the active value comes from --framework, not the persisted
# config (which is rewritten at the end of this script).
# shellcheck source=scripts/lib.sh
source "$LORE_REPO_DIR/scripts/lib.sh"

# resolve_install_path <kind> [framework]
# Wrap resolve_harness_install_path so that it (a) honors the
# install-time --framework flag without depending on framework.json
# being present yet, (b) prints a degraded notice and returns "unsupported"
# rather than failing when a kind is not wired for the active harness,
# and (c) shells out cleanly under set -e (the bare resolve_*
# helper exits non-zero on unknown kinds, which would abort the install).
resolve_install_path() {
  local kind="$1"
  local fw="${2:-$FRAMEWORK}"
  local path
  if path=$(LORE_FRAMEWORK="$fw" resolve_harness_install_path "$kind" 2>/dev/null); then
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
            LORE_FRAMEWORK="$fw" bash "$fw_adapter" uninstall || true
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

# --- 1b. Create default capture-config.json (idempotent) ---
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

# --- 1c. Persist framework selection + role/capability override config ---
# Schema (version 1):
#   {
#     "version": 1,
#     "framework": "claude-code" | "opencode" | "codex",
#     "capability_overrides": { "<capability>": "full|partial|fallback|none", ... },
#     "roles": { "default": "<model>", "lead": ..., "worker": ..., ... }
#   }
#
# - `framework` is rewritten on every install so re-running with a different
#   --framework value updates the active harness.
# - `capability_overrides` and `roles` are seeded only when missing; user edits
#   are preserved. Per-role bindings default to "sonnet" to match the legacy
#   default-model behavior in batch-spec.sh, batch-implement.sh, work-ai.sh,
#   and generate-review-summary.sh. resolve_model_for_role (T6) reads this map.
# - The role-id keyset is derived from `adapters/roles.json` (T3's closed
#   registry) rather than hardcoded here, so adding a role to the registry
#   automatically seeds it on the next install. Each new role defaults to
#   "sonnet" for backward compat; a future schema field
#   `capabilities.json frameworks.<active>.default_model` may override.
# - Capability profiles ship as static data in adapters/capabilities.json;
#   capability_overrides here are ad-hoc per-install opt-ins that downstream
#   readers layer on top of the static profile.
info "Persisting framework config (framework=$FRAMEWORK)"
if ! $DRY_RUN; then
  FRAMEWORK="$FRAMEWORK" LORE_REPO_DIR="$LORE_REPO_DIR" \
    python3 - "$LORE_DATA_DIR/config/framework.json" <<'PYEOF'
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
# Per-role model defaults preserve the legacy claude-code behavior:
# `lead` defaulted to `opus` (matched skills/implement/SKILL.md's pre-T35
# hardcoded `--model opus (override with --model sonnet)` status line).
# Every other role defaulted to `sonnet`. After T35 the SKILL.md status
# line is sourced from this seed via resolve_model_for_role, so seeding
# `lead → opus` here preserves byte-equivalent observable behavior on a
# default claude-code install — operators who relied on opus-for-lead
# get the same model without editing framework.json.
DEFAULT_BY_ROLE = {"lead": "opus"}
default_roles = {r["id"]: DEFAULT_BY_ROLE.get(r["id"], "sonnet") for r in roles_data["roles"]}

if os.path.exists(path):
    with open(path, "r") as f:
        cfg = json.load(f)
else:
    cfg = {}

cfg["version"] = 1
cfg["framework"] = framework

# Preserve user-edited overrides; only seed when key is absent.
if "capability_overrides" not in cfg or not isinstance(cfg.get("capability_overrides"), dict):
    cfg["capability_overrides"] = {}

existing_roles = cfg.get("roles") if isinstance(cfg.get("roles"), dict) else {}
merged_roles = dict(default_roles)
merged_roles.update(existing_roles)  # user values win for keys that exist
cfg["roles"] = merged_roles

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
PERM_SUPPORT=$(LORE_FRAMEWORK="$FRAMEWORK" framework_capability permission_hooks 2>/dev/null || echo "none")
PERM_EVIDENCE=$(LORE_FRAMEWORK="$FRAMEWORK" framework_capability_evidence permission_hooks 2>/dev/null || true)
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
        LORE_FRAMEWORK="$FRAMEWORK" bash "$HOOK_ADAPTER" install
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
# resolve_harness_install_path: claude-code/opencode → ~/.claude/CLAUDE.md
# (opencode reads it natively); codex → ~/.codex/AGENTS.md.
INSTRUCTIONS_TARGET=$(resolve_install_path instructions)
if [ "$INSTRUCTIONS_TARGET" = "unsupported" ]; then
  info "Skipping instruction-file assembly — framework=$FRAMEWORK has no instructions install path"
else
  info "Assembling instruction file: $INSTRUCTIONS_TARGET"
  if ! $DRY_RUN; then
    LORE_FRAMEWORK="$FRAMEWORK" bash "$LORE_REPO_DIR/scripts/assemble-instructions.sh"
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

# --- 8. Summary ---
echo ""
echo "Lore installed successfully."
echo ""
echo "  Data dir:    $LORE_DATA_DIR"
echo "  Scripts:     $LORE_DATA_DIR/scripts -> $LORE_REPO_DIR/scripts"
echo "  Claude-md:   $LORE_DATA_DIR/claude-md -> $LORE_REPO_DIR/claude-md"
echo "  Capture:     $LORE_DATA_DIR/config/capture-config.json"
echo "  Framework:   $LORE_DATA_DIR/config/framework.json (framework=$FRAMEWORK)"
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
