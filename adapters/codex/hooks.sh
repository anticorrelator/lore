#!/usr/bin/env bash
# adapters/codex/hooks.sh — Codex hook adapter (T27).
#
# Implements the hook adapter contract documented in
# adapters/hooks/README.md (T24) for Codex CLI 0.124.0+ native hooks.
# Codex exposes SessionStart, Stop, PreToolUse, PostToolUse, and
# PermissionRequest natively; PreCompact and TaskCompleted-blocking
# remain capability gaps and are routed through the orchestration
# adapter / SessionStart bookend per the hook ↔ orchestration
# cross-reference in adapters/hooks/README.md.
#
# Subcommands:
#   install    Inject the lore hook entries into ~/.codex/config.toml,
#              preserving any non-lore content the user has there.
#              Lore-managed entries are bracketed by sentinel comments
#              so a future install can strip and rewrite them without
#              touching user-authored hooks elsewhere in the file.
#   uninstall  Strip every lore-managed hook entry, leaving user
#              content intact.
#   smoke      Print, for the active framework (must be codex), every
#              Lore lifecycle event paired with its support level and
#              the native Codex hook (or fallback path) it routes
#              through. Honors adapters/hooks/README.md checklist
#              item 5.
#
# Wire format reference: ~/.codex/config.toml uses a TOML
# table-array per native event:
#
#   [[hooks.SessionStart]]
#   command = "bash ~/.lore/scripts/load-knowledge.sh"
#
# Per gotchas/hooks/hook-system-gotchas.md (May 2026 update), Codex
# signals via exit code (non-zero = abort the tool) for tool-shaped
# events and via JSON `behavior: allow|deny|abstain` for
# PermissionRequest. The hook commands written here are the same
# Lore handler scripts the claude-code adapter invokes; the adapter
# does NOT translate per-handler protocols (e.g. PreToolUse JSON
# stdout) — handlers that depend on Claude-Code-specific signaling
# may run as advisory `notify`-shaped commands on Codex. That is the
# `partial`/`fallback` part of the capability cells, and the
# orchestration adapter compensates for the genuine gaps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LORE_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=/dev/null
source "$LORE_REPO_DIR/scripts/lib.sh"

# Sentinel markers bracketing the lore-managed block inside config.toml.
# Idempotent install/uninstall keys on these literals: any text between
# them (inclusive) is rewritten as a unit, anything outside is preserved
# verbatim including user comments and table layout.
LORE_BEGIN_MARKER="# >>> lore hooks (managed) — do not edit between markers"
LORE_END_MARKER="# <<< lore hooks (managed)"

# Ensure the active framework is codex; install.sh sets LORE_FRAMEWORK
# before invoking us, so this guard is a contract check, not a routing
# decision.
require_codex() {
  local active
  active=$(resolve_active_framework 2>/dev/null) || active=""
  if [[ "$active" != "codex" ]]; then
    echo "Error: adapters/codex/hooks.sh requires active framework=codex (got '$active')" >&2
    echo "       set LORE_FRAMEWORK=codex or run install.sh --framework codex" >&2
    return 1
  fi
}

resolve_settings_path() {
  local settings_path
  if ! settings_path=$(resolve_harness_install_path settings 2>/dev/null); then
    echo "Error: resolve_harness_install_path settings failed for codex" >&2
    return 1
  fi
  if [[ "$settings_path" == "unsupported" ]]; then
    echo "Error: install_paths.settings is 'unsupported' for codex (capabilities.json contract violation)" >&2
    return 1
  fi
  echo "$settings_path"
}

