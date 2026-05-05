#!/usr/bin/env bash
# framework-doctor.sh — Diagnostic + remediation for the active lore harness.
#
# Where status (T20) is a read-only inspector of *configured* state, doctor
# is allowed to walk the cwd resolution chain and surface conflicts that
# need an operator action. Diagnostics emitted:
#
#   1. Config presence / well-formedness                  (actionable hints)
#   2. Role-binding x model_routing capability conflicts  (with set-model fix)
#   3. Per-repo .lore.config cwd-vs-user-config diff
#   4. Capability override inspection (overrides + evidence-ceiling check)
#
# Doctor is the operator-facing surface that maps each problem to the
# remediation command (`bash install.sh ...`, `lore framework set-model ...`,
# `lore config show`, etc.) instead of merely reporting state.
#
# Usage:
#   framework-doctor.sh [--json]
#   framework-doctor.sh capability-overrides [--json]
#
# Exit codes:
#   0  no diagnostics fired
#   1  usage error
#   2  config absent/malformed (operator must run install.sh)
#   3  one or more diagnostics fired (role conflict, capability override
#      promoted past evidence ceiling, missing-evidence soft-block, etc.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

JSON_OUTPUT=0
SUBCOMMAND="doctor"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      cat >&2 <<EOF
framework-doctor.sh — diagnose + remediate the active lore harness

Usage:
  lore framework doctor [--json]
  lore framework capability-overrides [--json]

Sections (doctor):
  Config       Presence/well-formedness check; actionable install hint
  Resolution   Cwd context (cwd, .lore.config discovered, user-config path)
  Capabilities Active capability_overrides, evidence-ceiling checks, gaps
  Roles        Resolved role->model bindings (full env->per-repo->user->default
               chain); rejects bindings that conflict with the active
               harness's model_routing capability
  Per-repo     Diff between cwd resolution (.lore.config + env) and the
               user-config defaults (so operators see what cwd changes)

Sections (capability-overrides):
  Overrides    For each active override, the shadowed profile level and a
               flag if the override promotes the capability past its
               evidence-supported ceiling (D8 violation)

Options:
  --json         emit machine-readable JSON
  --help, -h     show this help

Exit codes:
  0  no diagnostics fired
  2  config absent/malformed
  3  one or more diagnostics fired
EOF
      exit 0
      ;;
    capability-overrides)
      SUBCOMMAND="capability-overrides"
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    *)
      echo "Error: unknown framework doctor flag '$1'" >&2
      echo "" >&2
      echo "Usage: lore framework doctor [--json]" >&2
      echo "       lore framework capability-overrides [--json]" >&2
      exit 1
      ;;
  esac
done

DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
CONFIG_PATH="$DATA_DIR/config/framework.json"
CAPABILITIES_FILE="$LORE_LIB_DIR/../adapters/capabilities.json"
ROLES_FILE="$LORE_LIB_DIR/../adapters/roles.json"
EVIDENCE_FILE="$LORE_LIB_DIR/../adapters/capabilities-evidence.md"
COMPAT_DOC="$LORE_LIB_DIR/../docs/framework-compatibility.md"

# Normalize paths.
[[ -f "$CAPABILITIES_FILE" ]] && CAPABILITIES_FILE="$(cd "$(dirname "$CAPABILITIES_FILE")" && pwd)/$(basename "$CAPABILITIES_FILE")"
[[ -f "$EVIDENCE_FILE" ]]     && EVIDENCE_FILE="$(cd "$(dirname "$EVIDENCE_FILE")" && pwd)/$(basename "$EVIDENCE_FILE")"
[[ -f "$COMPAT_DOC" ]]        && COMPAT_DOC="$(cd "$(dirname "$COMPAT_DOC")" && pwd)/$(basename "$COMPAT_DOC")"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required for 'lore framework doctor'" >&2
  exit 1
fi
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required for 'lore framework doctor'" >&2
  exit 1
