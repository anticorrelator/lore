#!/usr/bin/env bash
# apply-correction.sh — Apply a correction, add a new entry, or advance an
# entry's confidence in the knowledge commons.
#
# Three modes, keyed on --add-entry / --advance-confidence (default: mutate):
#
# Advance-confidence mode:
#   apply-correction.sh --advance-confidence
#                        --entry <path>
#                        --verdict-id <id> --verdict-source <source>
#                        --evidence "<file:line quote>"
#                        --allow-settlement-verdict
#                        [--date <YYYY-MM-DD>]
#                        [--dry-run]
#
# Mutation mode (default):
#   apply-correction.sh --entry <path> --verdict-id <id> --verdict-source <source>
#                        --evidence "<file:line quote>"
#                        --superseded-text "<snippet>"
#                        --replacement-text "<snippet>"
#                        [--date <YYYY-MM-DD>]
#                        [--check-escalation]
#                        [--backlink-threshold N]
#                        [--allow-settlement-verdict]
#                        [--dry-run]
#
# Add-entry mode:
#   apply-correction.sh --add-entry
#                        --entry <new-path>
#                        --title <title>
#                        --body <body>
#                        --scale <scale>
#                        --verdict-id <id> --verdict-source <source>
#                        --evidence "<file:line quote>"
#                        --allow-settlement-verdict
#                        [--meta-fields <key=val,...>]
#                        [--date <YYYY-MM-DD>]
#                        [--dry-run]
#
# Mutation mode: replaces the superseded_text snippet in <entry> with
# replacement_text and appends a corrections[] item to the META block.
# H1 handling after the body replacement:
#   - If the entry's H1 was derived from the superseded claim (normalized
#     match against derive_entry_title(superseded_text), or a word-prefix of
#     the claim with >= 3 tokens), the H1 is regenerated from replacement_text
#     and the corrections[] item records previous_title/new_title.
#   - A non-derived (hand-authored) H1 is never rewritten; if the replacement
#     touched the entry's lead paragraph, META gains title_stale: <date> and a
#     notice goes to stderr.
#   - Otherwise the H1 is left alone.
# Authorization (default scorecard path): requires the verdict's
# calibration_state in rows.jsonl to be 'calibrated'.
# Authorization with --allow-settlement-verdict: validates against
# _settlement/runs/<verdict-id>.json — verdict.verdict must be 'contradicted'
# from a calibrated hard-cal gate (correctness-gate-assertion or
# correctness-gate-contradiction) with a non-empty correction.
#
# Add-entry mode: creates a NEW commons entry at <new-path> from <title>,
# <body>, <scale>, and optional --meta-fields. Forbids --superseded-text and
# --replacement-text. Authorization always requires --allow-settlement-verdict
# and validates against _settlement/runs/<verdict-id>.json — verdict.verdict
# must be 'verified' and the run must be either
#   (a) kind=task-claim with curator-selected + capture-gate-passed markers, OR
#   (b) kind=omission with capture-gate-passed marker.
# The capture-gate / curator markers land on the run record in Phase 2; for
# now the gate accepts a non-empty 'verified' verdict with matching kind.
#
# Advance-confidence mode: advances an existing entry's confidence from
# 'unaudited' to 'high' in its META block and appends a confidence_advances[]
# provenance item. Forbids the mutation/add-entry text flags. Authorization
# always requires --allow-settlement-verdict and validates against
# _settlement/runs/<verdict-id>.json — verdict.verdict must be 'verified'.
# Idempotent: an entry already at 'high' is a no-op (exit 0) that appends no
# duplicate confidence_advances[] item, so the settlement terminus can re-run it.
#
# With --check-escalation (mutation mode only), also evaluates L3 conditions:
#   (a) entry has >= N inbound backlinks (default 3) in _manifest.json
#   (b) entry's scale: field in META == 'architecture'
#   (c) entry's META has safety-relevant: true or evaluation-rule-relevant: true
#   (d) --evidence text contains prior-doctrine language ("prior", "supersedes", or a quoted phrase)
#   If any condition holds (L3 escalation):
#   - A copy of the prior version is written to <entry-dir>/<basename>-superseded-<date>.md
#   - Archived copy has 'status: superseded' added to its META block
#   - New version gains 'supersedes: <archived_path>' and 'precedent_note: ...' in its META block
#
# The META block extension looks like:
#   <!-- learned: ... | ... | corrections: [{date: 2026-04-23, verdict_source: correctness-gate, verdict_id: abc123, evidence: "scripts/foo.sh:10 — quote", superseded_text: "old snippet", replacement_text: "new snippet"}] -->
#
# Attribution: to the evidence anchor (file:line quote), not to the producing agent.
# This is blame-free per the settlement architecture (work-03 leak policy).
#
# Write gate (task-62): pre-calibration verdicts are logged to rows.jsonl as usual
# but MUST NOT reach the commons. Only verdicts with calibration_state=calibrated
# may modify entries. This prevents calibration-run noise from corrupting the
# knowledge base before judges have passed their discrimination tests.
#
# Exit codes:
#   0 — success
#   1 — usage error
#   2 — entry not found or superseded_text not found in body, or add-entry path conflict
#   3 — META block not found (unexpected entry format)
#   4 — verdict not authorized (write gate rejected)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ENTRY_PATH=""
VERDICT_ID=""
VERDICT_SOURCE=""
EVIDENCE=""
SUPERSEDED_TEXT=""
REPLACEMENT_TEXT=""
DATE_TODAY=$(date +"%Y-%m-%d")
CHECK_ESCALATION=0
BACKLINK_THRESHOLD=3
DRY_RUN=0
ALLOW_SETTLEMENT_VERDICT=0
ADD_ENTRY_MODE=0
ADVANCE_CONFIDENCE_MODE=0
NEW_TITLE=""
NEW_BODY=""
NEW_SCALE=""
META_FIELDS=""
KDIR_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Advance-confidence mode:
  apply-correction.sh --advance-confidence --entry <path>
                       --verdict-id <id> --verdict-source <source>
                       --evidence "<file:line quote>"
                       --allow-settlement-verdict
                       [--date <YYYY-MM-DD>]
                       [--dry-run]

