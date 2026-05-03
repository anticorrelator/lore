#!/usr/bin/env bash
# apply-correction.sh — Apply a correction to a knowledge entry from a contradicted verdict
#
# Usage:
#   apply-correction.sh --entry <path> --verdict-id <id> --verdict-source <source>
#                        --evidence "<file:line quote>"
#                        --superseded-text "<snippet>"
#                        --replacement-text "<snippet>"
#                        [--date <YYYY-MM-DD>]
#                        [--check-escalation]
#                        [--backlink-threshold N]
#                        [--dry-run]
#
# When a correctness-gate or reverse-auditor verdict produces a 'contradicted' result
# and that verdict maps to an existing commons entry, this script:
#   1. Checks the verdict's calibration_state in rows.jsonl — rejects if not 'calibrated'.
#   2. Replaces the superseded_text snippet in the entry body with replacement_text.
#   3. Appends a corrections[] YAML item to the entry's HTML META block.
#
# With --check-escalation, also evaluates L3 conditions:
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
#   2 — entry not found or superseded_text not found in body
#   3 — META block not found (unexpected entry format)
#   4 — verdict not calibrated (write gate rejected)

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

usage() {
  cat >&2 <<EOF
Usage: apply-correction.sh --entry <path> --verdict-id <id> --verdict-source <source>
                            --evidence "<file:line quote>"
                            --superseded-text "<snippet>"
                            --replacement-text "<snippet>"
                            [--date <YYYY-MM-DD>]
                            [--check-escalation]
                            [--backlink-threshold N]
                            [--dry-run]

Apply a correction from a contradicted verdict to a knowledge entry.

Required:
  --entry PATH              Absolute path to the target knowledge entry (.md file)
  --verdict-id ID           The verdict_id from the scorecard row
  --verdict-source SOURCE   'correctness-gate' or 'reverse-auditor'
  --evidence TEXT           file:line citation from the verdict's claim_anchor
  --superseded-text TEXT    The text snippet in the entry body to replace
  --replacement-text TEXT   The replacement text

Optional:
  --date YYYY-MM-DD         Override the correction date (default: today)
  --check-escalation        Evaluate L3 escalation conditions and create supersedes edge if triggered
  --backlink-threshold N    Backlink in-degree >= N triggers escalation (default: 3)
  --dry-run                 Print what would change without writing
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

# --- Validate required args ---
for flag_name in ENTRY_PATH VERDICT_ID VERDICT_SOURCE EVIDENCE SUPERSEDED_TEXT REPLACEMENT_TEXT; do
  if [[ -z "${!flag_name}" ]]; then
    flag_dashed="${flag_name//_/-}"
    echo "Error: --${flag_dashed,,} is required" >&2
    usage
    exit 1
  fi
done

case "$VERDICT_SOURCE" in
  correctness-gate|reverse-auditor) ;;
  *)
    echo "Error: --verdict-source must be 'correctness-gate' or 'reverse-auditor', got: '$VERDICT_SOURCE'" >&2
    exit 1
    ;;
esac

if [[ ! -f "$ENTRY_PATH" ]]; then
  echo "Error: entry not found: $ENTRY_PATH" >&2
  exit 2
fi

# --- Write gate: reject pre-calibration verdicts (task-62) ---
# Look up the verdict in rows.jsonl by verdict_id and check calibration_state.
# Pre-calibration verdicts are logged but must not reach the commons.
KDIR=$(resolve_knowledge_dir)
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
        if row.get("verdict_id") == verdict_id:
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

# --- Delegate to Python for safe multi-line text replacement and META editing ---
python3 - "$ENTRY_PATH" "$VERDICT_ID" "$VERDICT_SOURCE" "$EVIDENCE" \
          "$SUPERSEDED_TEXT" "$REPLACEMENT_TEXT" "$DATE_TODAY" "$DRY_RUN" "$KDIR" \
          "$ESCALATE" "$ESCALATION_REASONS" <<'PYEOF'
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

# --- Step 2: build the corrections[] item ---
# Encode the correction as a compact JSON object on one line; this is safe and parseable
# by downstream tasks (#10 retrieval, #11 drift audit) without custom parsers.
# Pipe-delimited META can't hold multi-line YAML, so we use JSON-in-META.
correction_item = json.dumps({
    "date": date_str,
    "verdict_source": verdict_source,
    "verdict_id": verdict_id,
    "evidence": evidence,
    "superseded_text": superseded,
    "replacement_text": replacement,
}, ensure_ascii=False, separators=(', ', ': '))

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
    if escalate:
        print(f"[dry-run][L3] escalation_reasons: {escalation_reasons}")
    sys.exit(0)

with open(entry_path, 'w', encoding='utf-8') as f:
    f.write(final)

rel_path = os.path.relpath(entry_path, kdir) if kdir else entry_path
print(f"[correction] Applied to {rel_path}")
print(f"  verdict_id={verdict_id}  verdict_source={verdict_source}")
print(f"  evidence={evidence!r}")
if escalate:
    print(f"  [L3] escalated: {escalation_reasons}")
    if archive_path:
        ar = os.path.relpath(archive_path, kdir) if kdir else archive_path
        print(f"  [L3] archived prior version: {ar}")

PYEOF
