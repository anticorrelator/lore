#!/usr/bin/env bash
# renormalize-plan.sh — Apply a renormalize-plan.json action set
#
# Usage:
#   renormalize-plan.sh --plan <path> --action <action> [--kdir <kdir>]
#
# Supported actions:
#   rescale        — edit scale: field in entry META block
#   status-update  — edit status: field in entry META block
#   relabel        — rename a scale label in scale-registry.json (no entry file changes)
#
# Other actions (prune, fix, merge, demote, consolidate, restructure, backlink) are
# handled by the Wave 1/Wave 2 agents in SKILL.md — this script handles the three
# new META-field actions added in task-42.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PLAN=""
ACTION=""
KDIR=""

usage() {
  cat >&2 <<EOF
Usage: renormalize-plan.sh --plan <path-to-renormalize-plan.json> --action <action> [--kdir <kdir>]
Actions: rescale | status-update | relabel | apply-all
  apply-all — runs relabels first, then batched rescales, emits summary line
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)   PLAN="$2";   shift 2 ;;
    --action) ACTION="$2"; shift 2 ;;
    --kdir)   KDIR="$2";   shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$PLAN" || -z "$ACTION" ]]; then
  echo "Error: --plan and --action are required" >&2
  usage
  exit 1
fi

if [[ ! -f "$PLAN" ]]; then
  echo "Error: plan file not found: $PLAN" >&2
  exit 1
fi

if [[ -z "$KDIR" ]]; then
  KDIR=$(resolve_knowledge_dir)
fi