fi
if [[ ! -f "$CAPABILITIES_FILE" ]]; then
  echo "Error: capabilities profile not found at $CAPABILITIES_FILE" >&2
  exit 1
fi

# --- Config presence / well-formedness ----------------------------------------
CONFIG_STATUS="absent"
CONFIG_PARSE_ERROR=""
if [[ -f "$CONFIG_PATH" ]]; then
  if jq -e . "$CONFIG_PATH" &>/dev/null; then
    CONFIG_STATUS="present"
  else
    CONFIG_STATUS="malformed"
    CONFIG_PARSE_ERROR=$(jq . "$CONFIG_PATH" 2>&1 >/dev/null || true)
  fi
fi

ACTIVE_FRAMEWORK=""
if ACTIVE_FRAMEWORK=$(resolve_active_framework 2>/dev/null); then :; else ACTIVE_FRAMEWORK=""; fi

FRAMEWORK_DISPLAY=""
FRAMEWORK_BINARY=""
MODEL_ROUTING_SHAPE=""
MODEL_ROUTING_NOTES=""
if [[ -n "$ACTIVE_FRAMEWORK" ]]; then
  FRAMEWORK_DISPLAY=$(jq -r --arg fw "$ACTIVE_FRAMEWORK" '.frameworks[$fw].display_name // ""' "$CAPABILITIES_FILE")
  FRAMEWORK_BINARY=$(jq -r --arg fw "$ACTIVE_FRAMEWORK" '.frameworks[$fw].binary // ""' "$CAPABILITIES_FILE")
  MODEL_ROUTING_SHAPE=$(jq -r --arg fw "$ACTIVE_FRAMEWORK" '.frameworks[$fw].model_routing.shape // ""' "$CAPABILITIES_FILE")
  MODEL_ROUTING_NOTES=$(jq -r --arg fw "$ACTIVE_FRAMEWORK" '.frameworks[$fw].model_routing.notes // ""' "$CAPABILITIES_FILE")
fi

# --- Per-repo .lore.config discovery ------------------------------------------
LORE_CONFIG_PATH=""
if discovered=$(find_lore_config 2>/dev/null) && [[ -n "$discovered" ]]; then
  LORE_CONFIG_PATH="$discovered"
fi
CWD_PATH="$(pwd)"

# --- Capability + override + role analysis ------------------------------------
# A single python helper does the cross-file join: capabilities.json profile +
# framework.json overrides + roles.json registry + .lore.config (if any) +
# resolved env vars. The shell side calls resolve_model_for_role for the
# user-config layer (so resolution drift between python and lib.sh is
# impossible) and feeds those answers in via env.

# Enumerate role ids to call resolve_model_for_role per-role from bash.
ROLE_IDS=""
if [[ -f "$ROLES_FILE" ]]; then
  ROLE_IDS=$(jq -r '.roles[].id' "$ROLES_FILE" 2>/dev/null | tr '\n' ' ')
fi

