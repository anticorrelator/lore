#!/usr/bin/env bash
# test_salvage_rejected_adjudications.sh — contract test for the migration that
# lands the judge corrections an executor's judge-name filter discarded.
#
# Two halves:
#
#   Fixture half — a synthetic store exercises each disposition the migration
#   can reach, including the dispute fallback that the live cohort never takes
#   (every live member matched its superseded span, so only a fixture can pin
#   that branch). It also pins the two properties the salvage is worth nothing
#   without: the join survives a one-second clock skew between a verdict row and
#   the ledger event it produced, and re-running writes nothing.
#
#   Delivered-manifest half — asserts the shipped salvage-manifest.json gives
#   every cohort member a terminal disposition, which is the precondition the
#   pipeline teardown reads before deleting anything.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$REPO_DIR/scripts/migrations/salvage-rejected-adjudication-corrections.py"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  PASS: $label"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "  FAIL: $label"
      echo "    Missing: $needle"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

assert_absent() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  FAIL: $label"
      echo "    Unexpectedly present: $needle"
      FAIL=$((FAIL + 1))
      ;;
    *)
      echo "  PASS: $label"
      PASS=$((PASS + 1))
      ;;
  esac
}

# Field lookup by claim id, so assertions never depend on member ordering.
member_field() {
  local manifest="$1" claim="$2" field="$3"
  python3 - "$manifest" "$claim" "$field" <<'PY'
import json, sys
manifest, claim, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(manifest, encoding="utf-8") as fh:
    data = json.load(fh)
for member in data["members"]:
    if member["claim_id"] == claim:
        print("" if member.get(field) is None else member[field])
        break
else:
    print("<no-such-member>")
PY
}

manifest_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
value = data
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

# --- Fixture store -----------------------------------------------------------

mkdir -p "$KDIR/_trust" "$KDIR/_settlement/runs" \
         "$KDIR/conventions/collection" "$KDIR/conventions" "$KDIR/conventions/protocol" \
         "$KDIR/_work/_archive/coordination-view-onto-arc-store/verdicts" \
         "$KDIR/_work/repair-settlement-executor-path-task-claim-audits/verdicts" \
         "$KDIR/_work/pty-hosted-worker-sessions/verdicts"

# The migration must never consult this tree; it exists so the run can be shown
# to leave it byte-identical.
echo '{"run_id": "audit-fixture", "verdict": "contradicted"}' \
  > "$KDIR/_settlement/runs/audit-fixture.json"

# Corrected branch: entry carries the superseded claim verbatim, and it lives at
# a path the recorded adjudication does not name — only a provenance-migration
# event connects the two.
cat > "$KDIR/conventions/collection/list-cursor.md" <<'ENTRY'
# Collection.List Does Not Skip Section-header Rows During Cursor
collection.List does not skip section-header rows during cursor movement — j/k walks visible rows one at a time regardless of Row.Header. Only CursorToFirstItem and CurrentID treat headers specially (CurrentID returns "" on a header). A list that adds section headers and needs a header-free cursor must step past them in its own Update.
<!-- learned: 2026-07-29 | confidence: unaudited | source: lore-promote | scale: implementation | status: current -->
ENTRY

# Dispute branch: the judge's correction is real, but the claim it supersedes is
# no longer in the entry word for word.
cat > "$KDIR/conventions/capabilities-evidence.md" <<'ENTRY'
# Adapters/capabilities.json Evidence Ids Are Cross-referenced By A Hand-maintained
adapters/capabilities.json evidence ids are cross-referenced by a hand-maintained extractor enumerating fixed JSON locations, duplicated across two test files. The cross-reference check is what surfaces a pointer the extractor has not learned about yet.
<!-- learned: 2026-07-24 | confidence: unaudited | source: lore-promote | scale: implementation | status: current -->
ENTRY

# Off-roster: a rejected adjudication another session's judge wrote. The ledger
# is shared and live, so the migration must leave this one entirely alone.
cat > "$KDIR/conventions/other-sessions-entry.md" <<'ENTRY'
# Some Other Session's Entry
A claim another session's judge has just rejected, whose own session owns the resolution.
<!-- learned: 2026-08-05 | confidence: unaudited | source: lore-promote | scale: implementation | status: current -->
ENTRY

