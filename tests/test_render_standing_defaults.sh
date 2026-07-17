#!/usr/bin/env bash
# test_render_standing_defaults.sh — contract test for render-standing-defaults.sh
# (routed as `lore defaults`). Exercises the real script against an isolated
# LORE_DATA_DIR: settings values must render as flattened key-paths, absence must
# render explicitly (never silently), and the exit code must be 0 in both cases.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/render-standing-defaults.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "render-standing-defaults: FAIL — $1" >&2; exit 1; }

# --- Case 1: isolated settings file renders as flattened key.path lines -------
mkdir -p "$TMP/config"
cat > "$TMP/config/settings.json" <<'JSON'
{
  "version": 1,
  "harnesses": {
    "claude-code": {
      "roles": { "lead": "opus", "worker": "sonnet" },
      "ceremonies": { "spec-design": ["codex-design-review"] }
    }
  },
  "retro_sampling": { "routine_rate": 0.5 }
}
JSON

out="$(LORE_DATA_DIR="$TMP" bash "$SCRIPT")" || fail "exit nonzero with settings present"
grep -q "Standing defaults in force" <<<"$out" || fail "missing header"
grep -q "harnesses.claude-code.roles.lead: opus" <<<"$out" || fail "role default not flattened"
grep -q "harnesses.claude-code.roles.worker: sonnet" <<<"$out" || fail "second role missing"
grep -q "retro_sampling.routine_rate: 0.5" <<<"$out" || fail "sampling rate missing"
grep -q "harnesses.claude-code.ceremonies.spec-design.0: codex-design-review" <<<"$out" \
  || fail "ceremony registration not flattened"
grep -q "Preference directives in force" <<<"$out" || fail "directives section missing"
grep -q "End standing defaults" <<<"$out" || fail "missing footer"

# --- Case 2: absent settings file renders explicit absence, exit 0 ------------
out2="$(LORE_DATA_DIR="$TMP/empty" bash "$SCRIPT")" || fail "exit nonzero with settings absent"
grep -q "no settings file at" <<<"$out2" || fail "absence not rendered explicitly"
grep -q "End standing defaults" <<<"$out2" || fail "footer missing on absence path"

echo "render standing defaults: PASS"