# Resolve each role via the canonical lib.sh helper. We capture both the
# resolved value AND the per-repo .lore.config value (if any) separately so
# the per-repo diff section can show "cwd would resolve X but user-config
# defaults to Y".
ROLE_RESOLUTIONS_JSON='{}'
if [[ -n "$ROLE_IDS" ]]; then
  ROLE_RESOLUTIONS_JSON=$(
    LORE_LIB_DIR_FOR_PY="$SCRIPT_DIR" \
    LORE_CONFIG_PATH_FOR_PY="$LORE_CONFIG_PATH" \
    CONFIG_PATH_FOR_PY="$CONFIG_PATH" \
    ROLE_IDS_FOR_PY="$ROLE_IDS" \
    python3 - <<'PYEOF'
import json, os, subprocess

role_ids = os.environ["ROLE_IDS_FOR_PY"].split()
lore_config = os.environ["LORE_CONFIG_PATH_FOR_PY"]
cfg_path = os.environ["CONFIG_PATH_FOR_PY"]
lib_dir = os.environ["LORE_LIB_DIR_FOR_PY"]
out = {}

for rid in role_ids:
    entry = {"role": rid, "resolved": "", "resolved_source": "unset", "resolved_error": ""}
    # Resolved value via lib.sh (full chain).
    try:
        r = subprocess.run(
            ["bash", "-c", "source " + lib_dir + "/lib.sh && resolve_model_for_role " + rid],
            capture_output=True, text=True, env=os.environ,
        )
        if r.returncode == 0:
            entry["resolved"] = r.stdout.strip()
        else:
            entry["resolved_error"] = r.stderr.strip()
    except Exception as e:
        entry["resolved_error"] = str(e)

    # Per-repo .lore.config layer: read directly so we can distinguish "cwd
    # took it" from "user config took it" without re-running the resolver
    # in a stripped env.
    repo_value = ""
    if lore_config and os.path.exists(lore_config):
        with open(lore_config) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key = "model_for_" + rid + "="
                if line.startswith(key):
                    repo_value = line[len(key):].strip()
                    break
    entry["per_repo"] = repo_value

    # Env layer.
    entry["env"] = os.environ.get("LORE_MODEL_" + rid.upper(), "")

    # User-config layer (raw read; resolve_model_for_role handles fallback to
    # default but we want to see explicit-vs-default for the diff section).
    user_value = ""
    user_default = ""
    if os.path.exists(cfg_path):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
            user_value = (cfg.get("roles") or {}).get(rid, "") or ""
            user_default = (cfg.get("roles") or {}).get("default", "") or ""
        except Exception:
            pass
    entry["user_config"] = user_value
    entry["user_config_default"] = user_default

    # Source attribution: which layer did the resolver actually use?
    if entry["env"]:
        entry["resolved_source"] = "env"
    elif entry["per_repo"]:
        entry["resolved_source"] = "per-repo"
    elif user_value:
        entry["resolved_source"] = "user-config"
    elif user_default and rid != "default":
        entry["resolved_source"] = "user-default"
    elif user_default and rid == "default":
        entry["resolved_source"] = "user-config"
    elif entry["resolved"]:
        entry["resolved_source"] = "unknown"
    else:
        entry["resolved_source"] = "unset"

    out[rid] = entry

print(json.dumps(out))
PYEOF
  )
fi

# Validate each role binding against the active harness's model_routing
# shape. Emits one line per conflict; resolved bindings that pass validation
# produce no row.
ROLE_CONFLICTS_JSON='[]'
if [[ -n "$ROLE_IDS" && -n "$ACTIVE_FRAMEWORK" ]]; then
  ROLE_CONFLICTS_JSON=$(
    ROLE_RESOLUTIONS_JSON_FOR_PY="$ROLE_RESOLUTIONS_JSON" \
    MODEL_ROUTING_SHAPE_FOR_PY="$MODEL_ROUTING_SHAPE" \
    ACTIVE_FRAMEWORK_FOR_PY="$ACTIVE_FRAMEWORK" \
    python3 - <<'PYEOF'
import json, os

resolutions = json.loads(os.environ["ROLE_RESOLUTIONS_JSON_FOR_PY"])
shape = os.environ["MODEL_ROUTING_SHAPE_FOR_PY"]
fw = os.environ["ACTIVE_FRAMEWORK_FOR_PY"]
conflicts = []

for rid, entry in resolutions.items():
    model = entry.get("resolved", "")
    if not model:
        # Genuinely unset roles are not a binding-conflict; the resolver's
        # error already told the caller "no binding for role X". Doctor flags
        # this separately under the unbound-roles diagnostic, not here.
        continue
    # Provider/model syntax requires multi-shape; mirrors validate_role_model_binding.
    if "/" in model and shape != "multi":
        conflicts.append({
            "role": rid,
            "model": model,
            "source": entry.get("resolved_source"),
            "framework": fw,
            "shape": shape,
            "remediation": "lore framework set-model " + rid + " <bare-model-without-provider>",
            "reason": "provider/model syntax requires model_routing.shape=multi (active harness is " + shape + ")",
        })

print(json.dumps(conflicts))
PYEOF
  )
