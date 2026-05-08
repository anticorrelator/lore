#!/usr/bin/env bash
# framework-status.sh — Diagnostic status report for the active lore harness.
#
# Surfaces the resolved framework, capability levels grouped by status, the
# active role->model bindings (collapsed one line per role), and pointers to
# the evidence + compatibility artifacts. This is the operator-facing
# counterpart to `lore config show` (which prints the raw framework.json):
# this command cross-references the persisted config against
# adapters/capabilities.json and adapters/roles.json so the operator sees the
# resolved view, not the raw file.
#
# Future siblings under the `framework` subgroup (T21 doctor, T22 set-model)
# will live in their own scripts; this one is read-only.
#
# Usage: framework-status.sh [--json]
#
# Exit codes:
#   0  success (report rendered)
#   1  usage error
#   2  framework config absent or malformed (report still printed; non-zero
#      so scripts can detect "needs install")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      cat >&2 <<EOF
framework-status.sh — diagnostic report for the active lore harness

Usage: lore framework status [--json]

Sections:
  Header         active framework display name + binary
  Capabilities   grouped as native (full) / partial / fallback / unavailable
  Roles          one collapsed line per role: <role> -> <model> (<source>)
  Evidence       paths to capabilities-evidence.md and framework-compatibility.md

Options:
  --json         emit machine-readable JSON instead of the human report
  --help, -h     show this help

Notes:
  Capability levels reflect any persisted capability_overrides on top of the
  static profile in adapters/capabilities.json. Role bindings reflect the
  full env -> per-repo -> user -> harness-default precedence chain via
  resolve_model_for_role; the (<source>) tag tells you which layer answered.
EOF
      exit 0
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    *)
      echo "Error: unknown framework status flag '$1'" >&2
      echo "" >&2
      echo "Usage: lore framework status [--json]" >&2
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

# Normalize to absolute paths when present so the operator can copy/paste them.
[[ -f "$CAPABILITIES_FILE" ]] && CAPABILITIES_FILE="$(cd "$(dirname "$CAPABILITIES_FILE")" && pwd)/$(basename "$CAPABILITIES_FILE")"
[[ -f "$EVIDENCE_FILE" ]]     && EVIDENCE_FILE="$(cd "$(dirname "$EVIDENCE_FILE")" && pwd)/$(basename "$EVIDENCE_FILE")"
[[ -f "$COMPAT_DOC" ]]        && COMPAT_DOC="$(cd "$(dirname "$COMPAT_DOC")" && pwd)/$(basename "$COMPAT_DOC")"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required for 'lore framework status'" >&2
  exit 1
fi

if [[ ! -f "$CAPABILITIES_FILE" ]]; then
  echo "Error: capabilities profile not found at $CAPABILITIES_FILE" >&2
  exit 1
fi

# --- Resolve active framework + identifying fields -----------------------------
CONFIG_STATUS="absent"
if [[ -f "$CONFIG_PATH" ]]; then
  if jq -e . "$CONFIG_PATH" &>/dev/null; then
    CONFIG_STATUS="present"
  else
    CONFIG_STATUS="malformed"
  fi
fi

# resolve_active_framework prints the resolved name on stdout and validates
# against capabilities.json; if config is missing it falls back to claude-code.
ACTIVE_FRAMEWORK=""
if ACTIVE_FRAMEWORK=$(resolve_active_framework 2>/dev/null); then
  :
else
  ACTIVE_FRAMEWORK=""
fi

# Collect per-framework display fields from the static profile.
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

# --- Build the capability table (cap, support, source, notes) -----------------
# The python helper produces JSON of the form:
#   [{"name": "...", "support": "...", "source": "profile|override", "notes": "..."}, ...]
# preserving the capability ordering from capabilities.json so output is stable.
CAPS_JSON='[]'
if [[ -n "$ACTIVE_FRAMEWORK" ]]; then
  CAPS_JSON=$(
    CAPABILITIES_FILE="$CAPABILITIES_FILE" \
    CONFIG_PATH="$CONFIG_PATH" \
    ACTIVE_FRAMEWORK="$ACTIVE_FRAMEWORK" \
    python3 - <<'PYEOF'
import json, os, sys

caps_path = os.environ["CAPABILITIES_FILE"]
cfg_path = os.environ["CONFIG_PATH"]
fw = os.environ["ACTIVE_FRAMEWORK"]

with open(caps_path) as f:
    caps = json.load(f)
fw_profile = (caps.get("frameworks") or {}).get(fw) or {}
profile_caps = fw_profile.get("capabilities") or {}

overrides = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
        overrides = cfg.get("capability_overrides") or {}
    except Exception:
        overrides = {}

# Preserve the ordering from capabilities.json's top-level capabilities map so
# the output is deterministic across runs (Python 3.7+ dicts preserve order).
order = list((caps.get("capabilities") or {}).keys())
seen = set()
rows = []
for name in order:
    if name not in profile_caps and name not in overrides:
        continue
    cell = profile_caps.get(name) or {}
    support = overrides.get(name) or cell.get("support") or "none"
    source = "override" if name in overrides else "profile"
    notes = cell.get("notes") or ""
    rows.append({"name": name, "support": support, "source": source, "notes": notes})
    seen.add(name)

# Tail in any framework-specific capabilities not present in the top-level map
# (rare; defensive against schema drift).
for name in profile_caps:
    if name in seen:
        continue
    cell = profile_caps[name] or {}
    support = overrides.get(name) or cell.get("support") or "none"
    source = "override" if name in overrides else "profile"
    notes = cell.get("notes") or ""
    rows.append({"name": name, "support": support, "source": source, "notes": notes})
    seen.add(name)

# And any pure-override entries that don't appear in the framework profile.
for name, support in overrides.items():
    if name in seen:
        continue
    rows.append({"name": name, "support": support, "source": "override", "notes": ""})

print(json.dumps(rows))
PYEOF
  )
