#!/usr/bin/env bash
# trigger-log-append.sh — Append a validated trigger outcome to trigger-log.jsonl
#
# Usage:
#   lore trigger-log append --ceremony <type> --configured-p <float> --fired <bool>
#                           [--artifact-id <id>] [--role <judge-role>]
#                           [--rolled <float>] [--kdir <path>] [--json]
#   echo '<json>' | lore trigger-log append
#
# Reads a single JSON object (via flags or stdin), validates it against the
# canonical trigger-log row schema, and appends one JSON line to
# $KDIR/_scorecards/trigger-log.jsonl. Creates the _scorecards/ directory
# and file on first use.
#
# Consumers: `/retro` Step 3.8 `Audit coverage` and `Judge liveness` health
# checks (Phase 7b, tasks-41/42), and `Trigger realization rate` (task-40)
# — they compute observed firing rate per ceremony against the configured
# `p` in `~/.lore/config/settlement-config.json`, and cross-reference
# trigger firings against judge rows in `rows.jsonl` for the zero-rows-
# despite-triggers signature.
#
# Row schema (one JSONL line per roll):
#   {
#     "schema_version": "1",
#     "ceremony": "implement | pr-self-review | pr-review | spec",
#     "configured_p": 0.3,              // threshold at time of roll
#     "fired": true | false,            // did the trigger land `lore audit`
#     "rolled": 0.147,                  // optional; the random value (for audit)
#     "artifact_id": "<slug | null>",   // populated when fired=true
#     "role": "correctness-gate | curator | reverse-auditor | batch | null",
#                                        // which judge was spawned (or null for no-fire)
#     "triggered_at": "<ISO-8601 UTC>"
#   }
#
# Required fields (hard-validated):
#   schema_version  any non-null scalar (readers enforce upgrade policy)
#   ceremony        enum: implement | pr-self-review | pr-review | spec
#   configured_p    number in [0.0, 1.0]
#   fired           boolean
#   triggered_at    ISO-8601 string
#
# Optional fields:
#   rolled          number in [0.0, 1.0] — useful for audit; many writers
#                   omit it to avoid revealing the sampling seed
#   artifact_id     string; null is legal when fired=false
#   role            string; null is legal when fired=false
#
# Relationship to rows.jsonl: trigger-log.jsonl is telemetry about
# the *sampling*; rows.jsonl is verdict output from audits that happened
# to fire. A healthy pipeline has trigger-log entries → spawned audits →
# rows. Missing rows for fired triggers = broken execution path (zero-
# rows-despite-triggers, task-42).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SUBCOMMAND=""
ROW_JSON=""
CEREMONY=""
CONFIGURED_P=""
FIRED=""
ROLLED=""
ARTIFACT_ID=""
ROLE=""
TRIGGERED_AT=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
lore trigger-log append — append a validated trigger outcome to trigger-log.jsonl

Usage:
  lore trigger-log append --ceremony <type> --configured-p <float> --fired <bool>
                          [--artifact-id <id>] [--role <role>] [--rolled <float>]
                          [--triggered-at <iso8601>] [--kdir <path>] [--json]
  lore trigger-log append --row '<json>'
  echo '<json>' | lore trigger-log append

Ceremony: implement | pr-self-review | pr-review | spec
Role:     correctness-gate | curator | reverse-auditor | batch (use when fired=true)

See header of this script for the full row schema and consumer contract.
EOF
}

if [[ $# -gt 0 && "$1" == "append" ]]; then
  SUBCOMMAND="append"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --row)
      ROW_JSON="$2"
      shift 2
      ;;
    --ceremony)
      CEREMONY="$2"
      shift 2
      ;;
    --configured-p)
      CONFIGURED_P="$2"
      shift 2
      ;;
    --fired)
      FIRED="$2"
      shift 2
      ;;
    --rolled)
      ROLLED="$2"
      shift 2
      ;;
    --artifact-id)
      ARTIFACT_ID="$2"
      shift 2
      ;;
    --role)
      ROLE="$2"
      shift 2
      ;;
    --triggered-at)
      TRIGGERED_AT="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      echo "[trigger-log] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# Resolve knowledge directory.
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  echo "[trigger-log] Error: knowledge directory not found: $KDIR" >&2
  exit 1
fi

# If no --row supplied and no flag-form ceremony provided, read JSON from stdin.
if [[ -z "$ROW_JSON" && -z "$CEREMONY" ]]; then
  if [[ -t 0 ]]; then
    echo "[trigger-log] Error: no --row, no flag-form ceremony, and stdin is a tty" >&2
    usage
    exit 1
  fi
  ROW_JSON=$(cat)