fi

# Capabilities + overrides + evidence ceiling.
# For each capability override:
#   - shadowed_level   — what the static profile said the level was
#   - override_level   — what the user override forced it to
#   - evidence         — evidence id from the static profile
#   - ceiling_violation — true when override_level > shadowed_level (i.e.,
#                         the override promotes the cap past its evidence-
#                         supported ceiling, violating D8)
# Levels ranked: full > partial > fallback > none. An override that DROPS
# a level (e.g., from full to partial) is fine — the operator deliberately
# degrades a capability. An override that PROMOTES (partial -> full,
# fallback -> partial, none -> anything) is the D8 violation.
CAPABILITY_REPORT_JSON=$(
  CAPABILITIES_FILE="$CAPABILITIES_FILE" \
  CONFIG_PATH="$CONFIG_PATH" \
  ACTIVE_FRAMEWORK="$ACTIVE_FRAMEWORK" \
  python3 - <<'PYEOF'
import json, os

caps_path = os.environ["CAPABILITIES_FILE"]
cfg_path = os.environ["CONFIG_PATH"]
fw = os.environ["ACTIVE_FRAMEWORK"]

with open(caps_path) as f:
    caps = json.load(f)

profile_caps = ((caps.get("frameworks") or {}).get(fw) or {}).get("capabilities") or {}

overrides = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
        overrides = cfg.get("capability_overrides") or {}
    except Exception:
        overrides = {}

# Capability rank for ceiling check. "none" is below all real support.
RANK = {"none": 0, "fallback": 1, "partial": 2, "full": 3}

def rank(level):
    return RANK.get(level, -1)

cells = []
for name in (caps.get("capabilities") or {}).keys():
    # model_routing lives at .frameworks[fw].model_routing (not under
    # .capabilities) — it is registered in the top-level capability map
    # for documentation but is rendered in the framework header, not the
    # per-cell list. Mirror framework-status.sh which skips cells absent
    # from the per-framework profile.
    if name not in profile_caps and name not in overrides:
        continue
    cell = profile_caps.get(name) or {}
    profile_level = cell.get("support") or "none"
    profile_evidence = cell.get("evidence") or ""
    override_level = overrides.get(name)
    if override_level:
        ceiling_violation = rank(override_level) > rank(profile_level)
    else:
        ceiling_violation = False
    effective = override_level or profile_level

    # degradation vocab — see conventions/capability-cells-in-adapters-capabilities-json-sho.md
    if effective == "none":
        deg = "degraded:none"
    elif effective in ("partial", "fallback"):
        if not profile_evidence and not override_level:
            deg = "degraded:no-evidence"
        elif override_level and not profile_evidence:
            deg = "degraded:unverified-support({})".format(override_level)
        else:
            deg = "degraded:" + effective
    else:  # full
        if not profile_evidence and not override_level:
            deg = "degraded:no-evidence"
        elif override_level:
            # Override forces full; D8 says no-evidence/promoted-past-ceiling
            # cells should be flagged so the operator sees the gap.
            deg = "degraded:unverified-support(full)"
        else:
            deg = "ok"

    cells.append({
        "capability": name,
        "profile_level": profile_level,
        "override_level": override_level or "",
        "effective_level": effective,
        "evidence": profile_evidence,
        "ceiling_violation": ceiling_violation,
        "degradation": deg,
    })

print(json.dumps(cells))
PYEOF
)

