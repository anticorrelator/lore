#!/usr/bin/env bash
# impl-gate-anchor.sh — File the anchor-coverage gate outcome for a work item
# Usage: impl-gate-anchor.sh <ref> --verdict <verdict> [--fit <text>] [--gap <text>]
#        [--scope-delta <text>] [--template-version <hash>] [--json]
#
# Appends exactly one entry to the work item's execution-log.md (via
# write-execution-log.sh, --source impl-verb) with the six fixed gate fields,
# then prints the route the caller should take: continue | respec | abort.
#
# The verdict is required — this script never infers it. Per-verdict field
# contract (R = required, - = must be omitted):
#
#   verdict              --fit  --gap  --scope-delta  remediation            route
#   aligned                R      -        -          continue               continue
#   misaligned-respec      -      R        -          run /spec <slug>       respec
#   misaligned-override    -      R        R          continue               continue
#   abort                  -      R        -          none (user aborted)    abort
#   legacy-skip            -      -        -          none (legacy skip)     continue
#
# The intent anchor is read from _meta.json (never passed as a flag). Verdict
# legacy-skip requires the anchor to be empty/absent; every other verdict
# requires it present. Free-text fields are JSON-string encoded in the log
# body so multi-line values survive as single lines. On misaligned-override
# the scope-delta acknowledgment is also appended to notes.md.
#
# Exit codes:
#   0  gate filed; route on stdout
#   1  validation error / no work-item match
#   2  ambiguous work-item reference

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

VALID_VERDICTS="aligned|misaligned-respec|misaligned-override|abort|legacy-skip"

REF=""
VERDICT=""
FIT=""
GAP=""
SCOPE_DELTA=""
TEMPLATE_VERSION=""
JSON_MODE=0
FIT_SET=0
GAP_SET=0
SCOPE_DELTA_SET=0

usage() {
  cat >&2 <<EOF
Usage: lore impl gate-anchor <ref> --verdict <verdict> [--fit <text>] [--gap <text>]
                             [--scope-delta <text>] [--template-version <hash>] [--json]

Verdicts: aligned | misaligned-respec | misaligned-override | abort | legacy-skip

Per-verdict fields: --fit on aligned; --gap on misaligned-* and abort;
--scope-delta on misaligned-override. All other combinations are rejected.

Exit codes: 0 filed (route on stdout), 1 error/no match, 2 ambiguous reference
EOF
}

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[impl] Error: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verdict)
      VERDICT="${2:-}"
      shift 2
      ;;
    --verdict=*)
      VERDICT="${1#--verdict=}"
      shift
      ;;
    --fit)
      FIT="${2:-}"
      FIT_SET=1
      shift 2
      ;;
    --fit=*)
      FIT="${1#--fit=}"
      FIT_SET=1
      shift
      ;;
    --gap)
      GAP="${2:-}"
      GAP_SET=1
      shift 2
      ;;
    --gap=*)
      GAP="${1#--gap=}"
      GAP_SET=1
      shift
      ;;
    --scope-delta)
      SCOPE_DELTA="${2:-}"
      SCOPE_DELTA_SET=1
      shift 2
      ;;
    --scope-delta=*)
      SCOPE_DELTA="${1#--scope-delta=}"
      SCOPE_DELTA_SET=1
      shift
      ;;
    --template-version)
      TEMPLATE_VERSION="${2:-}"
      shift 2
      ;;
    --template-version=*)
      TEMPLATE_VERSION="${1#--template-version=}"
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown flag: $1"
      ;;
    *)
      if [[ -z "$REF" ]]; then
        REF="$1"
      else
        fail "Unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$REF" ]]; then
  usage
  fail "Missing required argument: <ref>"
fi

if [[ -z "$VERDICT" ]]; then
  fail "--verdict is required ($VALID_VERDICTS)"
fi

case "$VERDICT" in
  aligned|misaligned-respec|misaligned-override|abort|legacy-skip) ;;
  *)
    fail "--verdict must be one of: $VALID_VERDICTS (got '$VERDICT')"
    ;;
esac

# --- Per-verdict field-presence contract -----------------------------------
require_field() {
  local set_flag="$1" value="$2" flag="$3"
  if [[ $set_flag -eq 0 || -z "$value" ]]; then
    fail "verdict '$VERDICT' requires $flag <text>"
  fi
}

forbid_field() {
  local set_flag="$1" flag="$2"
  if [[ $set_flag -eq 1 ]]; then
    fail "verdict '$VERDICT' does not take $flag"
  fi
}

case "$VERDICT" in
  aligned)
    require_field "$FIT_SET" "$FIT" --fit
    forbid_field "$GAP_SET" --gap
    forbid_field "$SCOPE_DELTA_SET" --scope-delta
    ;;
  misaligned-respec|abort)
    forbid_field "$FIT_SET" --fit
    require_field "$GAP_SET" "$GAP" --gap
    forbid_field "$SCOPE_DELTA_SET" --scope-delta
    ;;
  misaligned-override)
    forbid_field "$FIT_SET" --fit
    require_field "$GAP_SET" "$GAP" --gap
    require_field "$SCOPE_DELTA_SET" "$SCOPE_DELTA" --scope-delta
    ;;
  legacy-skip)
    forbid_field "$FIT_SET" --fit
    forbid_field "$GAP_SET" --gap
    forbid_field "$SCOPE_DELTA_SET" --scope-delta
    ;;
