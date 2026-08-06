#!/usr/bin/env bash
# generate-index.sh — Dynamically walk category directories and output a knowledge index
# Usage: bash generate-index.sh [directory] [--category <name>]
# Replaces static _index.md with on-demand directory walking.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TARGET_DIR=""
FILTER_CATEGORY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --category)
      FILTER_CATEGORY="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: lore index [--category <name>]" >&2
      echo "  Walks category directories and prints entry titles + summaries." >&2
      echo "  --category <name>  Show only entries in this category" >&2
      exit 0
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="$(pwd)"
fi

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found at: $KNOWLEDGE_DIR" >&2
  exit 1
fi

# Category directories in priority order. The list is a display ORDER, not a
# closed set: any other category directory in the store is appended after it,
# so a category added to the taxonomy can never be silently dropped from the
# index (the previous hardcoded list omitted `preferences` and
# `design-rationale` entirely). Directories that do not exist are skipped
# below, so listing a not-yet-created category costs nothing.
CATEGORY_ORDER=(principles workflows conventions architecture preferences gotchas design-rationale abstractions domains team)

CATEGORIES=()
for category in "${CATEGORY_ORDER[@]}"; do
  [[ -d "$KNOWLEDGE_DIR/$category" ]] && CATEGORIES+=("$category")
done
# Append any category directory not named in the order list (skip the store's
# internal `_`-prefixed and dotted directories, which are not knowledge).
while IFS= read -r discovered; do
  [[ -n "$discovered" ]] || continue
  for known in "${CATEGORY_ORDER[@]}"; do
    [[ "$discovered" == "$known" ]] && continue 2
  done
  CATEGORIES+=("$discovered")
done < <(find "$KNOWLEDGE_DIR" -mindepth 1 -maxdepth 1 -type d \
  ! -name '_*' ! -name '.*' -exec basename {} \; 2>/dev/null | sort)

for category in "${CATEGORIES[@]}"; do
  # Apply category filter if specified
  if [[ -n "$FILTER_CATEGORY" && "$category" != "$FILTER_CATEGORY" ]]; then
    continue
  fi

  cat_dir="$KNOWLEDGE_DIR/$category"

  # Entries live in category SUBDIRECTORIES since the April restructure, so
  # this walk is recursive. The previous non-recursive `$cat_dir/*.md` glob
  # under-reported the store by roughly 11x and listed only the handful of
  # entries that happened to sit at the category root.
  entry_files=()
  while IFS= read -r -d '' f; do
    entry_files+=("$f")
  done < <(find "$cat_dir" -type f -name '*.md' -print0 2>/dev/null | sort -z)

  entry_count=${#entry_files[@]}
  if [[ "$entry_count" -eq 0 ]]; then
    continue
  fi

  echo "## $category ($entry_count entries)"
  echo ""

  # Title + summary + meta-comment extraction runs as ONE awk pass over the
  # whole category, not the ~8 forks per entry (head x2, awk, grep x3, sed, tr,
  # xargs) the per-file loop used. At depth-1 that cost was invisible — 82
  # entries. Once the walk went recursive it dominated: 1173 entries took ~59s,
  # which makes `lore index` unusable as an interactive command. Same batching
  # already applied to the session-start index in load-knowledge.sh.
  #
  # Record shape: <path>US<title>US<summary>US<meta-comment>, US = \x1f (a
  # control byte that cannot occur in markdown). The parent-edge parsing stays
  # in shell but is gated on the record actually mentioning `parents:` — the
  # ungated path returned empty for every other entry anyway, so the gate is
  # behavior-preserving and skips the forks for ~99% of the store.
  while IFS=$'\x1f' read -r filepath title summary meta; do
    [[ -n "$filepath" ]] || continue

    # Truncate in bash, not awk: `${#s}`/`${s:0:117}` count characters under a
    # UTF-8 locale, while this platform's awk length()/substr() count bytes and
    # split multibyte characters mid-sequence. Both are builtins, so the fork
    # count is unchanged.
    if [[ ${#summary} -gt 120 ]]; then
      summary="${summary:0:117}..."
    fi

    # Retired entries stay listed, annotated. Browsing is where an agent goes
    # looking for what search would not return, so dropping them here would
    # make retirement read as deletion. The date is the most recent
    # retirements[] item's; entries retired before that array existed, or whose
    # reason text confuses the scan, degrade to a bare "[retired]".
    retired_tag=""
    if [[ "$meta" == *"status: retired"* ]]; then
      retired_tag=" [retired]"
      if [[ "$meta" == *"retirements: ["* ]]; then
        retirements="${meta#*retirements: [}"
        retirements="${retirements%%]*}"
        if [[ "$retirements" == *'"date": "'* ]]; then
          retired_date="${retirements##*'"date": "'}"
          retired_date="${retired_date%%\"*}"
          [[ -n "$retired_date" ]] && retired_tag=" [retired $retired_date]"
        fi
      fi
    fi

    if [[ -n "$summary" ]]; then
      echo "- **$title**$retired_tag — $summary"
    else
      echo "- **$title**$retired_tag"
    fi

    # Extract and render parent edges distinctly (explicit vs inferred)
    if [[ "$meta" == *"parents:"* ]]; then
      explicit_parents=$(echo "$meta" | grep -o '[^_]parents: [^|>]*' 2>/dev/null | grep -v 'inferred' | sed 's/[^ ]*parents: //' | tr -d ' ' || true)
      inferred_parents=$(echo "$meta" | grep -o 'inferred_parents: [^|]*' 2>/dev/null | sed 's/inferred_parents: //' | sed 's/[[:space:]]*-->$//' | xargs 2>/dev/null || true)
      if [[ -n "$explicit_parents" && "$explicit_parents" != "none" ]]; then
        echo "  - Parents (explicit): $explicit_parents"
      fi
      if [[ -n "$inferred_parents" && "$inferred_parents" != "none" ]]; then
        echo "  - Parents (inferred): $inferred_parents"
      fi
    fi
  done < <(awk -v SEP=$'\x1f' '
    function emit() {
      if (cur == "") return
      printf "%s%s%s%s%s%s%s\n", cur, SEP, title, SEP, summary, SEP, meta
    }
    FNR == 1 {
      emit()
      cur = FILENAME; meta = ""; summary = ""; have_summary = 0
      # H1 title, else filename stem — mirrors the `sed "s/^# //"` +
      # unchanged-line test the per-file path used.
      title = (substr($0, 1, 2) == "# ") ? substr($0, 3) : ""
      if (title == "") {
        n = split(FILENAME, parts, "/"); title = parts[n]; sub(/\.md$/, "", title)
      }
    }
    {
      # First complete <!-- ... --> on any line, including line 1.
      if (meta == "" && match($0, /<!--.*-->/)) meta = substr($0, RSTART, RLENGTH)
      # First non-blank, non-comment, non-"See also:" line after the H1.
      if (FNR > 1 && !have_summary && $0 !~ /^[ \t]*$/ && $0 !~ /^<!--/ && $0 !~ /^See also:/) {
        summary = $0
        have_summary = 1
      }
    }
    END { emit() }
  ' "${entry_files[@]}")

  # A zero-length entry file never reaches awk (no FNR==1 record), so those are
  # listed here with the same filename fallback the per-file path produced.
  # Order within the category is otherwise preserved; a contentless entry is a
  # broken entry, and surfacing it at all beats dropping it from the listing.
  for filepath in "${entry_files[@]}"; do
    [[ -s "$filepath" ]] && continue
    fname=$(basename "$filepath")
    echo "- **${fname%.md}**"
  done

  echo ""
done