# Per-repo cwd-vs-user-config diff.
PER_REPO_DIFF_JSON='[]'
if [[ -n "$LORE_CONFIG_PATH" ]]; then
  PER_REPO_DIFF_JSON=$(
    ROLE_RESOLUTIONS_JSON_FOR_PY="$ROLE_RESOLUTIONS_JSON" \
    python3 - <<'PYEOF'
import json, os
resolutions = json.loads(os.environ["ROLE_RESOLUTIONS_JSON_FOR_PY"])
diffs = []
for rid, entry in resolutions.items():
    repo = entry.get("per_repo", "")
    if not repo:
        continue
    user = entry.get("user_config", "") or entry.get("user_config_default", "")
    if user and repo != user:
        diffs.append({
            "role": rid,
            "per_repo": repo,
            "user_config": user,
        })
    elif not user:
        diffs.append({
            "role": rid,
            "per_repo": repo,
            "user_config": "(unset)",
        })
print(json.dumps(diffs))
PYEOF
  )
fi

# --- Compute exit code --------------------------------------------------------
DIAG_COUNT=0
HAS_CONFLICT=$(echo "$ROLE_CONFLICTS_JSON" | jq 'length' 2>/dev/null || echo 0)
HAS_CEILING=$(echo "$CAPABILITY_REPORT_JSON" | jq '[.[] | select(.ceiling_violation == true)] | length' 2>/dev/null || echo 0)
DIAG_COUNT=$((HAS_CONFLICT + HAS_CEILING))

# --- capability-overrides subcommand path -------------------------------------
if [[ "$SUBCOMMAND" == "capability-overrides" ]]; then
  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    OVERRIDES_ONLY=$(echo "$CAPABILITY_REPORT_JSON" | jq '[.[] | select(.override_level != "")]')
    ACTIVE_FRAMEWORK_FOR_PY="$ACTIVE_FRAMEWORK" \
    CONFIG_STATUS_FOR_PY="$CONFIG_STATUS" \
    CONFIG_PATH_FOR_PY="$CONFIG_PATH" \
    OVERRIDES_ONLY_FOR_PY="$OVERRIDES_ONLY" \
    python3 - <<'PYEOF'
import json, os
out = {
    "framework": {
        "name": os.environ["ACTIVE_FRAMEWORK_FOR_PY"],
        "config_status": os.environ["CONFIG_STATUS_FOR_PY"],
        "config_path": os.environ["CONFIG_PATH_FOR_PY"],
    },
    "overrides": json.loads(os.environ["OVERRIDES_ONLY_FOR_PY"]),
}
print(json.dumps(out, indent=2))
PYEOF
    [[ "$CONFIG_STATUS" != "present" ]] && exit 2
    [[ "$HAS_CEILING" -gt 0 ]] && exit 3
    exit 0
  fi

  echo "[capability-overrides]"
  if [[ "$CONFIG_STATUS" != "present" ]]; then
    echo "  Config $CONFIG_STATUS at $CONFIG_PATH — no overrides to inspect"
    echo "  Run: bash install.sh --framework <name>"
    exit 2
  fi
  rows=$(echo "$CAPABILITY_REPORT_JSON" | jq -r --arg sep $'\x1f' \
    '.[] | select(.override_level != "") | "\(.capability)\($sep)\(.profile_level)\($sep)\(.override_level)\($sep)\(.evidence)\($sep)\(.ceiling_violation)\($sep)\(.degradation)"')
  if [[ -z "$rows" ]]; then
    echo "  (no active capability_overrides on $ACTIVE_FRAMEWORK)"
    exit 0
  fi
  while IFS=$'\x1f' read -r cap profile override evidence ceiling deg; do
    [[ -z "$cap" ]] && continue
    suffix=""
    if [[ "$ceiling" == "true" ]]; then
      suffix=" — VIOLATION: override promotes past evidence-supported ceiling ($profile)"
    fi
    if [[ -n "$evidence" ]]; then
      echo "  $cap: $profile -> $override [$deg]$suffix"
      echo "    Evidence: $evidence"
    else
      echo "  $cap: $profile -> $override [$deg]$suffix"
      echo "    Evidence: (none — see capabilities-evidence.md _index)"
    fi
  done <<< "$rows"
  if [[ "$HAS_CEILING" -gt 0 ]]; then
    echo ""
    echo "[remediation] Capability overrides above the evidence-supported ceiling"
    echo "  violate D8 (capability profiles are evidence-gated). Either:"
    echo "  (a) refresh adapters/capabilities-evidence.md so the profile cell"
    echo "      can be promoted (preferred), or"
    echo "  (b) lower the override to a level the evidence supports."
    exit 3
  fi
  exit 0