# Already-current branch: the entry states what the judge said it should.
cat > "$KDIR/conventions/protocol/session-substrate.md" <<'ENTRY'
# The Session Substrate Is Deliberately Kind-agnostic Below The
The session substrate is deliberately kind-agnostic below the enqueue gate: type/session_type pass through the Go request decoder and journal writer unvalidated; the closed set spec|implement|chat|worker is asserted only at the bash enqueue gate and the docs schema tables.
<!-- learned: 2026-07-06 | confidence: unaudited | source: lore-promote | scale: subsystem | status: current -->
ENTRY

# The ledger. One confirmed adjudication is present to show the cohort is keyed
# on the rejected verdict, not on the event kind alone.
cat > "$KDIR/_trust/trust-events.jsonl" <<'LEDGER'
{"schema_version": "1", "event": "provenance-migration", "event_id": "mig01", "entry_path": "conventions/collection/list-cursor.md", "source": "renormalize", "observed_at": "2026-07-30T00:00:00Z", "payload": {"from_entry_path": "conventions/list-cursor.md", "to_entry_path": "conventions/collection/list-cursor.md", "reason": "renormalize-restructure"}}
{"schema_version": "1", "event": "adjudication", "event_id": "a1c0000000000000000000000000000000000000000000000000000000000001", "entry_path": "conventions/list-cursor.md", "source": "audit", "observed_at": "2026-07-29T04:36:57Z", "payload": {"claim_id": "collection-list-cursor-does-not-skip-section-headers", "verdict": "rejected", "template_id": "correctness-gate-assertion", "run_id": "audit-fixture-1"}}
{"schema_version": "1", "event": "adjudication", "event_id": "a1c0000000000000000000000000000000000000000000000000000000000002", "entry_path": "conventions/capabilities-evidence.md", "source": "audit", "observed_at": "2026-07-25T03:42:59Z", "payload": {"claim_id": "capabilities-evidence-scan-is-hand-maintained", "verdict": "rejected", "template_id": "correctness-gate-assertion", "run_id": "audit-fixture-2"}}
{"schema_version": "1", "event": "adjudication", "event_id": "a1c0000000000000000000000000000000000000000000000000000000000003", "entry_path": "conventions/protocol/session-substrate.md", "source": "audit", "observed_at": "2026-07-07T17:52:25Z", "payload": {"claim_id": "session-substrate-kind-agnostic-below-enqueue-gate", "verdict": "rejected", "template_id": "correctness-gate-assertion", "run_id": "audit-fixture-3"}}
{"schema_version": "1", "event": "adjudication", "event_id": "a1c0000000000000000000000000000000000000000000000000000000000004", "entry_path": "conventions/collection/list-cursor.md", "source": "audit", "observed_at": "2026-07-29T05:00:00Z", "payload": {"claim_id": "some-confirmed-claim", "verdict": "confirmed", "template_id": "correctness-gate-assertion", "run_id": "audit-fixture-4"}}
{"schema_version": "1", "event": "adjudication", "event_id": "a1c0000000000000000000000000000000000000000000000000000000000005", "entry_path": "conventions/other-sessions-entry.md", "source": "audit", "observed_at": "2026-08-05T23:26:44Z", "payload": {"claim_id": "another-sessions-rejected-claim", "verdict": "rejected", "template_id": "correctness-gate-assertion", "run_id": "audit-fixture-5"}}
LEDGER

