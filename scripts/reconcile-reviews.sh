#!/usr/bin/env bash
# reconcile-reviews.sh — Tournament reconciliation between /pr-review and /pr-self-review findings
#
# Usage:
#   lore followup reconcile --pr <number> [--owner <owner>] [--repo <repo>] [--json]
#   OR
#   reconcile-reviews.sh --self-review <path-to-lens-findings.json> \
#                         --external-review <path-to-external-findings.json> \
#                         [--out <path>] [--json]
#
# Produces a reconciliation record that tags each self-review finding with
# one of: `confirm | extend | contradict | orthogonal` relative to the
# external /pr-review findings. Writes the record to the self-review
# followup item as `reconciliation.json`, and (via task-33, in a
# follow-up commit) feeds rollup metrics to the scorecard.
#
# Programmatic, no agent. Matching is deterministic based on:
#   1. (file, line-overlap)  — same file AND line ranges overlap within ±5 lines
#   2. (lens-alignment)      — same lens OR themes overlap (see match_theme())
#
# Tags:
#   confirm     — self-review finding matches an external finding on (1) + (2),
#                 with agreeable severities (both blocking, or both
#                 suggestion, etc.)
#   extend      — self-review finding matches on (1) but external finding
#                 is narrower (less text, fewer sub-points) OR the
#                 self-review finding's severity is strictly higher
#                 (e.g., external=suggestion, self=blocking; the self
#                 identifies a deeper issue in the same location)
#   contradict  — match on (1) with opposing severity/verdict: external
#                 flags an issue, self declares safe; or vice versa. We
#                 detect this via the explicit `verdict` field when
#                 present (one says "issue", the other says "not-issue")
#                 or via textual opposites (e.g., "correctly handles"
#                 vs "fails to handle"). Strict — default is NOT
#                 contradict unless evidence is clear.
#   orthogonal  — self-review finding has no matching external finding on
#                 (1). The self saw something the external missed (or the
#                 external hadn't evaluated that location).
#
# External-only findings (external finding with no matching self-review)
# are tagged `coverage-miss` — they count against the self-review
# template's coverage_miss_rate in task-33's scorecard row.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SELF_REVIEW=""
EXTERNAL_REVIEW=""
PR_NUMBER=""
OWNER=""
REPO=""
OUT=""
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-review)
      SELF_REVIEW="$2"
      shift 2
      ;;
    --external-review)
      EXTERNAL_REVIEW="$2"
      shift 2
      ;;
    --pr)
      PR_NUMBER="$2"
      shift 2
      ;;
    --owner)
      OWNER="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,45p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

command -v python3 &>/dev/null || fail "python3 is required"

# --- Resolve self/external review paths from --pr if supplied ---
if [[ -n "$PR_NUMBER" && ( -z "$SELF_REVIEW" || -z "$EXTERNAL_REVIEW" ) ]]; then
  if [[ -n "$KDIR_OVERRIDE" ]]; then
    KDIR="$KDIR_OVERRIDE"
  else
    KDIR=$(resolve_knowledge_dir)
  fi
  FOLLOWUPS_DIR="$KDIR/_followups"

  # Locate followups matching this PR number. Convention: followup slug
  # contains the PR number or is keyed via meta.json's pr_number field.
  _match_pr() {
    local source="$1"  # 'pr-self-review' or 'pr-review'
    find "$FOLLOWUPS_DIR" -maxdepth 2 -name "_meta.json" 2>/dev/null | while read -r meta; do
      python3 -c "
import json, sys
try:
  d = json.load(open('$meta'))
  if str(d.get('pr_number', '')) == '$PR_NUMBER' and d.get('source') == '$source':
    print('${meta%/_meta.json}')
except: pass"
    done | head -1
  }

  if [[ -z "$SELF_REVIEW" ]]; then
    _self_dir=$(_match_pr "pr-self-review")
    if [[ -n "$_self_dir" && -f "$_self_dir/lens-findings.json" ]]; then
      SELF_REVIEW="$_self_dir/lens-findings.json"
    fi
  fi
  if [[ -z "$EXTERNAL_REVIEW" ]]; then
    _ext_dir=$(_match_pr "pr-review")
    # External reviews use lens-findings.json when produced by /pr-review's
    # lens synthesis; fall back to findings.json or content.md parsing if
    # the followup doesn't carry the structured payload.
    if [[ -n "$_ext_dir" && -f "$_ext_dir/lens-findings.json" ]]; then
      EXTERNAL_REVIEW="$_ext_dir/lens-findings.json"
    fi
  fi
