#!/usr/bin/env bash
# test_arc_migrate.sh — Acceptance for the arc migration.
#
# The two properties this suite exists for:
#   * a bare `arc migrate` writes nothing — proven by hashing every path in the
#     store before and after the run and asserting byte-identity, not by
#     reading the code and concluding it looks read-only;
#   * the status classifier is total — every combination of source seat, report
#     presence, originating-item status, forwarding-stub relationship, and
#     absorbed-pointer signature either lands on exactly one row or is refused
#     by name. There is no fallback row.
#
# The rest covers the transaction: a clean run, an identical re-run, a resumed
# interruption, a divergent destination, and a manifest that survives a change
# to the derivation rules.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$REPO_ROOT/scripts/arc-migrate.sh"
CLOSE="$REPO_ROOT/scripts/arc-close.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label" "missing '$needle'"; fi
}
assert_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$label"; else fail "$label" "no file at $path"; fi
}
assert_no_file() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then pass "$label"; else fail "$label" "$path exists"; fi
}

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# Every regular file under the store, content-hashed. Two snapshots that differ
# are the only proof that a run wrote something.
snapshot() {
  find "$1" -type f -exec shasum -a 256 {} \; | sed "s|$1||" | sort
}

meta_field() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError):
    print("<unreadable>"); sys.exit(0)
value = data.get(sys.argv[2], "<absent>")
print(json.dumps(value) if isinstance(value, (list, dict)) else value)
PYEOF
}

# The three fields the writer treats as immutable, in the shape the manifest
# records them.
record_identity() {
  python3 - "$1" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    meta = json.load(handle)
print(json.dumps({key: meta[key] for key in ("schema_version", "slug", "opened")}))
PYEOF
}

manifest_field() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for row in data["rows"]:
    if row["slug"] == sys.argv[2]:
        value = row.get(sys.argv[3], "<absent>")
        print(json.dumps(value) if isinstance(value, (list, dict)) else value)
        sys.exit(0)
print("<no row>")
PYEOF
}

manifest_exclusion() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for row in data.get("exclusions", []):
    if (row.get("source") or {}).get("path") == sys.argv[2]:
        value = row.get(sys.argv[3], "<absent>")
        print(json.dumps(value) if isinstance(value, (list, dict)) else value)
        sys.exit(0)
print("<no exclusion>")
PYEOF
}