fi

# --- Build the role binding table (role, model, source) ----------------------
# Resolution sources:
#   env       — LORE_MODEL_<ROLE_UPPER> set
#   per-repo  — .lore.config model_for_<role>= matched
#   user      — framework.json roles.<role> matched
#   default   — framework.json roles.default fallback
#   unset     — no binding anywhere (resolve_model_for_role exits non-zero)
# The user-config branch additionally reports "user-default" when the bound
# value came from .roles.default rather than .roles.<role> (so the operator
# can tell which roles are explicitly bound vs inheriting the fallback).
ROLES_JSON='[]'
if [[ -f "$ROLES_FILE" ]]; then
  ROLES_JSON=$(
    ROLES_FILE="$ROLES_FILE" \
    CONFIG_PATH="$CONFIG_PATH" \
    python3 - <<'PYEOF'
import json, os, sys, subprocess

roles_file = os.environ["ROLES_FILE"]
cfg_path = os.environ["CONFIG_PATH"]

with open(roles_file) as f:
    roles_data = json.load(f)
role_ids = [r["id"] for r in roles_data.get("roles", [])]

user_roles = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
        user_roles = cfg.get("roles") or {}
    except Exception:
        user_roles = {}

rows = []
for rid in role_ids:
    env_var = "LORE_MODEL_" + rid.upper()
    env_val = os.environ.get(env_var)
    # Per-repo lookup is intentionally skipped here — emulating the walk-up
    # search in pure python would diverge from resolve_model_for_role and
    # invite drift. Operators inspecting the *config* should see the
    # *configured* answer; per-repo overrides surface in `lore framework
    # doctor` (T21) which will run the resolver in cwd.
    if env_val:
        rows.append({"role": rid, "model": env_val, "source": "env"})
        continue
    if rid in user_roles and user_roles[rid]:
        rows.append({"role": rid, "model": user_roles[rid], "source": "user-config"})
        continue
    if "default" in user_roles and user_roles["default"]:
        if rid == "default":
            rows.append({"role": rid, "model": user_roles["default"], "source": "user-config"})
        else:
            rows.append({"role": rid, "model": user_roles["default"], "source": "user-default"})
        continue
    rows.append({"role": rid, "model": "", "source": "unset"})

print(json.dumps(rows))
PYEOF
  )
fi

# --- JSON output --------------------------------------------------------------
if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  CAPABILITIES_PATH_OUT="$CAPABILITIES_FILE"
  EVIDENCE_PATH_OUT=""; [[ -f "$EVIDENCE_FILE" ]] && EVIDENCE_PATH_OUT="$EVIDENCE_FILE"
  COMPAT_DOC_OUT=""; [[ -f "$COMPAT_DOC" ]] && COMPAT_DOC_OUT="$COMPAT_DOC"
  CONFIG_PATH_OUT="$CONFIG_PATH"

  python3 - <<PYEOF
import json
out = {
    "config_status": "$CONFIG_STATUS",
    "config_path": "$CONFIG_PATH_OUT",
    "framework": {
        "name": "$ACTIVE_FRAMEWORK",
        "display_name": "$FRAMEWORK_DISPLAY",
        "binary": "$FRAMEWORK_BINARY",
        "model_routing": {
            "shape": "$MODEL_ROUTING_SHAPE",
            "notes": "$MODEL_ROUTING_NOTES",
        },
    },
    "capabilities": json.loads('''$CAPS_JSON'''),
    "roles": json.loads('''$ROLES_JSON'''),
    "artifacts": {
        "capabilities_profile": "$CAPABILITIES_PATH_OUT",
        "capabilities_evidence": "$EVIDENCE_PATH_OUT",
        "framework_compatibility": "$COMPAT_DOC_OUT",
    },
}
print(json.dumps(out, indent=2))
PYEOF
  if [[ "$CONFIG_STATUS" != "present" ]]; then
    exit 2
  fi
  exit 0
