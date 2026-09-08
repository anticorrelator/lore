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
  "standing_decisions": {
    "modal_answers": {
      "codex-additional-safety-checks-keep-waiting-v1": {
        "enabled": true,
        "framework": "codex",
        "signature": {
          "kind": "numbered-modal-v1",
          "title": "Additional safety checks",
          "options": [
            {"number": 1, "label": "Retry with a faster model"},
            {"number": 2, "label": "Keep waiting"},
            {"number": 3, "label": "Learn more"}
          ]
        },
        "answer": {"option": 2, "expect": "Additional safety checks"},
        "registered_by": "user",
        "registered_at": "2026-07-21T00:00:00Z",
        "rationale": "Keep the current protocol session on its selected model."
      }
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
grep -q "standing_decisions.modal_answers.codex-additional-safety-checks-keep-waiting-v1.signature.options.1.label: Keep waiting" <<<"$out" \
  || fail "standing modal option not flattened"
grep -q "standing_decisions.modal_answers.codex-additional-safety-checks-keep-waiting-v1.registered_by: user" <<<"$out" \
  || fail "standing modal decision metadata not flattened"
grep -q "Preference directives in force" <<<"$out" || fail "directives section missing"
grep -q "End standing defaults" <<<"$out" || fail "missing footer"

# --- Case 2: absent settings file renders explicit absence, exit 0 ------------
out2="$(LORE_DATA_DIR="$TMP/empty" bash "$SCRIPT")" || fail "exit nonzero with settings absent"
grep -q "no settings file at" <<<"$out2" || fail "absence not rendered explicitly"
grep -q "End standing defaults" <<<"$out2" || fail "footer missing on absence path"

# --- Case 3: routing is opt-in, and the default payload is harness-independent --
# The dispatch-guidance digest hashes this script's default output; a worker's
# guidance is validated by whichever host claims it, so nothing in the default
# payload may depend on the requesting harness.
grep -q "Effective routing" <<<"$out" && fail "routing section rendered without --with-routing"
strip_header() { sed '1s/(rendered [^)]*)/(rendered <invocation>)/'; }
out_codex="$(LORE_DATA_DIR="$TMP" LORE_FRAMEWORK=codex bash "$SCRIPT" | strip_header)" || fail "codex render failed"
out_cc="$(LORE_DATA_DIR="$TMP" LORE_FRAMEWORK=claude-code bash "$SCRIPT" | strip_header)" || fail "claude-code render failed"
[[ "$out_codex" == "$out_cc" ]] || fail "default payload differs by requesting harness (digest would be host-dependent)"

# --- Case 4: --with-routing renders the effective route per role for this harness
out4="$(LORE_DATA_DIR="$TMP" LORE_FRAMEWORK=claude-code bash "$SCRIPT" --with-routing)" || fail "exit nonzero with --with-routing"
grep -q "Effective routing on claude-code" <<<"$out4" || fail "routing header missing with --with-routing"
grep -q -- "- lead -> claude-code/opus" <<<"$out4" || fail "lead route not rendered"
grep -q "End standing defaults" <<<"$out4" || fail "footer missing with --with-routing"

# --- Case 5: unknown arguments are refused ---------------------------------------
LORE_DATA_DIR="$TMP" bash "$SCRIPT" --bogus >/dev/null 2>&1 && fail "unknown argument accepted"

echo "render standing defaults: PASS"