Mutation mode:
  apply-correction.sh --entry <path> --verdict-id <id> --verdict-source <source>
                       --evidence "<file:line quote>"
                       --superseded-text "<snippet>"
                       --replacement-text "<snippet>"
                       [--date <YYYY-MM-DD>]
                       [--check-escalation]
                       [--backlink-threshold N]
                       [--allow-settlement-verdict]
                       [--dry-run]

Add-entry mode:
  apply-correction.sh --add-entry --entry <new-path>
                       --title <title> --body <body> --scale <scale>
                       --verdict-id <id> --verdict-source <source>
                       --evidence "<file:line quote>"
                       --allow-settlement-verdict
                       [--meta-fields key=val,...]
                       [--date <YYYY-MM-DD>]
                       [--dry-run]

Required (mutation):
  --entry PATH              Absolute path to the target knowledge entry (.md file)
  --verdict-id ID           The verdict_id from the scorecard row
  --verdict-source SOURCE   'correctness-gate' or 'reverse-auditor'
  --evidence TEXT           file:line citation from the verdict's claim_anchor
  --superseded-text TEXT    The text snippet in the entry body to replace
  --replacement-text TEXT   The replacement text

Required (add-entry):
  --add-entry                  Switch to add-entry mode (creates NEW commons entry)
  --entry PATH                 Absolute target path under \$KDIR/; MUST NOT exist
  --title TEXT                 H1 title for the new entry
  --body TEXT                  Prose body content
  --scale SCALE                Scale bucket — abstract|architecture|subsystem|implementation
  --verdict-id ID              Settlement run id
  --verdict-source SOURCE      'correctness-gate' or 'reverse-auditor'
  --evidence TEXT              file:line citation
  --allow-settlement-verdict   Required in add-entry mode; validates the run

Optional:
  --date YYYY-MM-DD            Override the correction date (default: today)
  --kdir PATH                  Override the knowledge directory (default: lore resolve)
  --check-escalation           [mutation mode only] Evaluate L3 escalation conditions
  --backlink-threshold N       Backlink in-degree >= N triggers escalation (default: 3)
  --meta-fields key=val,...    [add-entry mode only] Additional META fields
  --allow-settlement-verdict   Bypass the scorecard calibration_state gate; validate
                               against _settlement/runs/<verdict-id>.json instead.
                               Used by the autonomous settlement->commons loop.
                               Required in add-entry mode.
  --dry-run                    Print what would change without writing
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry)
      ENTRY_PATH="$2"
      shift 2
      ;;
    --verdict-id)
      VERDICT_ID="$2"
      shift 2
      ;;
    --verdict-source)
      VERDICT_SOURCE="$2"
      shift 2
      ;;
    --evidence)
      EVIDENCE="$2"
      shift 2
      ;;
    --superseded-text)
      SUPERSEDED_TEXT="$2"
      shift 2
      ;;
    --replacement-text)
      REPLACEMENT_TEXT="$2"
      shift 2
      ;;
    --date)
      DATE_TODAY="$2"
      shift 2
      ;;
    --check-escalation)
      CHECK_ESCALATION=1
      shift
      ;;
    --backlink-threshold)
      BACKLINK_THRESHOLD="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --allow-settlement-verdict)
      # Bypass the scorecard calibration_state gate; validate against
      # _settlement/runs/<verdict-id>.json instead. The settlement pipeline
      # IS the independent review — the calibrated-only gate is a permanent
      # stop in practice since nothing automatically promotes to calibrated.
      ALLOW_SETTLEMENT_VERDICT=1
      shift
      ;;
    --add-entry)
      ADD_ENTRY_MODE=1
      shift
      ;;
    --advance-confidence)
      ADVANCE_CONFIDENCE_MODE=1
      shift
      ;;
    --title)
      NEW_TITLE="$2"
      shift 2
      ;;
    --body)
      NEW_BODY="$2"
      shift 2
      ;;
    --scale)
      NEW_SCALE="$2"
      shift 2
      ;;
    --meta-fields)
      META_FIELDS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# --- Validate required args (per mode) ---
