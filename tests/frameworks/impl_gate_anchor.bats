#!/usr/bin/env bats
# impl_gate_anchor.bats — Coverage for `lore impl gate-anchor` (impl-gate-anchor.sh)
#
# Asserts:
#   - cmd_impl router surface (usage, unknown verb, no args)
#   - --verdict is required and enum-validated
#   - per-verdict field-presence contract (--fit / --gap / --scope-delta)
#   - six labeled log lines in fixed order, JSON-string field encoding
#   - exactly one execution-log entry per invocation, source: impl-verb
#   - misaligned-override dual write to notes.md
#   - legacy-skip <-> intent_anchor consistency
#   - route + remediation per verdict; tri-state exit passthrough
#   - --json output shape
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
GATE_SH="$REPO_DIR/scripts/impl-gate-anchor.sh"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -f "$GATE_SH" ]  || skip "impl-gate-anchor.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  mkdir -p "$WORK_DIR/anchored-item" "$WORK_DIR/legacy-item"

  python3 - "$WORK_DIR/anchored-item/_meta.json" <<'PYEOF'
import json, sys
meta = {
    "title": "Anchored Item",
    "intent_anchor": "Ship the gate verb.\nSecond anchor line.",
}
with open(sys.argv[1], "w") as f:
    json.dump(meta, f)
PYEOF
  printf '{"title": "Legacy Item"}\n' > "$WORK_DIR/legacy-item/_meta.json"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  unset LORE_KNOWLEDGE_DIR
}

log_file() { echo "$WORK_DIR/anchored-item/execution-log.md"; }

entry_count() {
  grep -c '^## ' "$(log_file)"
}

# --- Router surface -----------------------------------------------------

@test "lore impl with no args prints usage and exits non-zero" {
  run bash "$LORE_CLI" impl
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "gate-anchor"
}

@test "lore impl --help lists all eight verbs" {
  run bash "$LORE_CLI" impl --help
  [ "$status" -eq 0 ]
  for verb in gate-anchor start close open next-batch check-report consult-log promote-batch; do
    echo "$output" | grep -q "$verb"
  done
}

@test "unknown impl verb exits non-zero with error" {
  run bash "$LORE_CLI" impl no-such-verb
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown impl verb"
}

@test "top-level lore usage mentions the impl subgroup" {
  run bash "$LORE_CLI" --help
  echo "$output" | grep -q "impl"
}

# --- Verdict requirement and enum ----------------------------------------

@test "missing --verdict exits non-zero naming the flag" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--verdict is required"
}

@test "invalid verdict exits non-zero listing the enum" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict sideways
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "misaligned-respec"
}

# --- Per-verdict field-presence contract ----------------------------------

@test "aligned without --fit is rejected" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--fit"
}

@test "aligned with --gap is rejected" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "covers it" --gap "stray"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "does not take --gap"
}

@test "misaligned-respec without --gap is rejected" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict misaligned-respec
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--gap"
}

@test "misaligned-override without --scope-delta is rejected" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict misaligned-override --gap "plan misses X"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--scope-delta"
}

@test "legacy-skip with --fit is rejected" {
  run bash "$LORE_CLI" impl gate-anchor legacy-item --verdict legacy-skip --fit "n/a"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "does not take --fit"
}

# --- Aligned: log entry, encoding, route ----------------------------------

@test "aligned writes exactly one entry and prints route continue" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "plan covers the anchor"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Route: continue$"
  [ "$(entry_count)" -eq 1 ]
}

@test "aligned entry carries source impl-verb and six labeled lines in order" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "plan covers the anchor"
  [ "$status" -eq 0 ]
  grep -q "source: impl-verb" "$(log_file)"
  python3 - "$(log_file)" <<'PYEOF'
import sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
labels = [
    "Anchor-coverage gate: ",
    "Intent anchor: ",
    "Anchor fit statement: ",
    "Misalignment gap: ",
    "Override scope delta: ",
    "Remediation choice: ",
]
idx = [next(i for i, l in enumerate(lines) if l.startswith(p)) for p in labels]
assert idx == sorted(idx), f"labels out of order: {idx}"
PYEOF
}

@test "multi-line anchor is JSON-string encoded on a single log line" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "fits"
  [ "$status" -eq 0 ]
  anchor_line=$(grep "^Intent anchor: " "$(log_file)")
  echo "$anchor_line" | python3 -c '
import json, sys
raw = sys.stdin.read().removeprefix("Intent anchor: ").strip()
decoded = json.loads(raw)
assert decoded == "Ship the gate verb.\nSecond anchor line.", decoded
'
}