# A store covering every reachable row of the status table at once.
new_store() {
  local kdir="$TEST_DIR/store.$RANDOM.$RANDOM"
  mkdir -p "$kdir/_work/_projects/alpha/_ledgers" "$kdir/_work/_projects/beta" \
           "$kdir/_work/live" "$kdir/_work/done" \
           "$kdir/_work/_archive/gone" "$kdir/_work/_archive/stub" \
           "$kdir/_work/_archive/eaten"

  # Row 6 — project home carrying a report.
  printf '# Coordination Ledger — Alpha Home\n\n**Intent anchor:** alpha intent\n\n## Brief\ncites [[work:live]]\n' \
    > "$kdir/_work/_projects/alpha/coordination.md"
  printf 'alpha report\n' > "$kdir/_work/_projects/alpha/report.md"

  # Row 2 — a filed ledger paired with its report by filename stem.
  printf '# Coordination Ledger — Beta Filed\n\n**Intent anchor:** beta intent\n' \
    > "$kdir/_work/_projects/alpha/_ledgers/alpha-2026-01-02-beta-arc.md"
  printf 'beta report\n' > "$kdir/_work/_projects/alpha/_ledgers/alpha-2026-01-02-beta-report.md"

  # Row 2, named from its stem: no heading, a stem that ends in -report after one
  # -arc strip, and a second stem carrying -arc- mid-string.
  printf 'no heading here\n' \
    > "$kdir/_work/_projects/alpha/_ledgers/alpha-2026-01-03-gamma-arc-close-report-arc.md"
  printf 'no heading here either\n' \
    > "$kdir/_work/_projects/alpha/_ledgers/alpha-2026-01-04-delta-arc-mid-string.md"

  # Row 7 — project home with no report.
  printf '# Coordination Ledger — Beta Home\n\n**Intent anchor:** beta home intent\n' \
    > "$kdir/_work/_projects/beta/coordination.md"

  # Row 5 — active item, no report.
  printf '# Coordination Ledger — Live Work\n\n**Intent anchor:** live intent\n' \
    > "$kdir/_work/live/coordination.md"
  printf '{"slug":"live","status":"active","project":"alpha"}\n' > "$kdir/_work/live/_meta.json"

  # Row 4 — active item with a report, sitting beside three decoys that a glob
  # for *report*.md would pick up instead.
  printf '# Coordination Ledger — Done Work\n' > "$kdir/_work/done/coordination.md"
  printf 'the real report\n' > "$kdir/_work/done/report.md"
  printf 'decoy\n' > "$kdir/_work/done/worker-report.md"
  printf 'decoy\n' > "$kdir/_work/done/review-report.md"
  printf 'decoy\n' > "$kdir/_work/done/report-notes.md"
  printf '{"slug":"done","status":"active","intent_anchor":"anchor from the item"}\n' \
    > "$kdir/_work/done/_meta.json"

  # Row 3 — archived item.
  printf '# Coordination Ledger — Gone Work\n' > "$kdir/_work/_archive/gone/coordination.md"
  printf '{"slug":"gone","status":"archived"}\n' > "$kdir/_work/_archive/gone/_meta.json"

  # An absorbed pointer — a tombstone whose whole body points at the item that
  # absorbed the work. Not an arc: excluded, and the exclusion recorded.
  printf '# ABSORBED — eaten work\n\n2026-01-05: Absorbed into **beta-filed** (see its `coordination.md`).\n' \
    > "$kdir/_work/_archive/eaten/coordination.md"
  printf '{"slug":"eaten","status":"archived"}\n' > "$kdir/_work/_archive/eaten/_meta.json"

  # A forwarding stub pointing at the filed ledger it was moved to. The path it
  # names is stale, as the real one is — resolution falls back to the filename.
  printf '# Coordination Ledger — MOVED\n\n**→ `_work/_projects/alpha/alpha-2026-01-02-beta-arc.md`**\n' \
    > "$kdir/_work/_archive/stub/coordination.md"
  printf '{"slug":"stub","status":"archived"}\n' > "$kdir/_work/_archive/stub/_meta.json"

  # Dates well in the past, so a record that collapsed onto migration time is
  # obvious rather than plausible.
  touch -t 202401020304 "$kdir/_work/_projects/alpha/coordination.md"
  touch -t 202402030405 "$kdir/_work/_projects/alpha/report.md"

  echo "$kdir"
}

echo "== a bare run writes nothing =="
KDIR=$(new_store)
BEFORE=$(snapshot "$KDIR")
OUT=$(bash "$MIGRATE" --kdir "$KDIR"); RC=$?
AFTER=$(snapshot "$KDIR")
assert_eq "preflight exits clean" "0" "$RC"
assert_eq "the store is byte-identical after preflight" "$BEFORE" "$AFTER"
assert_no_file "preflight creates no arcs directory" "$KDIR/_work/_arcs"
assert_contains "preflight reports the row count it discovered" "$OUT" "8 arcs to migrate"
assert_contains "preflight names each record's classification row" "$OUT" "row 4"
assert_contains "preflight names the excluded absorbed pointer" "$OUT" \
  "_work/_archive/eaten/coordination.md"
assert_contains "with its absorbed-into target" "$OUT" "absorbed into beta-filed"

echo "== the row set is discovered, not enumerated =="
NEW=$(new_store)
mkdir -p "$NEW/_work/_projects/gamma"
printf '# Coordination Ledger — Late Arrival\n' > "$NEW/_work/_projects/gamma/coordination.md"
OUT=$(bash "$MIGRATE" --kdir "$NEW")
assert_contains "an arc added after the design was written is picked up" "$OUT" "9 arcs to migrate"

echo "== a clean run =="
KDIR=$(new_store)
LEGACY_BEFORE=$(snapshot "$KDIR")
OUT=$(bash "$MIGRATE" --kdir "$KDIR" --commit); RC=$?
assert_eq "commit exits clean" "0" "$RC"
assert_contains "commit reports what it migrated" "$OUT" "Migrated 8 arcs"
assert_contains "and what it excluded" "$OUT" "1 absorbed pointer excluded"