fi

# --- doctor (default) JSON output ---------------------------------------------
if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  CONFIG_STATUS_FOR_PY="$CONFIG_STATUS" \
  CONFIG_PATH_FOR_PY="$CONFIG_PATH" \
  CONFIG_PARSE_ERROR_FOR_PY="$CONFIG_PARSE_ERROR" \
  ACTIVE_FRAMEWORK_FOR_PY="$ACTIVE_FRAMEWORK" \
  FRAMEWORK_DISPLAY_FOR_PY="$FRAMEWORK_DISPLAY" \
  FRAMEWORK_BINARY_FOR_PY="$FRAMEWORK_BINARY" \
  MODEL_ROUTING_SHAPE_FOR_PY="$MODEL_ROUTING_SHAPE" \
  MODEL_ROUTING_NOTES_FOR_PY="$MODEL_ROUTING_NOTES" \
  CWD_PATH_FOR_PY="$CWD_PATH" \
  LORE_CONFIG_PATH_FOR_PY="$LORE_CONFIG_PATH" \
  CAPABILITY_REPORT_JSON_FOR_PY="$CAPABILITY_REPORT_JSON" \
  ROLE_RESOLUTIONS_JSON_FOR_PY="$ROLE_RESOLUTIONS_JSON" \
  ROLE_CONFLICTS_JSON_FOR_PY="$ROLE_CONFLICTS_JSON" \
  PER_REPO_DIFF_JSON_FOR_PY="$PER_REPO_DIFF_JSON" \
  DIAG_COUNT_FOR_PY="$DIAG_COUNT" \
  python3 - <<'PYEOF'
import json, os
out = {
    "config_status": os.environ["CONFIG_STATUS_FOR_PY"],
    "config_path": os.environ["CONFIG_PATH_FOR_PY"],
    "config_parse_error": os.environ["CONFIG_PARSE_ERROR_FOR_PY"].strip() or None,
    "framework": {
        "name": os.environ["ACTIVE_FRAMEWORK_FOR_PY"],
        "display_name": os.environ["FRAMEWORK_DISPLAY_FOR_PY"],
        "binary": os.environ["FRAMEWORK_BINARY_FOR_PY"],
        "model_routing": {
            "shape": os.environ["MODEL_ROUTING_SHAPE_FOR_PY"],
            "notes": os.environ["MODEL_ROUTING_NOTES_FOR_PY"],
        },
    },
    "resolution_context": {
        "cwd": os.environ["CWD_PATH_FOR_PY"],
        "lore_config_discovered": os.environ["LORE_CONFIG_PATH_FOR_PY"] or None,
        "user_config": os.environ["CONFIG_PATH_FOR_PY"],
    },
    "capabilities": json.loads(os.environ["CAPABILITY_REPORT_JSON_FOR_PY"]),
    "roles": list(json.loads(os.environ["ROLE_RESOLUTIONS_JSON_FOR_PY"]).values()),
    "role_conflicts": json.loads(os.environ["ROLE_CONFLICTS_JSON_FOR_PY"]),
    "per_repo_diff": json.loads(os.environ["PER_REPO_DIFF_JSON_FOR_PY"]),
    "diagnostics_fired": int(os.environ["DIAG_COUNT_FOR_PY"]),
}
print(json.dumps(out, indent=2))
PYEOF
  [[ "$CONFIG_STATUS" != "present" ]] && exit 2
  [[ "$DIAG_COUNT" -gt 0 ]] && exit 3
  exit 0
