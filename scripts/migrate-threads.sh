#!/usr/bin/env bash
# migrate-threads.sh — Migrate monolithic thread .md files to directory-per-thread with file-per-entry
# Usage: bash migrate-threads.sh [--dry-run]
#
# Converts:
#   _threads/how-we-work.md  (monolithic, YAML frontmatter + ## entries)
# Into:
#   _threads/how-we-work/
#     _meta.json              (tier, topic, created, updated, sessions)
#     2026-02-06.md           (entry from "## 2026-02-06")
#     2026-02-06-s6.md        (entry from "## 2026-02-06 (Session 6)")
#
# Entry filename rules:
#   ## 2026-02-06                       → 2026-02-06.md
#   ## 2026-02-06 (Session 6)          → 2026-02-06-s6.md
#   ## 2026-02-08 (Session 21)         → 2026-02-08-s21.md
#   ## 2026-02-07 (Session 14, continued) → 2026-02-07-s14-continued.md
#   Duplicate filenames get -2, -3 etc.
#
# Entry file content starts with **Summary:** (no ## heading line).
# The heading is reconstructed from the filename at load time.

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
THREADS_DIR="$KNOWLEDGE_DIR/_threads"

if [[ ! -d "$THREADS_DIR" ]]; then
  die "No _threads directory found at: $THREADS_DIR"
fi

# Check if already migrated
if [[ -f "$THREADS_DIR/_index.json" ]]; then
  HAS_V2=$(grep -c '"thread_format_version": 2' "$THREADS_DIR/_index.json" 2>/dev/null || echo "0")
  HAS_V2=$(echo "$HAS_V2" | tr -d '[:space:]')
  if [[ "$HAS_V2" -gt 0 ]]; then
    echo "[migrate-threads] Threads already at format_version 2 — nothing to do."
    exit 0
  fi
fi

