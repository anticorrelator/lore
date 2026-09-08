#!/usr/bin/env bash
# framework-set-model.sh — Mutate the active harness role->model map in settings.json.
#
# This is the write-side counterpart to framework-status.sh (read) and
# framework-doctor.sh (diagnose). It is the single source of truth for the
# `lore framework set-model` and `lore framework unset-model` subcommands;
# cli/lore::cmd_framework dispatches both subsubcommands here so the read
# side and the validators live in one place.
#
# Usage:
#   framework-set-model.sh set-model   <role> <model> [--json] [--dry-run]
#   framework-set-model.sh unset-model <role>         [--json] [--dry-run]
#
# Validation:
#   1. Role MUST be in the closed registry (adapters/roles.json).
#   2. set-model: model MUST be acceptable to validate_role_model_binding —
#      provider/model syntax (slash separator) requires the active harness's
#      model_routing.shape=multi; single-shape harnesses reject cross-provider
#      bindings. Remediation language matches framework-doctor.sh's role
#      conflict diagnostic so operators see the same string from both surfaces.
#   3. settings.json MUST exist; absent config emits a `[remediation]` line
#      directing the operator at install.sh and exits 2 (no implicit creation).
#
# Persistence:
#   Atomic write via scripts/settings.sh — mutate
#   `harnesses.<active>.roles.<role>` under the unified settings lock.
#
# Exit codes:
#   0  success (mutation written; dry-run print succeeded; idempotent no-op)
#   1  usage error (missing args, unknown flag)
#   2  settings.json absent or malformed (operator must run install.sh)
#   3  validation error (unknown role, role/model conflict with shape)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
framework-set-model.sh — mutate the persisted global route map

Usage:
  lore framework set-model   <role> <qualified-route|object> [--effort <v>] [--service-tier <v>] [--json] [--dry-run]
  lore framework unset-model <role>         [--json] [--dry-run]

Subcommands:
  set-model     Bind <role> in settings.json routes.<role>
  unset-model   Remove that role key (resolution falls through to
                the registry fallback role and then routes.default)

Options:
  --json        Emit a machine-readable JSON confirmation to stdout
  --dry-run     Print the planned mutation without writing settings.json
  --effort      Add an effort option when the supplied route does not contain one
  --service-tier Add a service tier when the supplied route does not contain one
  --help, -h    Show this help

Validation:
  Role MUST appear in adapters/roles.json's closed set. set-model also
  validates the complete candidate settings document through the canonical
  route parser before taking the existing settings mutation lock.

Exit codes:
  0  success (mutation written, dry-run printed, or unset no-op)
  1  usage error
  2  settings.json absent/malformed (run install.sh)
  3  validation error (unknown role or shape conflict)
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

SUBCOMMAND=""
ROLE=""
MODEL=""
JSON_OUTPUT=0
DRY_RUN=0
EFFORT=""
SERVICE_TIER=""

case "$1" in
  --help|-h)
    usage
    exit 0
    ;;
  set-model|unset-model)
    SUBCOMMAND="$1"
    shift
    ;;
  *)
    echo "Error: unknown subcommand '$1' (expected: set-model | unset-model)" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac

# Parse positional args + flags. Positional order is fixed:
#   set-model   <role> <model>
#   unset-model <role>
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --effort)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "Error: --effort requires a non-empty value" >&2; exit 1; }
      EFFORT="$2"; shift 2 ;;
    --service-tier)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "Error: --service-tier requires a non-empty value" >&2; exit 1; }
      SERVICE_TIER="$2"; shift 2 ;;
    --*)
      echo "Error: unknown flag '$1'" >&2
      echo "" >&2
      usage
      exit 1
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

