#!/usr/bin/env bash
# show-history.sh — Show an entry's correction history and supersession chain.
#
# Usage:
#   show-history.sh <entry_id> [--kdir <path>]
#
# entry_id: relative path to the entry (e.g. "conventions/foo.md") or without .md suffix.
#
# Prints:
#   1. All corrections[] items from the entry's META block (newest first)
#   2. The supersession chain by walking superseded_entry_id links in status-update history
#
# Exit codes:
#   0 — success (even if no corrections found)
#   1 — usage or setup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ENTRY_ID=""
KDIR=""

usage() {
  cat >&2 <<'EOF'
Usage: show-history.sh <entry_id> [--kdir <path>]

Shows the correction history and supersession chain for a knowledge entry.
entry_id: relative path (e.g. "conventions/foo.md" or "conventions/foo")
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)  KDIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    -*)
      echo "Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$ENTRY_ID" ]]; then
        ENTRY_ID="$1"
        shift
      else
        echo "Error: unexpected argument '$1'" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$ENTRY_ID" ]]; then
  usage
  exit 1
fi

if [[ -z "$KDIR" ]]; then
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  die "knowledge directory not found: $KDIR"
fi

# Normalize entry_id: ensure .md suffix
[[ "$ENTRY_ID" == *.md ]] || ENTRY_ID="${ENTRY_ID}.md"

python3 - "$KDIR" "$ENTRY_ID" <<'PYEOF'
import json
import os
import re
import sys

CORRECTIONS_RE = re.compile(r"\|\s*corrections:\s*(\[.*?\])\s*(?:-->|\|)", re.DOTALL)
STATUS_RE = re.compile(r"\|\s*status:\s*(?P<status>[^\s|>]+)", re.IGNORECASE)
SUPERSEDED_RE = re.compile(r"\|\s*superseded_entry_id:\s*(?P<path>.+?)(?:\s*-->|\s*\||\s*$)", re.IGNORECASE)
SUCCESSOR_RE = re.compile(r"\|\s*successor_entry_id:\s*(?P<path>.+?)(?:\s*-->|\s*\||\s*$)", re.IGNORECASE)

kdir = sys.argv[1]
entry_id = sys.argv[2]


def read_entry(eid: str) -> str | None:
    path = os.path.join(kdir, eid)
    if not os.path.isfile(path):
        return None
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        return None


def parse_corrections(text: str) -> list[dict]:
    m = CORRECTIONS_RE.search(text)
    if not m:
        return []
    try:
        items = json.loads(m.group(1))
        return [it for it in items if isinstance(it, dict)]
    except (json.JSONDecodeError, TypeError):
        return []


def parse_status(text: str) -> str:
    m = STATUS_RE.search(text)
    return m.group("status") if m else "current"


def parse_successor(text: str) -> str | None:
    # Walk forward via successor_entry_id or superseded_entry_id (written by status-update)
    m = SUCCESSOR_RE.search(text)
    if m:
        return m.group("path").strip()
    return None


text = read_entry(entry_id)
if text is None:
    print(f"Entry not found: {entry_id}", file=sys.stderr)
    sys.exit(1)

# --- Correction history ---
corrections = parse_corrections(text)
print(f"# History: {entry_id}")
print()

if corrections:
    print(f"## Corrections ({len(corrections)})")
    # Sort newest first
    try:
        sorted_corrections = sorted(corrections, key=lambda it: it.get("date", ""), reverse=True)
    except TypeError:
        sorted_corrections = corrections
    for i, c in enumerate(sorted_corrections, 1):
        date = c.get("date", "unknown")
        source = c.get("verdict_source", "")
        vid = c.get("verdict_id", "")
        evidence = c.get("evidence", "")
        sup_text = c.get("superseded_text", "")
        rep_text = c.get("replacement_text", "")
        print(f"  {i}. {date}", end="")
        if source:
            print(f" [{source}]", end="")
        if vid:
            print(f" verdict={vid}", end="")
        print()
        if evidence:
            print(f"     Evidence: {evidence}")
        if sup_text:
            print(f"     Before:   {sup_text!r}")
        if rep_text:
            print(f"     After:    {rep_text!r}")
else:
    print("  (no corrections recorded)")

# --- Supersession chain ---
print()
print("## Supersession chain")

status = parse_status(text)
if status not in ("superseded", "historical"):
    # Walk forward to find if this entry has a successor
    successor = parse_successor(text)
    if successor:
        print(f"  {entry_id} → {successor} (current)")
    else:
        print(f"  {entry_id} is current — no supersession")
else:
    # This entry is superseded; show chain
    chain = [entry_id]
    visited = {entry_id}
    current_text = text
    while True:
        succ = parse_successor(current_text)
        if not succ or succ in visited:
            break
        chain.append(succ)
        visited.add(succ)
        succ_text = read_entry(succ)
        if succ_text is None:
            chain.append(f"(not found: {succ})")
            break
        succ_status = parse_status(succ_text)
        if succ_status not in ("superseded", "historical"):
            break
        current_text = succ_text

    if len(chain) > 1:
        for j, step in enumerate(chain):
            prefix = "  " + ("└─ " if j == len(chain) - 1 else "├─ ")
            label = " (current)" if j == len(chain) - 1 else " (superseded)"
            if "(not found:" in step:
                print(f"{prefix}{step}")
            else:
                print(f"{prefix}{step}{label}")
    else:
        print(f"  {entry_id} is superseded but successor_entry_id not recorded in META")
PYEOF
