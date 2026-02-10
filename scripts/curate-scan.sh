#!/usr/bin/env bash
# curate-scan.sh — Mechanical pre-scan for /memory curate
# Lists quality issues that need judgment: medium-confidence entries,
# missing backlinks, inbox remnants. Does NOT modify files.
#
# Usage: bash curate-scan.sh [knowledge_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KDIR="${1:-$(resolve_knowledge_dir)}"

if [[ ! -d "$KDIR" ]]; then
  echo "Error: knowledge directory not found: $KDIR" >&2
  exit 1
fi

echo "=== Curate Scan ==="
echo ""

ISSUES=0

# 1. Inbox remnants
INBOX_DIR="$KDIR/_inbox"
if [[ -d "$INBOX_DIR" ]]; then
  INBOX_COUNT=$(find "$INBOX_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [[ "$INBOX_COUNT" -gt 0 ]]; then
    echo "## Inbox remnants: $INBOX_COUNT files"
    find "$INBOX_DIR" -maxdepth 1 -name '*.md' -exec basename {} \; 2>/dev/null | sort
    echo ""
    ISSUES=$((ISSUES + INBOX_COUNT))
  fi
fi

# 2. Medium-confidence entries (scan category directories)
MEDIUM_TOTAL=0
for dir in "$KDIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == _* ]] && continue

  for f in "$dir"*.md; do
    [[ -e "$f" ]] || continue
    if grep -q 'confidence: medium' "$f" 2>/dev/null; then
      if [[ "$MEDIUM_TOTAL" -eq 0 ]]; then
        echo "## Medium-confidence entries (need quality gate review):"
      fi
      RELPATH="${f#$KDIR/}"
      echo "  $RELPATH"
      MEDIUM_TOTAL=$((MEDIUM_TOTAL + 1))
    fi
  done
done

if [[ "$MEDIUM_TOTAL" -gt 0 ]]; then
  echo "  Total: $MEDIUM_TOTAL"
  echo ""
  ISSUES=$((ISSUES + MEDIUM_TOTAL))
fi

# 3. Entries without backlinks (scan category directories)
NO_BACKLINKS=0
for dir in "$KDIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == _* ]] && continue

  for f in "$dir"*.md; do
    [[ -e "$f" ]] || continue
    if ! grep -q '\[\[' "$f" 2>/dev/null; then
      if [[ $NO_BACKLINKS -eq 0 ]]; then
        echo "## Entries without backlinks:"
      fi
      RELPATH="${f#$KDIR/}"
      echo "  $RELPATH"
      NO_BACKLINKS=$((NO_BACKLINKS + 1))
    fi
  done
done

if [[ $NO_BACKLINKS -gt 0 ]]; then
  echo "  Total: $NO_BACKLINKS"
  echo ""
  ISSUES=$((ISSUES + NO_BACKLINKS))
fi

# 4. Renormalize flags — detect categories needing reorganization
#    Writes _meta/renormalize-flags.json with:
#    - oversized_categories: dirs with >20 entries
#    - stale_related_files: entries whose related_files no longer exist
#    - zero_access_entries: entries never accessed (if log has >10 sessions)
RENORM_FLAGS=$(python3 -c "
import json, os, re, sys

kdir = sys.argv[1]
repo_root = os.getcwd()

CATEGORY_DIRS = {'abstractions', 'architecture', 'conventions', 'gotchas', 'principles', 'workflows', 'domains'}
SKIP_FILES = {'_inbox.md', '_index.md', '_meta.md', '_meta.json', '_index.json', '_manifest.json'}
OVERSIZED_THRESHOLD = 20

META_RE = re.compile(
    r'<!--\s*'
    r'learned:\s*(?P<learned>\S+)'
    r'\s*\|\s*confidence:\s*(?P<confidence>\w+)'
    r'(?:\s*\|\s*source:\s*(?P<source>[^|]+?))?'
    r'(?:\s*\|\s*related_files:\s*(?P<related_files>[^-]+?))?'
    r'\s*-->',
    re.DOTALL,
)

flags = {
    'oversized_categories': [],
    'stale_related_files': [],
    'zero_access_entries': [],
}

# --- Oversized categories ---
for cat in sorted(CATEGORY_DIRS):
    cat_path = os.path.join(kdir, cat)
    if not os.path.isdir(cat_path):
        continue
    count = 0
    for root, dirs, files in os.walk(cat_path):
        dirs[:] = [d for d in dirs if not d.startswith('_')]
        count += sum(1 for f in files if f.endswith('.md') and f not in SKIP_FILES)
    if count > OVERSIZED_THRESHOLD:
        flags['oversized_categories'].append({'category': cat, 'entry_count': count})

# --- Stale related_files ---
for cat in sorted(CATEGORY_DIRS):
    cat_path = os.path.join(kdir, cat)
    if not os.path.isdir(cat_path):
        continue
    for root, dirs, files in os.walk(cat_path):
        dirs[:] = [d for d in dirs if not d.startswith('_')]
        for fname in sorted(files):
            if not fname.endswith('.md') or fname in SKIP_FILES:
                continue
            fpath = os.path.join(root, fname)
            try:
                text = open(fpath, encoding='utf-8').read()
            except (OSError, UnicodeDecodeError):
                continue
            m = META_RE.search(text)
            if not m or not m.group('related_files'):
                continue
            rf_str = m.group('related_files').strip()
            if not rf_str:
                continue
            related = [f.strip() for f in rf_str.split(',') if f.strip()]
            missing = [r for r in related if not os.path.exists(os.path.join(repo_root, r))]
            if missing:
                rel = os.path.relpath(fpath, kdir)
                flags['stale_related_files'].append({'entry': rel, 'missing': missing})

# --- Zero access entries (only if retrieval log has >10 sessions) ---
log_path = os.path.join(kdir, '_meta', 'retrieval-log.jsonl')
if os.path.isfile(log_path):
    sessions = set()
    try:
        with open(log_path, encoding='utf-8') as lf:
            for line in lf:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    ts = entry.get('timestamp', '')[:10]
                    branch = entry.get('git_branch', '')
                    sessions.add(f'{ts}:{branch}')
                except json.JSONDecodeError:
                    continue
    except OSError:
        sessions = set()

    if len(sessions) > 10:
        # Load usage report for cold entries
        usage_path = os.path.join(kdir, '_meta', 'usage-report.json')
        if os.path.isfile(usage_path):
            try:
                with open(usage_path, encoding='utf-8') as uf:
                    usage = json.load(uf)
                cold = usage.get('cold_entries', [])
                flags['zero_access_entries'] = cold
            except (OSError, json.JSONDecodeError):
                pass

# Write flags
meta_dir = os.path.join(kdir, '_meta')
os.makedirs(meta_dir, exist_ok=True)
out_path = os.path.join(meta_dir, 'renormalize-flags.json')
with open(out_path, 'w', encoding='utf-8') as of:
    json.dump(flags, of, indent=2)
    of.write('\n')

# Print summary for curate-scan output
total_flags = (len(flags['oversized_categories'])
    + len(flags['stale_related_files'])
    + len(flags['zero_access_entries']))
print(total_flags)
" "$KDIR" 2>&1) || true

RENORM_COUNT="${RENORM_FLAGS##*$'\n'}"
RENORM_COUNT="${RENORM_COUNT:-0}"

if [[ "$RENORM_COUNT" =~ ^[0-9]+$ ]] && [[ "$RENORM_COUNT" -gt 0 ]]; then
  echo "## Renormalize flags: $RENORM_COUNT"

  # Read and display the flags file
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    flags = json.load(f)
if flags.get('oversized_categories'):
    print('  Oversized categories (>20 entries):')
    for c in flags['oversized_categories']:
        print(f\"    {c['category']}: {c['entry_count']} entries\")
if flags.get('stale_related_files'):
    print('  Entries with stale related_files:')
    for e in flags['stale_related_files']:
        print(f\"    {e['entry']}: missing {', '.join(e['missing'])}\")
if flags.get('zero_access_entries'):
    count = len(flags['zero_access_entries'])
    print(f'  Zero-access entries: {count}')
    for e in flags['zero_access_entries'][:10]:
        print(f'    {e}')
    if count > 10:
        print(f'    ... and {count - 10} more')
" "$KDIR/_meta/renormalize-flags.json" 2>/dev/null || true

  echo ""
  echo "  Run /memory renormalize to address structural issues."
  echo ""
  ISSUES=$((ISSUES + RENORM_COUNT))
fi

# Summary
if [[ $ISSUES -eq 0 ]]; then
  echo "No issues found. Knowledge store looks clean."
else
  echo "---"
  echo "Total issues: $ISSUES"
  echo "Run /memory curate to address these."
fi
echo ""
echo "=== End Curate Scan ==="