@test "aligned entry has fit JSON string, gap and delta None, remediation continue" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "plan covers it"
  [ "$status" -eq 0 ]
  grep -q '^Anchor fit statement: "plan covers it"' "$(log_file)"
  grep -q '^Misalignment gap: None$' "$(log_file)"
  grep -q '^Override scope delta: None$' "$(log_file)"
  grep -q '^Remediation choice: continue$' "$(log_file)"
}

@test "aligned stamps a Template-version header on the entry" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "fits"
  [ "$status" -eq 0 ]
  grep -qE '^Template-version: [0-9a-f]{12}$' "$(log_file)"
}

@test "--template-version override is used verbatim" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "fits" --template-version abcdef123456
  [ "$status" -eq 0 ]
  grep -q '^Template-version: abcdef123456$' "$(log_file)"
}

# --- Other verdicts ---------------------------------------------------------

@test "misaligned-respec routes to respec with run /spec remediation, no notes write" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict misaligned-respec --gap "plan misses the anchor's second clause"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Route: respec$"
  grep -q '^Remediation choice: run /spec anchored-item$' "$(log_file)"
  [ ! -f "$WORK_DIR/anchored-item/notes.md" ]
}

@test "misaligned-override dual-writes notes.md and routes continue" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict misaligned-override \
    --gap "plan misses X" --scope-delta "X is deferred to followup; Y in scope"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Route: continue$"
  grep -q '^Override scope delta: "X is deferred to followup; Y in scope"' "$(log_file)"
  notes="$WORK_DIR/anchored-item/notes.md"
  [ -f "$notes" ]
  grep -q '^\*\*Anchor-coverage override:\*\* X is deferred to followup; Y in scope$' "$notes"
  grep -qE '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$' "$notes"
}

@test "abort routes to abort with user-aborted remediation" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict abort --gap "anchor unservable"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Route: abort$"
  grep -q '^Remediation choice: none (user aborted)$' "$(log_file)"
}

@test "legacy-skip on item without anchor logs None fields and routes continue" {
  run bash "$LORE_CLI" impl gate-anchor legacy-item --verdict legacy-skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Route: continue$"
  log="$WORK_DIR/legacy-item/execution-log.md"
  grep -q '^Intent anchor: None$' "$log"
  grep -q '^Anchor fit statement: None$' "$log"
  grep -q '^Remediation choice: none (legacy skip)$' "$log"
}

# --- Anchor consistency ------------------------------------------------------

@test "legacy-skip on item with anchor is rejected" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict legacy-skip
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "requires an empty intent_anchor"
}

@test "non-legacy verdict on item without anchor suggests legacy-skip" {
  run bash "$LORE_CLI" impl gate-anchor legacy-item --verdict aligned --fit "fits"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "legacy-skip"
}

# --- Reference resolution: tri-state passthrough -----------------------------

@test "no-match reference exits 1" {
  run bash "$LORE_CLI" impl gate-anchor no-such-item-zzz --verdict aligned --fit "fits"
  [ "$status" -eq 1 ]
}

@test "ambiguous reference exits 2" {
  cat > "$WORK_DIR/_index.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {"slug": "anchored-item", "title": "Anchored Item", "tags": ["shared-tag"], "branches": []},
    {"slug": "legacy-item", "title": "Legacy Item", "tags": ["shared-tag"], "branches": []}
  ],
  "archived": []
}
EOF
  run bash "$LORE_CLI" impl gate-anchor shared-tag --verdict aligned --fit "fits"
  [ "$status" -eq 2 ]
}

@test "archived work item is rejected" {
  mkdir -p "$WORK_DIR/_archive/done-item"
  printf '{"title": "Done Item", "intent_anchor": "old"}\n' > "$WORK_DIR/_archive/done-item/_meta.json"
  run bash "$LORE_CLI" impl gate-anchor done-item --verdict aligned --fit "fits"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "archived"
}

# --- JSON output -------------------------------------------------------------

@test "--json on aligned returns route and slug" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --verdict aligned --fit "fits" --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["slug"] == "anchored-item"
assert d["verdict"] == "aligned"
assert d["route"] == "continue"
assert d["notes_dual_write"] is False
'
}

@test "--json on validation error returns error object with exit 1" {
  run bash "$LORE_CLI" impl gate-anchor anchored-item --json
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json, sys; d = json.loads(sys.stdin.read()); assert "error" in d'
}

# --- write-execution-log.sh enum extension -----------------------------------

@test "write-execution-log.sh accepts --source impl-verb directly" {
  echo "direct body" | bash "$REPO_DIR/scripts/write-execution-log.sh" --slug anchored-item --source impl-verb
  grep -q "source: impl-verb" "$(log_file)"
}

@test "write-execution-log.sh still rejects unknown sources, naming impl-verb in the enum" {
  run bash -c 'echo body | bash "'"$REPO_DIR"'/scripts/write-execution-log.sh" --slug anchored-item --source bogus'
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "impl-verb"
}
