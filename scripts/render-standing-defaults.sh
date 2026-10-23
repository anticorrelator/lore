#!/usr/bin/env bash
# render-standing-defaults.sh — Render the standing defaults in force as a
# compact, agent-readable block. Routed as `lore defaults`.
#
# Purpose: settings.json values are consumed by scripts but were never rendered
# into any agent-visible surface, so agents could not learn the project's agent
# defaults (role→model maps, sampling rates) without
# happening to run a script that used them. This verb is the universal delivery
# mechanism — invocation-fresh on every harness because it needs only bash.
# Skills call it at step 0 of their orient sections; coordinator briefs open
# worker dispatches with the same instruction.
#
# Output contract (consumed as prompt content, keep it boring):
#   - a header naming the render time and settings source
#   - the effective settings document flattened to `key.path: value` lines
#   - the preferences in force, grouped by the activity each is filed under:
#     the project's working style, accumulated from many hands. Titles only,
#     one `<activity> (<count>):` group per activity in name order, an entry
#     filed under two activities listed under both, live entries without an
#     activity under `untagged`. The full text of one activity is
#     `lore search --preferences --activity <name>`, and the commands that
#     start an activity print it themselves.
#   - with --with-routing, the effective route per role as resolved from THIS
#     process's harness. Off by default because the dispatch-guidance digest
#     hashes this script's output and a worker is validated by whichever host
#     claims it: a section that differs by requesting harness would make a
#     codex lead's guidance stale on a claude-code host. `lore defaults` passes
#     the flag; render-/validate-dispatch-guidance.sh never do.
#
# Read-only. Exit 0 even when the settings file or preferences directory is
# absent — absence is rendered explicitly, never silently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SETTINGS_FILE="${LORE_DATA_DIR:-$HOME/.lore}/config/settings.json"

WITH_ROUTING=false
for arg in "$@"; do
  case "$arg" in
    --with-routing) WITH_ROUTING=true ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *) echo "Error: unknown argument '$arg' (accepted: --with-routing)" >&2; exit 1 ;;
  esac
done

echo "=== Standing defaults in force (rendered $(timestamp_iso)) ==="
echo ""

if [[ -f "$SETTINGS_FILE" ]] && command -v jq &>/dev/null; then
  echo "-- Settings ($SETTINGS_FILE) --"
  jq -r '
    paths(scalars) as $p
    | ($p | map(tostring) | join(".")) + ": " + (getpath($p) | tostring)
  ' "$SETTINGS_FILE"
else
  echo "-- Settings: no settings file at $SETTINGS_FILE (or jq unavailable) --"
fi

# Effective routing: one line per registry role, resolved from this process's
# active framework the way a session request or a dispatch would resolve it
# (env → repo → ceremony overlay → roles → fallback role → default), with a
# `codex/<model>` value shown as the target framework it selects. This is the
# surface a seat reads before dispatching; the flattened settings above are the
# inputs, this is the answer. Harness-relative, so excluded from the digest
# payload unless asked for (see header).
if [[ "$WITH_ROUTING" == true ]]; then
echo ""
ACTIVE_FW="$(resolve_active_framework 2>/dev/null || true)"
echo "-- Effective routing (role -> route/options/source) --"
ROLES_FILE="$SCRIPT_DIR/../adapters/roles.json"
if [[ -f "$ROLES_FILE" ]] && command -v jq &>/dev/null; then
  while IFS= read -r role; do
    if route="$(resolve_route_for_role "$role" 2>/dev/null)" && [[ -n "$route" ]]; then
      printf -- '- %s -> %s\n' "$role" "$(printf '%s' "$route" | jq -c '{framework,model,options,routing_source}')"
    else
      printf -- '- %s -> (unbound)\n' "$role"
    fi
  done < <(jq -r '.roles[].id' "$ROLES_FILE")
  for ceremony in $(jq -r '.ceremonies[].id' "$SCRIPT_DIR/../adapters/ceremonies.json" 2>/dev/null); do
    while IFS= read -r role; do
      [[ -n "$role" ]] || continue
      if route="$(resolve_route_for_role "$role" "$ceremony" 2>/dev/null)" && [[ -n "$route" ]]; then
        printf -- '- %s@%s -> %s\n' "$role" "$ceremony" "$(printf '%s' "$route" | jq -c '{framework,model,options,routing_source}')"
      fi
    done < <(jq -r --arg c "$ceremony" '.routes.ceremony_overlays[$c] // {} | keys[]' "$SETTINGS_FILE" 2>/dev/null)
  done
  echo "-- Native model maps --"
  jq -c '.harnesses | with_entries(.value = .value.native_models)' "$SETTINGS_FILE"
else
  echo "(routing not renderable: adapters/roles.json unavailable)"
fi
fi

echo ""
echo "-- Preferences in force, by activity (titles; full text: lore search --preferences --activity <name>) --"

KNOWLEDGE_DIR="$(resolve_knowledge_dir 2>/dev/null || true)"
PREF_DIR="$KNOWLEDGE_DIR/preferences"
if [[ -n "$KNOWLEDGE_DIR" && -d "$PREF_DIR" ]]; then
  # The dispatch-guidance digest hashes this output and is re-rendered at
  # admission, so the order must depend on nothing but the entries: groups by
  # name, entries by path, both as pk_activities.index returns them.
  if ! grouped="$(python3 - "$SCRIPT_DIR" "$KNOWLEDGE_DIR" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from pk_activities import index  # noqa: E402

for name, group in index(sys.argv[2]).items():
    if not group:
        continue
    print(f"{name} ({len(group)}):")
    for entry in group:
        print(f"- {entry['title']}")
PY
)"; then
    echo "(preferences not renderable: could not read $PREF_DIR)"
  elif [[ -n "$grouped" ]]; then
    printf '%s\n' "$grouped"
  else
    echo "(none)"
  fi
else
  echo "(no preferences directory in the knowledge store)"
fi

echo ""
echo "=== End standing defaults ==="
