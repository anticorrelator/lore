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
  "version": 2,
  "tui_launch_framework": "claude-code",
  "routes": {"default":"claude-code/opus","lead":"codex/gpt-6-astra","worker":{"framework":"codex","model":"gpt-5.6-sol","effort":"high","service_tier":"fast"}},
  "harnesses": {
    "claude-code": {
      "args": [], "native_models": {"default":"opus"},
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
grep -q "routes.lead: codex/gpt-6-astra" <<<"$out" || fail "role route not flattened"
grep -q "routes.worker.service_tier: fast" <<<"$out" || fail "route option missing"
grep -q "retro_sampling.routine_rate: 0.5" <<<"$out" || fail "sampling rate missing"
grep -q "harnesses.claude-code.ceremonies.spec-design.0: codex-design-review" <<<"$out" \
  || fail "ceremony registration not flattened"
grep -q "standing_decisions.modal_answers.codex-additional-safety-checks-keep-waiting-v1.signature.options.1.label: Keep waiting" <<<"$out" \
  || fail "standing modal option not flattened"
grep -q "standing_decisions.modal_answers.codex-additional-safety-checks-keep-waiting-v1.registered_by: user" <<<"$out" \
  || fail "standing modal decision metadata not flattened"
grep -q "Preference directives in force" <<<"$out" || fail "directives section missing"
grep -q "End standing defaults" <<<"$out" || fail "missing footer"

routing="$(LORE_DATA_DIR="$TMP" env -u LORE_FRAMEWORK bash "$SCRIPT" --with-routing)" || fail "routing render failed without an active framework"
grep -q 'worker -> {"framework":"codex","model":"gpt-5.6-sol","options":{"effort":"high","service_tier":"fast"}' <<<"$routing" || fail "effective route/options missing"
grep -q -- '-- Native model maps --' <<<"$routing" || fail "native maps missing"

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

# --- Case 4: --with-routing renders global routes plus native maps
out4="$(LORE_DATA_DIR="$TMP" LORE_FRAMEWORK=claude-code bash "$SCRIPT" --with-routing)" || fail "exit nonzero with --with-routing"
grep -q "Effective routing (role -> route/options/source)" <<<"$out4" || fail "routing header missing with --with-routing"
grep -q -- '- lead -> {"framework":"codex","model":"gpt-6-astra"' <<<"$out4" || fail "lead route not rendered"
grep -q "End standing defaults" <<<"$out4" || fail "footer missing with --with-routing"

# --- Case 5: unknown arguments are refused ---------------------------------------
LORE_DATA_DIR="$TMP" bash "$SCRIPT" --bogus >/dev/null 2>&1 && fail "unknown argument accepted"

echo "render standing defaults: PASS"
