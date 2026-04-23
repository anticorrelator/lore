#!/usr/bin/env bash
# scale-coverage.sh — Compute scale coverage across the knowledge store
#
# Usage:
#   scale-coverage.sh [--kdir <kdir>] [--json] [--threshold <float>]
#
# Scans all .md entry files in KDIR for a | scale: <value> | META field.
# Entries with scale: unknown (or no scale field at all) count as unscaled.
#
# Outputs:
#   --json  : JSON object with total, known, unknown, coverage, mode, threshold
#   default : human-readable summary line
#
# Exit codes:
#   0 — coverage >= threshold (drift-detector mode)
#   1 — coverage <  threshold (hybrid mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KDIR=""
JSON_MODE=0
THRESHOLD="0.80"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)      KDIR="$2";      shift 2 ;;
    --json)      JSON_MODE=1;    shift ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: scale-coverage.sh [--kdir <kdir>] [--json] [--threshold <float>]"
      exit 0
      ;;
    *) echo "Error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$KDIR" ]]; then
  KDIR=$(resolve_knowledge_dir)
fi

python3 - "$KDIR" "$JSON_MODE" "$THRESHOLD" << 'PYEOF'
import os, re, sys, json

kdir       = sys.argv[1]
json_mode  = sys.argv[2] == "1"
threshold  = float(sys.argv[3])

SKIP_DIRS = {"_work", "_threads", "_meta", "_followups", "_inbox",
             "_scorecards", "_self_test_results.md", "_batch-runs",
             "_calibration", "_renormalize", "_edge_synopses"}

# Regex matches: | scale: <value> | or | scale: <value> -->
SCALE_RE = re.compile(r'\|\s*scale:\s*([^\s|>]+)')

total   = 0
known   = 0
unknown = 0
unknown_paths = []

for root, dirs, files in os.walk(kdir):
    # Prune skip dirs in-place
    rel_root = os.path.relpath(root, kdir)
    top = rel_root.split(os.sep)[0]
    if top in SKIP_DIRS or top.startswith("_"):
        dirs.clear()
        continue
    dirs[:] = [d for d in dirs if not d.startswith("_")]

    for fname in files:
        if not fname.endswith(".md"):
            continue
        fpath = os.path.join(root, fname)
        rel   = os.path.relpath(fpath, kdir)
        try:
            content = open(fpath).read()
        except Exception:
            continue

        total += 1
        m = SCALE_RE.search(content)
        if m and m.group(1).lower() not in ("unknown", ""):
            known += 1
        else:
            unknown += 1
            unknown_paths.append(rel)

coverage  = known / total if total > 0 else 0.0
mode      = "drift-detector" if coverage >= threshold else "hybrid"
at_thresh = coverage >= threshold

if json_mode:
    print(json.dumps({
        "total":    total,
        "known":    known,
        "unknown":  unknown,
        "coverage": round(coverage, 4),
        "threshold": threshold,
        "mode":     mode,
        "unknown_paths": unknown_paths
    }, indent=2))
else:
    pct = f"{coverage:.1%}"
    print(f"Scale coverage: {known}/{total} ({pct}) — mode: {mode} (threshold: {threshold:.0%})")

sys.exit(0 if at_thresh else 1)
PYEOF