fi

# --- Human-readable output ----------------------------------------------------
# Style: bracketed informational prefixes, no emoji
# (per [[knowledge:conventions/design/informational-feedback-style]]).

# Header
if [[ -n "$ACTIVE_FRAMEWORK" ]]; then
  if [[ -n "$FRAMEWORK_DISPLAY" ]]; then
    echo "[framework] $FRAMEWORK_DISPLAY ($ACTIVE_FRAMEWORK)"
  else
    echo "[framework] $ACTIVE_FRAMEWORK"
  fi
  if [[ -n "$FRAMEWORK_BINARY" ]]; then
    echo "  Binary:        $FRAMEWORK_BINARY"
  fi
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

case "$CONFIG_STATUS" in
  present)
    echo "  Config:        $CONFIG_PATH"
    ;;
  malformed)
    echo "  Config:        $CONFIG_PATH (malformed — re-run install.sh)"
    ;;
  absent)
    echo "  Config:        not written yet at $CONFIG_PATH"
    echo "                 Run: bash install.sh --framework <name>"
    ;;
esac
echo ""

# Capabilities, grouped by status. Levels we care about:
#   native        = "full"
#   partial       = "partial"
#   fallback      = "fallback"
#   unavailable   = "none"
# The plan's verification line names native / fallback / unavailable as the
# three buckets the operator wants; partial is rendered as its own bucket
# rather than collapsed into fallback so degraded-but-native semantics stay
# visible. Each row is one line with "(override)" appended when the support
# level was supplied by capability_overrides rather than the static profile.
echo "[capabilities]"
if [[ "$CAPS_JSON" == "[]" || -z "$ACTIVE_FRAMEWORK" ]]; then
  echo "  (no profile available)"
else
  for level_label in "native:full" "partial:partial" "fallback:fallback" "unavailable:none"; do
    label="${level_label%%:*}"
    target="${level_label##*:}"
    # Use US (\x1f) as the field separator: jq emits one record per cap on a
    # single line, and US never appears in capability names/notes. A
    # whitespace-class IFS like tab silently collapses runs of empty fields,
    # which mangled rows whose notes were empty.
    rows=$(echo "$CAPS_JSON" | jq -r --arg t "$target" \
      '.[] | select(.support == $t) | "\(.name)\(.source)\(.notes)"')
    if [[ -n "$rows" ]]; then
      echo "  $label:"
      while IFS=$'\x1f' read -r name source notes; do
        [[ -z "$name" ]] && continue
        suffix=""
        [[ "$source" == "override" ]] && suffix=" (override)"
        if [[ -n "$notes" ]]; then
          # Trim notes to a single line for the status surface; full text
          # lives in capabilities.json + capabilities-evidence.md.
          short_notes=$(printf '%s' "$notes" | head -n 1 | cut -c1-90)
          echo "    $name$suffix — $short_notes"
        else
          echo "    $name$suffix"
        fi
      done <<< "$rows"
    fi
  done
fi
echo ""

# Roles, one collapsed line per role.
echo "[roles]"
if [[ "$ROLES_JSON" == "[]" ]]; then
  echo "  (roles registry unavailable at $ROLES_FILE)"
else
  # US (\x1f) separator: tab-separated rows collapse adjacent empty fields,
  # which would mis-attribute (role, "", source) to (role, source, "").
  echo "$ROLES_JSON" | jq -r --arg sep $'\x1f' \
    '.[] | "\(.role)\($sep)\(.model)\($sep)\(.source)"' | \
    while IFS=$'\x1f' read -r role model source; do
      if [[ "$source" == "unset" ]]; then
        echo "  $role -> (unset)"
      else
        echo "  $role -> $model ($source)"
      fi
    done
fi
echo ""

# Evidence + compatibility artifact pointers.
echo "[artifacts]"
echo "  Capabilities profile: $CAPABILITIES_FILE"
if [[ -f "$EVIDENCE_FILE" ]]; then
  echo "  Capabilities evidence: $EVIDENCE_FILE"
else
  echo "  Capabilities evidence: not found at $EVIDENCE_FILE"
fi
if [[ -f "$COMPAT_DOC" ]]; then
  echo "  Framework compatibility: $COMPAT_DOC"
else
  echo "  Framework compatibility: not found at $COMPAT_DOC"
fi

if [[ "$CONFIG_STATUS" != "present" ]]; then
  exit 2
fi
exit 0