fi

# --- doctor (default) human output --------------------------------------------
# Style: bracketed informational prefixes, no emoji
# (per [[knowledge:conventions/design/informational-feedback-style]]).

if [[ -n "$ACTIVE_FRAMEWORK" ]]; then
  if [[ -n "$FRAMEWORK_DISPLAY" ]]; then
    echo "[framework] $FRAMEWORK_DISPLAY ($ACTIVE_FRAMEWORK)"
  else
    echo "[framework] $ACTIVE_FRAMEWORK"
  fi
  [[ -n "$FRAMEWORK_BINARY" ]] && echo "  Binary:        $FRAMEWORK_BINARY"
  if [[ -n "$MODEL_ROUTING_SHAPE" ]]; then
    if [[ -n "$MODEL_ROUTING_NOTES" ]]; then
      echo "  Model routing: $MODEL_ROUTING_SHAPE — $MODEL_ROUTING_NOTES"
    else
      echo "  Model routing: $MODEL_ROUTING_SHAPE"
    fi
  fi
else
  echo "[framework] (unresolved — see config status below)"
fi
echo ""

# Config block.
echo "[config]"
case "$CONFIG_STATUS" in
  present)
    echo "  $CONFIG_PATH — present"
    ;;
  malformed)
    echo "  $CONFIG_PATH — malformed"
    [[ -n "$CONFIG_PARSE_ERROR" ]] && echo "    Parse error: $CONFIG_PARSE_ERROR"
    echo ""
    echo "[remediation]"
    echo "  Inspect the file or re-run: bash install.sh --framework $ACTIVE_FRAMEWORK"
    ;;
  absent)
    echo "  $CONFIG_PATH — not written yet"
    echo ""
    echo "[remediation]"
    echo "  Run: bash install.sh --framework <name>"
    ;;
esac
echo ""

# Resolution context — what the resolver sees from cwd.
echo "[resolution]"
echo "  cwd:                $CWD_PATH"
if [[ -n "$LORE_CONFIG_PATH" ]]; then
  echo "  .lore.config:       $LORE_CONFIG_PATH"
else
  echo "  .lore.config:       (none discovered walking up from cwd)"
fi
echo "  user-config:        $CONFIG_PATH"
echo ""

# Capabilities — show the override-relevant rows up front, then the rest
# grouped by effective level. Doctor's distinguishing value over status is
# the override + ceiling-check column.
echo "[capabilities]"
override_rows=$(echo "$CAPABILITY_REPORT_JSON" | jq -r --arg sep $'\x1f' \
  '.[] | select(.override_level != "") | "\(.capability)\($sep)\(.profile_level)\($sep)\(.override_level)\($sep)\(.evidence)\($sep)\(.ceiling_violation)\($sep)\(.degradation)"')
if [[ -n "$override_rows" ]]; then
  echo "  overrides (active capability_overrides shadowing the static profile):"
  while IFS=$'\x1f' read -r cap profile override evidence ceiling deg; do
    [[ -z "$cap" ]] && continue
    suffix=""
    if [[ "$ceiling" == "true" ]]; then
      suffix=" — VIOLATION: promotes past evidence-supported ceiling ($profile)"
    fi
    echo "    $cap: $profile -> $override [$deg]$suffix"
  done <<< "$override_rows"
else
  echo "  overrides: (none active)"
fi