# judge_run_at here is one second behind the ledger event it produced. The two
# timestamps are written by different steps, and an exact-equality join would
# drop this member for the same reason the executor dropped thirteen.
cat > "$KDIR/_work/_archive/coordination-view-onto-arc-store/verdicts/promoted-commons.jsonl" <<'VERDICTS'
{"artifact_id": "coordination-view-onto-arc-store", "judge_run_at": "2026-07-29T04:36:56Z", "judge": "correctness-gate-assertion", "verdicts": [{"claim_id": "collection-list-cursor-does-not-skip-section-headers", "verdict": "contradicted", "evidence": "tui/internal/collection/list.go:262-270 — emitCursorChange fires only for a non-header row with an ID.", "correction": "j/k navigation uses nextVisible without checking Row.Header, so it can land on headers; however, headers are also specially excluded from emitCursorChange callbacks, in addition to CursorToFirstItem and CurrentID."}]}
VERDICTS

cat > "$KDIR/_work/repair-settlement-executor-path-task-claim-audits/verdicts/promoted-commons.jsonl" <<'VERDICTS'
{"artifact_id": "repair-settlement-executor-path-task-claim-audits", "judge_run_at": "2026-07-25T03:42:58Z", "judge": "correctness-gate-assertion", "verdicts": [{"claim_id": "capabilities-evidence-scan-is-hand-maintained", "verdict": "contradicted", "evidence": "tests/frameworks/capabilities.bats:85-101 enumerates the consuming locations by hand.", "correction": "The evidence extractor is hand-maintained and duplicated in both test files, but only a newly indexed evidence id used exclusively at an unenumerated JSON location requires extending both copies."}]}
VERDICTS

cat > "$KDIR/_work/pty-hosted-worker-sessions/verdicts/promoted-commons.jsonl" <<'VERDICTS'
{"artifact_id": "pty-hosted-worker-sessions", "judge_run_at": "2026-07-07T17:52:25Z", "judge": "correctness-gate-assertion", "verdicts": [{"claim_id": "session-substrate-kind-agnostic-below-enqueue-gate", "verdict": "contradicted", "evidence": "scripts/session-request.sh:116-120 validates --type against four members.", "correction": "The session-type closed set asserted at the enqueue gate is spec|implement|chat|worker (four members), not spec|implement|chat."}]}
{"artifact_id": "some-other-work-item", "judge_run_at": "2026-08-05T23:26:44Z", "judge": "correctness-gate-assertion", "verdicts": [{"claim_id": "another-sessions-rejected-claim", "verdict": "contradicted", "evidence": "scripts/somewhere.py:10-12 shows otherwise.", "correction": "A correction another session's judge produced and that session owns."}]}
VERDICTS

FIXTURE_MANIFEST="$KDIR/_work/remove-settlement-pipeline-community-driven-verifi/salvage-manifest.json"

# --- Read-only inputs, before ------------------------------------------------

# The ledger is deliberately excluded: the migration appends correction and
# verification rows to it. Its own guarantee is append-only — the pre-run
# content must stay an exact prefix — and that is asserted separately.
readonly_digest() {
  { find "$KDIR/_settlement" -type f
    find "$KDIR/_work" -type f -path '*/verdicts/*.jsonl'
  } | sort | xargs shasum -a 256
}

ledger_rows() { wc -l < "$KDIR/_trust/trust-events.jsonl" | tr -d ' '; }

BEFORE_READONLY=$(readonly_digest)
BEFORE_LEDGER_ROWS=$(ledger_rows)
BEFORE_LEDGER_DIGEST=$(shasum -a 256 < "$KDIR/_trust/trust-events.jsonl")

# --- Run 1 -------------------------------------------------------------------

echo "== Run 1: every member reaches a terminal disposition =="
# A non-zero exit means unresolved members; the assertions below report which,
# which is more useful than dying here.
RUN1_OUT=$(python3 "$MIGRATION" --kdir "$KDIR" 2>&1) || true

assert_eq "cohort excludes confirmed adjudications" \
  "$(manifest_field "$FIXTURE_MANIFEST" cohort_size)" "3"
assert_eq "nothing left unresolved" \
  "$(manifest_field "$FIXTURE_MANIFEST" unresolved)" "0"
assert_contains "run reports the dispositions" "$RUN1_OUT" "3 rejected adjudications"

echo "== Corrected branch =="
assert_eq "superseded span present -> corrected" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers disposition)" \
  "corrected"
assert_eq "branch names the matched span" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers branch)" \
  "superseded-text-matched"
