#!/usr/bin/env bash
# test_title_derivation.sh — coverage for the shared title-derivation helper
# and the H1 regenerate-or-flag step in apply-correction.sh mutation mode.
#
# Capabilities proven here:
#   1. derive_entry_title() (lib.sh) reproduces the historical
#      capture.sh::generate_title output byte-for-byte, and capture-created
#      entries carry the helper-derived H1 (the delegation is real).
#   2. Regenerate: an H1 derived from the superseded claim is replaced with a
#      title derived from the replacement, and the corrections[] item records
#      previous_title/new_title.
#   3. Flag: a hand-authored H1 over a replaced lead paragraph is left intact;
#      META gains title_stale: <date>; a second correction does not duplicate
#      the flag.
#   4. No-op: a replacement outside the lead paragraph leaves the H1 alone and
#      adds no title_stale flag.
#   5. --dry-run prints the planned H1 action and writes nothing.
#   6. L3 escalation ordering: the archived prior version keeps the falsified
#      title while the live entry gets the regenerated one.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
APPLY="$SCRIPTS_DIR/apply-correction.sh"
source "$SCRIPTS_DIR/lib.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
export LORE_KNOWLEDGE_DIR="$KDIR"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected: $expected"; echo "    Actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected to contain: $needle"; echo "    Got: $(printf '%s' "$haystack" | head -3)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected NOT to contain: $needle"; FAIL=$((FAIL + 1))
  fi
}

# Fresh KDIR with a contradicted settlement run so --allow-settlement-verdict
# authorizes mutation mode without a scorecard fixture.
setup_kdir() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/conventions" "$KDIR/_settlement/runs"
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"
  cat > "$KDIR/_settlement/runs/run-title.json" <<'EOF'
{"run_id":"run-title","kind":"commons","verdict":{"verdict":"contradicted","evidence":"x","correction":"y"}}
EOF
}

apply_mutation() {
  local entry="$1" superseded="$2" replacement="$3"; shift 3
  LORE_KNOWLEDGE_DIR="$KDIR" bash "$APPLY" \
    --entry "$entry" --verdict-id run-title --verdict-source correctness-gate \
    --evidence "scripts/fixture.py:1 — contradicting behavior observed" \
    --superseded-text "$superseded" --replacement-text "$replacement" \
    --allow-settlement-verdict --date 2026-07-02 "$@"
}

echo "=== Title Derivation Tests ==="

# =============================================
# Test 1: derive_entry_title output and capture.sh delegation
# =============================================
echo ""
echo "Test 1: derive_entry_title matches historical generate_title semantics"
assert_eq "first 8 words, title-cased" \
  "$(derive_entry_title "the token bucket refills at a constant rate regardless of load")" \
  "The Token Bucket Refills At A Constant Rate"
assert_eq "short input is title-cased in full" \
  "$(derive_entry_title "workers drain queues")" \
  "Workers Drain Queues"
assert_eq "punctuation is preserved, not stripped" \
  "$(derive_entry_title "refills proportionally to observed headroom, throttling under sustained load.")" \
  "Refills Proportionally To Observed Headroom, Throttling Under Sustained"

echo ""
echo "Test 1b: capture.sh entries carry the helper-derived H1"
setup_kdir
CAPTURE_INSIGHT="settlement leases expire after ninety seconds of executor silence"
LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS_DIR/capture.sh" \
  --insight "$CAPTURE_INSIGHT" --scale implementation --category conventions >/dev/null 2>&1 || true
CAPTURED_FILE=$(find "$KDIR/conventions" -name '*.md' | head -1)
assert_eq "capture wrote an entry" "$([[ -n "$CAPTURED_FILE" ]] && echo yes || echo no)" "yes"
assert_eq "captured H1 equals derive_entry_title of the insight" \
  "$(head -1 "$CAPTURED_FILE")" "# $(derive_entry_title "$CAPTURE_INSIGHT")"

# =============================================
# Test 2: regenerate — derived H1 is rebuilt from the replacement
# =============================================
echo ""
echo "Test 2: derivation-matched H1 is regenerated from replacement_text"
setup_kdir
ENTRY="$KDIR/conventions/derived-title.md"
SUPERSEDED="The scheduler polls the queue every five seconds and skips empty batches."
REPLACEMENT="The scheduler subscribes to queue events and wakes only on demand."
cat > "$ENTRY" <<'EOF'
# The Scheduler Polls The Queue Every Five Seconds

The scheduler polls the queue every five seconds and skips empty batches.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/sched.py -->
EOF
OUT=$(apply_mutation "$ENTRY" "$SUPERSEDED" "$REPLACEMENT")
assert_eq "H1 regenerated to the replacement-derived title" \
  "$(head -1 "$ENTRY")" "# The Scheduler Subscribes To Queue Events And Wakes"
assert_contains "corrections item records previous_title" "$(cat "$ENTRY")" \
  '"previous_title": "The Scheduler Polls The Queue Every Five Seconds"'
assert_contains "corrections item records new_title" "$(cat "$ENTRY")" \
  '"new_title": "The Scheduler Subscribes To Queue Events And Wakes"'
assert_not_contains "regenerated entry is not flagged title_stale" "$(cat "$ENTRY")" "title_stale:"
assert_contains "stdout reports the title regeneration" "$OUT" "[title] regenerated:"

