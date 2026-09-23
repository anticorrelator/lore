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

# 2. Medium-confidence entries (category directories at any depth). Entries
#    search leaves out by default need no review. First output line is the
#    entry count; the rest is the section.
if MEDIUM_REPORT=$(python3 - "$KDIR" "$SCRIPT_DIR" <<'PY'
import os
import sys
from collections import Counter

kdir, script_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, script_dir)
from pk_cli import describe_statuses, withheld_status
from pk_markdown import MarkdownParser
from pk_search import CATEGORY_DIRS

medium = []
withheld = Counter()
for cat in sorted(CATEGORY_DIRS):
    for root, dirs, files in os.walk(os.path.join(kdir, cat)):
        dirs[:] = [d for d in dirs if not d.startswith("_")]
        for fname in files:
            if not fname.endswith(".md"):
                continue
            path = os.path.join(root, fname)
            try:
                meta = MarkdownParser._extract_metadata(open(path, encoding="utf-8").read())
            except (OSError, UnicodeDecodeError):
                continue
            if (meta["confidence"] or "").lower() != "medium":
                continue
            status = withheld_status(path)
            if status:
                withheld[status] += 1
            else:
                medium.append(os.path.relpath(path, kdir))

print(len(medium))
if medium or withheld:
    print("## Medium-confidence entries (need quality gate review):")
    for rel in sorted(medium):
        print(f"  {rel}")
    print(f"  Total: {len(medium)}")
    if withheld:
        print(
            f"  Left out: {sum(withheld.values())} kept for the record "
            f"({describe_statuses(withheld)})"
        )
PY
); then
  MEDIUM_TOTAL="${MEDIUM_REPORT%%$'\n'*}"
  MEDIUM_BODY="${MEDIUM_REPORT#"$MEDIUM_TOTAL"}"
  if [[ -n "$MEDIUM_BODY" ]]; then
    echo "${MEDIUM_BODY#$'\n'}"
    echo ""
  fi
else
  MEDIUM_TOTAL=0
  echo "## Medium-confidence entries: check did not run (the footer reader failed; see stderr)"
  echo ""
fi
[[ "$MEDIUM_TOTAL" =~ ^[0-9]+$ ]] || MEDIUM_TOTAL=0
ISSUES=$((ISSUES + MEDIUM_TOTAL))

# 3. Duplicate candidates — near-identical pairs from the concordance build.
#    First output line is the pair count; the rest is the section.
if DUP_REPORT=$(python3 - "$KDIR" "$SCRIPT_DIR" <<'PY'
import os
import sys
from collections import Counter

kdir, script_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, script_dir)
from pk_cli import (
    CONCORDANCE_REPAIR,
    concordance_build,
    describe_concordance_build,
    describe_statuses,
    withheld_status,
)
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
withheld = Counter()
for c in Concordance(db_path).find_merge_candidates(threshold=THRESHOLD):
    if not (os.path.isfile(c["target_path"]) and os.path.isfile(c["source_path"])):
        gone += 1
        continue
    status = withheld_status(c["target_path"]) or withheld_status(c["source_path"])
    if status:
        withheld[status] += 1
    else:
        candidates.append(c)

print(len(candidates))
print(f"## Duplicate candidates (similarity >= {THRESHOLD}): {len(candidates)}")
print(f"  {describe_concordance_build(built_at)}")
for c in candidates[:SHOWN]:
    print(f"  {c['similarity']:.2f}  {os.path.relpath(c['target_path'], kdir)}")
    print(f"        <-> {os.path.relpath(c['source_path'], kdir)}")
if len(candidates) > SHOWN:
    print(f"  ... and {len(candidates) - SHOWN} more")
if withheld:
    print(
        f"  Left out: {sum(withheld.values())} pair(s) naming an entry kept for the "
        f"record ({describe_statuses(withheld)})"
    )
if gone:
    print(f"  Left out: {gone} pair(s) naming an entry moved or deleted since the build")
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
from collections import Counter

kdir, repo_root, script_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, script_dir)
from pk_cli import describe_statuses, withheld_status
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


withheld = Counter()
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
                if not missing:
                    continue
                status = withheld_status(fpath)
                if status:
                    withheld[status] += 1
                    continue
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
if withheld:
    print(
        f"  Left out: {sum(withheld.values())} kept for the record "
        f"({describe_statuses(withheld)})"
    )
if stale:
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