esac

# --- Resolve the work-item reference (tri-state exit passthrough) ----------
set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF")
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"error": "could not resolve work-item reference (exit %s)"}\n' "$RESOLVE_RC"
  fi
  exit "$RESOLVE_RC"
fi

SLUG=$(printf '%s\n' "$RESOLVED" | head -1)
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')

if [[ "$ARCHIVED" == "true" ]]; then
  fail "work item '$SLUG' is archived — the anchor-coverage gate applies to active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
META="$ITEM_DIR/_meta.json"

if [[ ! -f "$META" ]]; then
  fail "missing _meta.json for work item '$SLUG'"
fi

# --- Intent anchor: machine-sourced from _meta.json -------------------------
# Emitted as a JSON string so multi-line anchors stay on one log line.
ANCHOR_JSON=$(python3 - "$META" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    meta = json.load(f)
anchor = meta.get("intent_anchor") or ""
if isinstance(anchor, str) and anchor.strip():
    print(json.dumps(anchor))
else:
    print("None")
PYEOF
)

if [[ "$VERDICT" == "legacy-skip" ]]; then
  if [[ "$ANCHOR_JSON" != "None" ]]; then
    fail "verdict 'legacy-skip' requires an empty intent_anchor, but '$SLUG' has one — evaluate the gate and pass a real verdict"
  fi
else
  if [[ "$ANCHOR_JSON" == "None" ]]; then
    fail "work item '$SLUG' has no intent_anchor — use --verdict legacy-skip"
  fi
fi

json_string() {
  printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

FIT_JSON="None"
GAP_JSON="None"
SCOPE_DELTA_JSON="None"
[[ $FIT_SET -eq 1 ]] && FIT_JSON=$(json_string "$FIT")
[[ $GAP_SET -eq 1 ]] && GAP_JSON=$(json_string "$GAP")
[[ $SCOPE_DELTA_SET -eq 1 ]] && SCOPE_DELTA_JSON=$(json_string "$SCOPE_DELTA")

case "$VERDICT" in
  aligned)
    REMEDIATION="continue"
    ROUTE="continue"
    ;;
  misaligned-respec)
    REMEDIATION="run /spec $SLUG"
    ROUTE="respec"
    ;;
  misaligned-override)
    REMEDIATION="continue"
    ROUTE="continue"
    ;;
  abort)
    REMEDIATION="none (user aborted)"
    ROUTE="abort"
    ;;
  legacy-skip)
    REMEDIATION="none (legacy skip)"
    ROUTE="continue"
    ;;
esac

# --- Provenance: stamp the producing template's version at emission ---------
# Default derives from the implement skill template; --template-version overrides.
if [[ -z "$TEMPLATE_VERSION" ]]; then
  REPO_DIR="$(dirname "$(cd "$SCRIPT_DIR" && pwd -P)")"
  SKILL_TEMPLATE="$REPO_DIR/skills/implement/SKILL.md"
  if [[ -f "$SKILL_TEMPLATE" ]]; then
    TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$SKILL_TEMPLATE" 2>/dev/null || true)
  fi
fi

# --- Append the gate entry via the execution-log sole writer ----------------
BODY=$(printf 'Anchor-coverage gate: %s\nIntent anchor: %s\nAnchor fit statement: %s\nMisalignment gap: %s\nOverride scope delta: %s\nRemediation choice: %s' \
  "$VERDICT" "$ANCHOR_JSON" "$FIT_JSON" "$GAP_JSON" "$SCOPE_DELTA_JSON" "$REMEDIATION")

WLOG_ARGS=(--slug "$SLUG" --source impl-verb)
if [[ -n "$TEMPLATE_VERSION" ]]; then
  WLOG_ARGS+=(--template-version "$TEMPLATE_VERSION")
fi

if ! printf '%s\n' "$BODY" | bash "$SCRIPT_DIR/write-execution-log.sh" "${WLOG_ARGS[@]}" >/dev/null; then
  fail "execution-log append failed for '$SLUG'"
fi

# --- Dual write: override acknowledgment to notes.md -------------------------
NOTES_DUAL_WRITE=false
if [[ "$VERDICT" == "misaligned-override" ]]; then
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M")"
    echo "**Anchor-coverage override:** $SCOPE_DELTA"
  } >> "$ITEM_DIR/notes.md"
  NOTES_DUAL_WRITE=true
fi

# --- Output -----------------------------------------------------------------
if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(printf '{"slug": "%s", "verdict": "%s", "remediation": %s, "route": "%s", "notes_dual_write": %s}' \
    "$SLUG" "$VERDICT" "$(json_string "$REMEDIATION")" "$ROUTE" "$NOTES_DUAL_WRITE")"
fi

echo "[impl] Anchor-coverage gate '$VERDICT' filed for $SLUG"
echo "[impl] Execution-log entry appended: $ITEM_DIR/execution-log.md"
if [[ "$NOTES_DUAL_WRITE" == "true" ]]; then
  echo "[impl] Override scope delta recorded in $ITEM_DIR/notes.md"
fi
echo "Remediation: $REMEDIATION"
echo "Route: $ROUTE"
