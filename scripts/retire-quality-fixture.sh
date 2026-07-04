#!/usr/bin/env bash
# retire-quality-fixture.sh — Retire a quality-regression fixture.
#
# Usage:
#   retire-quality-fixture.sh <fixture-id> --rationale "<reason>"
#       [--judge reverse-auditor] [--retired-by <agent>] [--kdir <path>]
#
# Moves the fixture to $KDIR/_quality-fixtures/_archive/<judge>/<fixture-id>/
# and records the rationale, retiring agent, sha, and date in a RETIREMENT.md
# file inside the archived fixture. This is the only sanctioned removal path
# for a fixture — deleting a fixture directory outright destroys the
# provenance trail the strict bar depends on.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  sed -n '2,13p' "$0" >&2
  exit 1
}

FIXTURE_ID=""
RATIONALE=""
JUDGE="reverse-auditor"
RETIRED_BY="${LORE_AGENT:-${USER:-unknown}}"
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rationale)  RATIONALE="${2:?--rationale requires a value}"; shift 2 ;;
    --judge)      JUDGE="${2:?--judge requires a value}"; shift 2 ;;
    --retired-by) RETIRED_BY="${2:?--retired-by requires a value}"; shift 2 ;;
    --kdir)       KDIR_OVERRIDE="${2:?--kdir requires a value}"; shift 2 ;;
    -h|--help)    usage ;;
    -*)           echo "[retire-fixture] Error: unknown flag: $1" >&2; usage ;;
    *)
      if [[ -z "$FIXTURE_ID" ]]; then FIXTURE_ID="$1"; else echo "[retire-fixture] Error: unexpected argument: $1" >&2; usage; fi
      shift ;;
  esac
done

[[ -n "$FIXTURE_ID" ]] || { echo "[retire-fixture] Error: <fixture-id> is required" >&2; usage; }
[[ -n "$RATIONALE" ]] || { echo "[retire-fixture] Error: --rationale is required (retirement without a recorded reason is prohibited)" >&2; usage; }

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR="$(resolve_knowledge_dir)"
fi

SRC="$KDIR/_quality-fixtures/$JUDGE/$FIXTURE_ID"
DEST_DIR="$KDIR/_quality-fixtures/_archive/$JUDGE"
DEST="$DEST_DIR/$FIXTURE_ID"

[[ -d "$SRC" ]] || die "fixture not found: $SRC"
[[ ! -e "$DEST" ]] || die "archived fixture already exists: $DEST"

LORE_REPO="${LORE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RETIRED_AT_SHA=$(git -C "$LORE_REPO" rev-parse HEAD 2>/dev/null || echo "unknown")
RETIRED_AT_ISO=$(timestamp_iso)

mkdir -p "$DEST_DIR"
mv "$SRC" "$DEST"

cat > "$DEST/RETIREMENT.md" << EOF
# Fixture Retirement — $FIXTURE_ID

- **Retired at:** $RETIRED_AT_ISO
- **Retired by:** $RETIRED_BY
- **Sha at retirement:** $RETIRED_AT_SHA
- **Judge:** $JUDGE

## Rationale

$RATIONALE
EOF

echo "[retire-fixture] retired '$FIXTURE_ID' to $DEST" >&2
echo "$DEST"