# Render the lore-managed TOML block. Hook commands point at the stable
# ~/.lore/scripts/<name> install symlink per checklist item 6. The chain
# of SessionStart hooks mirrors the claude-code adapter's order:
# doctor -> auto-reindex -> load-knowledge -> load-work -> load-threads ->
# extract-session-digest. Stop chains stop-novelty-check + check-plan-
# persistence. PreToolUse with matcher=Write covers guard-work-writes.
# PreCompact and SessionEnd are not native Codex events; PreCompact
# falls back to a SessionStart bookend (pre-compact.sh on every session
# start) and SessionEnd is derived from Stop (skipped here — Stop hook
# already runs the same work).
#
# Every command is prefixed with `LORE_FRAMEWORK=codex` so spawned
# scripts resolve the active framework at runtime independently of
# `~/.lore/config/framework.json`. The static framework.json default
# is single-valued (last install.sh run wins); without this prefix,
# codex sessions would resolve to whichever framework happened to be
# installed last and misroute through claude-code's capability profile
# (lib.sh::resolve_active_framework consults LORE_FRAMEWORK before
# framework.json — see scripts/lib.sh:528-530).
render_lore_block() {
  cat <<'TOML'
# >>> lore hooks (managed) — do not edit between markers
# Lore manages every entry between this marker and `<<< lore hooks
# (managed)`. To customize a hook, add a sibling [[hooks.<Event>]]
# table outside the markers — Codex concatenates table-arrays across
# the file. To opt out entirely, run `bash adapters/codex/hooks.sh
# uninstall` (or re-run install.sh with --framework=<other>).

[[hooks.SessionStart]]
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/doctor.sh --quiet"

[[hooks.SessionStart]]
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/auto-reindex.sh"

[[hooks.SessionStart]]
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/load-knowledge.sh"

[[hooks.SessionStart]]
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/load-work.sh"

[[hooks.SessionStart]]
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/load-threads.sh"

[[hooks.SessionStart]]
command = "LORE_FRAMEWORK=codex python3 ~/.lore/scripts/extract-session-digest.py"

# pre_compact fallback: Codex has no native PreCompact event, so the
# pre-compact reminder runs at SessionStart as a bookend. See
# adapters/hooks/README.md "Per-Harness Mapping" for the fallback.
[[hooks.SessionStart]]
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/pre-compact.sh"

[[hooks.Stop]]
command = "LORE_FRAMEWORK=codex python3 ~/.lore/scripts/stop-novelty-check.py"

[[hooks.Stop]]
command = "LORE_FRAMEWORK=codex python3 ~/.lore/scripts/check-plan-persistence.py"

[[hooks.PreToolUse]]
# Codex 0.124+ requires `matcher` to be a TOML string (the tool name),
# not an inline table. The previous `{ tool = "Write" }` form parsed
# under earlier codex versions but fails config load on 0.124 with
# "invalid type: map, expected a string in hooks.PreToolUse.matcher"
# (verified empirically against the installed binary). The bare-string
# form below is the schema codex actually expects.
matcher = "Write"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/guard-work-writes.sh"
# <<< lore hooks (managed)
TOML
}

# --- Subcommand: install ---
# Inject the lore-managed block into config.toml. Idempotent: existing
# managed block (between markers) is replaced; everything outside is
# preserved byte-for-byte. New file is created if config.toml does not
# exist yet.
cmd_install() {
  require_codex
  local settings_path
  settings_path=$(resolve_settings_path)
  mkdir -p "$(dirname "$settings_path")"

  local lore_block
  lore_block=$(render_lore_block)

  if [[ ! -f "$settings_path" ]]; then
    {
      echo "# Codex configuration — lore hooks injected by"
      echo "# adapters/codex/hooks.sh install."
      echo
      echo "$lore_block"
    } > "$settings_path"
    emit_degraded_notices
    return 0
  fi

  # Strip any existing lore-managed block, then append the fresh one.
  python3 - "$settings_path" "$LORE_BEGIN_MARKER" "$LORE_END_MARKER" "$lore_block" <<'PYEOF'
import sys

settings_path = sys.argv[1]
begin = sys.argv[2]
end = sys.argv[3]
lore_block = sys.argv[4]

with open(settings_path, "r") as f:
    text = f.read()

# Remove every existing managed block (handles repeat installs and
# accidental duplication). Use a stable line-anchored split so user
# content adjacent to the markers survives unchanged.
lines = text.splitlines(keepends=True)
out = []
in_block = False
for line in lines:
    stripped = line.rstrip("\n").rstrip("\r")
    if not in_block and stripped == begin:
        in_block = True
        continue
    if in_block:
        if stripped == end:
            in_block = False
        continue
    out.append(line)

# Preserve trailing newline behavior; ensure there is exactly one blank
# line between user content and the lore block when both are present.
preserved = "".join(out).rstrip()
if preserved:
    new_text = preserved + "\n\n" + lore_block.rstrip() + "\n"
else:
    new_text = lore_block.rstrip() + "\n"

with open(settings_path, "w") as f:
    f.write(new_text)
PYEOF

  emit_degraded_notices
}

