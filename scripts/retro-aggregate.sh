#!/usr/bin/env bash
# retro-aggregate.sh — Aggregate the maintainer's retro-pool into a convergence-tagged view
#
# Usage:
#   lore retro aggregate [--out <path>] [--json]
#
# Reads every bundle in `~/.lore/_retro-pool/<contributor_id>/*.json`,
# groups scorecard cells by (template_id, template_version, metric), and
# tags each group with one of:
#   convergent    — same direction across ≥2 contributors with non-trivial n
#   idiosyncratic — only one contributor (or one contributor supplies most evidence)
#   mixed         — contributors disagree
#   insufficient  — n too small
#
# Writes the aggregate to `~/.lore/_retro-aggregate/<timestamp>.json`.
# Only `convergent` cells drive template edits by default (see
# `/evolve --pooled`).
#
# SCOPE: maintainer-only. Same inline role gate as retro-import.sh.
#
# Per multi-user-evolution-design.md §4–5:
#   - Minimum per-template edit: ≥2 contributors, 15-25 scored samples.
#   - Views: row-weighted AND contributor-balanced surface side-by-side.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

OUT=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: lore retro aggregate [--out <path>] [--json]" >&2
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

command -v jq &>/dev/null || fail "jq is required but not found on PATH"
command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

# --- Role gate (inline; replaced by resolve_role() from task-53) ---
ROLE="contributor"
GLOBAL_CONFIG="$HOME/.lore/config/settings.json"
if [[ -f "$GLOBAL_CONFIG" ]]; then
  G_ROLE=$(jq -r '.role // ""' "$GLOBAL_CONFIG" 2>/dev/null || echo "")
  [[ -n "$G_ROLE" ]] && ROLE="$G_ROLE"
fi
KDIR=$(resolve_knowledge_dir 2>/dev/null || echo "")
if [[ -n "$KDIR" && -f "$KDIR/config.json" ]]; then
  R_ROLE=$(jq -r '.role // ""' "$KDIR/config.json" 2>/dev/null || echo "")
  [[ -n "$R_ROLE" ]] && ROLE="$R_ROLE"
fi

if [[ "$ROLE" != "maintainer" ]]; then
  fail "lore retro aggregate requires role=maintainer (current: $ROLE)"
fi

POOL_DIR="$HOME/.lore/_retro-pool"
if [[ ! -d "$POOL_DIR" ]]; then
  fail "retro pool not found at $POOL_DIR. Run 'lore retro import <bundle>' first."
fi

# --- Resolve OUT ---
AGG_DIR="$HOME/.lore/_retro-aggregate"
mkdir -p "$AGG_DIR"
TIMESTAMP=$(timestamp_iso | tr ':' '-')
[[ -z "$OUT" ]] && OUT="$AGG_DIR/$TIMESTAMP.json"

# --- Aggregate ---
AGG_JSON=$(python3 "$SCRIPT_DIR/retro-aggregate-compute.py" "$POOL_DIR" 2>/dev/null)

# --- Write ---
printf '%s\n' "$AGG_JSON" > "$OUT"

CONVERGENT=$(jq '[.groups[] | select(.tag == "convergent")] | length' <<<"$AGG_JSON")
IDIOSYNCRATIC=$(jq '[.groups[] | select(.tag == "idiosyncratic")] | length' <<<"$AGG_JSON")
MIXED=$(jq '[.groups[] | select(.tag == "mixed")] | length' <<<"$AGG_JSON")
INSUFFICIENT=$(jq '[.groups[] | select(.tag == "insufficient")] | length' <<<"$AGG_JSON")
CONTRIBUTORS=$(jq '.contributors | length' <<<"$AGG_JSON")

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n \
    --arg path "$OUT" \
    --argjson convergent "$CONVERGENT" \
    --argjson idiosyncratic "$IDIOSYNCRATIC" \
    --argjson mixed "$MIXED" \
    --argjson insufficient "$INSUFFICIENT" \
    --argjson contributors "$CONTRIBUTORS" \
    '{path: $path, convergent: $convergent, idiosyncratic: $idiosyncratic, mixed: $mixed, insufficient: $insufficient, contributors: $contributors}'
  exit 0
fi

echo "[retro-aggregate] Wrote aggregate to $OUT"
echo "  contributors: $CONTRIBUTORS"
echo "  convergent:    $CONVERGENT (these drive /evolve --pooled)"
echo "  idiosyncratic: $IDIOSYNCRATIC"
echo "  mixed:         $MIXED"
echo "  insufficient:  $INSUFFICIENT"
echo ""
echo "Run '/evolve --pooled $OUT' to propose template edits from convergent evidence."