fi

# Build ROW_JSON from flag-form if needed.
if [[ -z "$ROW_JSON" ]]; then
  if [[ -z "$TRIGGERED_AT" ]]; then
    TRIGGERED_AT=$(timestamp_iso)
  fi
  ROW_JSON=$(python3 - "$CEREMONY" "$CONFIGURED_P" "$FIRED" "$ROLLED" "$ARTIFACT_ID" "$ROLE" "$TRIGGERED_AT" <<'PYEOF'
import json, sys
ceremony, configured_p, fired, rolled, artifact_id, role, triggered_at = sys.argv[1:8]
row = {
    "schema_version": "1",
    "ceremony": ceremony,
    "configured_p": float(configured_p) if configured_p else None,
    "fired": {"true": True, "false": False}.get(fired.lower(), None),
    "triggered_at": triggered_at,
}
if rolled:
    row["rolled"] = float(rolled)
if artifact_id:
    row["artifact_id"] = artifact_id
if role:
    row["role"] = role
print(json.dumps(row))
PYEOF
)
fi

# Validate + append via python3.
export TRIGGER_LOG_ROW_JSON="$ROW_JSON"
export TRIGGER_LOG_PATH="$KDIR/_scorecards/trigger-log.jsonl"
export TRIGGER_LOG_JSON_MODE="$JSON_MODE"

python3 <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path

row_json = os.environ.get("TRIGGER_LOG_ROW_JSON", "").strip()
log_path = os.environ.get("TRIGGER_LOG_PATH", "")
json_mode = os.environ.get("TRIGGER_LOG_JSON_MODE", "0") == "1"

if not row_json:
    print("[trigger-log] Error: empty row", file=sys.stderr)
    sys.exit(1)

try:
    row = json.loads(row_json)
except json.JSONDecodeError as e:
    print(f"[trigger-log] Error: row is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(row, dict):
    print("[trigger-log] Error: row must be a JSON object", file=sys.stderr)
    sys.exit(1)

# Hard-validate required fields.
VALID_CEREMONIES = {"implement", "pr-self-review", "pr-review", "spec"}
errors = []

if not row.get("schema_version"):
    errors.append("schema_version: required, non-null")

ceremony = row.get("ceremony")
if ceremony not in VALID_CEREMONIES:
    errors.append(f"ceremony: must be one of {sorted(VALID_CEREMONIES)}, got {ceremony!r}")

p = row.get("configured_p")
if not isinstance(p, (int, float)) or not (0.0 <= p <= 1.0):
    errors.append(f"configured_p: must be a number in [0.0, 1.0], got {p!r}")

fired = row.get("fired")
if not isinstance(fired, bool):
    errors.append(f"fired: must be a boolean, got {type(fired).__name__}: {fired!r}")

# triggered_at: parseable ISO-8601.
triggered_at = row.get("triggered_at")
if not isinstance(triggered_at, str):
    errors.append("triggered_at: required ISO-8601 string")
else:
    try:
        datetime.fromisoformat(triggered_at.replace("Z", "+00:00"))
    except ValueError:
        errors.append(f"triggered_at: not a parseable ISO-8601 timestamp: {triggered_at!r}")

# Optional fields: validate when present.
rolled = row.get("rolled")
if rolled is not None and (not isinstance(rolled, (int, float)) or not (0.0 <= rolled <= 1.0)):
    errors.append(f"rolled: when present, must be a number in [0.0, 1.0], got {rolled!r}")

role = row.get("role")
VALID_ROLES = {"correctness-gate", "curator", "reverse-auditor", "batch", None}
if role is not None and role not in VALID_ROLES:
    errors.append(f"role: when present, must be one of {sorted(r for r in VALID_ROLES if r)} or null, got {role!r}")

if errors:
    for e in errors:
        print(f"[trigger-log] Validation error: {e}", file=sys.stderr)
    sys.exit(1)

# Ensure parent dir exists; append.
log_file = Path(log_path)
log_file.parent.mkdir(parents=True, exist_ok=True)

# Serialize as a single line (no indent) for JSONL.
line = json.dumps(row, separators=(",", ":"), sort_keys=False)
with open(log_file, "a", encoding="utf-8") as f:
    f.write(line + "\n")

if json_mode:
    print(json.dumps({"status": "appended", "path": str(log_file)}, indent=2))
else:
    print(f"[trigger-log] appended to {log_file}")
    print(f"[trigger-log]   ceremony={row['ceremony']} fired={row['fired']} p={row['configured_p']}")
PYEOF