# ---------------------------------------------------------------------------
# edit_meta_field <file> <field> <old_value> <new_value>
#
# Replaces "| field: old_value |" with "| field: new_value |" in the HTML
# comment META block at the bottom of an entry file. Also handles the end-of-
# comment case: "| field: old_value -->".
# ---------------------------------------------------------------------------
edit_meta_field() {
  local file="$1" field="$2" old_val="$3" new_val="$4"

  if [[ ! -f "$file" ]]; then
    echo "  SKIP (file not found): $file" >&2
    return 1
  fi

  # Replace in-place; exit code 0 = changed, 2 = field not found, 1 = other error
  python3 - "$file" "$field" "$old_val" "$new_val" <<'PYEOF'
import re, sys
path, field, old_val, new_val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()

# Match: "| field: old_val |" (mid-block) or "| field: old_val -->" (last field in comment)
# The end-of-HTML-comment is ' -->' (space then -->), mid-block delimiter is ' |' (space then pipe)
pattern = r'(\| ' + re.escape(field) + r': )' + re.escape(old_val) + r'( \|| -->)'
replacement = r'\g<1>' + new_val + r'\2'
new_content, count = re.subn(pattern, replacement, content)
if count == 0:
    sys.exit(2)
with open(path, 'w') as f:
    f.write(new_content)
PYEOF

  local rc=$?
  if [[ $rc -eq 2 ]]; then
    echo "  SKIP (field '${field}: ${old_val}' not found): $file" >&2
    return 1
  elif [[ $rc -ne 0 ]]; then
    echo "  ERROR editing $file (exit $rc)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Action: rescale
# Reads plan["rescale"] array; each item: {entry_id, from_scale, to_scale, reason}
# ---------------------------------------------------------------------------
do_rescale() {
  local total=0 ok=0 skipped=0

  python3 -c "
import json, sys
plan = json.load(open('$PLAN'))
items = plan.get('rescale', [])
for it in items:
    print(it['entry_id'] + '\t' + it.get('from_scale','') + '\t' + it['to_scale'] + '\t' + it.get('reason',''))
" | while IFS=$'\t' read -r entry_id from_scale to_scale reason; do
    total=$((total + 1))
    file="$KDIR/$entry_id"
    if edit_meta_field "$file" "scale" "$from_scale" "$to_scale"; then
      echo "  rescaled: $entry_id  ($from_scale -> $to_scale)"
      ok=$((ok + 1))
    else
      skipped=$((skipped + 1))
    fi
  done

  echo "[rescale] done."
}

# ---------------------------------------------------------------------------
# Action: status-update
# Reads plan["status_updates"] array; each item: {entry_id, from_status, to_status, [successor_entry_id], reason}
# ---------------------------------------------------------------------------
do_status_update() {
  python3 -c "
import json, sys
plan = json.load(open('$PLAN'))
items = plan.get('status_updates', [])
for it in items:
    succ = it.get('successor_entry_id', '')
    print(it['entry_id'] + '\t' + it.get('from_status','current') + '\t' + it['to_status'] + '\t' + succ + '\t' + it.get('reason',''))
" | while IFS=$'\t' read -r entry_id from_status to_status successor reason; do
    file="$KDIR/$entry_id"
    if edit_meta_field "$file" "status" "$from_status" "$to_status"; then
      msg="  status-updated: $entry_id  ($from_status -> $to_status)"
      if [[ -n "$successor" ]]; then
        msg="$msg  [successor: $successor]"
      fi
      echo "$msg"
    fi
  done

  echo "[status-update] done."
}

# ---------------------------------------------------------------------------
# Action: relabel
# Reads plan["relabels"] array; each item: {scale_id, current_label, new_label, reason}
# Delegates to scale-registry.sh relabel — no entry file changes.
# ---------------------------------------------------------------------------
do_relabel() {
  python3 -c "
import json, sys
plan = json.load(open('$PLAN'))
items = plan.get('relabels', [])
for it in items:
    print(it['scale_id'] + '\t' + it.get('current_label','') + '\t' + it['new_label'] + '\t' + it.get('reason',''))
" | while IFS=$'\t' read -r scale_id current_label new_label reason; do
    echo "  relabeling '$scale_id': '$current_label' -> '$new_label'"
    "$SCRIPT_DIR/scale-registry.sh" relabel "$scale_id" --new-label "$new_label"
  done

  echo "[relabel] done."
}

# ---------------------------------------------------------------------------
# Action: apply-all
# Applies relabels first (registry-only), then batched rescales (entry META edits).
# Emits summary line: "Label revisions: N | Batched rescales: N"
# ---------------------------------------------------------------------------
do_apply_all() {
  # Count items from plan for summary
  read -r relabel_count rescale_count < <(python3 -c "
import json, sys
plan = json.load(open('$PLAN'))
print(len(plan.get('relabels', [])), len(plan.get('rescale', [])))
")

  local relabel_ok=0 rescale_ok=0

  # Step 1: relabels (registry-only, no entry file changes)
  if [[ $relabel_count -gt 0 ]]; then
    python3 -c "
import json, sys
plan = json.load(open('$PLAN'))
items = plan.get('relabels', [])
for it in items:
    print(it['scale_id'] + '\t' + it.get('current_label','') + '\t' + it['new_label'] + '\t' + it.get('reason',''))
" | while IFS=$'\t' read -r scale_id current_label new_label reason; do
      echo "  relabeling '$scale_id': '$current_label' -> '$new_label'"
      if "$SCRIPT_DIR/scale-registry.sh" relabel "$scale_id" --new-label "$new_label"; then
        relabel_ok=$((relabel_ok + 1))
      fi
    done
  fi

  # Step 2: batched rescales (entry META scale: field edits, ordered)
  if [[ $rescale_count -gt 0 ]]; then
    python3 -c "
import json, sys
plan = json.load(open('$PLAN'))
items = plan.get('rescale', [])
for it in items:
    print(it['entry_id'] + '\t' + it.get('from_scale','') + '\t' + it['to_scale'] + '\t' + it.get('reason',''))
" | while IFS=$'\t' read -r entry_id from_scale to_scale reason; do
      file="$KDIR/$entry_id"
      if edit_meta_field "$file" "scale" "$from_scale" "$to_scale"; then
        echo "  rescaled: $entry_id  ($from_scale -> $to_scale)"
        rescale_ok=$((rescale_ok + 1))
      fi
    done
  fi

  echo ""
  echo "Label revisions: ${relabel_count} | Batched rescales: ${rescale_count}"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$ACTION" in
  rescale)        do_rescale ;;
  status-update)  do_status_update ;;
  relabel)        do_relabel ;;
  apply-all)      do_apply_all ;;
  *)
    echo "Error: unsupported action '$ACTION'" >&2
    echo "Supported: rescale | status-update | relabel | apply-all" >&2
    exit 1
    ;;
esac