if [[ $((ADD_ENTRY_MODE + ADVANCE_CONFIDENCE_MODE)) -gt 1 ]]; then
  echo "Error: --add-entry and --advance-confidence are mutually exclusive" >&2
  exit 1
fi
if [[ "$ADVANCE_CONFIDENCE_MODE" == "1" ]]; then
  # Advance-confidence forbids the text flags (it edits no body, only the META
  # confidence field) and demands the settlement authorization.
  if [[ -n "$SUPERSEDED_TEXT" || -n "$REPLACEMENT_TEXT" || -n "$NEW_TITLE" || -n "$NEW_BODY" || -n "$NEW_SCALE" ]]; then
    echo "Error: --advance-confidence forbids --superseded-text, --replacement-text, --title, --body, --scale" >&2
    usage
    exit 1
  fi
  for flag_name in ENTRY_PATH VERDICT_ID VERDICT_SOURCE EVIDENCE; do
    if [[ -z "${!flag_name}" ]]; then
      flag_dashed="${flag_name//_/-}"
      echo "Error: --${flag_dashed,,} is required in --advance-confidence mode" >&2
      usage
      exit 1
    fi
  done
  if [[ "$ALLOW_SETTLEMENT_VERDICT" != "1" ]]; then
    echo "Error: --advance-confidence requires --allow-settlement-verdict" >&2
    exit 1
  fi
elif [[ "$ADD_ENTRY_MODE" == "1" ]]; then
  # Add-entry mode forbids the mutation-specific text flags and demands the
  # new-entry-specific ones plus the settlement authorization. This branch
  # creates a NEW commons entry rather than mutating an existing one.
  if [[ -n "$SUPERSEDED_TEXT" || -n "$REPLACEMENT_TEXT" ]]; then
    echo "Error: --add-entry forbids --superseded-text and --replacement-text" >&2
    usage
    exit 1
  fi
  for flag_name in ENTRY_PATH VERDICT_ID VERDICT_SOURCE EVIDENCE NEW_TITLE NEW_BODY NEW_SCALE; do
    if [[ -z "${!flag_name}" ]]; then
      flag_dashed="${flag_name//_/-}"
      case "$flag_name" in
        NEW_TITLE) flag_label="--title" ;;
        NEW_BODY)  flag_label="--body" ;;
        NEW_SCALE) flag_label="--scale" ;;
        *)         flag_label="--${flag_dashed,,}" ;;
      esac
      echo "Error: $flag_label is required in --add-entry mode" >&2
      usage
      exit 1
    fi
  done
  if [[ "$ALLOW_SETTLEMENT_VERDICT" != "1" ]]; then
    echo "Error: --add-entry requires --allow-settlement-verdict" >&2
    exit 1
  fi
  case "$NEW_SCALE" in
    abstract|architecture|subsystem|implementation) : ;;
    *)
      echo "Error: --scale must be 'abstract', 'architecture', 'subsystem', or 'implementation' (got '$NEW_SCALE')" >&2
      exit 1
      ;;
  esac
else
  for flag_name in ENTRY_PATH VERDICT_ID VERDICT_SOURCE EVIDENCE SUPERSEDED_TEXT REPLACEMENT_TEXT; do
    if [[ -z "${!flag_name}" ]]; then
      flag_dashed="${flag_name//_/-}"
      echo "Error: --${flag_dashed,,} is required" >&2
      usage
      exit 1
    fi
  done
fi

case "$VERDICT_SOURCE" in
  correctness-gate|reverse-auditor) ;;
  *)
    echo "Error: --verdict-source must be 'correctness-gate' or 'reverse-auditor', got: '$VERDICT_SOURCE'" >&2
    exit 1
    ;;
esac

if [[ "$ADD_ENTRY_MODE" == "1" ]]; then
  if [[ -e "$ENTRY_PATH" ]]; then
    echo "Error: --add-entry target already exists: $ENTRY_PATH" >&2
    exit 2
  fi
elif [[ ! -f "$ENTRY_PATH" ]]; then
  echo "Error: entry not found: $ENTRY_PATH" >&2
  exit 2
fi

# --- Write gate ---
# Two paths:
#   (a) --allow-settlement-verdict: validate against _settlement/runs/<id>.json.
#       The settlement pipeline IS the independent review; "calibrated-only" is a
#       permanent stop in practice because nothing automatically promotes to
#       calibrated. Replacing the gate with a settlement-authorization check
#       (run exists + verdict=contradicted + nonempty correction) lets the loop
#       actually run while preserving git history + in-entry corrections[] META
#       as the visible accountability layer.
#   (b) default: scorecard rows.jsonl calibration_state==calibrated (task-62).
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

