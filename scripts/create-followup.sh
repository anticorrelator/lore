#!/usr/bin/env bash
# create-followup.sh — Create a new follow-up artifact in _followups/
# Usage: bash create-followup.sh --title <name> --source <agent>
#   [--attachments <json-array>] [--suggested-actions <json-array>]
#   [--proposed-comments <filepath>] [--lens-findings <filepath>]
#   [--content <body>] [--json]
#   [--pr <number>] [--owner <owner>] [--repo <repo>] [--head-sha <sha>]
#   [--producer-role <role>] [--protocol-slot <slot>] [--template-version <hash>]
#   [--capturer-role <role>] [--source-artifact-ids <csv>]
#   [--captured-at-branch <name>] [--captured-at-sha <sha>] [--captured-at-merge-base-sha <sha>]
# Creates $KNOWLEDGE_DIR/_followups/<id>/ with _meta.json and finding.md
# When --pr/--owner/--repo/--head-sha are all provided with --proposed-comments,
# the sidecar is written in ProposedReview wrapper format.
#
# Provenance flags (Phase 2 — work item 02-durable-signal-foundation):
#   --producer-role         Role of the agent that produced the followup (e.g., researcher, worker, lead).
#   --protocol-slot         Protocol slot in which the followup emerged (e.g., review, capture, synthesis).
#   --template-version      Template-version hash of the producing agent template (see scripts/template-version.sh).
#   --capturer-role         Role of the agent writing this followup (set only when different from producer — lead-synthesis path).
#   --source-artifact-ids   Comma-separated artifact IDs the followup synthesizes from (lead-synthesis path).
#
# Branch-provenance flags (task 7 — always emitted):
#   --captured-at-branch          Branch at capture time. Defaults to local git resolution; falls back to JSON null.
#   --captured-at-sha             HEAD commit SHA at capture time. Defaults to local git resolution; falls back to JSON null.
#   --captured-at-merge-base-sha  Merge-base against origin/main. Defaults to local git resolution; falls back to JSON null.
#
# Propagation rules:
#   * Non-empty provenance flags are emitted as top-level fields in _meta.json.
#     Omitted or empty flags are OMITTED entirely — legacy followups remain field-identical.
#   * When --lens-findings is provided, each finding is enriched with any CLI-provided
#     provenance field that the finding does not already carry. Per-finding values win
#     over CLI defaults to support lead-synthesis followups where individual findings
#     retain their original producer's attribution.
#   * The branch-provenance trio is always emitted in _meta.json (JSON string or null).
#     It is NOT propagated into per-finding enrichment — findings inherit their branch
#     context from the followup itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
TITLE=""
SOURCE=""
AUTHOR=""
ATTACHMENTS="[]"
SUGGESTED_ACTIONS="[]"
PROPOSED_COMMENTS=""
LENS_FINDINGS=""
CONTENT=""
JSON_MODE=0
PR_NUMBER=""
PR_OWNER=""
PR_REPO=""
PR_HEAD_SHA=""
PRODUCER_ROLE=""
PROTOCOL_SLOT=""
TEMPLATE_VERSION=""
CAPTURER_ROLE=""
SOURCE_ARTIFACT_IDS=""
CAPTURED_AT_BRANCH=""
CAPTURED_AT_SHA=""
CAPTURED_AT_MERGE_BASE_SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      TITLE="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --author)
      AUTHOR="$2"
      shift 2
      ;;
    --attachments)
      ATTACHMENTS="$2"
      shift 2
      ;;
    --suggested-actions)
      SUGGESTED_ACTIONS="$2"
      shift 2
      ;;
    --proposed-comments)
      PROPOSED_COMMENTS="$2"
      shift 2
      ;;
    --lens-findings)
      LENS_FINDINGS="$2"
      shift 2
      ;;
    --content)
      CONTENT="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --pr)
      PR_NUMBER="$2"
      shift 2
      ;;
    --owner)
      PR_OWNER="$2"
      shift 2
      ;;
    --repo)
      PR_REPO="$2"
      shift 2
      ;;
    --head-sha)
      PR_HEAD_SHA="$2"
      shift 2
      ;;
    --producer-role)
      PRODUCER_ROLE="$2"
      shift 2
      ;;
    --protocol-slot)
      PROTOCOL_SLOT="$2"
      shift 2
      ;;
    --template-version)
      TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --capturer-role)
      CAPTURER_ROLE="$2"
      shift 2
      ;;
    --source-artifact-ids)
      SOURCE_ARTIFACT_IDS="$2"
      shift 2
      ;;
    --captured-at-branch)
      CAPTURED_AT_BRANCH="$2"
      shift 2
      ;;
    --captured-at-sha)
      CAPTURED_AT_SHA="$2"
      shift 2
      ;;
    --captured-at-merge-base-sha)
      CAPTURED_AT_MERGE_BASE_SHA="$2"
      shift 2
      ;;
    *)
      echo "[followup] Error: Unknown flag '$1'" >&2
      echo "Usage: create-followup.sh --title <name> --source <agent> [--attachments <json>] [--suggested-actions <json>] [--proposed-comments <filepath>] [--lens-findings <filepath>] [--content <body>] [--json] [--pr <number> --owner <owner> --repo <repo> --head-sha <sha>] [--producer-role <role>] [--protocol-slot <slot>] [--template-version <hash>] [--capturer-role <role>] [--source-artifact-ids <csv>] [--captured-at-branch <name>] [--captured-at-sha <sha>] [--captured-at-merge-base-sha <sha>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TITLE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing --title"
  fi
  echo "[followup] Error: Missing --title." >&2
  exit 1
