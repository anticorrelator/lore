#!/usr/bin/env bash
# infer-parent-edges.sh — Infer parent edges for a new capture from /spec researcher assertions
#
# Usage:
#   infer-parent-edges.sh --entry <path-to-entry.md> --work-item <slug>
#
# Looks for _research/*.md files under $KDIR/_work/<slug>/_research/.
# For each research file, checks whether any file path from the entry's related_files
# metadata field appears in the research file content. Where overlap exists, the
# research file's basename (without .md) is added as an inferred parent.
#
# When parents are found, writes `inferred_parents: <id1>, <id2>...` into the
# entry's HTML metadata comment block (before the closing -->).
# When no parents found, writes `inferred_parents: none` (makes absence explicit).
#
# Never aborts capture on failure — all errors are warnings only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ENTRY_PATH=""
WORK_ITEM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry)
      ENTRY_PATH="$2"
      shift 2
      ;;
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    *)
      echo "[infer-parent-edges] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ENTRY_PATH" || -z "$WORK_ITEM" ]]; then
  echo "[infer-parent-edges] --entry and --work-item are required" >&2
  exit 1
fi

if [[ ! -f "$ENTRY_PATH" ]]; then
  echo "[infer-parent-edges] Entry not found: $ENTRY_PATH" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
RESEARCH_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM/_research"

if [[ ! -d "$RESEARCH_DIR" ]]; then
  exit 0
fi

# Extract related_files from the metadata comment
RELATED_FILES=$(grep -o 'related_files: [^|>]*' "$ENTRY_PATH" | head -1 | sed 's/related_files: //' | tr -d ' ')

if [[ -z "$RELATED_FILES" ]]; then
  exit 0
fi

# Split related_files on commas into an array
IFS=',' read -ra FILE_LIST <<< "$RELATED_FILES"

# Collect inferred parents from research files
PARENTS=()
while IFS= read -r -d '' research_file; do
  assertion_id=$(basename "$research_file" .md)
  matched=0
  for rel_file in "${FILE_LIST[@]}"; do
    rel_file="${rel_file// /}"
    [[ -z "$rel_file" ]] && continue
    # Strip leading path components for a basename match too, to handle partial paths
    basename_part=$(basename "$rel_file")
    if grep -qF "$rel_file" "$research_file" 2>/dev/null || grep -qF "$basename_part" "$research_file" 2>/dev/null; then
      matched=1
      break
    fi
  done
  if [[ $matched -eq 1 ]]; then
    PARENTS+=("$assertion_id")
  fi
done < <(find "$RESEARCH_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)

# Build the inferred_parents value
if [[ ${#PARENTS[@]} -eq 0 ]]; then
  PARENTS_VALUE="none"
else
  PARENTS_VALUE=$(printf "%s, " "${PARENTS[@]}")
  PARENTS_VALUE="${PARENTS_VALUE%, }"
fi

# Inject inferred_parents into the metadata comment (before the closing -->)
# The comment is a single line ending with -->
sed -i '' "s/ -->$/ | inferred_parents: ${PARENTS_VALUE} -->/" "$ENTRY_PATH"