if [[ "$ALLOW_SETTLEMENT_VERDICT" == "1" ]]; then
  # A settled run may have been compacted out of the hot dir into the archive
  # (immutable terminal state, ≥7 days old). Resolve hot first, then archive.
  RUN_FILE="$KDIR/_settlement/runs/${VERDICT_ID}.json"
  if [[ ! -f "$RUN_FILE" ]]; then
    ARCHIVE_RUN_FILE="$KDIR/_settlement/archive/runs/${VERDICT_ID}.json"
    if [[ -f "$ARCHIVE_RUN_FILE" ]]; then
      RUN_FILE="$ARCHIVE_RUN_FILE"
    fi
  fi
  if [[ ! -f "$RUN_FILE" ]]; then
    echo "Correction rejected: --allow-settlement-verdict set but settlement run not found in hot or archive: _settlement/runs/${VERDICT_ID}.json" >&2
    exit 4
  fi
  # Authorization branches keyed on mode:
  #   mutate            → verdict.verdict == "contradicted" + non-empty correction
  #   add-entry         → verdict.verdict == "verified" + matching kind (task-claim
  #                       with curator-selected + capture-gate-passed, OR omission
  #                       with capture-gate-passed). The curator/capture markers are
  #                       written on the run record in Phase 2; for now we accept a
  #                       verified verdict with kind ∈ {task-claim, omission}.
  #   advance-confidence → verdict.verdict == "verified" (the commons audit
  #                       confirmed the promoted claim).
  if [[ "$ADVANCE_CONFIDENCE_MODE" == "1" ]]; then
    SETTLEMENT_OK=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        run = json.load(f)
except (OSError, json.JSONDecodeError):
    print("unreadable"); sys.exit(0)
verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
if verdict.get("verdict") != "verified":
    print("not_verified"); sys.exit(0)
print("ok")
' "$RUN_FILE" 2>/dev/null || echo "error")
  elif [[ "$ADD_ENTRY_MODE" == "1" ]]; then
    SETTLEMENT_OK=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        run = json.load(f)
except (OSError, json.JSONDecodeError):
    print("unreadable"); sys.exit(0)
verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
if verdict.get("verdict") != "verified":
    print("not_verified"); sys.exit(0)
kind = run.get("kind") or "task-claim"
if kind not in ("task-claim", "omission"):
    print(f"non_addable_kind:{kind}"); sys.exit(0)
print("ok")
' "$RUN_FILE" 2>/dev/null || echo "error")
  else
    SETTLEMENT_OK=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        run = json.load(f)
except (OSError, json.JSONDecodeError):
    print("unreadable"); sys.exit(0)
verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
if verdict.get("verdict") != "contradicted":
    print("not_contradicted"); sys.exit(0)
correction = verdict.get("correction")
if not (isinstance(correction, str) and correction.strip()):
    print("empty_correction"); sys.exit(0)
print("ok")
' "$RUN_FILE" 2>/dev/null || echo "error")
  fi
  if [[ "$SETTLEMENT_OK" != "ok" ]]; then
    echo "Correction rejected: settlement verdict $VERDICT_ID failed authorization check ($SETTLEMENT_OK)" >&2
    exit 4
  fi
