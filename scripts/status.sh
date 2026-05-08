#!/usr/bin/env bash
# status.sh — Quick knowledge store health summary
# Reads _meta/ files (retrieval-log.jsonl, renormalize-flags.json, staleness/usage reports)
# and _manifest.json to give a snapshot of store health.
#
# Usage: bash status.sh [knowledge_dir] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
JSON_OUTPUT=0
KDIR=""

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=1 ;;
    --help|-h)
      echo "Usage: lore status [--json]" >&2
      echo "  Show a quick knowledge store health summary." >&2
      echo "  Reads _meta/ logs and _manifest.json for status indicators." >&2
      exit 0
      ;;
    *)
      if [[ -z "$KDIR" ]]; then
        KDIR="$arg"
      fi
      ;;
  esac
done

if [[ -z "$KDIR" ]]; then
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  echo "Error: knowledge directory not found: $KDIR" >&2
  exit 1
fi

META_DIR="$KDIR/_meta"

# --- Entry count from manifest ---
ENTRY_COUNT=0
FORMAT_VERSION=0
if [[ -f "$KDIR/_manifest.json" ]]; then
  # Sum entry_count values from manifest categories
  ENTRY_COUNT=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
fmt = m.get('format_version', 1)
total = sum(c.get('entry_count', 0) for c in m.get('categories', {}).values())
print(f'{fmt} {total}')
" "$KDIR/_manifest.json" 2>/dev/null || echo "0 0")
  FORMAT_VERSION=$(echo "$ENTRY_COUNT" | cut -d' ' -f1)
  ENTRY_COUNT=$(echo "$ENTRY_COUNT" | cut -d' ' -f2)
fi

# --- Category count ---
CATEGORY_COUNT=0
for dir in "$KDIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == _* ]] && continue
  CATEGORY_COUNT=$((CATEGORY_COUNT + 1))
done

# --- Budget utilization from retrieval log ---
BUDGET_USED=0
BUDGET_TOTAL=0
RETRIEVAL_SESSIONS=0
LAST_RETRIEVAL=""
if [[ -f "$META_DIR/retrieval-log.jsonl" ]]; then
  # Read last line for most recent session data
  LAST_LINE=$(tail -1 "$META_DIR/retrieval-log.jsonl" 2>/dev/null || echo "")
  if [[ -n "$LAST_LINE" ]]; then
    eval "$(python3 -c "
import json, sys
line = sys.argv[1]
d = json.loads(line)
print(f'BUDGET_USED={d.get(\"budget_used\", 0)}')
print(f'BUDGET_TOTAL={d.get(\"budget_total\", 0)}')
print(f'LAST_RETRIEVAL=\"{d.get(\"timestamp\", \"\")}\"')
" "$LAST_LINE" 2>/dev/null || echo "")"
    RETRIEVAL_SESSIONS=$(wc -l < "$META_DIR/retrieval-log.jsonl" | tr -d '[:space:]')
  fi
fi

BUDGET_PCT=0
if [[ "$BUDGET_TOTAL" -gt 0 ]]; then
  BUDGET_PCT=$(python3 -c "print(round($BUDGET_USED / $BUDGET_TOTAL * 100, 1))")
fi

# --- Staleness indicators ---
STALE_COUNT=0
AGING_COUNT=0
FRESH_COUNT=0
STALENESS_SCAN_TIME=""
if [[ -f "$META_DIR/staleness-report.json" ]]; then
  eval "$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
counts = r.get('counts', {})
print(f'STALE_COUNT={counts.get(\"stale\", 0)}')
print(f'AGING_COUNT={counts.get(\"aging\", 0)}')
print(f'FRESH_COUNT={counts.get(\"fresh\", 0)}')
print(f'STALENESS_SCAN_TIME=\"{r.get(\"scan_time\", \"\")}\"')
" "$META_DIR/staleness-report.json" 2>/dev/null || echo "")"
fi

# --- Usage analysis indicators ---
COLD_ENTRIES=0
USAGE_SCAN_TIME=""
if [[ -f "$META_DIR/usage-report.json" ]]; then
  eval "$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
s = r.get('summary', {})
print(f'COLD_ENTRIES={s.get(\"cold_entry_count\", 0)}')
print(f'USAGE_SCAN_TIME=\"{r.get(\"generated_at\", \"\")}\"')
" "$META_DIR/usage-report.json" 2>/dev/null || echo "")"
fi

# --- Renormalize flags ---
RENORM_FLAG_COUNT=0
LAST_RENORMALIZE=""
if [[ -f "$META_DIR/renormalize-flags.json" ]]; then
  eval "$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
# Count flags across all categories (oversized_categories, stale_related_files, zero_access_entries)
total = (len(r.get('oversized_categories', []))
    + len(r.get('stale_related_files', []))
    + len(r.get('zero_access_entries', [])))