fi

# --- Auto-skip branch for --pr mode ---
# When the caller specified --pr <number> but one side of the tournament
# is absent, exit 0 with a clean informational message. This is the
# automatic-invocation contract: /pr-review Step 8 runs this on every
# review and expects a graceful no-op when the corresponding
# /pr-self-review sidecar was not produced. Explicit --self-review /
# --external-review invocations still hard-fail because the caller named
# both files and we can't help if one is missing.
if [[ -n "$PR_NUMBER" ]]; then
  if [[ -z "$SELF_REVIEW" || ! -f "$SELF_REVIEW" ]]; then
    echo "[reconcile] skipped — no /pr-self-review sidecar found for PR #$PR_NUMBER"
    exit 0
  fi
  if [[ -z "$EXTERNAL_REVIEW" || ! -f "$EXTERNAL_REVIEW" ]]; then
    echo "[reconcile] skipped — no /pr-review external sidecar found for PR #$PR_NUMBER"
    exit 0
  fi
fi

[[ -z "$SELF_REVIEW" ]] && fail "--self-review <path> required (or --pr <number>)"
[[ -z "$EXTERNAL_REVIEW" ]] && fail "--external-review <path> required (or --pr <number>)"
[[ -f "$SELF_REVIEW" ]] || fail "self-review not found: $SELF_REVIEW"
[[ -f "$EXTERNAL_REVIEW" ]] || fail "external-review not found: $EXTERNAL_REVIEW"

# --- Resolve OUT default ---
if [[ -z "$OUT" ]]; then
  _self_parent=$(dirname "$SELF_REVIEW")
  OUT="$_self_parent/reconciliation.json"
fi

# --- Run reconciliation ---
python3 "$SCRIPT_DIR/reconcile-reviews-compute.py" \
  "$SELF_REVIEW" "$EXTERNAL_REVIEW" "$OUT"

# --- Summarize ---
CONFIRM=$(jq '[.reconciled[] | select(.tag == "confirm")] | length' "$OUT")
EXTEND=$(jq '[.reconciled[] | select(.tag == "extend")] | length' "$OUT")
CONTRADICT=$(jq '[.reconciled[] | select(.tag == "contradict")] | length' "$OUT")
ORTHOGONAL=$(jq '[.reconciled[] | select(.tag == "orthogonal")] | length' "$OUT")
COVERAGE_MISS=$(jq '.coverage_miss | length' "$OUT")
TOTAL_SELF=$(jq '.reconciled | length' "$OUT")
TOTAL_EXT=$(jq '.external_finding_count' "$OUT")

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n \
    --arg path "$OUT" \
    --argjson confirm "$CONFIRM" \
    --argjson extend "$EXTEND" \
    --argjson contradict "$CONTRADICT" \
    --argjson orthogonal "$ORTHOGONAL" \
    --argjson coverage_miss "$COVERAGE_MISS" \
    --argjson total_self "$TOTAL_SELF" \
    --argjson total_external "$TOTAL_EXT" \
    '{path: $path, confirm: $confirm, extend: $extend, contradict: $contradict, orthogonal: $orthogonal, coverage_miss: $coverage_miss, total_self: $total_self, total_external: $total_external}'
  exit 0
fi

echo "[reconcile-reviews] Wrote reconciliation to $OUT"
echo "  self-review findings:     $TOTAL_SELF"
echo "    confirm:    $CONFIRM"
echo "    extend:     $EXTEND"
echo "    contradict: $CONTRADICT"
echo "    orthogonal: $ORTHOGONAL"
echo "  external-review findings: $TOTAL_EXT"
echo "    coverage-miss: $COVERAGE_MISS (findings external caught that self missed)"
echo ""
echo "Run 'lore scorecard append' (via task-33 wiring) to feed the derived metrics"
echo "into the self-review template scorecard: external_confirm_rate,"
echo "external_contradict_rate, coverage_miss_rate."
