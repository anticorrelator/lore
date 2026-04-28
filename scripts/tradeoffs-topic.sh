#!/usr/bin/env bash
# tradeoffs-topic.sh — Surface design alternatives considered and rejected for a topic
#
# Searches the knowledge store with a bias toward:
#   1. Entries in the design-rationale/ category
#   2. Entries tagged type: rationale
#   3. Entries whose body mentions rejected/alternative/tradeoff/considered
#
# Renders top N results with title, scale, status, and trust stamp.
# Falls back to standard search with a note when no rationale entries found.
#
# Usage:
#   tradeoffs-topic.sh <topic> --scale-set <bucket> [--limit N] [--json]
#
# Exit codes:
#   0 — success
#   1 — usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: tradeoffs-topic.sh <topic> --scale-set <bucket> [--limit N] [--json]

Surface design alternatives considered and rejected for a topic.
Searches design-rationale/ entries first, then falls back to general search.

Options:
  --scale-set S  Required: retrieval scale bucket (application|architectural|subsystem|implementation)
  --limit N      Max results to show (default: 5)
  --json         Output raw JSON instead of formatted text
  --help, -h     Show this help
EOF
}

TOPIC=""
LIMIT=5
JSON_MODE=0
SCALE_SET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)      LIMIT="$2"; shift 2 ;;
    --json)       JSON_MODE=1; shift ;;
    --scale-set)  SCALE_SET="$2"; shift 2 ;;
    --scale-set=*) SCALE_SET="${1#--scale-set=}"; shift ;;
    --help|-h) usage; exit 0 ;;
    -*)
      echo "Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$TOPIC" ]]; then
        TOPIC="$1"
      else
        echo "Error: unexpected argument '$1'" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "Error: <topic> is required" >&2
  usage
  exit 1
fi

if [[ -z "$SCALE_SET" ]]; then
  echo "Error: --scale-set is required; declare your retrieval scale, e.g. --scale-set architectural" >&2
  echo "  Buckets: application, architectural, subsystem, implementation" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
PK_CLI="$SCRIPT_DIR/pk_cli.py"

if [[ ! -f "$PK_CLI" ]]; then
  echo "Error: pk_cli.py not found at $PK_CLI" >&2
  exit 1
fi

check_fts_available
if [[ $USE_FTS -eq 0 ]]; then
  echo "Error: FTS not available — cannot search knowledge store" >&2
  exit 1
fi

python3 - "$KNOWLEDGE_DIR" "$TOPIC" "$LIMIT" "$JSON_MODE" "$PK_CLI" "$SCRIPT_DIR" "$SCALE_SET" <<'PYEOF'
import json
import os
import subprocess
import sys

kdir, topic, limit_s, json_mode_s, pk_cli, script_dir, scale_set = sys.argv[1:8]
limit = int(limit_s)
json_mode = json_mode_s == "1"

sys.path.insert(0, script_dir)
from pk_search import render_trust_stamp

RATIONALE_KEYWORDS = {"rejected", "alternative", "tradeoff", "considered", "rationale", "instead", "over"}


def run_search(query, extra_args=None):
    args = ["python3", pk_cli, "search", kdir, query,
            "--scale-set", scale_set,
            "--limit", str(limit * 3), "--json", "--caller", "tradeoffs"]
    if extra_args:
        args += extra_args
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return []


def score_rationale(entry):
    """Score an entry's rationale relevance (higher = more rationale-like)."""
    score = 0
    fp = entry.get("file_path", "")
    heading = (entry.get("heading") or "").lower()
    snippet = (entry.get("snippet") or "").lower()

    # Strong signal: design-rationale category
    if "design-rationale/" in fp:
        score += 10

    # Moderate signal: rationale keywords in heading
    for kw in RATIONALE_KEYWORDS:
        if kw in heading:
            score += 3

    # Weak signal: rationale keywords in snippet
    for kw in RATIONALE_KEYWORDS:
        if kw in snippet:
            score += 1

    # Bonus: entry_status = current (prefer fresh rationale)
    if entry.get("entry_status") in ("current", "active"):
        score += 1

    return score


# Search design-rationale category specifically
rationale_results = run_search(f"design-rationale {topic}")
general_results = run_search(topic)

# Combine, score, deduplicate by file_path
seen_paths = set()
combined = []
for entry in rationale_results + general_results:
    fp = entry.get("file_path", "")
    if fp not in seen_paths:
        seen_paths.add(fp)
        entry["_rationale_score"] = score_rationale(entry)
        combined.append(entry)

# Sort by rationale score descending, then search score descending
combined.sort(key=lambda e: (-e["_rationale_score"], -e.get("score", 0)))

# Split into rationale-boosted and fallback
rationale_entries = [e for e in combined if e["_rationale_score"] >= 3]
fallback_entries = [e for e in combined if e["_rationale_score"] < 3]

if json_mode:
    output = (rationale_entries + fallback_entries)[:limit]
    print(json.dumps(output, indent=2))
    sys.exit(0)

if rationale_entries:
    top = rationale_entries[:limit]
    print(f"## Tradeoffs: {topic}")
    print(f"Design alternatives considered and rejected ({len(top)} of {len(rationale_entries)} rationale entries):")
    for e in top:
        fp = e.get("file_path", "")
        heading = e.get("heading", "")
        scale = e.get("scale", "") or ""
        status = e.get("entry_status", "") or ""
        snippet = (e.get("snippet") or "").strip()
        trust = render_trust_stamp(e)

        scale_tag = f" [{scale}]" if scale else ""
        status_tag = f" [{status}]" if status else ""
        print()
        print(f"### {heading}{scale_tag}{status_tag} (from {fp})")
        print(trust)
        if snippet:
            # Show first 300 chars of snippet
            shown = snippet[:300]
            if len(snippet) > 300:
                shown += "..."
            print(shown)
else:
    # Fallback: use general results with a note
    top = fallback_entries[:limit]
    if not top:
        print(f"No results found for tradeoffs topic: {topic!r}")
        sys.exit(0)
    print(f"## Tradeoffs: {topic}")
    print("_No explicit rationale entries found; showing closest knowledge matches:_")
    for e in top:
        fp = e.get("file_path", "")
        heading = e.get("heading", "")
        scale = e.get("scale", "") or ""
        status = e.get("entry_status", "") or ""
        snippet = (e.get("snippet") or "").strip()
        trust = render_trust_stamp(e)

        scale_tag = f" [{scale}]" if scale else ""
        status_tag = f" [{status}]" if status else ""
        print()
        print(f"### {heading}{scale_tag}{status_tag} (from {fp})")
        print(trust)
        if snippet:
            shown = snippet[:300]
            if len(snippet) > 300:
                shown += "..."
            print(shown)
PYEOF