assert_contains "entry carries the judge's replacement" \
  "$(cat "$KDIR/conventions/collection/list-cursor.md")" \
  "CursorToFirstItem, CurrentID, and emitCursorChange treat headers specially"
assert_contains "entry records the correction id" \
  "$(cat "$KDIR/conventions/collection/list-cursor.md")" "correction_id"

echo "== Join tolerates verdict-row clock skew =="
assert_eq "one-second skew still joins" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers join_skew_seconds)" \
  "1"

echo "== Path resolution runs through provenance-migration =="
assert_eq "recorded path is the pre-migration one" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers entry_path_recorded)" \
  "conventions/list-cursor.md"
assert_eq "resolved path is the migration target" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers entry_path_resolved)" \
  "conventions/collection/list-cursor.md"
assert_eq "resolution route is recorded" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers path_resolution)" \
  "provenance-migration"

echo "== Dispute branch: an unmatchable member is never a silent skip =="
assert_eq "superseded span absent -> disputed" \
  "$(member_field "$FIXTURE_MANIFEST" capabilities-evidence-scan-is-hand-maintained disposition)" \
  "disputed"
assert_eq "branch names the absent span" \
  "$(member_field "$FIXTURE_MANIFEST" capabilities-evidence-scan-is-hand-maintained branch)" \
  "superseded-text-absent"
DISPUTED_ENTRY=$(cat "$KDIR/conventions/capabilities-evidence.md")
assert_contains "marker is dated" "$DISPUTED_ENTRY" "**Disputed "
assert_contains "marker carries the judge's correction prose" "$DISPUTED_ENTRY" \
  "only a newly indexed evidence id used exclusively at an unenumerated JSON location requires extending both copies"
assert_contains "marker invites the next reader to settle it" "$DISPUTED_ENTRY" \
  "A later agent whose context settles this can correct the entry"
assert_contains "dispute is recorded in META" "$DISPUTED_ENTRY" "dispute_id"
assert_eq "manifest carries the dispute id" \
  "$(member_field "$FIXTURE_MANIFEST" capabilities-evidence-scan-is-hand-maintained owner_ref | cut -c1-5)" \
  "disp-"

echo "== Already-current branch is checked against the entry, not asserted =="
assert_eq "entry already states the correction" \
  "$(member_field "$FIXTURE_MANIFEST" session-substrate-kind-agnostic-below-enqueue-gate disposition)" \
  "already-current"
assert_absent "no dispute marker on an entry that is already right" \
  "$(cat "$KDIR/conventions/protocol/session-substrate.md")" "**Disputed "

echo "== Roster bound: another session's rejected adjudication is left alone =="
assert_eq "off-roster member is not settled" \
  "$(member_field "$FIXTURE_MANIFEST" another-sessions-rejected-claim disposition)" \
  "<no-such-member>"
assert_contains "off-roster member is reported, not silently dropped" \
  "$(python3 - "$FIXTURE_MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(",".join(m["claim_id"] for m in data["off_roster_rejected_adjudications"]))
PY
)" "another-sessions-rejected-claim"
OTHER_ENTRY=$(cat "$KDIR/conventions/other-sessions-entry.md")
assert_absent "no dispute marker on another session's entry" "$OTHER_ENTRY" "**Disputed "
assert_absent "no correction on another session's entry" "$OTHER_ENTRY" "corrections:"

echo "== Ledger: the repair is visible to a ledger query, not only on the entry =="
CORRECTION_ROW=$(python3 - "$KDIR/_trust/trust-events.jsonl" <<'PY'
import json, sys
want = "a1c0000000000000000000000000000000000000000000000000000000000001"
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row.get("event") == "correction" and row["payload"].get("verification_event_id") == want:
        print(json.dumps(row["payload"]))
        break
else:
    print("<none>")
PY
)
assert_contains "correction event is anchored to the adjudication" "$CORRECTION_ROW" \
  "a1c0000000000000000000000000000000000000000000000000000000000001"
