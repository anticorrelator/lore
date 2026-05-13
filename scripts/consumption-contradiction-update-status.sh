#!/usr/bin/env bash
# consumption-contradiction-update-status.sh — Flip the status field on an
# existing contradiction row in `_work/<slug>/consumption-contradictions.jsonl`.
#
# Sibling sole-update-writer to consumption-contradiction-append.sh. The
# append script remains the sole creator of new rows (its append-only
# invariant at :46-49 is preserved). This script is the sole sanctioned
# mutator of the `status` field on rows that already exist.
#
# Sole-writer discipline is per-file, not per-script: append-writer + a
# sibling update-writer satisfies the invariant
# (knowledge:conventions/validation/sole-writer-discipline-across-settlement-substrate).
#
# Usage (see --help):
#   consumption-contradiction-update-status.sh
#       --contradiction-id <ctr-id>
#       --status <verified|rejected>
#       [--settled-by-run-id <id>]
#       [--kdir <path>]
#       [--json]
#
# Semantics:
#   - Locates the sidecar by scanning $KDIR/_work/*/consumption-contradictions.jsonl
#     for a row whose `contradiction_id` matches.
#   - Identity-verified read-modify-write: re-reads the file, finds the row
#     (verifying contradiction_id matches before mutation), then writes back.
#   - Idempotent: if the row is already in the target status, exit 0 with a
#     no-op log to stderr — no file mutation.
#   - On mutation: sets `status` to the new value, `settled_at` to the current
#     ISO-8601 UTC timestamp, and (when supplied) `settled_by_run_id`.
#   - Post-write byte-count check: file size must equal pre-write size + the
#     row-level delta. If it does not match, the script bails and does not
#     attempt to repair partial state.
#
# Exit codes:
#   0 — row updated, OR row already in target state (idempotent no-op)
#   1 — validation failure, contradiction-id not found, or post-write
#       byte-count mismatch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: consumption-contradiction-update-status.sh \
           --contradiction-id <ctr-id> \
           --status <verified|rejected> \
           [--settled-by-run-id <id>] \
           [--kdir <path>] \
           [--json]

Flip the status field on an existing contradiction row to verified|rejected.
Idempotent: re-running with the same target state exits 0 with no file change.
EOF
}

CONTRADICTION_ID=""
NEW_STATUS=""
SETTLED_BY_RUN_ID=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contradiction-id)     CONTRADICTION_ID="$2";    shift 2 ;;
    --status)               NEW_STATUS="$2";          shift 2 ;;
    --settled-by-run-id)    SETTLED_BY_RUN_ID="$2";   shift 2 ;;
    --kdir)                 KDIR_OVERRIDE="$2";       shift 2 ;;
    --json)                 JSON_MODE=1;              shift ;;
    --help|-h)              usage; exit 0 ;;
    *)
      echo "[contradiction-update] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[contradiction-update] $msg"
  fi
  echo "[contradiction-update] Error: $msg" >&2
  exit 1
}

# --- Required-field validation ---
[[ -n "$CONTRADICTION_ID" ]] || fail "--contradiction-id is required"
[[ -n "$NEW_STATUS"       ]] || fail "--status is required"

# --- Enum validation: --status (only the terminal canonical values are
#     valid update targets; pending/accepted/declined/remediated are legacy
#     append-time values, not update targets). ---
case "$NEW_STATUS" in
  verified|rejected) : ;;
  *)
    fail "--status must be 'verified' or 'rejected' (got '$NEW_STATUS')"
    ;;
esac

# --- jq availability (for the --json result envelope) ---
if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

