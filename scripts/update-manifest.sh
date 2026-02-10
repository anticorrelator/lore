#!/usr/bin/env bash
# update-manifest.sh — Regenerate _manifest.json from knowledge files (format v2)
# Usage: bash update-manifest.sh [directory]
# Walks category directories, creates per-entry manifest with metadata.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found at: $KNOWLEDGE_DIR"
  exit 1
fi

MANIFEST="$KNOWLEDGE_DIR/_manifest.json"
TIMESTAMP=$(timestamp_iso)
REPO_NAME=$(basename "$KNOWLEDGE_DIR")

# Category directories and their default priority scores (passed as key=value to Python)
CATEGORY_PRIORITIES="principles=100
workflows=90
conventions=80
architecture=70
gotchas=60
abstractions=50
domains=40
team=30"

# --- Build per-entry JSON via Python for reliable output ---
python3 - "$KNOWLEDGE_DIR" "$REPO_NAME" "$TIMESTAMP" "$CATEGORY_PRIORITIES" << 'PYEOF'
import sys
import os
import re
import json

knowledge_dir = sys.argv[1]
repo_name = sys.argv[2]
timestamp = sys.argv[3]
priority_map = {}
categories = []
for line in sys.argv[4].strip().split('\n'):
    if '=' in line:
        cat, score = line.split('=', 1)
        cat = cat.strip()
        priority_map[cat] = int(score.strip())
        categories.append(cat)

entries = []
category_stats = {}

for category in categories:
    cat_dir = os.path.join(knowledge_dir, category)
    if not os.path.isdir(cat_dir):
        continue

    cat_entry_count = 0

    for fname in sorted(os.listdir(cat_dir)):
        if not fname.endswith('.md'):
            continue

        filepath = os.path.join(cat_dir, fname)
        if not os.path.isfile(filepath):
            continue

        relpath = os.path.join(category, fname)

        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

        # Extract keywords from H1 title
        keywords = set()
        title_match = re.match(r'^#\s+(.+)$', content, re.MULTILINE)
        if title_match:
            title_text = title_match.group(1)
            # Split title into words, lowercase, remove punctuation
            for word in re.split(r'[^a-zA-Z0-9-]+', title_text):
                word = word.lower().strip('-')
                if word and len(word) > 1:
                    keywords.add(word)

        # Extract backlinks [[...]]
        backlinks = set()
        for bl_match in re.finditer(r'\[\[([^\]|]+?)(?:\|[^\]]+)?\]\]', content):
            backlinks.add(bl_match.group(1))

        # Extract HTML comment metadata: <!-- learned: ... | confidence: ... | source: ... -->
        learned = ""
        confidence = ""
        related_files = []
        meta_match = re.search(r'<!--\s*(.*?)\s*-->', content)
        if meta_match:
            meta_text = meta_match.group(1)
            for part in meta_text.split('|'):
                part = part.strip()
                if part.startswith('learned:'):
                    learned = part[len('learned:'):].strip()
                elif part.startswith('confidence:'):
                    confidence = part[len('confidence:'):].strip()
                elif part.startswith('related-files:') or part.startswith('related_files:'):
                    rf_text = part.split(':', 1)[1].strip()
                    related_files = [r.strip() for r in rf_text.split(',') if r.strip()]

        priority_score = priority_map.get(category, 30)

        entry = {
            "path": relpath,
            "category": category,
            "keywords": sorted(keywords),
            "backlinks": sorted(backlinks),
            "learned": learned,
            "confidence": confidence,
            "related_files": related_files,
            "priority_score": priority_score,
        }
        entries.append(entry)
        cat_entry_count += 1

    if cat_entry_count > 0:
        category_stats[category] = {
            "entry_count": cat_entry_count,
            "priority_score": priority_map.get(category, 30),
        }

manifest = {
    "format_version": 2,
    "repo": repo_name,
    "last_updated": timestamp,
    "categories": category_stats,
    "entries": entries,
}

with open(os.path.join(knowledge_dir, '_manifest.json'), 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f"Manifest updated: {os.path.join(knowledge_dir, '_manifest.json')}")
print(f"  {len(entries)} entries across {len(category_stats)} categories")
PYEOF