assert_contains "correction event carries the entry's correction id" "$CORRECTION_ROW" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers owner_ref)"
assert_contains "correction event records the resulting status" "$CORRECTION_ROW" "corrected"

HELD_ROW=$(python3 - "$KDIR/_trust/trust-events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    payload = row.get("payload") or {}
    if (row.get("event") == "consumption-verification"
            and payload.get("claim_id") == "session-substrate-kind-agnostic-below-enqueue-gate"):
        print(json.dumps(payload))
        break
else:
    print("<none>")
PY
)
assert_contains "already-current member leaves a held verification" "$HELD_ROW" '"disposition": "held"'
assert_contains "held verification is grounded in the code the judge cited" "$HELD_ROW" \
  "session-request.sh"
assert_absent "no correction event is manufactured for an unchanged entry" "$HELD_ROW" \
  "correction_id"

echo "== Manifest reports its own effect on the substrate =="
assert_eq "corrected member says the claim was replaced" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers entry_effect)" \
  "claim-replaced-in-place"
assert_eq "disputed member says a marker was added" \
  "$(member_field "$FIXTURE_MANIFEST" capabilities-evidence-scan-is-hand-maintained entry_effect)" \
  "dispute-marker-added"
assert_eq "already-current member says the entry was not touched" \
  "$(member_field "$FIXTURE_MANIFEST" session-substrate-kind-agnostic-below-enqueue-gate entry_effect)" \
  "unchanged"

echo "== Read-only inputs =="
assert_eq "settlement tree and verdict files are byte-identical" \
  "$(readonly_digest)" "$BEFORE_READONLY"

# --- Run 2 -------------------------------------------------------------------

echo "== Run 2: re-running changes nothing =="
ENTRIES_AFTER_RUN1=$(shasum -a 256 \
  "$KDIR/conventions/collection/list-cursor.md" \
  "$KDIR/conventions/capabilities-evidence.md" \
  "$KDIR/conventions/protocol/session-substrate.md")
CORRECTION_ID_RUN1=$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers owner_ref)
DISPUTE_ID_RUN1=$(member_field "$FIXTURE_MANIFEST" capabilities-evidence-scan-is-hand-maintained owner_ref)
LEDGER_ROWS_AFTER_RUN1=$(ledger_rows)

python3 "$MIGRATION" --kdir "$KDIR" >/dev/null 2>&1

assert_eq "no entry changed" \
  "$(shasum -a 256 \
      "$KDIR/conventions/collection/list-cursor.md" \
      "$KDIR/conventions/capabilities-evidence.md" \
      "$KDIR/conventions/protocol/session-substrate.md")" \
  "$ENTRIES_AFTER_RUN1"
assert_eq "correction recognized as already applied" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers last_run)" \
  "noop"
assert_eq "dispute recognized as already applied" \
  "$(member_field "$FIXTURE_MANIFEST" capabilities-evidence-scan-is-hand-maintained last_run)" \
  "noop"
assert_eq "entry_effect still reports what the salvage did, not what this run did" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers entry_effect)" \
  "claim-replaced-in-place"
assert_contains "ledger row is recognized as already present" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers ledger_event)" \
  "deduped"
assert_eq "correction id is stable across runs" \
  "$(member_field "$FIXTURE_MANIFEST" collection-list-cursor-does-not-skip-section-headers owner_ref)" \
  "$CORRECTION_ID_RUN1"
assert_eq "dispute id is stable across runs" \
  "$(member_field "$FIXTURE_MANIFEST" capabilities-evidence-scan-is-hand-maintained owner_ref)" \
  "$DISPUTE_ID_RUN1"
assert_eq "dispositions unchanged" \
  "$(manifest_field "$FIXTURE_MANIFEST" unresolved)" "0"
assert_eq "read-only inputs still byte-identical" \
  "$(readonly_digest)" "$BEFORE_READONLY"
assert_eq "no ledger row appended on the second run" \
  "$(ledger_rows)" "$LEDGER_ROWS_AFTER_RUN1"