ARCS="$KDIR/_work/_arcs"
assert_file "the project-home arc landed" "$ARCS/alpha-home/_meta.json"
assert_file "its ledger came with it" "$ARCS/alpha-home/coordination.md"
assert_file "its report came with it" "$ARCS/alpha-home/report.md"
assert_eq "the project home classifies closed" "closed" "$(meta_field "$ARCS/alpha-home/_meta.json" status)"
assert_eq "the project label is carried" "alpha" "$(meta_field "$ARCS/alpha-home/_meta.json" project)"
assert_eq "members come from the items the ledger names" '["live"]' "$(meta_field "$ARCS/alpha-home/_meta.json" members)"
assert_eq "the anchor is preserved verbatim" "alpha intent" "$(meta_field "$ARCS/alpha-home/_meta.json" anchor)"
assert_eq "schema_version is the integer 1" "1" "$(meta_field "$ARCS/alpha-home/_meta.json" schema_version)"

assert_eq "a project home with no report stays active" "active" "$(meta_field "$ARCS/beta-home/_meta.json" status)"
assert_eq "an active arc records no closure" "<absent>" "$(meta_field "$ARCS/beta-home/_meta.json" closed_at)"
assert_eq "a filed ledger is closed by its filing" "closed" "$(meta_field "$ARCS/beta-filed/_meta.json" status)"
assert_eq "an archived item's arc is archived" "archived" "$(meta_field "$ARCS/gone-work/_meta.json" status)"
assert_eq "an active item with a report is closed" "closed" "$(meta_field "$ARCS/done-work/_meta.json" status)"
assert_eq "an active item without one stays active" "active" "$(meta_field "$ARCS/live-work/_meta.json" status)"
assert_eq "the item is recorded as a member" '["done"]' "$(meta_field "$ARCS/done-work/_meta.json" members)"
assert_eq "the anchor falls back to the work item's" "anchor from the item" \
  "$(meta_field "$ARCS/done-work/_meta.json" anchor)"
assert_eq "a project label absent on the item is omitted" "<absent>" \
  "$(meta_field "$ARCS/done-work/_meta.json" project)"

