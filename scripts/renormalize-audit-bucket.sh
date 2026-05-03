#!/usr/bin/env bash
# renormalize-audit-bucket.sh — Compute rotating 1/16 audit bucket membership for a renormalize run.
#
# Usage:
#   renormalize-audit-bucket.sh [--dry-run] [--kdir <path>]
#
# Output (stdout, one path per line): entry paths (relative to KDIR) assigned to the current bucket.
# Also updates $KDIR/_renormalize/audit-bucket-state.json (unless --dry-run).
#
# Exit codes:
#   0 — success
#   1 — usage/setup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
KDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --kdir)    KDIR="$2"; shift 2 ;;
    --help|-h)
      cat >&2 <<'EOF'
Usage: renormalize-audit-bucket.sh [--dry-run] [--kdir <path>]

Computes the 1/16 rotating hash-bucket audit set for the current renormalize cycle.
Hash function: sha256(entry_path)[0:2] as hex, mod 16.
State file: $KDIR/_renormalize/audit-bucket-state.json

Options:
  --dry-run    Advance bucket index in memory only; do not write state file.
  --kdir       Override knowledge directory (default: lore resolve).
EOF
      exit 0
      ;;
    *) echo "Error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$KDIR" ]]; then
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  die "knowledge directory not found: $KDIR"
fi

MANIFEST="$KDIR/_manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
  die "_manifest.json not found in $KDIR"
fi

STATE_DIR="$KDIR/_renormalize"
STATE_FILE="$STATE_DIR/audit-bucket-state.json"

# Load or initialize state
if [[ -f "$STATE_FILE" ]]; then
  LAST_BUCKET=$(python3 - "$STATE_FILE" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
print(s.get("last_bucket", -1))
EOF
)
else
  LAST_BUCKET=-1
fi

# Advance bucket
CURRENT_BUCKET=$(( (LAST_BUCKET + 1) % 16 ))

# Compute bucket membership and emit matching entry paths
python3 - "$MANIFEST" "$CURRENT_BUCKET" <<'EOF'
import json, sys, hashlib

manifest_path = sys.argv[1]
target_bucket = int(sys.argv[2])

with open(manifest_path) as f:
    manifest = json.load(f)

entries = manifest.get("entries", {})
for path in sorted(entries.keys()):
    digest = hashlib.sha256(path.encode()).hexdigest()
    bucket = int(digest[:2], 16) % 16
    if bucket == target_bucket:
        print(path)
EOF

# Update state (unless dry-run)
if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$STATE_DIR"
  python3 - "$STATE_FILE" "$CURRENT_BUCKET" <<'EOF'
import json, sys
from datetime import datetime, timezone

state_file = sys.argv[1]
bucket = int(sys.argv[2])
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

state = {"last_bucket": bucket, "started_at": now}
with open(state_file, "w") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
EOF
fi

>&2 echo "[audit-bucket] Bucket $CURRENT_BUCKET/15 (dry-run=$DRY_RUN)"
