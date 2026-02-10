#!/usr/bin/env bash
# heal-knowledge.sh — Detect and repair knowledge store structural issues
# Usage: bash heal-knowledge.sh [--fix]
# Default: report-only. With --fix: apply automatic repairs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
FIX=0
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    *) ;;
  esac
done

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "[memory] Error: No knowledge store found." >&2
  exit 1
fi

ISSUES=0
WARNINGS=0

echo "=== Knowledge Heal Report ==="
echo ""

# --- (b) Missing _manifest.json ---
if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  if [[ $FIX -eq 1 ]]; then
    "$SCRIPT_DIR/update-manifest.sh" 2>/dev/null || true
    echo "[heal] Regenerated missing _manifest.json"
    ISSUES=$((ISSUES + 1))
  else
    echo "[heal] Missing _manifest.json — run with --fix to regenerate"
    ISSUES=$((ISSUES + 1))
  fi
fi

# --- (b2) Validate format_version: 2 in _manifest.json ---
if [[ -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  FORMAT_VERSION=$(grep -o '"format_version"[[:space:]]*:[[:space:]]*[0-9]*' "$KNOWLEDGE_DIR/_manifest.json" 2>/dev/null | grep -o '[0-9]*$' || echo "0")
  FORMAT_VERSION=$(echo "$FORMAT_VERSION" | tr -d '[:space:]')
  if [[ "$FORMAT_VERSION" -ne 2 ]]; then
    if [[ $FIX -eq 1 ]]; then
      "$SCRIPT_DIR/update-manifest.sh" 2>/dev/null || true
      echo "[heal] Regenerated _manifest.json with format_version: 2"
      ISSUES=$((ISSUES + 1))
    else
      echo "[heal] _manifest.json has format_version $FORMAT_VERSION (expected 2) — run with --fix to regenerate"
      ISSUES=$((ISSUES + 1))
    fi
  fi
fi

# --- (c) Missing domains/ directory ---
if [[ ! -d "$KNOWLEDGE_DIR/domains" ]]; then
  if [[ $FIX -eq 1 ]]; then
    mkdir -p "$KNOWLEDGE_DIR/domains"
    echo "[heal] Created missing domains/ directory"
    ISSUES=$((ISSUES + 1))
  else
    echo "[heal] Missing domains/ directory — run with --fix to create"
    ISSUES=$((ISSUES + 1))
  fi
fi

# --- (c2) Missing _meta/ directory ---
if [[ ! -d "$KNOWLEDGE_DIR/_meta" ]]; then
  if [[ $FIX -eq 1 ]]; then
    mkdir -p "$KNOWLEDGE_DIR/_meta"
    touch "$KNOWLEDGE_DIR/_meta/.gitkeep"
    echo "[heal] Created missing _meta/ directory"
    ISSUES=$((ISSUES + 1))
  else
    echo "[heal] Missing _meta/ directory — run with --fix to create"
    ISSUES=$((ISSUES + 1))
  fi
fi

# --- (d) Empty category directories (no .md entries) ---
for dir in "$KNOWLEDGE_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  # Skip underscore-prefixed directories (_meta, _inbox, _work, _threads, etc.)
  [[ "$DIRNAME" == _* ]] && continue

  ENTRY_COUNT=$(find "$dir" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [[ "$ENTRY_COUNT" -eq 0 ]]; then
    echo "[heal] Warning: $DIRNAME/ has no entries"
    WARNINGS=$((WARNINGS + 1))
  fi
done

# --- (e) Low-confidence entries older than 90 days ---
NOW_EPOCH=$(date +%s)
NINETY_DAYS=$((90 * 86400))

for dir in "$KNOWLEDGE_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == _* ]] && continue

  for f in "$dir"*.md; do
    [[ -e "$f" ]] || continue
    RELPATH="${f#$KNOWLEDGE_DIR/}"

    # Read HTML comment metadata from individual entry file
    while IFS= read -r line; do
      if [[ "$line" =~ learned:\ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        ENTRY_DATE="${BASH_REMATCH[1]}"
        if [[ "$line" =~ confidence:\ (low|medium) ]]; then
          CONFIDENCE="${BASH_REMATCH[1]}"
          # Parse date to epoch (macOS compatible)
          ENTRY_EPOCH=$(date -j -f "%Y-%m-%d" "$ENTRY_DATE" +%s 2>/dev/null || echo "0")
          if [[ "$ENTRY_EPOCH" -gt 0 ]]; then
            AGE=$((NOW_EPOCH - ENTRY_EPOCH))
            if [[ $AGE -gt $NINETY_DAYS ]]; then
              DAYS=$((AGE / 86400))
              echo "[heal] Warning: $RELPATH has $CONFIDENCE-confidence entry from $ENTRY_DATE (${DAYS}d old) — verify or upgrade"
              WARNINGS=$((WARNINGS + 1))
            fi
          fi
        fi
      fi
    done < "$f"
  done
done

# --- (f) Broken backlinks ---
check_fts_available
if [[ -f "$SCRIPT_DIR/pk_cli.py" ]] && [[ $USE_FTS -eq 1 ]]; then
  LINK_OUTPUT=$(python3 "$SCRIPT_DIR/pk_cli.py" check-links "$KNOWLEDGE_DIR" 2>/dev/null || true)
  if [[ -n "$LINK_OUTPUT" ]]; then
    # Count broken links (lines with "Broken:" prefix)
    BROKEN_COUNT=$(echo "$LINK_OUTPUT" | grep -c "Broken:" 2>/dev/null || echo "0")
    BROKEN_COUNT=$(echo "$BROKEN_COUNT" | tr -d '[:space:]')
    if [[ "$BROKEN_COUNT" -gt 0 ]]; then
      echo "[heal] $BROKEN_COUNT broken backlink(s) found:"
      echo "$LINK_OUTPUT" | grep "Broken:" | head -10 | sed 's/^/  /'
      WARNINGS=$((WARNINGS + BROKEN_COUNT))
    fi
  fi
fi

# --- (g) Stale inbox ---
INBOX_DIR="$KNOWLEDGE_DIR/_inbox"
if [[ -d "$INBOX_DIR" ]]; then
  INBOX_COUNT=$(find "$INBOX_DIR" -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [[ "$INBOX_COUNT" -gt 0 ]]; then
    echo "[heal] Warning: $INBOX_COUNT entries in inbox — run \`/memory curate\` to review"
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# --- (h) Rebuild manifest if fixes were applied ---
if [[ $FIX -eq 1 && $ISSUES -gt 0 ]]; then
  "$SCRIPT_DIR/update-manifest.sh" 2>/dev/null || true
fi

# --- Summary ---
echo ""
if [[ $ISSUES -eq 0 && $WARNINGS -eq 0 ]]; then
  echo "No issues found."
else
  if [[ $ISSUES -gt 0 ]]; then
    if [[ $FIX -eq 1 ]]; then
      echo "Fixed: $ISSUES issues"
    else
      echo "Found: $ISSUES issues (run with --fix to repair)"
    fi
  fi
  if [[ $WARNINGS -gt 0 ]]; then
    echo "Warnings: $WARNINGS items"
  fi
fi
echo ""
echo "=== End Heal Report ==="