# --- Locate the sidecar containing the target contradiction_id ---
# Scan every work item's sidecar; the contradiction-id is the join key.
SIDECAR=""
shopt -s nullglob
for candidate in "$KNOWLEDGE_DIR"/_work/*/consumption-contradictions.jsonl; do
  if python3 -c '
import json, sys
sidecar, want = sys.argv[1:3]
try:
    with open(sidecar) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("contradiction_id") == want:
                sys.exit(0)
    sys.exit(1)
except FileNotFoundError:
    sys.exit(1)
' "$candidate" "$CONTRADICTION_ID"; then
    SIDECAR="$candidate"
    break
  fi
done
shopt -u nullglob

if [[ -z "$SIDECAR" ]]; then
  fail "contradiction-id $CONTRADICTION_ID not found"
fi

PRE_WRITE_SIZE=$(wc -c < "$SIDECAR" | tr -d ' ')
SETTLED_AT_NOW=$(timestamp_iso)

# --- Identity-verified RMW ---
# The Python helper re-reads the sidecar, finds the matching row, and emits
# a header line followed by the rewritten file content. Header schema:
#
#   noop|<previous_status>|0
#   update|<previous_status>|<expected_delta_bytes>
#
# Header sentinel: we delimit header from body with a NUL byte so the body
# is byte-preserving even when it contains newlines.
TMP_PIPE=$(mktemp -t cc-update-XXXXXX)
trap 'rm -f "$TMP_PIPE" "$TMP_PIPE.body"' EXIT

SIDECAR="$SIDECAR" \
CONTRADICTION_ID="$CONTRADICTION_ID" \
NEW_STATUS="$NEW_STATUS" \
SETTLED_BY_RUN_ID="$SETTLED_BY_RUN_ID" \
SETTLED_AT_NOW="$SETTLED_AT_NOW" \
HEADER_PATH="$TMP_PIPE" \
BODY_PATH="$TMP_PIPE.body" \
python3 <<'PY_EOF'
import json, os, sys

sidecar = os.environ["SIDECAR"]
want_id = os.environ["CONTRADICTION_ID"]
new_status = os.environ["NEW_STATUS"]
settled_by = os.environ.get("SETTLED_BY_RUN_ID", "")
settled_at = os.environ["SETTLED_AT_NOW"]
header_path = os.environ["HEADER_PATH"]
body_path = os.environ["BODY_PATH"]

with open(sidecar, "rb") as f:
    raw = f.read()
trailing_nl = raw.endswith(b"\n")
text = raw.decode("utf-8")
lines = text.split("\n")
if trailing_nl and lines and lines[-1] == "":
    lines = lines[:-1]

found_idx = -1
previous_status = ""
target_row = None
for idx, line in enumerate(lines):
    s = line.strip()
    if not s:
        continue
    try:
        row = json.loads(s)
    except json.JSONDecodeError:
        continue
    if row.get("contradiction_id") == want_id:
        found_idx = idx
        previous_status = row.get("status", "")
        target_row = row
        break

if found_idx == -1 or target_row is None:
    # Should not happen — pre-locate verified presence. Surface clearly.
    sys.stderr.write(
        "[contradiction-update] Error: contradiction-id vanished between locate and RMW\n"
    )
    sys.exit(2)

# Idempotent no-op: already in target state. Write header only; do NOT
# rewrite the file body. Bash side will skip the file replace.
if previous_status == new_status:
    with open(header_path, "w") as h:
        h.write(f"noop|{previous_status}|0\n")
    sys.exit(0)

# Mutate.
target_row["status"] = new_status
target_row["settled_at"] = settled_at
if settled_by:
    target_row["settled_by_run_id"] = settled_by
# If --settled-by-run-id was not passed but the row already carried one
# (from a prior append), leave it intact — sole-update-writer flips status;
# it does not blank out existing provenance.

# Match the append script's `jq -c` output style: compact (no spaces
# after , or :), unicode preserved.
old_line = lines[found_idx]
new_line = json.dumps(target_row, ensure_ascii=False, separators=(",", ":"))
lines[found_idx] = new_line

out = "\n".join(lines)
if trailing_nl:
    out += "\n"

expected_delta = len(new_line.encode("utf-8")) - len(old_line.encode("utf-8"))

with open(header_path, "w") as h:
    h.write(f"update|{previous_status}|{expected_delta}\n")
with open(body_path, "wb") as b:
    b.write(out.encode("utf-8"))
PY_EOF

HEADER=$(cat "$TMP_PIPE")
VERB=$(printf '%s' "$HEADER" | awk -F'|' '{print $1}')
PREVIOUS_STATUS=$(printf '%s' "$HEADER" | awk -F'|' '{print $2}')
EXPECTED_DELTA=$(printf '%s' "$HEADER" | awk -F'|' '{print $3}')

case "$VERB" in
  noop)
    echo "[contradiction-update] already $NEW_STATUS: $CONTRADICTION_ID" >&2
    if [[ $JSON_MODE -eq 1 ]]; then
      RESULT=$(jq -n \
        --arg cid "$CONTRADICTION_ID" \
        --arg prev "$PREVIOUS_STATUS" \
        --arg new "$NEW_STATUS" \
        '{contradiction_id: $cid, previous_status: $prev, new_status: $new, noop: true}')
      json_output "$RESULT"
    fi
    echo "[contradiction-update] OK: $CONTRADICTION_ID → $NEW_STATUS (no-op)"
    exit 0
    ;;
  update)
    : ;;
  *)
    fail "internal error: unrecognized control header '$HEADER'"
    ;;
esac

# --- Byte-count check on the candidate body BEFORE swapping in ---
POST_WRITE_SIZE=$(wc -c < "$TMP_PIPE.body" | tr -d ' ')
if [[ "$POST_WRITE_SIZE" -ne $((PRE_WRITE_SIZE + EXPECTED_DELTA)) ]]; then
  fail "post-write byte-count mismatch: pre=$PRE_WRITE_SIZE expected_delta=$EXPECTED_DELTA actual=$POST_WRITE_SIZE — refusing to leave sidecar partially written"
fi

# Atomic replace.
mv "$TMP_PIPE.body" "$SIDECAR"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg cid "$CONTRADICTION_ID" \
    --arg prev "$PREVIOUS_STATUS" \
    --arg new "$NEW_STATUS" \
    --arg settled_at "$SETTLED_AT_NOW" \
    '{contradiction_id: $cid, previous_status: $prev, new_status: $new, settled_at: $settled_at}')
  json_output "$RESULT"
fi

echo "[contradiction-update] OK: $CONTRADICTION_ID → $NEW_STATUS"
