#!/usr/bin/env bash
# retro-aggregate.sh — Aggregate the maintainer's retro-pool into a convergence-tagged view
#
# Usage:
#   lore retro aggregate [--out <path>] [--json] [--kdir <path>] [--cycle-id <slug>]
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
# When --kdir and --cycle-id are provided, also emits the six-signal scale
# block and the three "better-than-no-scale" derivations.
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
KDIR_ARG=""
CYCLE_ID_ARG=""

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
    --kdir)
      KDIR_ARG="$2"
      shift 2
      ;;
    --cycle-id)
      CYCLE_ID_ARG="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: lore retro aggregate [--out <path>] [--json] [--kdir <path>] [--cycle-id <slug>]" >&2
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
COMPUTE_ARGS=("$POOL_DIR")
if [[ -n "$KDIR_ARG" && -n "$CYCLE_ID_ARG" ]]; then
  COMPUTE_ARGS+=(--kdir "$KDIR_ARG" --cycle-id "$CYCLE_ID_ARG")
fi
AGG_JSON=$(python3 "$SCRIPT_DIR/retro-aggregate-compute.py" "${COMPUTE_ARGS[@]}" 2>/dev/null)

# --- Write ---
printf '%s\n' "$AGG_JSON" > "$OUT"

CONVERGENT=$(jq '[.groups[] | select(.tag == "convergent")] | length' <<<"$AGG_JSON")
IDIOSYNCRATIC=$(jq '[.groups[] | select(.tag == "idiosyncratic")] | length' <<<"$AGG_JSON")
MIXED=$(jq '[.groups[] | select(.tag == "mixed")] | length' <<<"$AGG_JSON")
INSUFFICIENT=$(jq '[.groups[] | select(.tag == "insufficient")] | length' <<<"$AGG_JSON")
CONTRIBUTORS=$(jq '.contributors | length' <<<"$AGG_JSON")

HAS_SIGNALS=$(jq 'has("scale_signals")' <<<"$AGG_JSON")

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

# --- Six-signal block (emitted only when --kdir + --cycle-id were provided) ---
if [[ "$HAS_SIGNALS" == "true" ]]; then
  SIGNALS=$(jq '.scale_signals' <<<"$AGG_JSON")

  DECL_FRAC=$(jq -r '.declaration_coverage.fraction // "n/a"' <<<"$SIGNALS")
  REDECLARE_FRAC=$(jq -r '.redeclare_rate.fraction // "n/a"' <<<"$SIGNALS")
  ROUTES=$(jq -r '.off_scale_routes_emitted.count' <<<"$SIGNALS")
  VERIFIER=$(jq -r '.verifier_disagreements.count' <<<"$SIGNALS")

  # off_altitude_skipped and counterfactual_better from retro-scale-access sidecar
  OAS="n/a"
  CTF="n/a"
  if [[ -n "$KDIR_ARG" && -n "$CYCLE_ID_ARG" ]]; then
    SIDECAR="$KDIR_ARG/_scorecards/retro-scale-access.jsonl"
    if [[ -f "$SIDECAR" ]]; then
      # Most recent row for this cycle_id (compact output = one line per object)
      SIDECAR_ROW=$(jq -c --arg cid "$CYCLE_ID_ARG" 'select(.cycle_id == $cid)' "$SIDECAR" 2>/dev/null | tail -1)
      if [[ -n "$SIDECAR_ROW" ]]; then
        OAS_RAW=$(jq -r '.off_altitude_skipped // "n/a"' <<<"$SIDECAR_ROW")
        CTF_RAW=$(jq -r '.counterfactual_better // "n/a"' <<<"$SIDECAR_ROW")
        [[ -n "$OAS_RAW" ]] && OAS="$OAS_RAW"
        [[ -n "$CTF_RAW" ]] && CTF="$CTF_RAW"
      fi
    fi
  fi

  echo "== Scale signals (cycle $CYCLE_ID_ARG) =="
  echo "declaration_coverage:     $DECL_FRAC"
  echo "redeclare_rate:           $REDECLARE_FRAC"
  echo "off_scale_routes_emitted: $ROUTES"
  echo "verifier_disagreements:   $VERIFIER"
  echo "off_altitude_skipped:     $OAS"
  echo "counterfactual_better:    $CTF"
  echo ""

  # --- Three "better than no scale" derivations ---
  # 1. off_scale_routes_emitted > 0
  if [[ "$ROUTES" -gt 0 ]] 2>/dev/null; then
    D1="yes"
  else
    D1="no"
  fi

  # 2. counterfactual_better dominantly same-or-worse
  case "$CTF" in
    same|worse) D2="yes" ;;
    better)     D2="no" ;;
    *)          D2="unknown" ;;
  esac

  # 3. redeclare_rate stable/decreasing vs prior cycle
  # Read the prior cycle's redeclare_rate from the aggregate dir if available
  D3="unknown"
  if [[ -n "$KDIR_ARG" ]]; then
    PRIOR_AGG=$(ls -t "$HOME/.lore/_retro-aggregate/"*.json 2>/dev/null | sed -n '2p')
    if [[ -f "$PRIOR_AGG" ]]; then
      PRIOR_REDECLARE=$(jq -r '.scale_signals.redeclare_rate.fraction // "null"' "$PRIOR_AGG" 2>/dev/null)
      if [[ "$PRIOR_REDECLARE" != "null" && "$REDECLARE_FRAC" != "n/a" ]]; then
        if python3 -c "import sys; sys.exit(0 if float('$REDECLARE_FRAC') <= float('$PRIOR_REDECLARE') else 1)" 2>/dev/null; then
          D3="yes"
        else
          D3="no"
        fi
      fi
    fi
  fi

  echo "== Better-than-no-scale derivations =="
  echo "- off_scale_routes_emitted > 0: $D1"
  echo "- counterfactual_better dominantly same-or-worse: $D2"
  echo "- redeclare_rate stable/decreasing vs prior cycle: $D3"
  echo ""
fi

echo "Run '/evolve --pooled $OUT' to propose template edits from convergent evidence."
