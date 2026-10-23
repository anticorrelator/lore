#!/usr/bin/env bash
# test_render_standing_defaults.sh — contract test for render-standing-defaults.sh
# (routed as `lore defaults`). Exercises the real script against an isolated
# LORE_DATA_DIR: settings values must render as flattened key-paths, absence must
# render explicitly (never silently), and the exit code must be 0 in both cases.
# Preferences render as titles grouped by activity, deterministically, and the
# grouped payload passes the dispatch-guidance digest check.

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
      "args": [], "native_models": {"default":"opus"}
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
grep -q "standing_decisions.modal_answers.codex-additional-safety-checks-keep-waiting-v1.signature.options.1.label: Keep waiting" <<<"$out" \
  || fail "standing modal option not flattened"
grep -q "standing_decisions.modal_answers.codex-additional-safety-checks-keep-waiting-v1.registered_by: user" <<<"$out" \
  || fail "standing modal decision metadata not flattened"
grep -q "Preferences in force, by activity" <<<"$out" || fail "preferences section missing"
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

# --- Case 5: live preferences render grouped by activity -----------------------
# A retired or superseded preference keeps its file for history but is not in
# force; listing it presents it as binding to every dispatch that reads this.
# Groups are sorted by name, an entry filed under two activities is under both,
# and a live entry filed without an activity is under `untagged`, never dropped.
KSTORE="$TMP/store"
mkdir -p "$KSTORE/preferences/nested"
printf '# Price Arcs First\nBody.\n<!-- learned: 2026-09-01 | activity: coordination | status: current -->\n' > "$KSTORE/preferences/b-current.md"
printf '# Corrected Routing Rule\nBody.\n<!-- learned: 2026-09-01 | activity: model-routing, coordination | status: corrected -->\n' > "$KSTORE/preferences/a-corrected.md"
printf '# Unstamped Scoping Rule\nBody.\n<!-- learned: 2026-09-01 | activity: work-scoping -->\n' > "$KSTORE/preferences/nested/unstamped.md"
printf '# Filed Before Activities\nBody.\n<!-- learned: 2026-09-01 | status: current -->\n' > "$KSTORE/preferences/untagged.md"
printf '# No Footer At All\nBody.\n' > "$KSTORE/preferences/no-footer.md"
printf '# Retired Routing Directive\nBody.\n**Retired 2026-09-25.** Stale.\n<!-- learned: 2026-07-06 | activity: model-routing | status: retired -->\n' > "$KSTORE/preferences/retired.md"
printf '# Superseded Directive\nBody.\n<!-- learned: 2026-07-06 | activity: coordination | status: superseded -->\n' > "$KSTORE/preferences/superseded.md"
printf '# Store Readme\n' > "$KSTORE/preferences/README.md"
out5="$(LORE_DATA_DIR="$TMP" LORE_KNOWLEDGE_DIR="$KSTORE" bash "$SCRIPT")" || fail "exit nonzero with a preferences directory"
section5="$(sed -n '/^-- Preferences in force, by activity/,/^=== End standing defaults ===$/p' <<<"$out5")"
expected5="-- Preferences in force, by activity (titles; full text: lore search --preferences --activity <name>) --
coordination (2):
- Corrected Routing Rule
- Price Arcs First
model-routing (1):
- Corrected Routing Rule
untagged (2):
- No Footer At All
- Filed Before Activities
work-scoping (1):
- Unstamped Scoping Rule

=== End standing defaults ==="
[[ "$section5" == "$expected5" ]] || fail "grouped preferences section differs:
--- got ---
$section5
--- expected ---
$expected5"
for title in "Retired Routing Directive" "Superseded Directive" "Store Readme"; do
  grep -q -- "$title" <<<"$section5" && fail "'$title' listed as a preference in force"
done
grep -q "Preference directives in force" <<<"$out5" && fail "the flat directive list is still rendered"

# The dispatch-guidance digest is re-rendered at admission, so two renders of
# the same store must match byte for byte apart from the timestamp header.
again5="$(LORE_DATA_DIR="$TMP" LORE_KNOWLEDGE_DIR="$KSTORE" bash "$SCRIPT")"
[[ "$(strip_header <<<"$out5")" == "$(strip_header <<<"$again5")" ]] || fail "two renders of one store differ"

# A store whose preferences/ holds no live entry says so.
mkdir -p "$TMP/empty-prefs/preferences"
cp "$KSTORE/preferences/retired.md" "$TMP/empty-prefs/preferences/"
out5b="$(LORE_DATA_DIR="$TMP" LORE_KNOWLEDGE_DIR="$TMP/empty-prefs" bash "$SCRIPT")" || fail "exit nonzero with only retired preferences"
grep -A1 -- "^-- Preferences in force" <<<"$out5b" | grep -qx "(none)" || fail "no-live-entry store not rendered as (none)"
# A store with no preferences/ says that instead.
mkdir -p "$TMP/no-prefs"
out5c="$(LORE_DATA_DIR="$TMP" LORE_KNOWLEDGE_DIR="$TMP/no-prefs" bash "$SCRIPT")" || fail "exit nonzero without preferences/"
grep -q "(no preferences directory in the knowledge store)" <<<"$out5c" || fail "absent preferences/ not rendered explicitly"

# --- Case 5b: the grouped rendering round-trips through the guidance gate --------
GUIDANCE="$TMP/guidance.md"
LORE_DATA_DIR="$TMP" LORE_KNOWLEDGE_DIR="$KSTORE" bash "$REPO_DIR/scripts/render-dispatch-guidance.sh" > "$GUIDANCE" \
  || fail "dispatch guidance did not render over grouped preferences"
grep -qx "coordination (2):" "$GUIDANCE" || fail "guidance does not carry the grouped preferences"
LORE_DATA_DIR="$TMP" LORE_KNOWLEDGE_DIR="$KSTORE" bash "$REPO_DIR/scripts/validate-dispatch-guidance.sh" --prompt-file "$GUIDANCE" \
  || fail "freshly rendered guidance over grouped preferences failed validation"

# --- Case 6: unknown arguments are refused ---------------------------------------
LORE_DATA_DIR="$TMP" bash "$SCRIPT" --bogus >/dev/null 2>&1 && fail "unknown argument accepted"

# --- Case 7: --help prints the whole header ---------------------------------------
help7="$(bash "$SCRIPT" --help)" || fail "--help exited nonzero"
grep -q "absence is rendered explicitly, never silently" <<<"$help7" || fail "--help cut off before the header's last line"
grep -q "Preferences in force\|preferences in force" <<<"$help7" || fail "--help does not describe the preferences section"

echo "render standing defaults: PASS"
