#!/usr/bin/env bash
# test_load_threads_prefs.sh — load-threads.sh renders thread entries only.
#
# A thread's _meta.json may still carry accumulated_preferences (older stores,
# or a thread written before its list was migrated into preferences/). The
# loader prints no **Preferences:** line for it and spends its whole budget on
# entries: the fixture's three newest entries need more than the 2,600
# characters entries used to get, and the fourth would pass 3,000.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER="$REPO_DIR/scripts/load-threads.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
MAIN_REPO="$TEST_DIR/repo"
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
unset LORE_AGENT_DISABLED

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1 (missing: $3)"; fi
}

assert_not_contains() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1 (found: $3)"; else pass "$1"; fi
}

mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init

# write_thread <slug> <tier> <prefs: short|long> <entry count> <entry chars>
write_thread() {
  python3 - "$KNOWLEDGE_DIR/_threads" "$@" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

root, slug, tier, prefs, count, chars = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
thread = Path(root) / slug
thread.mkdir(parents=True, exist_ok=True)
if prefs == "short":
    notes = [f"PREF-MARKER-{slug} short note one", f"PREF-MARKER-{slug} short note two"]
else:
    notes = [f"PREF-MARKER-{slug} long note {i} " + "x" * 60 for i in range(12)]
meta = {
    "topic": slug,
    "tier": tier,
    "created": "2026-01-01T00:00:00Z",
    "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "sessions": count,
    "accumulated_preferences": [
        {"preference": n, "first_seen": "2026-01-01", "last_reinforced": "2026-01-01", "source_entries": []}
        for n in notes
    ],
}
(thread / "_meta.json").write_text(json.dumps(meta, indent=2) + "\n")
for day in range(1, count + 1):
    head = f"**Summary:** ENTRY-{slug}-{day} summary.\n\n"
    body = f"ENTRY-{slug}-{day} " + "y" * chars
    (thread / f"2026-01-{day:02d}.md").write_text((head + body)[:chars] + "\n")
index = Path(root) / "_index.json"
data = json.loads(index.read_text()) if index.exists() else {"threads": []}
data["threads"].append({"slug": slug, "tier": tier})
index.write_text(json.dumps(data, indent=2) + "\n")
PY
}

run_loader() {
  (cd "$MAIN_REPO" && bash "$LOADER" 2>&1)
}

budget_used() {
  printf '%s\n' "$1" | sed -n 's/^\[threads\] Budget: \([0-9]*\)\/\([0-9]*\) chars.*/\1 \2/p'
}

echo "Test 1: a pinned thread with a short preferences list (it used to fit the 400-char reserve)"
rm -rf "$KNOWLEDGE_DIR"; mkdir -p "$KNOWLEDGE_DIR/_threads"
write_thread big pinned short 4 880
OUT=$(run_loader)
assert_contains "loader ran" "$OUT" "=== Conversational Threads ==="
if printf '%s\n' "$OUT" | grep -q '^\*\*Preferences:\*\*'; then
  fail "no **Preferences:** line"
else
  pass "no **Preferences:** line"
fi
assert_not_contains "no preference text from _meta.json" "$OUT" "PREF-MARKER-big"
assert_contains "three newest entries load in full" "$OUT" "(pinned, 3 full, 0 summary, 1 omitted)"
assert_contains "newest entry rendered" "$OUT" "ENTRY-big-4"
assert_contains "third-newest entry rendered" "$OUT" "ENTRY-big-2"
assert_not_contains "oldest entry would pass 3,000 and is left out" "$OUT" "ENTRY-big-1 "
read -r USED TOTAL <<< "$(budget_used "$OUT")"
if [[ "${TOTAL:-}" == "3000" ]]; then pass "budget is 3000"; else fail "budget is 3000 (got '${TOTAL:-}')"; fi
if [[ -n "${USED:-}" && $USED -gt 2600 && $USED -le 3000 ]]; then
  pass "entries use more than the old 2,600 and stay within 3,000 (used $USED)"
else
  fail "entries use more than the old 2,600 and stay within 3,000 (used '${USED:-}')"
fi

echo ""
echo "Test 2: an active thread with a long preferences list"
rm -rf "$KNOWLEDGE_DIR"; mkdir -p "$KNOWLEDGE_DIR/_threads"
write_thread busy active long 2 400
OUT=$(run_loader)
if printf '%s\n' "$OUT" | grep -q '^\*\*Preferences:\*\*'; then
  fail "no **Preferences:** line"
else
  pass "no **Preferences:** line"
fi
assert_not_contains "no preference text from _meta.json" "$OUT" "PREF-MARKER-busy"
assert_contains "both entries load" "$OUT" "(active, 2 full, 0 summary, 0 omitted)"

echo ""
echo "Test 3: the loader carries no preferences reserve"
for name in PREFS_BUDGET format_thread_preferences ENTRY_BUDGET accumulated_preferences '**Preferences:**'; do
  if grep -qF -- "$name" "$LOADER"; then
    fail "load-threads.sh no longer mentions $name"
  else
    pass "load-threads.sh no longer mentions $name"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