else
  ROWS_FILE="$KDIR/_scorecards/rows.jsonl"

  if [[ -f "$ROWS_FILE" ]]; then
    CAL_STATE=$(python3 -c '
import json, sys
rows_file, verdict_id = sys.argv[1], sys.argv[2]
with open(rows_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        ids = {row.get("verdict_id"), row.get("calibrated_by_verdict_id")}
        ids.update(row.get("verdict_ids") or [])
        if verdict_id in ids:
            print(row.get("calibration_state", "unknown"))
            sys.exit(0)
# Not found — treat as unknown
print("unknown")
' "$ROWS_FILE" "$VERDICT_ID" 2>/dev/null || echo "unknown")
  else
    CAL_STATE="unknown"
  fi

  if [[ "$CAL_STATE" != "calibrated" ]]; then
    echo "Correction rejected: verdict $VERDICT_ID is in calibration_state=$CAL_STATE. Only calibrated verdicts may modify the commons." >&2
    exit 4
  fi
fi

# --- Add-entry mode: write the new commons entry and exit. ---
# The new entry layout is the canonical lore commons format:
#   # <title>
#   <body>
#   <!-- learned: <date> | scale: <scale> | source: settlement-add-entry | verdict_id: <id> | verdict_source: <source> [| <meta-fields>] -->
# The entry path was validated earlier (must not exist; must resolve under $KDIR).
if [[ "$ADD_ENTRY_MODE" == "1" ]]; then
  # Reject attempts to plant entries outside $KDIR.
  abs_entry=$(python3 -c '
import os, sys
p = os.path.abspath(sys.argv[1])
print(p)
' "$ENTRY_PATH")
  abs_kdir=$(python3 -c '
import os, sys
print(os.path.abspath(sys.argv[1]))
' "$KDIR")
  case "$abs_entry" in
    "$abs_kdir"/*) : ;;
    *)
      echo "Error: --entry path must resolve under \$KDIR ($abs_kdir): $abs_entry" >&2
      exit 1
      ;;
  esac

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run][add-entry] Would create: $abs_entry"
    echo "[dry-run][add-entry]   title:  $NEW_TITLE"
    echo "[dry-run][add-entry]   scale:  $NEW_SCALE"
    echo "[dry-run][add-entry]   verdict_id: $VERDICT_ID  verdict_source: $VERDICT_SOURCE"
    if [[ -n "$META_FIELDS" ]]; then
      echo "[dry-run][add-entry]   meta:   $META_FIELDS"
    fi
    exit 0
  fi

  mkdir -p "$(dirname "$abs_entry")"
  ADD_ENTRY_PATH="$abs_entry" \
  ADD_ENTRY_TITLE="$NEW_TITLE" \
  ADD_ENTRY_BODY="$NEW_BODY" \
  ADD_ENTRY_SCALE="$NEW_SCALE" \
  ADD_ENTRY_DATE="$DATE_TODAY" \
  ADD_ENTRY_VERDICT_ID="$VERDICT_ID" \
  ADD_ENTRY_VERDICT_SOURCE="$VERDICT_SOURCE" \
  ADD_ENTRY_EVIDENCE="$EVIDENCE" \
  ADD_ENTRY_META_FIELDS="$META_FIELDS" \
  python3 <<'ADDENTRY_PY'
import os, json

path = os.environ["ADD_ENTRY_PATH"]
title = os.environ["ADD_ENTRY_TITLE"].strip()
body = os.environ["ADD_ENTRY_BODY"]
scale = os.environ["ADD_ENTRY_SCALE"]
date_today = os.environ["ADD_ENTRY_DATE"]
verdict_id = os.environ["ADD_ENTRY_VERDICT_ID"]
verdict_source = os.environ["ADD_ENTRY_VERDICT_SOURCE"]
evidence = os.environ["ADD_ENTRY_EVIDENCE"]
meta_fields = os.environ.get("ADD_ENTRY_META_FIELDS", "")

meta_parts = [
    f"learned: {date_today}",
    f"scale: {scale}",
    "source: settlement-add-entry",
    f"verdict_source: {verdict_source}",
    f"verdict_id: {verdict_id}",
]
if evidence:
    meta_parts.append(f"evidence: {evidence}")
if meta_fields:
    for pair in meta_fields.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            continue
        k, v = pair.split("=", 1)
        k = k.strip()
        v = v.strip()
        if not k:
            continue
        meta_parts.append(f"{k}: {v}")

meta_block = "<!-- " + " | ".join(meta_parts) + " -->"
content_parts = [f"# {title}", "", body.rstrip(), "", meta_block, ""]
content = "\n".join(content_parts)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(content)
ADDENTRY_PY

  rel=$(python3 -c '
import os, sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
' "$abs_entry" "$abs_kdir")
  echo "[add-entry] Created $rel"
  echo "  verdict_id=$VERDICT_ID  verdict_source=$VERDICT_SOURCE"
  echo "  scale=$NEW_SCALE"
  exit 0
fi

# --- Advance-confidence mode: advance META confidence and exit. ---
# Rewrites `confidence: unaudited` -> `confidence: high` in the entry's META
# block and appends a confidence_advances[] provenance item (mirroring the
# corrections[] trail). Idempotent: an entry already at `high` is a no-op that
# appends nothing, so the settlement terminus can re-run on a retried verdict.
if [[ "$ADVANCE_CONFIDENCE_MODE" == "1" ]]; then
  python3 - "$ENTRY_PATH" "$VERDICT_ID" "$VERDICT_SOURCE" "$EVIDENCE" "$DATE_TODAY" "$DRY_RUN" "$KDIR" <<'ADVANCE_PY'
import sys, os, re, json

entry_path     = sys.argv[1]
verdict_id     = sys.argv[2]
verdict_source = sys.argv[3]
evidence       = sys.argv[4]
date_str       = sys.argv[5]
dry_run        = sys.argv[6] == '1'
kdir           = sys.argv[7]

try:
    original = open(entry_path, encoding='utf-8').read()
except (OSError, UnicodeDecodeError) as e:
    print(f"Error: cannot read entry: {e}", file=sys.stderr)
    sys.exit(2)

META_RE = re.compile(r'(<!--)(.*?)(-->)', re.DOTALL)
meta_matches = list(META_RE.finditer(original))
if not meta_matches:
    print(f"Error: no HTML META block found in entry: {entry_path!r}", file=sys.stderr)
    sys.exit(3)
meta_match = meta_matches[-1]
meta_inner = meta_match.group(2)

rel_path = os.path.relpath(entry_path, kdir) if kdir else entry_path

# Read current confidence from META. Absent confidence is treated as unaudited.
conf_match = re.search(r'\|\s*confidence:\s*(\S+)', meta_inner)
current = conf_match.group(1) if conf_match else "unaudited"
if current == "high":
    print(f"[advance-confidence] {rel_path}: already high — no-op")
    sys.exit(0)

advance_item = json.dumps({
    "date": date_str,
    "verdict_source": verdict_source,
    "verdict_id": verdict_id,
    "evidence": evidence,
    "from": current,
    "to": "high",
}, ensure_ascii=False, separators=(', ', ': '))

if conf_match:
    new_inner = meta_inner[:conf_match.start(1)] + "high" + meta_inner[conf_match.end(1):]
else:
    new_inner = meta_inner.rstrip() + " | confidence: high"

ADVANCES_RE = re.compile(r'\|\s*confidence_advances:\s*\[.*?\]', re.DOTALL)
existing = ADVANCES_RE.search(new_inner)
if existing:
    block = existing.group(0)
    new_inner = new_inner.replace(block, block.rstrip(']') + ', ' + advance_item + ']')
else:
    new_inner = new_inner.rstrip() + f' | confidence_advances: [{advance_item}]'

final = original[:meta_match.start()] + meta_match.group(1) + new_inner + meta_match.group(3) + original[meta_match.end():]

if dry_run:
    print(f"[dry-run][advance-confidence] Would update: {rel_path}")
    print(f"[dry-run][advance-confidence]   confidence: {current} -> high")
    print(f"[dry-run][advance-confidence]   confidence_advances item: {advance_item}")
    sys.exit(0)

with open(entry_path, 'w', encoding='utf-8') as f:
    f.write(final)
print(f"[advance-confidence] {rel_path}: confidence {current} -> high")
print(f"  verdict_id={verdict_id}  verdict_source={verdict_source}")
ADVANCE_PY
  exit 0
fi

# --- L3 escalation check (task-61) ---
# Evaluate escalation conditions; if any hold, Python will perform L3 actions
# (archive prior version, add supersedes edge + precedent_note) in addition to L2.
ESCALATE=0
ESCALATION_REASONS=""

if [[ "$CHECK_ESCALATION" == "1" ]]; then
  ESCALATION_REASONS=$(python3 - "$ENTRY_PATH" "$EVIDENCE" "$BACKLINK_THRESHOLD" "$KDIR" <<'ESCALATION_PY'
import json, os, re, sys

entry_path = sys.argv[1]
evidence   = sys.argv[2]
threshold  = int(sys.argv[3])
kdir       = sys.argv[4]

reasons = []

# (a) Backlink in-degree >= threshold in _manifest.json
manifest_path = os.path.join(kdir, "_manifest.json")
if os.path.isfile(manifest_path):
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    rel_entry = os.path.relpath(entry_path, kdir)
    for entry in manifest.get("entries", []):
        if entry.get("path") == rel_entry:
            backlinks = entry.get("backlinks") or []
            if len(backlinks) >= threshold:
                reasons.append(f"high-backlink:{len(backlinks)}>={threshold}")
            break

# Read META block for remaining checks
try:
    content = open(entry_path, encoding="utf-8").read()
except (OSError, UnicodeDecodeError):
    content = ""

meta_blocks = list(re.finditer(r"<!--(.*?)-->", content, re.DOTALL))
meta_inner = meta_blocks[-1].group(1) if meta_blocks else ""

# (b) scale: architecture
if re.search(r"\|\s*scale:\s*architecture\b", meta_inner):
    reasons.append("architecture-scale")

# (c) safety or evaluation-rule tags
if re.search(r"\|\s*safety-relevant:\s*true\b", meta_inner):
    reasons.append("safety-relevant")
if re.search(r"\|\s*evaluation-rule-relevant:\s*true\b", meta_inner):
    reasons.append("evaluation-rule-relevant")

# (d) prior-doctrine language in evidence ("prior", "supersedes", or a quoted phrase >=5 chars)
if re.search(r'\b(prior|supersedes)\b|"[^"]{5,}"', evidence, re.IGNORECASE):
    reasons.append("doctrine-language")

print(",".join(reasons))
ESCALATION_PY
  )

  if [[ -n "$ESCALATION_REASONS" ]]; then
    ESCALATE=1
    echo "[escalation] L3 triggered: $ESCALATION_REASONS" >&2
  fi
fi

# --- Candidate titles for the H1 decision ---
# Bash derives both candidates through the same helper capture.sh titles new
# entries with; the Python heredoc decides whether the entry's H1 was derived
# from the superseded claim and applies the outcome.
SUPERSEDED_DERIVED_TITLE=$(derive_entry_title "$SUPERSEDED_TEXT")
REPLACEMENT_DERIVED_TITLE=$(derive_entry_title "$REPLACEMENT_TEXT")

# --- Delegate to Python for safe multi-line text replacement and META editing ---
python3 - "$ENTRY_PATH" "$VERDICT_ID" "$VERDICT_SOURCE" "$EVIDENCE" \
          "$SUPERSEDED_TEXT" "$REPLACEMENT_TEXT" "$DATE_TODAY" "$DRY_RUN" "$KDIR" \
          "$ESCALATE" "$ESCALATION_REASONS" \
          "$SUPERSEDED_DERIVED_TITLE" "$REPLACEMENT_DERIVED_TITLE" <<'PYEOF'
import sys
import os
import re
import json

entry_path        = sys.argv[1]
verdict_id        = sys.argv[2]
verdict_source    = sys.argv[3]
evidence          = sys.argv[4]
superseded        = sys.argv[5]
replacement       = sys.argv[6]
date_str          = sys.argv[7]
dry_run           = sys.argv[8] == '1'
kdir              = sys.argv[9]
escalate          = sys.argv[10] == '1'
escalation_reasons = sys.argv[11]  # comma-separated reason tags
superseded_title  = sys.argv[12]  # derive_entry_title(superseded_text)
candidate_title   = sys.argv[13]  # derive_entry_title(replacement_text)

try:
    original = open(entry_path, encoding='utf-8').read()
except (OSError, UnicodeDecodeError) as e:
    print(f"Error: cannot read entry: {e}", file=sys.stderr)
    sys.exit(2)

# --- Step 1: locate and replace superseded_text in body ---
if superseded not in original:
    print(f"Error: superseded_text not found in entry body: {entry_path!r}", file=sys.stderr)
    print(f"  Searched for: {superseded[:120]!r}", file=sys.stderr)
    sys.exit(2)

updated_body = original.replace(superseded, replacement, 1)

# --- Step 1b: decide the H1 action ---
# A capture-derived H1 is mechanically the title-cased first ~8 words of the
# claim it was derived from, so "was this title derived from the superseded
# claim" is decidable by normalized token comparison. Derived titles are
# regenerated from the replacement so the H1 stops asserting the falsified
# claim; hand-authored titles are never rewritten — when the mutation replaced
# the lead paragraph under one, the title is flagged title_stale instead.
def norm_tokens(text):
    return re.sub(r'[^a-z0-9\s]+', ' ', text.lower()).split()

h1_action = 'none'
previous_title = None
new_title = None
h1_match = re.search(r'^# (.+)$', original, re.MULTILINE)
if h1_match:
    h1_tokens = norm_tokens(h1_match.group(1))
    sup_tokens = norm_tokens(superseded)
    derivation_matched = (
        h1_tokens == norm_tokens(superseded_title)
        or (len(h1_tokens) >= 3 and sup_tokens[:len(h1_tokens)] == h1_tokens)
    )
    if derivation_matched:
        h1_action = 'regenerate'
        previous_title = h1_match.group(1)
        # An H1 must stay on one line even if the derived candidate spans several.
        new_title = ' '.join(candidate_title.split())
        updated_body = re.sub(r'^# .+$', lambda m: '# ' + new_title,
                              updated_body, count=1, flags=re.MULTILINE)
    else:
        # Lead paragraph span in the original: after the H1 line, skipping
        # blank lines, through to the next blank line (or EOF).
        lead_start = h1_match.end()
        rest = original[lead_start:]
        stripped = rest.lstrip('\n')
        lead_start += len(rest) - len(stripped)
        para_break = stripped.find('\n\n')
        lead_end = lead_start + (para_break if para_break != -1 else len(stripped))
        rep_start = original.find(superseded)
        rep_end = rep_start + len(superseded)
        if rep_start < lead_end and rep_end > lead_start:
            h1_action = 'flag'

# --- Step 2: build the corrections[] item ---
# Encode the correction as a compact JSON object on one line; this is safe and parseable
# by downstream tasks (#10 retrieval, #11 drift audit) without custom parsers.
# Pipe-delimited META can't hold multi-line YAML, so we use JSON-in-META.
correction_fields = {
    "date": date_str,
    "verdict_source": verdict_source,
    "verdict_id": verdict_id,
    "evidence": evidence,
    "superseded_text": superseded,
    "replacement_text": replacement,
}
if h1_action == 'regenerate':
    correction_fields["previous_title"] = previous_title
    correction_fields["new_title"] = new_title
correction_item = json.dumps(correction_fields, ensure_ascii=False, separators=(', ', ': '))

# --- Step 3: locate the META block (last <!-- ... --> in the file) ---
META_RE = re.compile(r'(<!--)(.*?)(-->)', re.DOTALL)
meta_matches = list(META_RE.finditer(updated_body))
if not meta_matches:
    print(f"Error: no HTML META block found in entry: {entry_path!r}", file=sys.stderr)
    sys.exit(3)

meta_match = meta_matches[-1]  # use the last comment block (the META block)
meta_inner = meta_match.group(2)

# Check if corrections field already exists in META
CORRECTIONS_RE = re.compile(r'\|\s*corrections:\s*\[.*?\]', re.DOTALL)
existing_corrections = CORRECTIONS_RE.search(meta_inner)

if existing_corrections:
    # Append to the existing corrections array
    existing_block = existing_corrections.group(0)
    arr_match = re.search(r'\[(.+)\]', existing_block, re.DOTALL)
    if arr_match:
        new_inner = meta_inner.replace(
            existing_block,
            existing_block.rstrip(']') + ', ' + correction_item + ']'
        )
    else:
        new_inner = meta_inner + f' | corrections: [{correction_item}]'
else:
    new_inner = meta_inner.rstrip() + f' | corrections: [{correction_item}]'

# Flag a hand-authored title whose lead insight was just replaced. The flag is
# durable and single-shot: an already-flagged entry keeps its original date.
if h1_action == 'flag' and not re.search(r'\|\s*title_stale:', new_inner):
    new_inner = new_inner.rstrip() + f' | title_stale: {date_str}'

# --- Step 3b (L3): if escalating, archive the original and add supersedes edge ---
archive_path = None
if escalate:
    entry_dir  = os.path.dirname(entry_path)
    entry_base = os.path.basename(entry_path)
    stem       = entry_base[:-3] if entry_base.endswith('.md') else entry_base
    # Trim slug to stay within reasonable filename lengths
    stem_trimmed = stem[:60] if len(stem) > 60 else stem
    archive_name = f"{stem_trimmed}-superseded-{date_str}.md"
    archive_path = os.path.join(entry_dir, archive_name)
    archive_rel  = os.path.relpath(archive_path, kdir) if kdir else archive_path

    if dry_run:
        print(f"[dry-run][L3] Would archive prior version to: {archive_rel}")
    else:
        # Write archived copy with status: superseded + successor_entry_id added to its META.
        # successor_entry_id lets show-history.sh walk forward from the archived copy to the
        # current version.
        entry_rel = os.path.relpath(entry_path, kdir) if kdir else entry_path
        archive_meta_re = re.compile(r'(<!--)(.*?)(-->)', re.DOTALL)
        arch_matches = list(archive_meta_re.finditer(original))
        if arch_matches:
            am = arch_matches[-1]
            arch_inner = am.group(2)
            if not re.search(r'\|\s*status:', arch_inner):
                arch_inner = arch_inner.rstrip() + ' | status: superseded'
            else:
                arch_inner = re.sub(r'(\|\s*status:\s*)\S+', r'\1superseded', arch_inner)
            arch_inner = arch_inner.rstrip() + f' | successor_entry_id: {entry_rel}'
            archived_content = (
                original[:am.start()]
                + am.group(1) + arch_inner + am.group(3)
                + original[am.end():]
            )
        else:
            archived_content = original
        with open(archive_path, 'w', encoding='utf-8') as f:
            f.write(archived_content)
        print(f"[escalation] Archived prior version to: {archive_rel}")

    # Add supersedes: and precedent_note: to the new version's META
    # Build a short summary from the first 80 chars of superseded_text
    claim_summary = superseded[:80].replace('\n', ' ').strip()
    if len(superseded) > 80:
        claim_summary += '...'
    archive_rel_for_meta = os.path.relpath(archive_path, kdir) if kdir else archive_path
    new_inner = (
        new_inner.rstrip()
        + f' | supersedes: {archive_rel_for_meta}'
        + f' | precedent_note: supersedes prior claim "{claim_summary}"'
        + f' | escalation_reasons: {escalation_reasons}'
    )

new_meta = meta_match.group(1) + new_inner + meta_match.group(3)
final = updated_body[:meta_match.start()] + new_meta + updated_body[meta_match.end():]

# --- Step 4: emit diff or write ---
if dry_run:
    print(f"[dry-run] Would update: {entry_path}")
    print(f"[dry-run] Body replacement:")
    print(f"  - {superseded[:80]!r}...")
    print(f"  + {replacement[:80]!r}...")
    print(f"[dry-run] META correction item:")
    print(f"  {correction_item}")
    if h1_action == 'regenerate':
        print(f"[dry-run] H1 action: regenerate")
        print(f"  - {previous_title!r}")
        print(f"  + {new_title!r}")
    elif h1_action == 'flag':
        print(f"[dry-run] H1 action: flag title_stale: {date_str}")
    else:
        print(f"[dry-run] H1 action: none")
    if escalate:
        print(f"[dry-run][L3] escalation_reasons: {escalation_reasons}")
    sys.exit(0)

with open(entry_path, 'w', encoding='utf-8') as f:
    f.write(final)

rel_path = os.path.relpath(entry_path, kdir) if kdir else entry_path
print(f"[correction] Applied to {rel_path}")
print(f"  verdict_id={verdict_id}  verdict_source={verdict_source}")
print(f"  evidence={evidence!r}")
if h1_action == 'regenerate':
    print(f"  [title] regenerated: {previous_title!r} -> {new_title!r}")
elif h1_action == 'flag':
    print(f"[title] H1 of {rel_path} not derived from the superseded claim; flagged title_stale: {date_str} instead of rewriting", file=sys.stderr)
if escalate:
    print(f"  [L3] escalated: {escalation_reasons}")
    if archive_path:
        ar = os.path.relpath(archive_path, kdir) if kdir else archive_path
        print(f"  [L3] archived prior version: {ar}")

PYEOF

# --- L3 trust-ledger provenance migration ---
# The prior version's trust-event history follows its content to the archive
# path; the corrected entry accrues trust events fresh. Emission is contained:
# a ledger failure warns but never rolls back the already-applied correction.
if [[ "$ESCALATE" == "1" && "$DRY_RUN" != "1" ]]; then
  {
    ENTRY_REL=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
      "$ENTRY_PATH" "$KDIR")
    # Must mirror the archive naming in the L3 escalation step above
    # (stem trimmed to 60 chars + "-superseded-<date>.md").
    ARCHIVE_REL=$(python3 - "$ENTRY_PATH" "$KDIR" "$DATE_TODAY" <<'ARCHREL_PY'
import os, sys
entry_path, kdir, date_str = sys.argv[1:4]
stem = os.path.basename(entry_path)
if stem.endswith('.md'):
    stem = stem[:-3]
stem = stem[:60]
archive = os.path.join(os.path.dirname(entry_path), f"{stem}-superseded-{date_str}.md")
print(os.path.relpath(archive, kdir))
ARCHREL_PY
)
    bash "$SCRIPT_DIR/trust-event-migrate.sh" \
      --from-entry-path "$ENTRY_REL" \
      --to-entry-path "$ARCHIVE_REL" \
      --reason l3-supersede \
      --source apply-correction \
      --verdict-id "$VERDICT_ID" \
      --kdir "$KDIR" >/dev/null
  } || echo "[correction] Warning: trust-ledger provenance-migration emission failed (correction itself was applied)" >&2
fi
