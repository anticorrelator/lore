#!/usr/bin/env bash
# render-standing-defaults.sh — Render the standing defaults in force as a
# compact, agent-readable block. Routed as `lore defaults`.
#
# Purpose: settings.json values are consumed by scripts but were never rendered
# into any agent-visible surface, so agents could not learn the project's agent
# defaults (role→model maps, ceremony registrations, sampling rates) without
# happening to run a script that used them. This verb is the universal delivery
# mechanism — invocation-fresh on every harness because it needs only bash.
# Skills call it at step 0 of their orient sections; coordinator briefs open
# worker dispatches with the same instruction.
#
# Output contract (consumed as prompt content, keep it boring):
#   - a header naming the render time and settings source
#   - the effective settings document flattened to `key.path: value` lines
#   - the preference directives currently in force, cited by entry title only
#     (full text is retrieved via `lore search` when a directive binds a step)
#
# Read-only. Exit 0 even when the settings file or preferences directory is
# absent — absence is rendered explicitly, never silently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SETTINGS_FILE="${LORE_DATA_DIR:-$HOME/.lore}/config/settings.json"

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

echo ""
echo "-- Preference directives in force (titles; retrieve full text via lore search) --"

KNOWLEDGE_DIR="$(resolve_knowledge_dir 2>/dev/null || true)"
PREF_DIR="$KNOWLEDGE_DIR/preferences"
if [[ -n "$KNOWLEDGE_DIR" && -d "$PREF_DIR" ]]; then
  found=0
  while IFS= read -r f; do
    found=1
    title="$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# //')"
    [[ -n "$title" ]] || title="$(basename "$f" .md)"
    echo "- $title"
  done < <(find "$PREF_DIR" -name '*.md' -type f | sort)
  [[ $found -eq 1 ]] || echo "(none)"
else
  echo "(no preferences directory in the knowledge store)"
fi

echo ""
echo "=== End standing defaults ==="