# Surface degraded status (adapters/hooks/README.md checklist item 4).
# Codex has no native PreCompact event and no native subagent-completion
# blocking event; lore covers them via SessionStart bookend and the
# orchestration adapter's lead-side validator respectively. Emit one
# line per fallback event so operators see exactly what is degraded.
emit_degraded_notices() {
  echo "[lore] degraded: pre_compact via SessionStart bookend (~/.lore/scripts/pre-compact.sh) (capability=fallback)" >&2
  echo "[lore] degraded: task_completed via lead-side validator in orchestration adapter (capability=fallback)" >&2
}

# --- Subcommand: uninstall ---
# Strip every line between (and including) the lore sentinel markers.
# User content above and below the markers is preserved verbatim. If
# config.toml does not exist, this is a no-op.
cmd_uninstall() {
  require_codex
  local settings_path
  settings_path=$(resolve_settings_path)
  if [[ ! -f "$settings_path" ]]; then
    return 0
  fi

  python3 - "$settings_path" "$LORE_BEGIN_MARKER" "$LORE_END_MARKER" <<'PYEOF'
import sys

settings_path = sys.argv[1]
begin = sys.argv[2]
end = sys.argv[3]

with open(settings_path, "r") as f:
    text = f.read()

lines = text.splitlines(keepends=True)
out = []
in_block = False
for line in lines:
    stripped = line.rstrip("\n").rstrip("\r")
    if not in_block and stripped == begin:
        in_block = True
        continue
    if in_block:
        if stripped == end:
            in_block = False
        continue
    out.append(line)

new_text = "".join(out).rstrip() + ("\n" if out else "")
with open(settings_path, "w") as f:
    f.write(new_text)
PYEOF
}

# --- Subcommand: smoke ---
# Print Lore lifecycle event -> support level + native Codex hook
# (or fallback mechanism) for the active framework. Mirrors the
# claude-code adapter's output shape so tests/frameworks/hooks.bats
# can assert structurally without per-adapter format branches.
cmd_smoke() {
  require_codex
  local settings_path
  settings_path=$(resolve_settings_path 2>/dev/null) || settings_path="<unresolved>"

  echo "[codex hook adapter smoke]"
  echo "  active framework: codex"
  echo "  settings path:    $settings_path"
  echo
  echo "  Lore event           Support   Native hook (codex)"
  echo "  -------------------- --------- ----------------------------------------"
  printf '  %-20s %-9s %s\n' session_start      full      "SessionStart hook (~/.lore/scripts/{doctor,auto-reindex,load-knowledge,load-work,load-threads,extract-session-digest})"
  printf '  %-20s %-9s %s\n' user_prompt        full      "(no native UserPromptSubmit; PreToolUse matcher=Write covers lore writes)"
  printf '  %-20s %-9s %s\n' pre_tool           full      "PreToolUse hook (matcher=Write -> guard-work-writes.sh)"
  printf '  %-20s %-9s %s\n' post_tool          full      "(currently unused by lore; PostToolUse hook surface available)"
  printf '  %-20s %-9s %s\n' permission_request full      "PermissionRequest hook (behavior=allow|deny|abstain JSON-stdout)"
  printf '  %-20s %-9s %s\n' pre_compact        fallback  "(no native PreCompact; SessionStart bookend -> pre-compact.sh)"
  printf '  %-20s %-9s %s\n' stop               full      "Stop hook (stop-novelty-check.py + check-plan-persistence.py)"
  printf '  %-20s %-9s %s\n' session_end        full      "(no native SessionEnd; Stop hook covers both turn-stop and clear)"
  printf '  %-20s %-9s %s\n' task_completed     fallback  "(no native blocking event; lead-side validator via orchestration adapter, T31/T32)"
}

# --- Dispatch ---
cmd="${1:-}"
case "$cmd" in
  install)   shift; cmd_install   "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  smoke)     shift; cmd_smoke     "$@" ;;
  -h|--help|"")
    cat <<EOF >&2
Usage: $(basename "$0") <subcommand>

Subcommands:
  install    Inject lore hooks into the active framework's config.toml.
  uninstall  Remove every lore-managed hook entry, preserving user content.
  smoke      Print Lore lifecycle event -> native hook mapping for
             the active framework (codex only).

Refer to adapters/hooks/README.md for the full hook adapter contract.
EOF
    [[ -z "$cmd" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$cmd' (allowed: install, uninstall, smoke)" >&2
    exit 1
    ;;
esac
