#!/usr/bin/env bash
# curate-scan.sh — Mechanical pre-scan for /memory curate
# Lists quality issues that need judgment: medium-confidence entries,
# duplicate candidates, entries whose related_files are gone, inbox remnants.
# Does not modify entries; the only write is _meta/renormalize-flags.json.
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

# 2. Medium-confidence entries (category directories at any depth)
MEDIUM_ENTRIES=$(
  for dir in "$KDIR"/*/; do
    dir="${dir%/}"
    [[ -d "$dir" && "$(basename "$dir")" != _* ]] || continue
    find "$dir" -type d -name '_*' -prune -o -type f -name '*.md' -print0
  done | xargs -0 grep -l 'confidence: medium' 2>/dev/null | sort
) || true

MEDIUM_TOTAL=0
if [[ -n "$MEDIUM_ENTRIES" ]]; then
  echo "## Medium-confidence entries (need quality gate review):"
  while IFS= read -r f; do
    echo "  ${f#$KDIR/}"
    MEDIUM_TOTAL=$((MEDIUM_TOTAL + 1))
  done <<< "$MEDIUM_ENTRIES"
  echo "  Total: $MEDIUM_TOTAL"
  echo ""
  ISSUES=$((ISSUES + MEDIUM_TOTAL))
fi

# 3. Duplicate candidates — near-identical pairs from the concordance build.
#    First output line is the pair count; the rest is the section.
if DUP_REPORT=$(python3 - "$KDIR" "$SCRIPT_DIR" <<'PY'
import os
import sys

kdir, script_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, script_dir)
from pk_cli import CONCORDANCE_REPAIR, concordance_build, describe_concordance_build
from pk_concordance import Concordance
from pk_search import DB_FILENAME

THRESHOLD = 0.6
SHOWN = 20

db_path = os.path.join(kdir, DB_FILENAME)
pairs, built_at = concordance_build(db_path) if os.path.isfile(db_path) else (0, None)
if pairs == 0 and built_at is None:
    print(0)
    print("## Duplicate candidates: check did not run (no concordance build to read)")
    print(f"  Build one with {CONCORDANCE_REPAIR}.")
    sys.exit()

candidates = []
gone = 0
for c in Concordance(db_path).find_merge_candidates(threshold=THRESHOLD):
    if os.path.isfile(c["target_path"]) and os.path.isfile(c["source_path"]):
        candidates.append(c)
    else:
        gone += 1

print(len(candidates))
print(f"## Duplicate candidates (similarity >= {THRESHOLD}): {len(candidates)}")
print(f"  {describe_concordance_build(built_at)}")
for c in candidates[:SHOWN]:
    print(f"  {c['similarity']:.2f}  {os.path.relpath(c['target_path'], kdir)}")
    print(f"        <-> {os.path.relpath(c['source_path'], kdir)}")
if len(candidates) > SHOWN:
    print(f"  ... and {len(candidates) - SHOWN} more")
if gone:
    print(f"  {gone} more pair(s) name an entry moved or deleted since the build")
PY
); then
  DUP_COUNT="${DUP_REPORT%%$'\n'*}"
  echo "${DUP_REPORT#*$'\n'}"
else
  DUP_COUNT=0
  echo "## Duplicate candidates: check did not run (the similarity reader failed; see stderr)"
fi
echo ""
[[ "$DUP_COUNT" =~ ^[0-9]+$ ]] || DUP_COUNT=0
ISSUES=$((ISSUES + DUP_COUNT))

# 4. Renormalize flags — writes _meta/renormalize-flags.json, which status.sh
#    and /remember read. First output line is the flag count; the rest is the
#    section. related_files resolve against the checkout this store belongs to.
REPO_ROOT=""
if TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) \
  && [[ "$("$SCRIPT_DIR/resolve-repo.sh" "$TOPLEVEL" 2>/dev/null)" -ef "$KDIR" ]]; then
  REPO_ROOT="$TOPLEVEL"
fi

if RENORM_REPORT=$(python3 - "$KDIR" "$REPO_ROOT" "$SCRIPT_DIR" <<'PY'
import importlib.util
import json
import os
import sys

kdir, repo_root, script_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, script_dir)
from pk_search import CATEGORY_DIRS

spec = importlib.util.spec_from_file_location(
    "staleness_scan", os.path.join(script_dir, "staleness-scan.py")
)
staleness_scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staleness_scan)

SHOWN = 20

# status.sh and /remember sum these three lists. The category-size and
# zero-access checks are retired; their keys stay, empty, so those readers
# keep working.
flags = {
    "oversized_categories": [],
    "stale_related_files": [],
    "zero_access_entries": [],
}


def related_file_exists(path):
    path = os.path.expanduser(path)
    if os.path.isabs(path):
        return os.path.exists(path)
    return any(os.path.exists(os.path.join(root, path)) for root in (repo_root, kdir))


if repo_root:
    for cat in sorted(CATEGORY_DIRS):
        for root, dirs, files in os.walk(os.path.join(kdir, cat)):
            dirs[:] = sorted(d for d in dirs if not d.startswith("_"))
            for fname in sorted(files):
                if not fname.endswith(".md") or fname in staleness_scan.SKIP_FILES:
                    continue
                fpath = os.path.join(root, fname)
                related = staleness_scan.parse_metadata(fpath)["related_files"]
                missing = [r for r in related if not related_file_exists(r)]
                if missing:
                    flags["stale_related_files"].append(
                        {"entry": os.path.relpath(fpath, kdir), "missing": missing}
                    )
else:
    flags["not_checked"] = {
        "stale_related_files": "not run from a checkout of the repository this store belongs to"
    }

meta_dir = os.path.join(kdir, "_meta")
os.makedirs(meta_dir, exist_ok=True)
with open(os.path.join(meta_dir, "renormalize-flags.json"), "w", encoding="utf-8") as f:
    json.dump(flags, f, indent=2)
    f.write("\n")

stale = flags["stale_related_files"]
print(len(stale))
if not repo_root:
    print("## Renormalize flags: stale related_files check did not run")
    print("  Run lore curate from a checkout of the repository this store belongs to.")
elif not stale:
    print("## Renormalize flags: 0")
else:
    print(f"## Renormalize flags: {len(stale)}")
    print("  Entries whose related_files no longer exist:")
    for e in stale[:SHOWN]:
        print(f"    {e['entry']}: missing {', '.join(e['missing'])}")
    if len(stale) > SHOWN:
        print(f"    ... and {len(stale) - SHOWN} more (all in _meta/renormalize-flags.json)")
    print("")
    print("  Run /memory renormalize to address structural issues.")
PY
); then
  RENORM_COUNT="${RENORM_REPORT%%$'\n'*}"
  echo "${RENORM_REPORT#*$'\n'}"
else
  RENORM_COUNT=0
  echo "## Renormalize flags: check did not run (the flag scan failed; see stderr)"
fi
echo ""
[[ "$RENORM_COUNT" =~ ^[0-9]+$ ]] || RENORM_COUNT=0
ISSUES=$((ISSUES + RENORM_COUNT))

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