# =============================================
# Test 3: flag — hand-authored H1 over a replaced lead paragraph
# =============================================
echo ""
echo "Test 3: hand-authored H1 is flagged title_stale, never rewritten"
setup_kdir
ENTRY="$KDIR/conventions/hand-title.md"
cat > "$ENTRY" <<'EOF'
# Scheduler Design Notes

The scheduler polls the queue every five seconds and skips empty batches.

Workers are stateless between polls.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/sched.py -->
EOF
FLAG_ERR=$(apply_mutation "$ENTRY" "$SUPERSEDED" "$REPLACEMENT" 2>&1 >/dev/null)
assert_eq "hand-authored H1 unchanged" "$(head -1 "$ENTRY")" "# Scheduler Design Notes"
assert_contains "META gains title_stale with the correction date" "$(cat "$ENTRY")" "title_stale: 2026-07-02"
assert_contains "stderr notice explains the flag" "$FLAG_ERR" "flagged title_stale"
assert_not_contains "no previous_title recorded when flagging" "$(cat "$ENTRY")" '"previous_title"'

# A second correction on the already-flagged entry must not duplicate the flag.
apply_mutation "$ENTRY" "$REPLACEMENT" "The scheduler uses a hybrid poll-plus-subscribe loop." >/dev/null 2>&1
FLAG_COUNT=$(grep -o 'title_stale:' "$ENTRY" | wc -l | tr -d ' ')
assert_eq "second correction does not duplicate title_stale" "$FLAG_COUNT" "1"

# =============================================
# Test 4: no-op — replacement outside the lead paragraph
# =============================================
echo ""
echo "Test 4: replacement outside the lead paragraph leaves the H1 alone"
setup_kdir
ENTRY="$KDIR/conventions/no-op-title.md"
cat > "$ENTRY" <<'EOF'
# Scheduler Design Notes

The lead paragraph is untouched by this correction.

Workers are stateless between polls.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/sched.py -->
EOF
apply_mutation "$ENTRY" "Workers are stateless between polls." "Workers keep a warm cache between polls." >/dev/null
assert_eq "H1 unchanged" "$(head -1 "$ENTRY")" "# Scheduler Design Notes"
assert_not_contains "no title_stale flag for a non-lead replacement" "$(cat "$ENTRY")" "title_stale:"

# =============================================
# Test 5: --dry-run prints the planned H1 action and writes nothing
# =============================================
echo ""
echo "Test 5: dry-run prints the H1 action without writing"
setup_kdir
ENTRY="$KDIR/conventions/dry-run-title.md"
cat > "$ENTRY" <<'EOF'
# The Scheduler Polls The Queue Every Five Seconds

The scheduler polls the queue every five seconds and skips empty batches.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/sched.py -->
EOF
BEFORE=$(cat "$ENTRY")
DRY_OUT=$(apply_mutation "$ENTRY" "$SUPERSEDED" "$REPLACEMENT" --dry-run)
assert_contains "dry-run announces regenerate" "$DRY_OUT" "H1 action: regenerate"
assert_contains "dry-run shows the planned new title" "$DRY_OUT" "The Scheduler Subscribes To Queue Events And Wakes"
assert_eq "dry-run wrote nothing" "$(cat "$ENTRY")" "$BEFORE"

cat > "$ENTRY" <<'EOF'
# Scheduler Design Notes

The scheduler polls the queue every five seconds and skips empty batches.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/sched.py -->
EOF
BEFORE=$(cat "$ENTRY")
DRY_OUT=$(apply_mutation "$ENTRY" "$SUPERSEDED" "$REPLACEMENT" --dry-run)
assert_contains "dry-run announces flag for hand-authored title" "$DRY_OUT" "H1 action: flag title_stale: 2026-07-02"
assert_eq "flag dry-run wrote nothing" "$(cat "$ENTRY")" "$BEFORE"

cat > "$ENTRY" <<'EOF'
# Scheduler Design Notes

Lead paragraph stays intact.

Workers are stateless between polls.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/sched.py -->
EOF
DRY_OUT=$(apply_mutation "$ENTRY" "Workers are stateless between polls." "Workers keep a warm cache." --dry-run)
assert_contains "dry-run announces none for non-lead replacement" "$DRY_OUT" "H1 action: none"

# =============================================
# Test 6: L3 escalation archives the prior version BEFORE the H1 rewrite
# =============================================
echo ""
echo "Test 6: L3 archive keeps the falsified title; live entry gets the new one"
setup_kdir
ENTRY="$KDIR/conventions/escalated-title.md"
cat > "$ENTRY" <<'EOF'
# The Scheduler Polls The Queue Every Five Seconds

The scheduler polls the queue every five seconds and skips empty batches.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/sched.py | scale: architecture -->
EOF
apply_mutation "$ENTRY" "$SUPERSEDED" "$REPLACEMENT" --check-escalation >/dev/null 2>&1
ARCHIVED=$(find "$KDIR/conventions" -name 'escalated-title-superseded-*.md' | head -1)
assert_eq "L3 archive file created" "$([[ -n "$ARCHIVED" ]] && echo yes || echo no)" "yes"
assert_eq "archived copy keeps the falsified title" \
  "$(head -1 "$ARCHIVED")" "# The Scheduler Polls The Queue Every Five Seconds"
assert_eq "live entry carries the regenerated title" \
  "$(head -1 "$ENTRY")" "# The Scheduler Subscribes To Queue Events And Wakes"
assert_contains "live entry records the supersedes edge" "$(cat "$ENTRY")" "supersedes:"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]]
