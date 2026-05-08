#!/usr/bin/env bash
# framework-set-model.sh — Mutate the persisted role->model map in framework.json.
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
#   3. framework.json MUST exist; absent config emits a `[remediation]` line
#      directing the operator at install.sh and exits 2 (no implicit creation).
#
# Persistence:
#   Atomic write — read existing JSON → mutate `roles.<role>` → serialize to
#   temp via jq (preserving sibling keys, pretty-printed) → rename. No
#   in-place edit. Other top-level keys (framework, capability_overrides,
#   version) are preserved verbatim.
#
# Exit codes:
#   0  success (mutation written; dry-run print succeeded; idempotent no-op)
#   1  usage error (missing args, unknown flag)
#   2  framework.json absent or malformed (operator must run install.sh)
#   3  validation error (unknown role, role/model conflict with shape)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
framework-set-model.sh — mutate the persisted role->model map

Usage:
  lore framework set-model   <role> <model> [--json] [--dry-run]
  lore framework unset-model <role>         [--json] [--dry-run]

Subcommands:
  set-model     Bind <role> to <model> in framework.json roles.<role>
  unset-model   Remove the roles.<role> key (resolution falls through to
                roles.default per resolve_model_for_role precedence)

Options:
  --json        Emit a machine-readable JSON confirmation to stdout
  --dry-run     Print the planned mutation without writing framework.json
  --help, -h    Show this help

Validation:
  Role MUST appear in adapters/roles.json's closed set. set-model also
  validates the model against the active harness's model_routing.shape:
  provider/model syntax (slash separator) requires shape=multi; single-shape
  harnesses (claude-code, codex) reject cross-provider bindings with the
  same remediation language as 'lore framework doctor'.

Exit codes:
  0  success (mutation written, dry-run printed, or unset no-op)
  1  usage error
  2  framework.json absent/malformed (run install.sh)
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
CONFIG_PATH="$DATA_DIR/config/framework.json"
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

# --- Pre-flight: framework.json must exist + parse ---------------------------
if [[ ! -f "$CONFIG_PATH" ]]; then
  msg="framework config not found at $CONFIG_PATH"
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
  msg="framework config at $CONFIG_PATH is malformed JSON"
  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    emit_json "$SUBCOMMAND" "$ROLE" "$MODEL" "config-malformed" "$msg"
  else
    echo "Error: $msg" >&2
    echo "" >&2
    echo "[remediation] Inspect the file or re-run: bash install.sh --framework <name>" >&2
  fi
  exit 2
fi

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
  bind_err=""
  if ! bind_err=$(validate_role_model_binding "$ROLE" "$MODEL" 2>&1 >/dev/null); then
    # Build the same remediation language used by framework-doctor.sh's
    # role-conflict diagnostic so a user copying the hint from doctor sees
    # consistent language here. The doctor remediation is:
    #   "lore framework set-model <role> <bare-model-without-provider>"
    active=$(resolve_active_framework 2>/dev/null || echo "<unknown>")
    shape=$(framework_model_routing_shape 2>/dev/null || echo "single")
    remediation="lore framework set-model $ROLE <bare-model-without-provider>"
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
existing=$(jq -r --arg r "$ROLE" '.roles[$r] // ""' "$CONFIG_PATH")

case "$SUBCOMMAND" in
  set-model)
    if [[ "$existing" == "$MODEL" ]]; then
      msg="roles.$ROLE already bound to $MODEL — no change"
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
      msg="roles.$ROLE was already unset — no change"
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
      msg="would set roles.$ROLE=$MODEL in $CONFIG_PATH (was: ${existing:-<unset>})"
      ;;
    unset-model)
      msg="would remove roles.$ROLE from $CONFIG_PATH (was: $existing)"
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
# Write to a temp file in the same directory so the rename is on the same
# filesystem (no cross-device hop). On any failure between read and rename,
# the original framework.json is untouched.
tmp_file=$(mktemp "${CONFIG_PATH}.XXXXXX.tmp")
trap 'rm -f "$tmp_file"' EXIT

case "$SUBCOMMAND" in
  set-model)
    jq --arg r "$ROLE" --arg m "$MODEL" '.roles[$r] = $m' "$CONFIG_PATH" > "$tmp_file"
    ;;
  unset-model)
    jq --arg r "$ROLE" 'del(.roles[$r])' "$CONFIG_PATH" > "$tmp_file"
    ;;
esac

# Final newline for POSIX text-file friendliness — matches install.sh's
# `f.write("\n")` after json.dump.
printf '\n' >> "$tmp_file"

mv "$tmp_file" "$CONFIG_PATH"
trap - EXIT

# --- Confirmation -----------------------------------------------------------
case "$SUBCOMMAND" in
  set-model)
    msg="roles.$ROLE=$MODEL"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      emit_json "set-model" "$ROLE" "$MODEL" "ok" "$msg"
    else
      echo "[set-model] $msg"
    fi
    ;;
  unset-model)
    msg="removed roles.$ROLE (was: $existing); resolution will fall through to roles.default"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      emit_json "unset-model" "$ROLE" "" "ok" "$msg"
    else
      echo "[unset-model] $msg"
    fi
    ;;
esac

exit 0
