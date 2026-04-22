#!/usr/bin/env bash
# scale-compute.sh — compute clamped absolute capture scale from (work-scope, role, slot)
#
# Usage:
#   scale-compute.sh --work-scope <scope> --role <role> --slot <slot> [--json]
#
# Inputs:
#   work-scope ∈ {architectural, subsystem, implementation, granular-fix, cross-cycle-meta}
#   role       ∈ {researcher, worker, advisor, spec-lead, implement-lead, retro}
#   slot       ∈ {Assertions, Observations, Investigation, Tests, Guidance, Synthesis, Reflection}
#
# Output (stdout, default plain):
#   architectural | subsystem | implementation
#
# With --json:
#   {"scale":"subsystem","offset":-1,"outcome":"canonical-capture"}
#
# Exit codes:
#   0 — success
#   1 — usage error (missing/unknown flag, unknown scope/role/slot value)
#   2 — role × slot combination is not a canonical capture (evidence-only or unknown pair)
#
# The canonical matrix lives in `architecture/agents/role-slot-matrix.md` (task #15).
# The offsets below are copied from that matrix. When the matrix changes, update this
# table — or refactor this script to parse the markdown file directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: scale-compute.sh --work-scope <scope> --role <role> --slot <slot> [--json]

Compute the clamped absolute capture scale for a (work-scope, role, slot) triple.

Scopes: architectural | subsystem | implementation | granular-fix | cross-cycle-meta
Roles:  researcher | worker | advisor | spec-lead | implement-lead | retro
Slots:  Assertions | Observations | Investigation | Tests | Guidance | Synthesis | Reflection

Output (plain): one of architectural | subsystem | implementation
Output (--json): {"scale":..., "offset":..., "outcome":...}
EOF
}

WORK_SCOPE=""
ROLE=""
SLOT=""
JSON=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-scope) WORK_SCOPE="$2"; shift 2 ;;
    --role)       ROLE="$2";       shift 2 ;;
    --slot)       SLOT="$2";       shift 2 ;;
    --json)       JSON=1;          shift ;;
    --help|-h)    usage; exit 0 ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$WORK_SCOPE" || -z "$ROLE" || -z "$SLOT" ]]; then
  echo "Error: --work-scope, --role, and --slot are all required" >&2
  usage
  exit 1
fi

# Map work-scope → integer (larger = broader).
# granular-fix and cross-cycle-meta are out-of-band anchors that clamp into
# {implementation, architectural} after any matrix offset.
case "$WORK_SCOPE" in
  cross-cycle-meta) SCOPE_NUM=4 ;;
  architectural)    SCOPE_NUM=3 ;;
  subsystem)        SCOPE_NUM=2 ;;
  implementation)   SCOPE_NUM=1 ;;
  granular-fix)     SCOPE_NUM=0 ;;
  *)
    echo "Error: unknown work-scope '$WORK_SCOPE'" >&2
    echo "  expected one of: architectural, subsystem, implementation, granular-fix, cross-cycle-meta" >&2
    exit 1
    ;;
esac

# Validate role/slot independently before pairing.
case "$ROLE" in
  researcher|worker|advisor|spec-lead|implement-lead|retro) : ;;
  *)
    echo "Error: unknown role '$ROLE'" >&2
    echo "  expected one of: researcher, worker, advisor, spec-lead, implement-lead, retro" >&2
    exit 1
    ;;
esac

case "$SLOT" in
  Assertions|Observations|Investigation|Tests|Guidance|Synthesis|Reflection) : ;;
  *)
    echo "Error: unknown slot '$SLOT'" >&2
    echo "  expected one of: Assertions, Observations, Investigation, Tests, Guidance, Synthesis, Reflection" >&2
    exit 1
    ;;
esac

# Role × slot matrix. Keyed "<role>|<slot>".
# Outcomes: canonical-capture | off-scale-route | evidence-only
# Offsets are integers in [-2, +2]; only meaningful for canonical-capture rows.
OUTCOME=""
OFFSET=0
case "$ROLE|$SLOT" in
  "researcher|Assertions")   OUTCOME="canonical-capture"; OFFSET=0 ;;
  "researcher|Observations") OUTCOME="canonical-capture"; OFFSET=-1 ;;
  "researcher|Investigation") OUTCOME="evidence-only" ;;
  "worker|Observations")     OUTCOME="canonical-capture"; OFFSET=-1 ;;
  "worker|Tests")            OUTCOME="evidence-only" ;;
  "advisor|Guidance")        OUTCOME="canonical-capture"; OFFSET=0 ;;
  "spec-lead|Synthesis")     OUTCOME="canonical-capture"; OFFSET=0 ;;
  "implement-lead|Synthesis") OUTCOME="canonical-capture"; OFFSET=0 ;;
  "retro|Reflection")        OUTCOME="canonical-capture"; OFFSET=1 ;;
  *)
    echo "Error: role × slot pair '$ROLE × $SLOT' has no matrix entry" >&2
    echo "  see architecture/agents/role-slot-matrix.md for valid combinations" >&2
    exit 2
    ;;
esac

if [[ "$OUTCOME" != "canonical-capture" ]]; then
  echo "Error: role × slot pair '$ROLE × $SLOT' resolves to outcome '$OUTCOME' — no scale to compute" >&2
  exit 2
fi

# Compute raw scale, then clamp to [1, 3] = {implementation, subsystem, architectural}.
RAW=$(( SCOPE_NUM + OFFSET ))
if   (( RAW < 1 )); then SCALE_NUM=1
elif (( RAW > 3 )); then SCALE_NUM=3
else                     SCALE_NUM=$RAW
fi

case "$SCALE_NUM" in
  3) SCALE="architectural" ;;
  2) SCALE="subsystem" ;;
  1) SCALE="implementation" ;;
esac

if (( JSON )); then
  printf '{"scale":"%s","offset":%d,"outcome":"%s"}\n' "$SCALE" "$OFFSET" "$OUTCOME"
else
  printf '%s\n' "$SCALE"
fi