print(f'RENORM_FLAG_COUNT={total}')
print(f'LAST_RENORMALIZE=\"{r.get(\"last_renormalize\", \"never\")}\"')
" "$META_DIR/renormalize-flags.json" 2>/dev/null || echo "")"
fi

# --- Inbox count ---
INBOX_COUNT=0
if [[ -d "$KDIR/_inbox" ]]; then
  INBOX_COUNT=$(find "$KDIR/_inbox" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
fi

# --- Agent symlink drift ---
# Resolve the harness-specific agents install dir via harness_path_or_empty
# (T71) so this check works on Claude Code, OpenCode, and any future harness
# with an agents-install path. The helper returns an empty string when the
# active harness has no agents surface; the block then falls through with
# AGENT_TOTAL=0, matching the prior behavior when ~/.claude/agents/ did not
# exist.
AGENT_TOTAL=0
MISSING_AGENTS=()
LORE_REPO_DIR=""
LORE_SCRIPTS_LINK="$HOME/.lore/scripts"
if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
fi
AGENTS_INSTALL_DIR=$(harness_path_or_empty agents)
if [[ -n "$LORE_REPO_DIR" && -n "$AGENTS_INSTALL_DIR" && -d "$LORE_REPO_DIR/agents" ]]; then
  for agent_file in "$LORE_REPO_DIR"/agents/*.md; do
    [[ -f "$agent_file" ]] || continue
    agent_name="$(basename "$agent_file")"
    if [[ ! -L "$AGENTS_INSTALL_DIR/$agent_name" ]]; then
      MISSING_AGENTS+=("$agent_name")
    fi
    AGENT_TOTAL=$((AGENT_TOTAL + 1))
  done
fi
AGENT_LINKED=$((AGENT_TOTAL - ${#MISSING_AGENTS[@]}))

# --- Framework / role / capability profile ---
# Reads $LORE_DATA_DIR/config/framework.json (written by install.sh, T4) and
# adapters/capabilities.json (T2) to surface what harness Lore is targeting,
# which capabilities are degraded for that harness, and the active role->model
# bindings. The block is best-effort: a missing config or missing adapters
# directory yields FRAMEWORK_STATUS="absent" rather than failing the whole
# status command — `lore status` should still report knowledge-store health
# even when the framework config is in-flight.
FRAMEWORK_STATUS="absent"
FRAMEWORK_NAME=""
FRAMEWORK_DISPLAY=""
FRAMEWORK_BINARY=""
MODEL_ROUTING_SHAPE=""
DEGRADED_CAPS_HUMAN=""    # comma-separated: "name=level,..."
DEGRADED_CAPS_JSON="[]"   # JSON array of {name, support} objects
ROLES_HUMAN=""            # compact "default=sonnet, lead=opus, ..."
ROLES_JSON="{}"           # JSON object {role: model}
EVIDENCE_PATH=""          # absolute path to capabilities-evidence.md when present

FRAMEWORK_CONFIG_PATH="${LORE_DATA_DIR:-$HOME/.lore}/config/framework.json"
ADAPTERS_CAPS=""
ADAPTERS_EVIDENCE=""
if [[ -n "$LORE_REPO_DIR" ]]; then
  ADAPTERS_CAPS="$LORE_REPO_DIR/adapters/capabilities.json"
  ADAPTERS_EVIDENCE="$LORE_REPO_DIR/adapters/capabilities-evidence.md"
fi

if [[ -f "$FRAMEWORK_CONFIG_PATH" ]]; then
  FRAMEWORK_BLOCK=$(FRAMEWORK_CONFIG_PATH="$FRAMEWORK_CONFIG_PATH" \
                   ADAPTERS_CAPS="$ADAPTERS_CAPS" \
                   ADAPTERS_EVIDENCE="$ADAPTERS_EVIDENCE" \
                   python3 - <<'PYEOF' 2>/dev/null || echo ""
import json, os, sys

cfg_path = os.environ["FRAMEWORK_CONFIG_PATH"]
caps_path = os.environ.get("ADAPTERS_CAPS", "")
evidence_path = os.environ.get("ADAPTERS_EVIDENCE", "")

try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except Exception as e:
    print("FRAMEWORK_STATUS=malformed", file=sys.stdout)
    sys.exit(0)

framework = cfg.get("framework") or ""
roles = cfg.get("roles") or {}
overrides = cfg.get("capability_overrides") or {}

# Static profile lookup (display name, binary, model_routing.shape, degraded caps)
display = ""
binary = ""
shape = ""
degraded = []  # list of (cap_name, support_level)
caps_present = os.path.exists(caps_path) if caps_path else False
if caps_present:
    try:
        with open(caps_path) as f:
            caps_data = json.load(f)
        fw_profile = (caps_data.get("frameworks") or {}).get(framework) or {}
        display = fw_profile.get("display_name") or ""
        binary = fw_profile.get("binary") or ""
        shape = ((fw_profile.get("model_routing") or {}).get("shape")) or ""
        # "Major" degraded = none or fallback. partial is treated as
        # supported-with-caveats and excluded from the status line to keep
        # it short; full inspection is via `lore framework doctor` (T60).
        for cap_name, cell in (fw_profile.get("capabilities") or {}).items():
            support = (overrides.get(cap_name) if cap_name in overrides else cell.get("support")) or ""
            if support in ("fallback", "none"):
                degraded.append((cap_name, support))
        for cap_name, support in overrides.items():
            if cap_name in (fw_profile.get("capabilities") or {}):
                continue
            if support in ("fallback", "none"):
                degraded.append((cap_name, support))
    except Exception:
        pass

# Render fields to stdout as KEY=VALUE so the bash caller can eval them.
def kv(k, v):
    # Quote so embedded spaces/quotes survive eval in bash.
    safe = (v or "").replace('"', '\\"')
    print(f'{k}="{safe}"')

print("FRAMEWORK_STATUS=present")
kv("FRAMEWORK_NAME", framework)
kv("FRAMEWORK_DISPLAY", display)
kv("FRAMEWORK_BINARY", binary)
kv("MODEL_ROUTING_SHAPE", shape)

if degraded:
    human = ", ".join(f"{name}={lvl}" for name, lvl in degraded)
    kv("DEGRADED_CAPS_HUMAN", human)
    kv("DEGRADED_CAPS_JSON", json.dumps([{"name": n, "support": s} for n, s in degraded]))
else:
    kv("DEGRADED_CAPS_HUMAN", "")
    kv("DEGRADED_CAPS_JSON", "[]")

if roles:
    # Stable order: default first, then sorted remainder.
    keys = ["default"] + sorted(k for k in roles.keys() if k != "default")
    seen = set()
    parts = []
    for k in keys:
        if k in roles and k not in seen:
            parts.append(f"{k}={roles[k]}")
            seen.add(k)
    kv("ROLES_HUMAN", ", ".join(parts))
    kv("ROLES_JSON", json.dumps(roles))
else:
    kv("ROLES_HUMAN", "")
    kv("ROLES_JSON", "{}")

if evidence_path and os.path.exists(evidence_path):
    kv("EVIDENCE_PATH", evidence_path)
else:
    kv("EVIDENCE_PATH", "")
PYEOF
  )
  if [[ -n "$FRAMEWORK_BLOCK" ]]; then
    eval "$FRAMEWORK_BLOCK"
  else
    FRAMEWORK_STATUS="malformed"
  fi
fi

# Build JSON-safe missing agents array
MISSING_AGENTS_JSON="[]"
if [[ ${#MISSING_AGENTS[@]} -gt 0 ]]; then
  MISSING_AGENTS_JSON=$(printf '%s\n' "${MISSING_AGENTS[@]}" | python3 -c "
import sys, json
names = [line.strip().removesuffix('.md') for line in sys.stdin if line.strip()]
print(json.dumps(names))
")
fi

# --- JSON output ---
if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  python3 -c "
import json
data = {
    'knowledge_dir': '$KDIR',
    'format_version': $FORMAT_VERSION,
    'entries': {
        'total': $ENTRY_COUNT,
        'categories': $CATEGORY_COUNT,
        'inbox_pending': $INBOX_COUNT,
    },
    'budget': {
        'used': $BUDGET_USED,
        'total': $BUDGET_TOTAL,
        'utilization_pct': $BUDGET_PCT,
    },
    'retrieval': {
        'total_sessions': $RETRIEVAL_SESSIONS,
        'last_retrieval': '$LAST_RETRIEVAL',
    },
    'staleness': {
        'stale': $STALE_COUNT,
        'aging': $AGING_COUNT,
        'fresh': $FRESH_COUNT,
        'last_scan': '$STALENESS_SCAN_TIME',
    },
    'usage': {
        'cold_entries': $COLD_ENTRIES,
        'last_scan': '$USAGE_SCAN_TIME',
    },
    'renormalize': {
        'flag_count': $RENORM_FLAG_COUNT,
        'last_renormalize': '$LAST_RENORMALIZE',
    },
    'agents': {
        'total': $AGENT_TOTAL,
        'linked': $AGENT_LINKED,
        'missing': $MISSING_AGENTS_JSON,
    },
    'framework': {
        'status': '$FRAMEWORK_STATUS',
        'name': '$FRAMEWORK_NAME',
        'display_name': '$FRAMEWORK_DISPLAY',
        'binary': '$FRAMEWORK_BINARY',
        'model_routing': '$MODEL_ROUTING_SHAPE',
        'degraded_capabilities': $DEGRADED_CAPS_JSON,
        'roles': $ROLES_JSON,
        'evidence_path': '$EVIDENCE_PATH',
    },
}
print(json.dumps(data, indent=2))
"
  exit 0
fi

# --- Human-readable output ---
draw_separator "Knowledge Store Status"
echo ""
echo "Store: $KDIR"
echo "Format version: $FORMAT_VERSION"
echo ""

# Framework / harness profile (T15). Always rendered: the operator wants to
# see the active harness even if the framework config is missing — that
# absence is itself a status signal.
draw_separator "Framework"
case "$FRAMEWORK_STATUS" in
  present)
    if [[ -n "$FRAMEWORK_DISPLAY" ]]; then
      echo "  Active: $FRAMEWORK_DISPLAY ($FRAMEWORK_NAME)"
    else
      echo "  Active: $FRAMEWORK_NAME"
    fi
    if [[ -n "$FRAMEWORK_BINARY" ]]; then
      echo "  Binary: $FRAMEWORK_BINARY"
    fi
    if [[ -n "$MODEL_ROUTING_SHAPE" ]]; then
      echo "  Model routing: $MODEL_ROUTING_SHAPE"
    fi
    if [[ -n "$ROLES_HUMAN" ]]; then
      echo "  Roles: $ROLES_HUMAN"
    fi
    if [[ -n "$DEGRADED_CAPS_HUMAN" ]]; then
      echo "  Degraded: $DEGRADED_CAPS_HUMAN"
    fi
    if [[ -n "$EVIDENCE_PATH" ]]; then
      echo "  Evidence: $EVIDENCE_PATH"
    fi
    ;;
  malformed)
    echo "  [warning] $FRAMEWORK_CONFIG_PATH is malformed; re-run install.sh."
    ;;
  *)
    echo "  [warning] Framework config not found at $FRAMEWORK_CONFIG_PATH."
    echo "  Run: bash install.sh --framework <name>"
    ;;
esac
echo ""

draw_separator "Entries"
echo "  Total: $ENTRY_COUNT across $CATEGORY_COUNT categories"
if [[ "$INBOX_COUNT" -gt 0 ]]; then
  echo "  Inbox pending: $INBOX_COUNT"
fi
echo ""

draw_separator "Budget"
echo "  Last load: ${BUDGET_USED}/${BUDGET_TOTAL} tokens (${BUDGET_PCT}%)"
echo "  Retrieval sessions logged: $RETRIEVAL_SESSIONS"
if [[ -n "$LAST_RETRIEVAL" ]]; then
  echo "  Last retrieval: $LAST_RETRIEVAL"
fi
echo ""

if [[ -f "$META_DIR/staleness-report.json" ]]; then
  draw_separator "Staleness"
  echo "  Fresh: $FRESH_COUNT | Aging: $AGING_COUNT | Stale: $STALE_COUNT"
  if [[ -n "$STALENESS_SCAN_TIME" ]]; then
    echo "  Last scan: $STALENESS_SCAN_TIME"
  fi
  echo ""
fi

if [[ -f "$META_DIR/usage-report.json" ]]; then
  draw_separator "Usage"
  echo "  Cold entries (never retrieved): $COLD_ENTRIES"
  if [[ -n "$USAGE_SCAN_TIME" ]]; then
    echo "  Last scan: $USAGE_SCAN_TIME"
  fi
  echo ""
fi

if [[ "$RENORM_FLAG_COUNT" -gt 0 ]]; then
  draw_separator "Renormalize"
  echo "  Flags accumulated: $RENORM_FLAG_COUNT"
  if [[ -n "$LAST_RENORMALIZE" ]]; then
    echo "  Last renormalize: $LAST_RENORMALIZE"
  fi
  echo "  Run /memory renormalize to optimize."
  echo ""
fi

if [[ "$AGENT_TOTAL" -gt 0 ]]; then
  draw_separator "Agents"
  if [[ ${#MISSING_AGENTS[@]} -eq 0 ]]; then
    echo "  Agents: ${AGENT_LINKED}/${AGENT_TOTAL} linked"
  else
    echo "  Agents: ${AGENT_LINKED}/${AGENT_TOTAL} linked"
    echo "  [warning] Missing symlinks in ${AGENTS_INSTALL_DIR}/:"
    for agent in "${MISSING_AGENTS[@]}"; do
      echo "    - ${agent%.md}"
    done
    echo "  Run: bash install.sh to fix"
  fi
  echo ""
fi

draw_separator
