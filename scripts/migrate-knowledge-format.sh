#!/usr/bin/env bash
# migrate-knowledge-format.sh — Migrate monolithic .md files to file-per-entry directories
# Usage: bash migrate-knowledge-format.sh [--dry-run]
# Splits each category .md (e.g., conventions.md) on ### headings into
# individual <category>/<slug>.md files. Backs up originals, removes _index.md,
# updates format_version to 2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) ;;
  esac
done

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  die "No knowledge store found at: $KNOWLEDGE_DIR"
fi

# Check format_version — only migrate from version 1
# Use grep to avoid JSON parsing issues with invalid manifests
HAS_V2=$(grep -c '"format_version": 2' "$KNOWLEDGE_DIR/_manifest.json" 2>/dev/null || echo "0")
HAS_V2=$(echo "$HAS_V2" | tr -d '[:space:]')
if [[ "$HAS_V2" -gt 0 ]]; then
  echo "[migrate] Knowledge store is already format_version 2 — nothing to do."
  exit 0
fi

# --- Identify files to migrate ---
# Monolithic category files at the root (not prefixed with _, not in subdirs)
MIGRATE_FILES=()
for f in "$KNOWLEDGE_DIR"/*.md; do
  [[ -e "$f" ]] || continue
  BASENAME=$(basename "$f")
  # Skip underscore-prefixed files (_index.md, _inbox.md, _self_test_results.md, etc.)
  [[ "$BASENAME" == _* ]] && continue
  MIGRATE_FILES+=("$f")
done

if [[ ${#MIGRATE_FILES[@]} -eq 0 ]]; then
  echo "[migrate] No monolithic category files found to migrate."
  exit 0
fi

echo "=== Knowledge Store Migration: v1 → v2 ==="
echo ""
echo "Knowledge store: $KNOWLEDGE_DIR"
echo "Files to migrate: ${#MIGRATE_FILES[@]}"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Mode: DRY RUN (no changes will be written)"
fi
echo ""

# --- Python does all the heavy lifting ---
# Parse markdown, split entries, write files (or report dry-run)
# Build file list as newline-separated env var (avoids heredoc+argv conflict)
MIGRATE_LIST=$(printf '%s\n' "${MIGRATE_FILES[@]}")
export MIGRATE_LIST
export KNOWLEDGE_DIR
export DRY_RUN

python3 << 'PYEOF'
import sys, re, os

def slugify(text, max_len=60):
    s = text.lower()
    s = re.sub(r'[^a-z0-9]', '-', s)
    s = re.sub(r'-+', '-', s)
    s = s.strip('-')
    return s[:max_len]

knowledge_dir = os.environ['KNOWLEDGE_DIR']
dry_run = os.environ['DRY_RUN'] == "1"
files = [f for f in os.environ['MIGRATE_LIST'].split('\n') if f]

entries = []  # (source_basename, category, slug, title, content)
slug_counts = {}  # category/slug -> count for dedup

for filepath in files:
    basename = os.path.basename(filepath)
    category = os.path.splitext(basename)[0]

    with open(filepath, 'r') as f:
        lines = f.readlines()

    # Parse entries, skipping ### inside fenced code blocks
    in_fence = False
    current_title = None
    current_body = []
    raw_entries = []  # (title, body_text)

    for line in lines:
        stripped = line.rstrip('\n')
        if stripped.startswith('```'):
            in_fence = not in_fence
            if current_title is not None:
                current_body.append(line)
            continue

        if not in_fence and stripped.startswith('### '):
            # Save previous entry
            if current_title is not None:
                raw_entries.append((current_title, ''.join(current_body)))
            current_title = stripped.lstrip('#').strip()
            current_body = []
        elif current_title is not None:
            current_body.append(line)
        # else: preamble before first ###, skip

    # Don't forget the last entry
    if current_title is not None:
        raw_entries.append((current_title, ''.join(current_body)))

    for title, body in raw_entries:
        slug = slugify(title)

        if not slug:
            continue

        # Skip entries with no meaningful content (just whitespace)
        body_stripped = body.strip()
        if not body_stripped:
            continue

        # Dedup slugs within category
        key = f'{category}/{slug}'
        if key in slug_counts:
            slug_counts[key] += 1
            slug = f'{slug}-{slug_counts[key]}'
        else:
            slug_counts[key] = 1

        # Build the entry content: H1 title + body
        entry_content = f'# {title}\n{body_stripped}\n'

        entries.append((basename, category, slug, title, entry_content))

# --- Report or write ---
for source_file, category, slug, title, content in entries:
    target_dir = os.path.join(knowledge_dir, category)
    target_file = os.path.join(target_dir, f'{slug}.md')

    if dry_run:
        print(f'  [dry-run] {source_file} -> {category}/{slug}.md  ({title})')
    else:
        os.makedirs(target_dir, exist_ok=True)
        with open(target_file, 'w') as f:
            f.write(content)

print()
print(f'Entries to create: {len(entries)}')

if dry_run:
    # Collision check — already disambiguated, but report original collisions
    base_slugs = {}
    for _, category, slug, title, _ in entries:
        # Strip -N suffix to find original slug
        base = re.sub(r'-\d+$', '', slug)
        key = f'{category}/{base}'
        base_slugs.setdefault(key, []).append(title)
    collisions = {k: v for k, v in base_slugs.items() if len(v) > 1}
    if collisions:
        print()
        print('Slug collisions detected (disambiguated with -N suffix):')
        for key, titles in collisions.items():
            print(f'  {key}: {", ".join(titles)}')
    else:
        print('No slug collisions detected.')

# Output categories for summary
cats = sorted(set(e[1] for e in entries))
# Write to a temp file for bash to read
with open(os.path.join(knowledge_dir, '_meta', '.migration_categories'), 'w') as f:
    f.write(', '.join(cats))
with open(os.path.join(knowledge_dir, '_meta', '.migration_count'), 'w') as f:
    f.write(str(len(entries)))
PYEOF

if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  echo "=== Dry run complete. Re-run without --dry-run to apply. ==="
  # Clean up temp files
  rm -f "$KNOWLEDGE_DIR/_meta/.migration_categories" "$KNOWLEDGE_DIR/_meta/.migration_count"
  exit 0
fi

# --- Backup originals ---
BACKUP_DIR="$KNOWLEDGE_DIR/_meta/pre-migration-backup"
mkdir -p "$BACKUP_DIR"

for f in "${MIGRATE_FILES[@]}"; do
  cp "$f" "$BACKUP_DIR/"
done

# Back up _index.md if it exists
if [[ -f "$KNOWLEDGE_DIR/_index.md" ]]; then
  cp "$KNOWLEDGE_DIR/_index.md" "$BACKUP_DIR/"
fi

echo "Backed up ${#MIGRATE_FILES[@]} files + _index.md to _meta/pre-migration-backup/"

# --- Remove originals ---
for f in "${MIGRATE_FILES[@]}"; do
  rm "$f"
done

# Remove _index.md
if [[ -f "$KNOWLEDGE_DIR/_index.md" ]]; then
  rm "$KNOWLEDGE_DIR/_index.md"
fi

echo "Removed monolithic files and _index.md"

# --- Regenerate manifest (picks up new file-per-entry structure) ---
"$SCRIPT_DIR/update-manifest.sh" 2>/dev/null || true

# --- Update format_version to 2 in manifest ---
# update-manifest.sh writes format_version: 1, so patch it to 2
sed -i.tmp 's/"format_version": 1/"format_version": 2/' "$KNOWLEDGE_DIR/_manifest.json"
rm -f "$KNOWLEDGE_DIR/_manifest.json.tmp"

echo "Updated format_version to 2 in _manifest.json"

# --- Summary ---
ENTRY_COUNT=$(cat "$KNOWLEDGE_DIR/_meta/.migration_count" 2>/dev/null || echo "0")
CATEGORIES=$(cat "$KNOWLEDGE_DIR/_meta/.migration_categories" 2>/dev/null || echo "unknown")
rm -f "$KNOWLEDGE_DIR/_meta/.migration_categories" "$KNOWLEDGE_DIR/_meta/.migration_count"

echo ""
echo "=== Migration Complete ==="
echo "  Entries created: $ENTRY_COUNT"
echo "  Categories: $CATEGORIES"
echo "  Backup: _meta/pre-migration-backup/"
echo "  format_version: 2"
echo ""