assert_eq "pre-run ledger content is still an exact prefix" \
  "$(head -n "$BEFORE_LEDGER_ROWS" "$KDIR/_trust/trust-events.jsonl" | shasum -a 256)" \
  "$BEFORE_LEDGER_DIGEST"

# --- Already-current source guard --------------------------------------------

# The already-current disposition rests on two runtime checks, and a guard that
# is documented but never fires is the failure this pins: each recorded source
# anchor must still read exactly as recorded, and must stop matching the moment
# the file, the line range, or the text moves.
echo "== Already-current source guard actually rejects drift =="
GUARD=$(python3 - "$MIGRATION" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("salvage", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
bad = []
for claim_id, entry in mod.ALREADY_CURRENT.items():
    checks = {
        "matches": mod.source_reads(mod.REPO_DIR, entry["file"], entry["line_range"], entry["snippet"]),
        "wrong_lines": mod.source_reads(mod.REPO_DIR, entry["file"], "1-4", entry["snippet"]),
        "missing_file": mod.source_reads(mod.REPO_DIR, "scripts/no-such-file.sh", entry["line_range"], entry["snippet"]),
        "altered": mod.source_reads(mod.REPO_DIR, entry["file"], entry["line_range"], entry["snippet"] + "X"),
    }
    if not (checks["matches"] and not checks["wrong_lines"]
            and not checks["missing_file"] and not checks["altered"]):
        bad.append(f"{claim_id}:{checks}")
print(";".join(bad))
PY
)
assert_eq "every recorded source anchor matches, and drift in file/lines/text is rejected" \
  "$GUARD" ""

# --- Delivered manifest ------------------------------------------------------

echo "== Delivered manifest: the teardown's precondition =="
LIVE_KDIR=$(bash "$REPO_DIR/scripts/resolve-repo.sh")
LIVE_MANIFEST="$LIVE_KDIR/_work/remove-settlement-pipeline-community-driven-verifi/salvage-manifest.json"

if [[ -f "$LIVE_MANIFEST" ]]; then
  assert_eq "all thirteen discarded corrections are accounted for" \
    "$(manifest_field "$LIVE_MANIFEST" cohort_size)" "13"
  assert_eq "none left unresolved" \
    "$(manifest_field "$LIVE_MANIFEST" unresolved)" "0"
  NON_TERMINAL=$(python3 - "$LIVE_MANIFEST" <<'PY'
import json, sys
terminal = {"corrected", "disputed", "already-current"}
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
bad = [m["claim_id"] for m in data["members"] if m["disposition"] not in terminal]
print(",".join(bad))
PY
)
  assert_eq "every member holds a terminal disposition" "$NON_TERMINAL" ""
  MISSING_PROVENANCE=$(python3 - "$LIVE_MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
bad = [
    m["claim_id"] for m in data["members"]
    if m["entry_path_recorded"] != m["entry_path_resolved"]
    and m["path_resolution"] != "provenance-migration"
]
print(",".join(bad))
PY
)
  assert_eq "every relocated entry resolved through a provenance-migration event" \
    "$MISSING_PROVENANCE" ""
  UNLEDGERED=$(python3 - "$LIVE_MANIFEST" "$LIVE_KDIR/_trust/trust-events.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    manifest = json.load(fh)
corrections, held = set(), set()
with open(sys.argv[2], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        payload = row.get("payload") or {}
        if row.get("event") == "correction":
            corrections.add(payload.get("verification_event_id"))
        elif row.get("event") == "consumption-verification" and payload.get("disposition") == "held":
            held.add(payload.get("claim_id"))
bad = []
for member in manifest["members"]:
    if member["disposition"] == "corrected":
        if member["adjudication_event_id"] not in corrections:
            bad.append(member["claim_id"])
    elif member["disposition"] == "already-current":
        if member["claim_id"] not in held:
            bad.append(member["claim_id"])
print(",".join(bad))
PY
)
  assert_eq "every settled member has a ledger row naming its adjudication" "$UNLEDGERED" ""
else
  echo "  FAIL: delivered salvage-manifest.json not found at $LIVE_MANIFEST"
  FAIL=$((FAIL + 1))
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