fi

# Warn on long titles (>70 chars, git convention)
if [[ ${#TITLE} -gt 70 ]]; then
  echo "[followup] Warning: Title is ${#TITLE} chars (recommended ≤70)." >&2
fi

if [[ -z "$SOURCE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing --source"
  fi
  echo "[followup] Error: Missing --source." >&2
  exit 1
fi

# All-or-nothing validation: PR metadata flags must all be present together
# when --proposed-comments is also provided
PR_FLAGS_SET=0
PR_FLAGS_MISSING=0
for _flag in "$PR_NUMBER" "$PR_OWNER" "$PR_REPO" "$PR_HEAD_SHA"; do
  if [[ -n "$_flag" ]]; then
    PR_FLAGS_SET=$((PR_FLAGS_SET + 1))
  else
    PR_FLAGS_MISSING=$((PR_FLAGS_MISSING + 1))
  fi
done
if [[ $PR_FLAGS_SET -gt 0 && $PR_FLAGS_MISSING -gt 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "PR metadata flags --pr, --owner, --repo, --head-sha must all be provided together"
  fi
  echo "[followup] Error: PR metadata flags --pr, --owner, --repo, --head-sha must all be provided together." >&2
  exit 1
fi
if [[ $PR_FLAGS_SET -eq 4 && -z "$PROPOSED_COMMENTS" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "PR metadata flags require --proposed-comments"
  fi
  echo "[followup] Error: PR metadata flags require --proposed-comments." >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"

# Initialize _followups/ if it doesn't exist
if [[ ! -d "$FOLLOWUPS_DIR" ]]; then
  mkdir -p "$FOLLOWUPS_DIR"
fi

# Generate readable slug; append numeric suffix (-2, -3, ...) on collision.
TIMESTAMP=$(timestamp_iso)
TITLE_SLUG=$(slugify "$TITLE")
ID="$TITLE_SLUG"

if [[ -d "$FOLLOWUPS_DIR/$ID" ]]; then
  N=2
  while [[ -d "$FOLLOWUPS_DIR/${TITLE_SLUG}-${N}" ]]; do
    N=$((N + 1))
  done
  ID="${TITLE_SLUG}-${N}"
fi

ITEM_DIR="$FOLLOWUPS_DIR/$ID"

mkdir -p "$ITEM_DIR"

# Escape strings for JSON using python3
escape_json() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

TITLE_JSON=$(escape_json "$TITLE")
SOURCE_JSON=$(escape_json "$SOURCE")
AUTHOR_JSON=$(escape_json "$AUTHOR")

# Build provenance field fragment for _meta.json (omitted-field convention: only
# non-empty flags produce JSON keys; legacy callers that omit all flags get a
# byte-identical _meta.json to pre-Phase-2 output).
PROVENANCE_META=$(python3 -c '
import json, sys
fields = [
    ("producer_role", sys.argv[1]),
    ("protocol_slot", sys.argv[2]),
    ("template_version", sys.argv[3]),
    ("capturer_role", sys.argv[4]),
    ("source_artifact_ids", sys.argv[5]),
]
out = []
for key, val in fields:
    if val:
        out.append(",\n  {}: {}".format(json.dumps(key), json.dumps(val)))
sys.stdout.write("".join(out))
' "$PRODUCER_ROLE" "$PROTOCOL_SLOT" "$TEMPLATE_VERSION" "$CAPTURER_ROLE" "$SOURCE_ARTIFACT_IDS")

# Branch-provenance trio (always emitted — resolve from git when caller did not
# pass an explicit value; fall back to JSON null on any git failure).
if [[ -z "$CAPTURED_AT_BRANCH" ]]; then
  _resolved_branch=$(captured_at_branch)
  if [[ "$_resolved_branch" != "null" ]]; then
    CAPTURED_AT_BRANCH="$_resolved_branch"
  fi
fi
if [[ -z "$CAPTURED_AT_SHA" ]]; then
  _resolved_sha=$(captured_at_sha)
  if [[ "$_resolved_sha" != "null" ]]; then
    CAPTURED_AT_SHA="$_resolved_sha"
  fi
fi
if [[ -z "$CAPTURED_AT_MERGE_BASE_SHA" ]]; then
  _resolved_mb=$(captured_at_merge_base_sha)
  if [[ "$_resolved_mb" != "null" ]]; then
    CAPTURED_AT_MERGE_BASE_SHA="$_resolved_mb"
  fi
fi

BRANCH_META=$(python3 -c '
import json, sys
fields = [
    ("captured_at_branch", sys.argv[1]),
    ("captured_at_sha", sys.argv[2]),
    ("captured_at_merge_base_sha", sys.argv[3]),
]
out = []
for key, val in fields:
    out.append(",\n  {}: {}".format(json.dumps(key), json.dumps(val) if val else "null"))
sys.stdout.write("".join(out))
' "$CAPTURED_AT_BRANCH" "$CAPTURED_AT_SHA" "$CAPTURED_AT_MERGE_BASE_SHA")

# Write _meta.json
cat > "$ITEM_DIR/_meta.json" << METAEOF
{
  "id": "$ID",
  "title": $TITLE_JSON,
  "source": $SOURCE_JSON,
  "author": $AUTHOR_JSON,
  "status": "open",
  "attachments": $ATTACHMENTS,
  "suggested_actions": $SUGGESTED_ACTIONS,
  "created": "$TIMESTAMP",
  "updated": "$TIMESTAMP"$PROVENANCE_META$BRANCH_META
}
METAEOF

# Write finding.md
if [[ -n "$CONTENT" ]]; then
  cat > "$ITEM_DIR/finding.md" << FINDINGEOF
# $TITLE

$CONTENT
FINDINGEOF
else
  cat > "$ITEM_DIR/finding.md" << FINDINGEOF
# $TITLE

<!-- Add finding details here. -->
FINDINGEOF
fi

# Write proposed-comments.json sidecar (accepts filepath or inline JSON)
if [[ -n "$PROPOSED_COMMENTS" ]]; then
  # Resolve the raw comments array first
  if [[ -f "$PROPOSED_COMMENTS" ]]; then
    _raw_comments=$(cat "$PROPOSED_COMMENTS")
  elif printf '%s' "$PROPOSED_COMMENTS" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    _raw_comments="$PROPOSED_COMMENTS"
  else
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "Proposed comments: not a valid file path or JSON"
    fi
    echo "[followup] Error: --proposed-comments is neither a valid file path nor valid JSON" >&2
    exit 1
  fi

  if [[ $PR_FLAGS_SET -eq 4 ]]; then
    # Wrap in ProposedReview format when all PR metadata flags are provided
    # Write raw comments to a temp file, then wrap via Python to avoid quoting issues
    _tmp_comments=$(mktemp)
    printf '%s\n' "$_raw_comments" > "$_tmp_comments"
    python3 - "$_tmp_comments" "$ITEM_DIR/proposed-comments.json" \
      "$PR_NUMBER" "$PR_OWNER" "$PR_REPO" "$PR_HEAD_SHA" << 'PYEOF'
import json, sys
comments_path, out_path, pr_number, owner, repo, head_sha = sys.argv[1:]
try:
    pr_number_int = int(pr_number)
except ValueError:
    print(f"[followup] Error: --pr must be a number, got: {pr_number!r}", file=sys.stderr)
    sys.exit(1)
with open(comments_path) as f:
    comments = json.load(f)
wrapper = {
    "pr": pr_number_int,
    "owner": owner,
    "repo": repo,
    "head_sha": head_sha,
    "comments": comments,
}
with open(out_path, "w") as f:
    json.dump(wrapper, f, indent=2)
    f.write("\n")
PYEOF
    rm -f "$_tmp_comments"
  else
    # Bare-array behavior when no PR flags
    printf '%s\n' "$_raw_comments" > "$ITEM_DIR/proposed-comments.json"
  fi
fi

# Write lens-findings.json sidecar (accepts filepath or inline JSON)
if [[ -n "$LENS_FINDINGS" ]]; then
  if [[ -f "$LENS_FINDINGS" ]]; then
    _lf_raw=$(cat "$LENS_FINDINGS")
  elif printf '%s' "$LENS_FINDINGS" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    _lf_raw="$LENS_FINDINGS"
  else
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "Lens findings: not a valid file path or JSON"
    fi
    echo "[followup] Error: --lens-findings is neither a valid file path nor valid JSON" >&2
    exit 1
  fi

  # Validate lens-findings contract: no disposition, grounding required for
  # blocking/suggestion, selected boolean required on every finding.
  _lf_err_file=$(mktemp)
  _lf_ok=0
  printf '%s' "$_lf_raw" | python3 -c '
import json, sys

data = json.load(sys.stdin)
findings = data.get("findings", [])
errors = []

for i, f in enumerate(findings):
    label = "finding[{}] ({})".format(i, f.get("title", "(no title)"))
    if "disposition" in f:
        errors.append("{}: contains retired \"disposition\" field — update producer to use grounding+selected".format(label))
    sev = f.get("severity", "")
    if sev in ("blocking", "suggestion"):
        grounding = f.get("grounding", "")
        if not grounding or not grounding.strip():
            errors.append("{}: severity \"{}\" requires a non-empty \"grounding\" field".format(label, sev))
    if "selected" not in f:
        errors.append("{}: missing required \"selected\" boolean field".format(label))
    elif not isinstance(f["selected"], bool):
        errors.append("{}: \"selected\" must be a boolean (true/false), got {}".format(label, type(f["selected"]).__name__))

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
' > "$_lf_err_file" 2>&1 || _lf_ok=$?
  if [[ $_lf_ok -ne 0 ]]; then
    _lf_errors=$(cat "$_lf_err_file")
    rm -f "$_lf_err_file"
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "Lens findings validation failed: $_lf_errors"
    fi
    echo "[followup] Error: lens-findings validation failed:" >&2
    printf '%s\n' "$_lf_errors" >&2
    exit 1
  fi
  rm -f "$_lf_err_file"

  # When any provenance flag is non-empty, enrich each finding with the CLI-provided
  # fields it does not already carry. Per-finding values win over CLI defaults so
  # lead-synthesis followups can preserve each finding's original producer attribution.
  # When no provenance flags are set, pass through the raw payload byte-identically to
  # keep legacy callers' output unchanged.
  if [[ -n "$PRODUCER_ROLE" || -n "$PROTOCOL_SLOT" || -n "$TEMPLATE_VERSION" \
        || -n "$CAPTURER_ROLE" || -n "$SOURCE_ARTIFACT_IDS" ]]; then
    _lf_tmp=$(mktemp)
    printf '%s' "$_lf_raw" > "$_lf_tmp"
    python3 - "$_lf_tmp" "$ITEM_DIR/lens-findings.json" \
      "$PRODUCER_ROLE" "$PROTOCOL_SLOT" "$TEMPLATE_VERSION" \
      "$CAPTURER_ROLE" "$SOURCE_ARTIFACT_IDS" << 'PYEOF'
import json, sys
raw_path, out_path, producer, slot, template, capturer, artifacts = sys.argv[1:]
with open(raw_path) as f:
    data = json.load(f)
defaults = [
    ("producer_role", producer),
    ("protocol_slot", slot),
    ("template_version", template),
    ("capturer_role", capturer),
    ("source_artifact_ids", artifacts),
]
for finding in data.get("findings", []):
    for key, val in defaults:
        if val and key not in finding:
            finding[key] = val
with open(out_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    rm -f "$_lf_tmp"
  else
    printf '%s\n' "$_lf_raw" > "$ITEM_DIR/lens-findings.json"
  fi
fi

# Update the followup index
if [[ -x "$SCRIPT_DIR/update-followup-index.sh" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    bash "$SCRIPT_DIR/update-followup-index.sh" > /dev/null 2>&1 || true
    json_output "$(cat "$ITEM_DIR/_meta.json")"
  else
    bash "$SCRIPT_DIR/update-followup-index.sh"
  fi
else
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(cat "$ITEM_DIR/_meta.json")"
  fi
fi

echo "Created follow-up '$TITLE' at $ITEM_DIR"