case "$SUBCOMMAND" in
  set-model)
    if [[ ${#positional[@]} -ne 2 ]]; then
      echo "Error: 'set-model' requires exactly two positional args: <role> <model>" >&2
      echo "" >&2
      usage
      exit 1
    fi
    ROLE="${positional[0]}"
    MODEL="${positional[1]}"
    ;;
  unset-model)
    if [[ ${#positional[@]} -ne 1 ]]; then
      echo "Error: 'unset-model' requires exactly one positional arg: <role>" >&2
      echo "" >&2
      usage
      exit 1
    fi
    ROLE="${positional[0]}"
    ;;
esac

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required for 'lore framework set-model'" >&2
  exit 1
fi

DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
CONFIG_PATH="$DATA_DIR/config/settings.json"
SETTINGS_SH="$SCRIPT_DIR/settings.sh"
ROLES_FILE="$LORE_LIB_DIR/../adapters/roles.json"

# emit_json_then_exit <action> <role> [model] <status> <exit_code> [extra_message]
# Used by both the JSON and the human-text branches; the human branch only
# calls this when --json was set, so the "should I serialize?" check is at
# the call sites.
emit_json() {
  local action="$1" role="$2" model="$3" status="$4" message="$5"
  python3 - "$action" "$role" "$model" "$status" "$message" "$CONFIG_PATH" <<'PYEOF'
import json, sys
action, role, model, status, message, cfg_path = sys.argv[1:7]
out = {
    "action": action,
    "role": role,
    "status": status,
    "config_path": cfg_path,
    "message": message,
}
if model:
    out["model"] = model
print(json.dumps(out, indent=2))
PYEOF
}

# --- Pre-flight: settings.json must exist + parse ----------------------------
if [[ ! -f "$CONFIG_PATH" ]]; then
  msg="settings config not found at $CONFIG_PATH"
  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    emit_json "$SUBCOMMAND" "$ROLE" "$MODEL" "config-absent" "$msg"
  else
    echo "Error: $msg" >&2
    echo "" >&2
    echo "[remediation] Run: bash install.sh --framework <name>" >&2
  fi
  exit 2
fi
if ! jq -e . "$CONFIG_PATH" &>/dev/null; then
  msg="settings config at $CONFIG_PATH is malformed JSON"
  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    emit_json "$SUBCOMMAND" "$ROLE" "$MODEL" "config-malformed" "$msg"
  else
    echo "Error: $msg" >&2
    echo "" >&2
    echo "[remediation] Inspect the file or re-run: bash install.sh --framework <name>" >&2
  fi
  exit 2
fi

ROLE_PATH="routes.$ROLE"

# --- Validate role against the closed registry ------------------------------
# Done here (rather than relying solely on validate_role_model_binding) so the
# unset-model path also rejects unknown roles — validate_role_model_binding
# requires a non-empty model.
if [[ -f "$ROLES_FILE" ]]; then
  if ! jq -e --arg r "$ROLE" '.roles[] | select(.id == $r)' "$ROLES_FILE" &>/dev/null; then
    known=$(jq -r '[.roles[].id] | join(", ")' "$ROLES_FILE")
    msg="unknown role '$ROLE' (closed registry: $known)"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      emit_json "$SUBCOMMAND" "$ROLE" "$MODEL" "unknown-role" "$msg"
    else
      echo "Error: $msg" >&2
      echo "  See: $ROLES_FILE" >&2
    fi
    exit 3
  fi
fi

# --- set-model: validate role->model binding against shape ------------------
if [[ "$SUBCOMMAND" == "set-model" ]]; then
  # validate_role_model_binding writes its own error to stderr; we capture
  # it so the JSON branch can fold it into the message. The shape mismatch
  # error there mirrors the doctor remediation hint: provider/model syntax
  # requires shape=multi.
  route_err=""
  ROUTE_RESULT=$(python3 - "$SCRIPT_DIR" "$MODEL" "$EFFORT" "$SERVICE_TIER" <<'PY'
import importlib.util, json, sys
from pathlib import Path
scripts, raw, effort, tier = sys.argv[1:]
spec = importlib.util.spec_from_file_location("route_config", Path(scripts) / "route_config.py")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
try:
    try: supplied = json.loads(raw)
    except json.JSONDecodeError: supplied = raw
    parsed = mod.parse_route(supplied, str(Path(scripts).parent))
    options = dict(parsed["options"])
    if effort and "effort" in options:
        raise mod.RouteConfigError("duplicate_option", "--effort duplicates the supplied route option", "effort")
    if tier and "service_tier" in options:
        raise mod.RouteConfigError("duplicate_option", "--service-tier duplicates the supplied route option", "service_tier")
    if effort: options["effort"] = effort
    if tier: options["service_tier"] = tier
    candidate = {"framework": parsed["framework"], "model": parsed["model"], **options}
    # Re-parse after overlay so capability-declared values remain authoritative.
    mod.parse_route(candidate, str(Path(scripts).parent))
    print(json.dumps({"ok": True, "route": candidate}, separators=(",", ":"), sort_keys=True))
except mod.RouteConfigError as exc:
    print(json.dumps({"ok": False, "error": exc.message}, separators=(",", ":"), sort_keys=True))
PY
  )
  if [[ "$(printf '%s' "$ROUTE_RESULT" | jq -r '.ok')" != true ]]; then
    route_err=$(printf '%s' "$ROUTE_RESULT" | jq -r '.error')
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      emit_json "set-model" "$ROLE" "$MODEL" "binding-conflict" "$route_err"
    else
      echo "Error: $route_err" >&2
    fi
    exit 3
  fi
  ROUTE_CANON=$(printf '%s' "$ROUTE_RESULT" | jq -c '.route')
  MODEL="$ROUTE_CANON"
  CANDIDATE=$(jq -c --argjson route "$MODEL" --arg role "$ROLE" '.routes[$role]=$route' "$CONFIG_PATH")
  bind_err=""
  VALIDATION=$(printf '%s' "$CANDIDATE" | python3 -c 'import json,sys; print(json.dumps({"operation":"validate-settings","repo_root":sys.argv[1],"settings":json.load(sys.stdin)}))' "$SCRIPT_DIR/.." | python3 "$SCRIPT_DIR/route_config.py" || true)
  if [[ "$(printf '%s' "$VALIDATION" | jq -r '.ok')" != true ]]; then
    bind_err=$(printf '%s' "$VALIDATION" | jq -r '.error.message')
    active="global"
    shape="qualified"
    remediation="lore framework set-model $ROLE <framework/model>"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      python3 - "$ROLE" "$MODEL" "$active" "$shape" "$bind_err" "$remediation" "$CONFIG_PATH" <<'PYEOF'
import json, sys
role, model, fw, shape, err, remediation, cfg_path = sys.argv[1:8]
print(json.dumps({
    "action": "set-model",
    "role": role,
    "model": model,
    "status": "binding-conflict",
    "framework": fw,
    "model_routing_shape": shape,
    "config_path": cfg_path,
    "message": err.strip(),
    "remediation": remediation,
}, indent=2))
PYEOF
    else
      # validate_role_model_binding already prefixes its own "Error: " so we
      # echo the message verbatim — re-prefixing would produce "Error: Error: ".
      echo "$bind_err" >&2
      echo "  Active harness: $active (model_routing.shape=$shape)" >&2
      echo "  Remediation: $remediation" >&2
    fi
    exit 3
  fi
fi

# --- Compute the mutation + check for no-op ---------------------------------
# We check the existing value before the write so unset-model can report
# idempotent no-op (role wasn't bound) and set-model can flag "no change"
# for clarity. Both still exit 0 in the no-op case — the operator's intent
# is satisfied either way.
existing_raw=$(LORE_DATA_DIR="$DATA_DIR" bash "$SETTINGS_SH" get "$ROLE_PATH" 2>/dev/null || true)
existing=""
if [[ -n "$existing_raw" ]]; then
  existing=$(printf '%s' "$existing_raw" | jq -c '. // empty' 2>/dev/null || true)
fi

if [[ "$SUBCOMMAND" == "unset-model" && -n "$existing" ]]; then
  CANDIDATE=$(jq -c --arg role "$ROLE" 'del(.routes[$role])' "$CONFIG_PATH")
  VALIDATION=$(printf '%s' "$CANDIDATE" | python3 -c 'import json,sys; print(json.dumps({"operation":"validate-settings","repo_root":sys.argv[1],"settings":json.load(sys.stdin)}))' "$SCRIPT_DIR/.." | python3 "$SCRIPT_DIR/route_config.py" || true)
  if [[ "$(printf '%s' "$VALIDATION" | jq -r '.ok')" != true ]]; then
    msg="unsetting $ROLE would make the routing configuration invalid: $(printf '%s' "$VALIDATION" | jq -r '.error.message')"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      emit_json "unset-model" "$ROLE" "" "binding-conflict" "$msg"
    else
      echo "Error: $msg" >&2
    fi
    exit 3
  fi
fi

case "$SUBCOMMAND" in
  set-model)
    if [[ "$existing" == "$MODEL" ]]; then
      msg="$ROLE_PATH already bound to $MODEL — no change"
      if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        emit_json "set-model" "$ROLE" "$MODEL" "no-change" "$msg"
      else
        echo "[set-model] $msg"
      fi
      exit 0
    fi
    ;;
  unset-model)
    if [[ -z "$existing" ]]; then
      msg="$ROLE_PATH was already unset — no change"
      if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        emit_json "unset-model" "$ROLE" "" "no-change" "$msg"
      else
        echo "[unset-model] $msg"
      fi
      exit 0
    fi
    ;;
esac

# --- Dry-run path: print the planned mutation, do not write -----------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  case "$SUBCOMMAND" in
    set-model)
      msg="would set $ROLE_PATH=$MODEL in $CONFIG_PATH (was: ${existing:-<unset>})"
      ;;
    unset-model)
      msg="would remove $ROLE_PATH from $CONFIG_PATH (was: $existing)"
      ;;
  esac
  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    emit_json "$SUBCOMMAND" "$ROLE" "$MODEL" "dry-run" "$msg"
  else
    echo "[$SUBCOMMAND] [dry-run] $msg"
  fi
  exit 0
fi

# --- Atomic write -----------------------------------------------------------
case "$SUBCOMMAND" in
  set-model)
    LORE_DATA_DIR="$DATA_DIR" bash "$SETTINGS_SH" patch "$ROLE_PATH" "$MODEL"
    ;;
  unset-model)
    LORE_DATA_DIR="$DATA_DIR" bash "$SETTINGS_SH" delete "$ROLE_PATH"
    ;;
esac

# --- Confirmation -----------------------------------------------------------
case "$SUBCOMMAND" in
  set-model)
    msg="$ROLE_PATH=$MODEL"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      emit_json "set-model" "$ROLE" "$MODEL" "ok" "$msg"
    else
      echo "[set-model] $msg"
    fi
    ;;
  unset-model)
    msg="removed $ROLE_PATH (was: $existing); resolution will fall through to the registry fallback or routes.default"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      emit_json "unset-model" "$ROLE" "" "ok" "$msg"
    else
      echo "[unset-model] $msg"
    fi
    ;;
esac

exit 0