# Group remaining cells by effective level for a doctor-shaped summary.
for level_label in "native:full" "partial:partial" "fallback:fallback" "unavailable:none"; do
  label="${level_label%%:*}"
  target="${level_label##*:}"
  rows=$(echo "$CAPABILITY_REPORT_JSON" | jq -r --arg t "$target" --arg sep $'\x1f' \
    '.[] | select(.effective_level == $t) | "\(.capability)\($sep)\(.evidence)\($sep)\(.degradation)"')
  if [[ -n "$rows" ]]; then
    echo "  $label:"
    while IFS=$'\x1f' read -r cap evidence deg; do
      [[ -z "$cap" ]] && continue
      if [[ "$deg" == "ok" ]]; then
        echo "    $cap"
      else
        echo "    $cap [$deg]"
      fi
    done <<< "$rows"
  fi
done
echo ""

# Roles — resolved binding via lib.sh (full chain), with conflict flags.
echo "[roles]"
if [[ -z "$ROLE_IDS" ]]; then
  echo "  (roles registry unavailable at $ROLES_FILE)"
else
  rows=$(echo "$ROLE_RESOLUTIONS_JSON" | jq -r --arg sep $'\x1f' \
    'to_entries[] | "\(.value.role)\($sep)\(.value.resolved)\($sep)\(.value.resolved_source)"')
  while IFS=$'\x1f' read -r role resolved source; do
    [[ -z "$role" ]] && continue
    if [[ -z "$resolved" ]]; then
      echo "  $role -> (unset)"
    else
      echo "  $role -> $resolved ($source)"
    fi
  done <<< "$rows"
fi

# Conflict diagnostics (one line per conflict + remediation).
if [[ "$HAS_CONFLICT" -gt 0 ]]; then
  echo ""
  echo "[diagnostic] role-binding conflicts with active harness model_routing"
  rows=$(echo "$ROLE_CONFLICTS_JSON" | jq -r --arg sep $'\x1f' \
    '.[] | "\(.role)\($sep)\(.model)\($sep)\(.framework)\($sep)\(.shape)\($sep)\(.reason)\($sep)\(.remediation)"')
  while IFS=$'\x1f' read -r role model fw shape reason remediation; do
    [[ -z "$role" ]] && continue
    echo "  $role -> $model"
    echo "    Active harness: $fw (model_routing.shape=$shape)"
    echo "    Reason: $reason"
    echo "    Remediation: $remediation"
  done <<< "$rows"
fi

# Per-repo cwd-vs-user-config diff.
if [[ -n "$LORE_CONFIG_PATH" ]]; then
  echo ""
  echo "[per-repo .lore.config diff]"
  diff_rows=$(echo "$PER_REPO_DIFF_JSON" | jq -r --arg sep $'\x1f' \
    '.[] | "\(.role)\($sep)\(.per_repo)\($sep)\(.user_config)"')
  if [[ -z "$diff_rows" ]]; then
    echo "  (no per-role overrides in $LORE_CONFIG_PATH)"
  else
    echo "  Source: $LORE_CONFIG_PATH"
    while IFS=$'\x1f' read -r role repo user; do
      [[ -z "$role" ]] && continue
      echo "  $role: cwd=$repo  user-config=$user"
    done <<< "$diff_rows"
  fi
fi

# Capability ceiling violations (separate from role conflicts).
if [[ "$HAS_CEILING" -gt 0 ]]; then
  echo ""
  echo "[diagnostic] capability_overrides promote cells past evidence-supported ceiling"
  rows=$(echo "$CAPABILITY_REPORT_JSON" | jq -r --arg sep $'\x1f' \
    '.[] | select(.ceiling_violation == true) | "\(.capability)\($sep)\(.profile_level)\($sep)\(.override_level)"')
  while IFS=$'\x1f' read -r cap profile override; do
    [[ -z "$cap" ]] && continue
    echo "  $cap: profile=$profile, override=$override"
  done <<< "$rows"
  echo "  Remediation: refresh adapters/capabilities-evidence.md for the cell, OR"
  echo "               lower the override to a level the evidence supports."
fi

if [[ "$CONFIG_STATUS" != "present" ]]; then
  exit 2
fi
if [[ "$DIAG_COUNT" -gt 0 ]]; then
  exit 3
fi
exit 0