# --- Identify monolithic thread files ---
MIGRATE_FILES=()
for f in "$THREADS_DIR"/*.md; do
  [[ -e "$f" ]] || continue
  BASENAME=$(basename "$f")
  # Skip underscore-prefixed files (_index.json, _pending_digest.md, etc.)
  [[ "$BASENAME" == _* ]] && continue
  MIGRATE_FILES+=("$f")
done

if [[ ${#MIGRATE_FILES[@]} -eq 0 ]]; then
  echo "[migrate-threads] No monolithic thread files found to migrate."
  exit 0
fi

echo "=== Thread Migration: monolithic → file-per-entry ==="
echo ""
echo "Threads directory: $THREADS_DIR"
echo "Files to migrate: ${#MIGRATE_FILES[@]}"
for f in "${MIGRATE_FILES[@]}"; do
  echo "  - $(basename "$f")"
done
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Mode: DRY RUN (no changes will be written)"
fi
echo ""

# --- Python does the heavy parsing ---
MIGRATE_LIST=$(printf '%s\n' "${MIGRATE_FILES[@]}")
export MIGRATE_LIST
export THREADS_DIR
export DRY_RUN

python3 << 'PYEOF'
import sys, re, os, json

threads_dir = os.environ['THREADS_DIR']
dry_run = os.environ['DRY_RUN'] == "1"
files = [f for f in os.environ['MIGRATE_LIST'].split('\n') if f]

total_entries = 0
total_threads = 0

def parse_heading_to_filename(heading):
    """Convert a ## heading to an entry filename (without .md extension).

    Rules:
      ## 2026-02-06                            → 2026-02-06
      ## 2026-02-06 (Session 6)                → 2026-02-06-s6
      ## 2026-02-08 (Session 21)               → 2026-02-08-s21
      ## 2026-02-07 (Session 14, continued)    → 2026-02-07-s14-continued
    """
    text = heading.strip()

    # Match: date + optional (Session N) or (Session N, qualifier)
    m = re.match(
        r'^(\d{4}-\d{2}-\d{2})'           # date
        r'(?:\s*\(Session\s+(\d+)'         # optional session number
        r'(?:,\s*(.+?))?\))?'              # optional qualifier after comma
        r'$',
        text
    )
    if m:
        date = m.group(1)
        session = m.group(2)
        qualifier = m.group(3)

        parts = [date]
        if session:
            parts.append(f's{session}')
        if qualifier:
            # Slugify the qualifier
            q = qualifier.lower().strip()
            q = re.sub(r'[^a-z0-9]', '-', q)
            q = re.sub(r'-+', '-', q).strip('-')
            if q:
                parts.append(q)
        return '-'.join(parts)

    # Fallback: slugify the whole heading
    s = text.lower()
    s = re.sub(r'[^a-z0-9]', '-', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s[:60] if s else 'untitled'


def parse_frontmatter(lines):
    """Parse YAML frontmatter from lines. Returns (metadata_dict, first_line_after_frontmatter)."""
    meta = {}
    if not lines or lines[0].strip() != '---':
        return meta, 0

    i = 1
    while i < len(lines) and lines[i].strip() != '---':
        line = lines[i].strip()
        if ':' in line:
            key, _, val = line.partition(':')
            meta[key.strip()] = val.strip()
        i += 1
    return meta, i + 1  # skip closing ---


def parse_entries(lines, start_line):
    """Parse ## entries from lines starting at start_line.
    Returns list of (heading_text, body_text) tuples.
    heading_text is the text after '## ' (e.g., '2026-02-06 (Session 6)').
    body_text is everything after the heading line, stripped of leading/trailing whitespace.
    """
    entries = []
    current_heading = None
    current_body = []
    in_fence = False

    for i in range(start_line, len(lines)):
        line = lines[i]
        stripped = line.rstrip('\n')

        if stripped.startswith('```'):
            in_fence = not in_fence
            if current_heading is not None:
                current_body.append(line)
            continue

        if not in_fence and stripped.startswith('## '):
            # Save previous entry
            if current_heading is not None:
                entries.append((current_heading, ''.join(current_body).strip()))
            current_heading = stripped[3:].strip()
            current_body = []
        elif current_heading is not None:
            current_body.append(line)
        # else: content before first ## (e.g., # Title line), skip

    # Last entry
    if current_heading is not None:
        entries.append((current_heading, ''.join(current_body).strip()))

    return entries


for filepath in files:
    basename = os.path.basename(filepath)
    slug = os.path.splitext(basename)[0]

    with open(filepath, 'r') as f:
        lines = f.readlines()

    # Parse frontmatter
    meta, content_start = parse_frontmatter(lines)

    # Skip the # Title line if present
    # (it's between frontmatter and first ## entry)

    # Parse entries
    entries = parse_entries(lines, content_start)

    if not entries:
        print(f'  [skip] {basename}: no ## entries found')
        continue

    total_threads += 1
    thread_dir = os.path.join(threads_dir, slug)

    # Build _meta.json from frontmatter
    meta_json = {
        "topic": meta.get('topic', slug.replace('-', ' ').title()),
        "tier": meta.get('tier', 'active'),
        "created": meta.get('created', ''),
        "updated": meta.get('updated', ''),
        "sessions": len(entries),
    }

    # Deduplicate filenames
    filename_counts = {}
    entry_files = []  # (filename, body_text, heading_text)

    for heading, body in entries:
        if not body:
            continue

        base_name = parse_heading_to_filename(heading)
        fname = base_name

        if fname in filename_counts:
            filename_counts[fname] += 1
            fname = f'{base_name}-{filename_counts[fname]}'
        else:
            filename_counts[fname] = 1

        entry_files.append((f'{fname}.md', body, heading))

    print(f'Thread: {slug}/')
    print(f'  _meta.json: topic={meta_json["topic"]}, tier={meta_json["tier"]}, sessions={meta_json["sessions"]}')

    for fname, body, heading in entry_files:
        total_entries += 1
        if dry_run:
            # Show first 60 chars of body for preview
            preview = body[:60].replace('\n', ' ')
            print(f'  [dry-run] {slug}/{fname}  (## {heading})')
        else:
            os.makedirs(thread_dir, exist_ok=True)

            # Write _meta.json (once per thread, but ok to overwrite with same content)
            meta_path = os.path.join(thread_dir, '_meta.json')
            with open(meta_path, 'w') as f:
                json.dump(meta_json, f, indent=2)
                f.write('\n')

            # Write entry file (body only, no ## heading)
            entry_path = os.path.join(thread_dir, fname)
            with open(entry_path, 'w') as f:
                f.write(body + '\n')

            print(f'  {slug}/{fname}  (## {heading})')

    print()

# Write summary counts for bash to read
summary_path = os.path.join(threads_dir, '.migration_summary')
with open(summary_path, 'w') as f:
    json.dump({"threads": total_threads, "entries": total_entries}, f)

print(f'Total threads: {total_threads}')
print(f'Total entries: {total_entries}')

if dry_run:
    # Check for filename collisions
    print()
    collision_found = False
    for filepath in files:
        basename = os.path.basename(filepath)
        slug = os.path.splitext(basename)[0]
        with open(filepath, 'r') as f:
            lines = f.readlines()
        _, content_start = parse_frontmatter(lines)
        entries = parse_entries(lines, content_start)
        fnames = {}
        for heading, body in entries:
            if not body:
                continue
            fname = parse_heading_to_filename(heading)
            fnames.setdefault(fname, []).append(heading)
        collisions = {k: v for k, v in fnames.items() if len(v) > 1}
        if collisions:
            if not collision_found:
                print('Filename collisions detected (disambiguated with -N suffix):')
                collision_found = True
            for fname, headings in collisions.items():
                print(f'  {slug}/{fname}: {", ".join(headings)}')
    if not collision_found:
        print('No filename collisions detected.')

PYEOF

if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  echo "=== Dry run complete. Re-run without --dry-run to apply. ==="
  rm -f "$THREADS_DIR/.migration_summary"
  exit 0
fi

# --- Backup originals ---
BACKUP_DIR="$THREADS_DIR/.pre-migration-backup"
mkdir -p "$BACKUP_DIR"

for f in "${MIGRATE_FILES[@]}"; do
  cp "$f" "$BACKUP_DIR/"
done

# Back up _index.json if it exists
if [[ -f "$THREADS_DIR/_index.json" ]]; then
  cp "$THREADS_DIR/_index.json" "$BACKUP_DIR/"
fi

echo "Backed up ${#MIGRATE_FILES[@]} files + _index.json to .pre-migration-backup/"

# --- Remove monolithic originals ---
for f in "${MIGRATE_FILES[@]}"; do
  rm "$f"
done

echo "Removed monolithic thread files"

# --- Update _index.json with thread_format_version: 2 ---
if [[ -f "$THREADS_DIR/_index.json" ]]; then
  python3 -c "
import json, sys

index_path = sys.argv[1]
with open(index_path, 'r') as f:
    data = json.load(f)

data['thread_format_version'] = 2

with open(index_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" "$THREADS_DIR/_index.json"
  echo "Updated _index.json with thread_format_version: 2"
fi

# --- Summary ---
SUMMARY=$(cat "$THREADS_DIR/.migration_summary" 2>/dev/null || echo '{"threads":0,"entries":0}')
THREAD_COUNT=$(echo "$SUMMARY" | python3 -c "import json,sys; print(json.load(sys.stdin)['threads'])")
ENTRY_COUNT=$(echo "$SUMMARY" | python3 -c "import json,sys; print(json.load(sys.stdin)['entries'])")
rm -f "$THREADS_DIR/.migration_summary"

echo ""
echo "=== Thread Migration Complete ==="
echo "  Threads migrated: $THREAD_COUNT"
echo "  Entry files created: $ENTRY_COUNT"
echo "  Backup: _threads/.pre-migration-backup/"
echo "  thread_format_version: 2"
echo ""