echo "== history survives the move =="
EXPECTED_OPENED=$(python3 -c "
import os, sys
from datetime import datetime, timezone
print(datetime.fromtimestamp(os.path.getmtime(sys.argv[1]), timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$KDIR/_work/_projects/alpha/coordination.md")
assert_eq "opened keeps the ledger's own date" "$EXPECTED_OPENED" \
  "$(meta_field "$ARCS/alpha-home/_meta.json" opened)"
assert_contains "and that date is historical, not migration time" \
  "$(meta_field "$ARCS/alpha-home/_meta.json" opened)" "2024-01-02"
EXPECTED_CLOSED=$(python3 -c "
import os, sys
from datetime import datetime, timezone
print(datetime.fromtimestamp(os.path.getmtime(sys.argv[1]), timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$KDIR/_work/_projects/alpha/report.md")
assert_eq "closed_at comes from the report" "$EXPECTED_CLOSED" \
  "$(meta_field "$ARCS/alpha-home/_meta.json" closed_at)"
assert_eq "the manifest says where opened came from" "mtime" \
  "$(manifest_field "$ARCS/_migration-manifest.json" alpha-home opened_source)"

echo "== opened prefers the commit that introduced the ledger =="
GITSTORE=$(new_store)
(
  cd "$GITSTORE" || exit 1
  git init -q . >/dev/null 2>&1
  git config user.email "test@example.com"
  git config user.name "Test"
  git add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE="2023-05-06T07:08:09Z" GIT_COMMITTER_DATE="2025-11-12T00:00:00Z" \
    git commit -q -m "seed" >/dev/null 2>&1
)
bash "$MIGRATE" --kdir "$GITSTORE" --commit >/dev/null 2>&1
assert_eq "opened is the author date of the introducing commit" "2023-05-06T07:08:09Z" \
  "$(meta_field "$GITSTORE/_work/_arcs/alpha-home/_meta.json" opened)"
assert_eq "and the manifest records it as a real date, not a guess" "git" \
  "$(manifest_field "$GITSTORE/_work/_arcs/_migration-manifest.json" alpha-home opened_source)"

echo "== report discovery is seat-specific =="
assert_eq "the exact report.md is the one that moved" "the real report" \
  "$(cat "$ARCS/done-work/report.md")"
assert_no_file "a decoy matching *report*.md does not" "$ARCS/done-work/worker-report.md"
assert_eq "a filed ledger pairs with its report by stem" "beta report" \
  "$(cat "$ARCS/beta-filed/report.md")"
assert_no_file "and the report file never becomes its own arc" "$ARCS/beta-report"
assert_no_file "nor under a stripped name" "$ARCS/beta"

echo "== slug derivation =="
assert_file "the trailing -arc is stripped once, leaving -report" \
  "$ARCS/gamma-arc-close-report/coordination.md"
assert_file "an -arc- mid-string is left alone" "$ARCS/delta-arc-mid-string/coordination.md"
assert_eq "a stem-named arc gets a title derived from its name" "Gamma arc close report" \
  "$(meta_field "$ARCS/gamma-arc-close-report/_meta.json" title)"

echo "== an absorbed pointer is excluded, and checkably so =="
assert_no_file "it becomes no arc of its own" "$ARCS/absorbed-eaten-work"
assert_eq "the exclusion records the absorbed-into target" "beta-filed" \
  "$(manifest_exclusion "$ARCS/_migration-manifest.json" _work/_archive/eaten/coordination.md absorbed_into)"
assert_eq "and its classification row" "absorbed" \
  "$(manifest_exclusion "$ARCS/_migration-manifest.json" _work/_archive/eaten/coordination.md classification_row)"
EXPECTED_SHA=$(shasum -a 256 "$KDIR/_work/_archive/eaten/coordination.md" | cut -d' ' -f1)
assert_contains "and the source content it excluded" \
  "$(manifest_exclusion "$ARCS/_migration-manifest.json" _work/_archive/eaten/coordination.md source)" \
  "$EXPECTED_SHA"

echo "== the forwarding stub merges into its target =="
assert_no_file "the stub does not become an arc of its own" "$ARCS/moved"
assert_file "the target's ledger is the canonical one" "$ARCS/beta-filed/coordination.md"
assert_contains "and it is the target's content" "$(cat "$ARCS/beta-filed/coordination.md")" "Beta Filed"
assert_file "the stub is kept beside it" "$ARCS/beta-filed/forwarded-from-stub.md"
assert_contains "verbatim" "$(cat "$ARCS/beta-filed/forwarded-from-stub.md")" "MOVED"
assert_eq "the stub's work item joins the members" '["stub"]' \
  "$(meta_field "$ARCS/beta-filed/_meta.json" members)"
assert_contains "and both sources are on the manifest row" \
  "$(manifest_field "$ARCS/_migration-manifest.json" beta-filed sources)" "_archive/stub/coordination.md"

echo "== the migration is additive =="
LEGACY_AFTER=$(snapshot "$KDIR" | grep -v "_work/_arcs/")
assert_eq "no legacy source was modified or removed" "$LEGACY_BEFORE" "$LEGACY_AFTER"

echo "== an identical re-run writes nothing =="
BEFORE=$(snapshot "$KDIR")
OUT=$(bash "$MIGRATE" --kdir "$KDIR" --commit); RC=$?
AFTER=$(snapshot "$KDIR")
assert_eq "the re-run exits clean" "0" "$RC"
assert_eq "the store is byte-identical after it" "$BEFORE" "$AFTER"
assert_contains "and reports the records as already in place" "$OUT" "8 already in place"

echo "== --verify against the manifest =="
OUT=$(bash "$MIGRATE" --kdir "$KDIR" --verify 2>&1); RC=$?
assert_eq "a clean migration verifies" "0" "$RC"
assert_contains "and reports what it checked" "$OUT" "Verified 8 migrated arcs"
assert_contains "exclusions included" "$OUT" "1 recorded exclusion"

bash "$CLOSE" beta-home --kdir "$KDIR" >/dev/null 2>&1
OUT=$(bash "$MIGRATE" --kdir "$KDIR" --verify 2>&1); RC=$?
assert_eq "closing a migrated arc does not break verification" "0" "$RC"
assert_eq "because the record's identity fields are what get checked" "closed" \
  "$(meta_field "$ARCS/beta-home/_meta.json" status)"

printf 'a later append\n' >> "$KDIR/_work/_projects/beta/coordination.md"
OUT=$(bash "$MIGRATE" --kdir "$KDIR" --verify 2>&1); RC=$?
assert_eq "a changed legacy source is drift, not failure" "3" "$RC"
assert_contains "named by source path" "$OUT" "_work/_projects/beta/coordination.md has changed"

printf 'a later append\n' >> "$KDIR/_work/_archive/eaten/coordination.md"
OUT=$(bash "$MIGRATE" --kdir "$KDIR" --verify 2>&1); RC=$?
assert_eq "a changed excluded source is drift too" "3" "$RC"
assert_contains "named as the exclusion it is" "$OUT" \
  "excluded absorbed pointer _work/_archive/eaten/coordination.md has changed"

printf 'tampered\n' >> "$ARCS/gone-work/coordination.md"
OUT=$(bash "$MIGRATE" --kdir "$KDIR" --verify 2>&1); RC=$?
assert_eq "a changed migrated document is a failure" "1" "$RC"
assert_contains "named by arc" "$OUT" "gone-work: coordination.md has changed"

echo "== a changed derivation does not invalidate the manifest =="
DERIV=$(new_store)
bash "$MIGRATE" --kdir "$DERIV" --commit >/dev/null 2>&1
# Both inputs the derivation reads: the heading a slug comes from, and the item
# status the classifier reads. Preflight would now name a different arc and
# refuse to classify another; --verify reads neither.
printf '# Coordination Ledger — Renamed Entirely\n' > "$DERIV/_work/_projects/alpha/coordination.md"
printf '{"slug":"live","status":"closed","project":"alpha"}\n' > "$DERIV/_work/live/_meta.json"
OUT=$(bash "$MIGRATE" --kdir "$DERIV" 2>&1); RC=$?
assert_eq "preflight now refuses the store" "1" "$RC"
assert_contains "because a record no longer classifies" "$OUT" "matches no row"
OUT=$(bash "$MIGRATE" --kdir "$DERIV" --verify --json 2>&1); RC=$?
assert_eq "verification still reports only drift" "3" "$RC"
assert_contains "over every row the manifest holds" "$OUT" '"checked": 8'
assert_contains "with no failures" "$OUT" '"failures": []'
assert_eq "and the recorded name is untouched" "alpha-home" \
  "$(manifest_field "$DERIV/_work/_arcs/_migration-manifest.json" alpha-home slug)"

echo "== an interrupted run resumes =="
RESUME=$(new_store)
bash "$MIGRATE" --kdir "$RESUME" --commit >/dev/null 2>&1
RARCS="$RESUME/_work/_arcs"
# Interrupted between the manifest row and the rename: a row with no destination.
rm -rf "$RARCS/beta-home"
OUT=$(bash "$MIGRATE" --kdir "$RESUME" --commit); RC=$?
assert_eq "the resumed run exits clean" "0" "$RC"
assert_file "and completes the record the interrupt left behind" "$RARCS/beta-home/_meta.json"
assert_eq "with its recorded history intact" \
  "$(manifest_field "$RARCS/_migration-manifest.json" beta-home identity)" \
  "$(record_identity "$RARCS/beta-home/_meta.json")"

# Interrupted before the manifest row: staging residue, no row, no destination.
rm -rf "$RARCS/gone-work"
python3 - "$RARCS/_migration-manifest.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
data["rows"] = [r for r in data["rows"] if r["slug"] != "gone-work"]
with open(sys.argv[1], "w") as handle:
    json.dump(data, handle, indent=2)
PYEOF
mkdir -p "$RARCS/.staging-gone-work"
printf 'half-written\n' > "$RARCS/.staging-gone-work/coordination.md"
OUT=$(bash "$MIGRATE" --kdir "$RESUME" --commit); RC=$?
assert_eq "a run interrupted before its row also resumes" "0" "$RC"
assert_file "the record is rebuilt from source" "$RARCS/gone-work/_meta.json"
assert_no_file "and the staging residue is gone" "$RARCS/.staging-gone-work"
assert_contains "the rebuilt ledger is the source, not the residue" \
  "$(cat "$RARCS/gone-work/coordination.md")" "Gone Work"
RC=0; bash "$MIGRATE" --kdir "$RESUME" --verify >/dev/null 2>&1 || RC=$?
assert_eq "the resumed store verifies" "0" "$RC"

echo "== a divergent destination is refused by name =="
DIVERGE=$(new_store)
bash "$MIGRATE" --kdir "$DIVERGE" --commit >/dev/null 2>&1
printf 'someone edited this\n' >> "$DIVERGE/_work/_arcs/alpha-home/coordination.md"
CONTENT_BEFORE=$(cat "$DIVERGE/_work/_arcs/alpha-home/coordination.md")
OUT=$(bash "$MIGRATE" --kdir "$DIVERGE" --commit 2>&1); RC=$?
assert_eq "the run refuses" "1" "$RC"
assert_contains "naming the record it will not overwrite" "$OUT" \
  "_work/_arcs/alpha-home has changed since it was migrated"
assert_eq "and the edit is still there" "$CONTENT_BEFORE" \
  "$(cat "$DIVERGE/_work/_arcs/alpha-home/coordination.md")"

rm -rf "$DIVERGE/_work/_arcs/beta-home"
mkdir -p "$DIVERGE/_work/_arcs/beta-home"
printf 'not ours\n' > "$DIVERGE/_work/_arcs/beta-home/coordination.md"
python3 - "$DIVERGE/_work/_arcs/_migration-manifest.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
data["rows"] = [r for r in data["rows"] if r["slug"] != "beta-home"]
with open(sys.argv[1], "w") as handle:
    json.dump(data, handle, indent=2)
PYEOF
OUT=$(bash "$MIGRATE" --kdir "$DIVERGE" --commit 2>&1); RC=$?
assert_eq "a destination with no manifest row is refused too" "1" "$RC"
assert_contains "since the migration cannot claim it wrote it" "$OUT" \
  "already exists and this migration did not write it"

echo "== an absorbed pointer retires the record an earlier run migrated =="
RETIRE=$(new_store)
# Yesterday's classifier saw an ordinary archived ledger and migrated it; today
# the same source reads as an absorbed pointer. The re-run must retire the
# record itself — by machine, not by hand.
printf '# Coordination Ledger — Eaten Work\n' > "$RETIRE/_work/_archive/eaten/coordination.md"
bash "$MIGRATE" --kdir "$RETIRE" --commit >/dev/null 2>&1
assert_file "the record was migrated while its source still read as an arc" \
  "$RETIRE/_work/_arcs/eaten-work/_meta.json"
printf '# ABSORBED — eaten work\n\n2026-01-05: Absorbed into **beta-filed** (see its `coordination.md`).\n' \
  > "$RETIRE/_work/_archive/eaten/coordination.md"
OUT=$(bash "$MIGRATE" --kdir "$RETIRE" --commit); RC=$?
assert_eq "the retiring re-run exits clean" "0" "$RC"
assert_no_file "the record is retired from the store" "$RETIRE/_work/_arcs/eaten-work"
assert_eq "its manifest row is gone" "<no row>" \
  "$(manifest_field "$RETIRE/_work/_arcs/_migration-manifest.json" eaten-work slug)"
assert_eq "and the exclusion is recorded in its place" "beta-filed" \
  "$(manifest_exclusion "$RETIRE/_work/_arcs/_migration-manifest.json" _work/_archive/eaten/coordination.md absorbed_into)"
assert_contains "the run names what it retired" "$OUT" "Retired: eaten-work"
RC=0; bash "$MIGRATE" --kdir "$RETIRE" --verify >/dev/null 2>&1 || RC=$?
assert_eq "the store verifies after retirement" "0" "$RC"
BEFORE=$(snapshot "$RETIRE")
bash "$MIGRATE" --kdir "$RETIRE" --commit >/dev/null 2>&1
AFTER=$(snapshot "$RETIRE")
assert_eq "and a further re-run writes nothing" "$BEFORE" "$AFTER"

echo "== a diverged record blocks its own retirement =="
BLOCKED=$(new_store)
printf '# Coordination Ledger — Eaten Work\n' > "$BLOCKED/_work/_archive/eaten/coordination.md"
bash "$MIGRATE" --kdir "$BLOCKED" --commit >/dev/null 2>&1
printf 'edited after migration\n' >> "$BLOCKED/_work/_arcs/eaten-work/coordination.md"
printf '# ABSORBED — eaten work\n\n2026-01-05: Absorbed into **beta-filed** (see its `coordination.md`).\n' \
  > "$BLOCKED/_work/_archive/eaten/coordination.md"
OUT=$(bash "$MIGRATE" --kdir "$BLOCKED" --commit 2>&1); RC=$?
assert_eq "the run refuses" "1" "$RC"
assert_contains "naming the record it will not retire" "$OUT" "refusing to retire"
assert_file "the record is left in place" "$BLOCKED/_work/_arcs/eaten-work/coordination.md"
assert_eq "and no exclusion is recorded for it" "<no exclusion>" \
  "$(manifest_exclusion "$BLOCKED/_work/_arcs/_migration-manifest.json" _work/_archive/eaten/coordination.md absorbed_into)"

echo "== a stub forwarding to an absorbed pointer is refused =="
TANGLED=$(new_store)
mkdir -p "$TANGLED/_work/_archive/stub2"
printf '# Coordination Ledger — MOVED TOO\n\n**→ `_work/_archive/eaten/coordination.md`**\n' \
  > "$TANGLED/_work/_archive/stub2/coordination.md"
printf '{"slug":"stub2","status":"archived"}\n' > "$TANGLED/_work/_archive/stub2/_meta.json"
OUT=$(bash "$MIGRATE" --kdir "$TANGLED" --commit 2>&1); RC=$?
assert_eq "the run refuses rather than losing the stub" "1" "$RC"
assert_contains "naming both ends" "$OUT" \
  "which is excluded as an absorbed pointer"

echo "== preflight refuses what it cannot name or classify =="
BAD=$(mktemp -d "$TEST_DIR/bad.XXXXXX")
mkdir -p "$BAD/_work/_projects/alpha/_ledgers" "$BAD/_work/limbo"
printf 'no heading\n' > "$BAD/_work/_projects/alpha/_ledgers/-.md"
printf '# Coordination Ledger — Limbo\n' > "$BAD/_work/limbo/coordination.md"
printf '{"slug":"limbo","status":"closed"}\n' > "$BAD/_work/limbo/_meta.json"
printf 'orphan\n' > "$BAD/_work/_projects/alpha/_ledgers/alpha-2026-02-02-orphan-report.md"
BEFORE=$(snapshot "$BAD")
OUT=$(bash "$MIGRATE" --kdir "$BAD" --commit 2>&1); RC=$?
AFTER=$(snapshot "$BAD")
assert_eq "commit refuses when preflight has anything to say" "1" "$RC"
assert_eq "and writes nothing at all" "$BEFORE" "$AFTER"
assert_contains "an unnameable record is named by path" "$OUT" "yields no name"
assert_contains "an unclassifiable record too" "$OUT" "matches no row"
assert_contains "and a report with no ledger beside it" "$OUT" "is a report with no"

echo "== a slug two records both want is refused, never merged =="
CLASH=$(mktemp -d "$TEST_DIR/clash.XXXXXX")
mkdir -p "$CLASH/_work/_archive/one" "$CLASH/_work/_archive/two"
for name in one two; do
  printf '# ABSORBED — do not spec separately\n' > "$CLASH/_work/_archive/$name/coordination.md"
  printf '{"slug":"%s","status":"archived"}\n' "$name" > "$CLASH/_work/_archive/$name/_meta.json"
done
OUT=$(bash "$MIGRATE" --kdir "$CLASH" 2>&1); RC=$?
assert_eq "preflight refuses the collision" "1" "$RC"
assert_contains "naming every record that wants the name" "$OUT" \
  "2 of these want the name 'absorbed-do-not-spec-separately'"
assert_contains "and both source paths" "$OUT" "_archive/two/coordination.md"

echo "== the status classifier is total =="
COMBOS=0
ACCEPTED=0
REFUSED=0
MISROUTED=0
for seat in project-home ledgers active-item archived-item; do
  for report in yes no; do
    for origin in active archived none; do
      for stub in yes no; do
       for absorbed in yes no; do
        COMBOS=$((COMBOS + 1))
        OUT=$(bash "$MIGRATE" --kdir "$TEST_DIR" --classify "$seat" "$report" "$origin" "$stub" "$absorbed" 2>&1)
        RC=$?
        # The table, restated independently of the implementation.
        if [[ "$absorbed" == "yes" ]]; then
          want="absorbed"
        elif [[ "$stub" == "yes" ]]; then
          want="merge"
        elif [[ "$seat" == "ledgers" ]]; then
          want="row 2 → closed"
        elif [[ "$seat" == "archived-item" && "$origin" == "archived" ]]; then
          want="row 3 → archived"
        elif [[ "$seat" == "active-item" && "$origin" == "active" && "$report" == "yes" ]]; then
          want="row 4 → closed"
        elif [[ "$seat" == "active-item" && "$origin" == "active" && "$report" == "no" ]]; then
          want="row 5 → active"
        elif [[ "$seat" == "project-home" && "$report" == "yes" ]]; then
          want="row 6 → closed"
        elif [[ "$seat" == "project-home" && "$report" == "no" ]]; then
          want="row 7 → active"
        else
          want=""
        fi
        if [[ -z "$want" ]]; then
          REFUSED=$((REFUSED + 1))
          if [[ $RC -ne 1 || "$OUT" != *"no row covers"* ]]; then
            MISROUTED=$((MISROUTED + 1))
            echo "    unexpected acceptance: $seat report=$report origin=$origin stub=$stub absorbed=$absorbed -> $OUT"
          fi
        elif [[ "$want" == "absorbed" ]]; then
          ACCEPTED=$((ACCEPTED + 1))
          if [[ $RC -ne 0 || "$OUT" != *"excluded as an absorbed pointer"* ]]; then
            MISROUTED=$((MISROUTED + 1))
            echo "    absorbed pointer not excluded: $seat report=$report origin=$origin stub=$stub -> $OUT"
          fi
        elif [[ "$want" == "merge" ]]; then
          ACCEPTED=$((ACCEPTED + 1))
          if [[ $RC -ne 0 || "$OUT" != *"merged into its target"* ]]; then
            MISROUTED=$((MISROUTED + 1))
            echo "    forwarding stub not merged: $seat report=$report origin=$origin -> $OUT"
          fi
        else
          ACCEPTED=$((ACCEPTED + 1))
          if [[ $RC -ne 0 || "$OUT" != "$want" ]]; then
            MISROUTED=$((MISROUTED + 1))
            echo "    wrong row: $seat report=$report origin=$origin stub=$stub absorbed=$absorbed -> '$OUT', wanted '$want'"
          fi
        fi
       done
      done
    done
  done
done
assert_eq "every combination of the five inputs is exercised" "96" "$COMBOS"
assert_eq "each lands on exactly the row the table gives it" "0" "$MISROUTED"
assert_eq "the reachable combinations classify" "88" "$ACCEPTED"
assert_eq "the unreachable ones are refused, not defaulted" "8" "$REFUSED"

echo "== the grammar =="
OUT=$(bash "$MIGRATE" --kdir "$TEST_DIR" --commit --verify 2>&1); RC=$?
assert_eq "--commit and --verify together are refused" "1" "$RC"
assert_contains "with a reason" "$OUT" "ask for different runs"
OUT=$(bash "$MIGRATE" --kdir "$TEST_DIR" --nonsense 2>&1); RC=$?
assert_eq "an unknown flag is refused" "1" "$RC"
OUT=$(bash "$MIGRATE" --kdir "$TEST_DIR" --classify ledgers no none no 2>&1); RC=$?
assert_eq "--classify with four values is refused" "1" "$RC"
assert_contains "and says it takes five" "$OUT" "takes five values"
OUT=$(bash "$MIGRATE" --kdir "$TEST_DIR" stray 2>&1); RC=$?
assert_eq "so is a positional" "1" "$RC"
EMPTY=$(mktemp -d "$TEST_DIR/empty.XXXXXX")
OUT=$(bash "$MIGRATE" --kdir "$EMPTY" --verify 2>&1); RC=$?
assert_eq "verifying a store that was never migrated is an error" "1" "$RC"
assert_contains "that says so" "$OUT" "nothing has been migrated yet"

echo "== a verb reaches the script =="
OUT=$(bash "$REPO_ROOT/cli/lore" arc --help 2>&1)
assert_contains "lore arc --help lists migrate" "$OUT" "migrate"
if grep -q 'arc-migrate.sh' "$REPO_ROOT/cli/lore"; then
  pass "the dispatcher has an arm for it"
else
  fail "the dispatcher has an arm for it"
fi

echo ""
echo "Passed: $PASS   Failed: $FAIL"
[[ $FAIL -eq 0 ]]
