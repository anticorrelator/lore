#!/usr/bin/env bash
# impl-start.sh — /implement Step 1 envelope: resolve, validate, assemble the start struct
# Usage: bash impl-start.sh <ref> [--branch <name>] [--json]
#
# Absorbs the Step 1 bookkeeping of /implement:
#   - resolve <ref> to a canonical slug (delegates to resolve-work-ref.sh)
#   - validate plan.md exists with a "## Phases" section and >=1 unchecked "- [ ]"
#   - read _meta.json: title plus intent_anchor, returned VERBATIM — the
#     anchor-coverage verdict belongs to the lead (gate-anchor verb); this
#     script computes facts only and never adjudicates
#   - write the branch cache via cache-branch.sh (skipped for archived items,
#     non-fatal on failure) — the only artifact this verb writes
#   - parse prior task-claims.jsonl into per-task and per-file maps
#   - resolve role->model bindings (lead, worker, advisor) and the three
#     template versions (implement SKILL.md, worker, advisor templates);
#     each resolution failure degrades to "" with a stderr warning
#
# --branch affects fuzzy resolution (tier 5) only; the cache write always
# uses the actual current branch.
#
# Exit codes:
#   0  start struct printed (text, or single JSON object with --json)
#   1  no match / missing plan / no unchecked tasks / usage error
#   2  ambiguous reference (resolver candidates propagated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
BRANCH=""
BRANCH_SET=0
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:-}"
      BRANCH_SET=1
      shift 2
      ;;
    --branch=*)
      BRANCH="${1#--branch=}"
      BRANCH_SET=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --help|-h)
      cat >&2 <<EOF
Usage: lore impl start <ref> [--branch <name>] [--json]

Resolve a work item and return the /implement start struct: title, verbatim
intent anchor, phase/unchecked-task counts, prior Tier 2 claims maps,
role->model bindings, template versions, and branch-cache status.

Writes only the branch cache; makes no judgments.

Exit codes:
  0  start struct printed
  1  no match, missing plan.md, or no unchecked tasks
  2  ambiguous reference (candidate list on stderr; "candidates":[...] in JSON)
EOF
      exit 0
      ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "Unknown flag: $1"
      fi
      echo "[impl] Error: Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$REF" ]]; then
        REF="$1"
      else
        if [[ $JSON_MODE -eq 1 ]]; then
          json_error "Unexpected extra argument: $1"
        fi
        echo "[impl] Error: Unexpected extra argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$REF" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required argument: <ref>"
  fi
  echo "[impl] Error: Missing required argument: <ref>" >&2
  echo "Usage: lore impl start <ref> [--branch <name>] [--json]" >&2
  exit 1
fi

if [[ $BRANCH_SET -eq 0 ]]; then
  BRANCH=$(get_git_branch)
fi

# --- Resolve <ref> to (slug, archived) via the canonical resolver ----------
RESOLVE_ARGS=("$REF")
[[ -n "$BRANCH" ]] && RESOLVE_ARGS+=(--branch "$BRANCH")
[[ $JSON_MODE -eq 1 ]] && RESOLVE_ARGS+=(--json)

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "${RESOLVE_ARGS[@]}")
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  # Resolver already wrote diagnostics (stderr in text mode, JSON on stdout
  # with --json) — propagate its output and tri-state exit code unchanged.
  [[ -n "$RESOLVED" ]] && printf '%s\n' "$RESOLVED"
  exit "$RC"
fi

if [[ $JSON_MODE -eq 1 ]]; then
  SLUG=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slug"])')
  ARCHIVED=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["archived"] else "false")')
else
  SLUG=$(printf '%s\n' "$RESOLVED" | sed -n '1p')
  ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"
if [[ "$ARCHIVED" == "true" ]]; then
  ITEM_DIR="$WORK_DIR/_archive/$SLUG"
else
  ITEM_DIR="$WORK_DIR/$SLUG"
fi

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  echo "[impl] Error: $msg" >&2
  exit 1
}

[[ -f "$ITEM_DIR/_meta.json" ]] || fail "work item '$SLUG' resolved but $ITEM_DIR/_meta.json is missing"

# --- Validate plan.md before any write -------------------------------------
PLAN="$ITEM_DIR/plan.md"
if [[ ! -f "$PLAN" ]]; then
  fail "No structured plan found for '$SLUG'. Run /spec first to create phases and tasks."
fi
UNCHECKED=$(grep -cE '^[[:space:]]*- \[ \]' "$PLAN") || true
PHASES=$(grep -cE '^### Phase [0-9]+:' "$PLAN") || true
if ! grep -qE '^## Phases' "$PLAN" || [[ "${UNCHECKED:-0}" -eq 0 ]]; then
  fail "All plan tasks are already complete."
fi

# --- Branch cache write (the verb's only artifact) --------------------------
CURRENT_BRANCH=$(get_git_branch)
if [[ "$ARCHIVED" == "true" ]]; then
  CACHE_STATUS="skipped-archived"
elif [[ -z "$CURRENT_BRANCH" || "$CURRENT_BRANCH" == "HEAD" ]]; then
  CACHE_STATUS="skipped-no-branch"
elif bash "$SCRIPT_DIR/cache-branch.sh" --write "$SLUG" >/dev/null 2>&1; then
  CACHE_STATUS="written"
else
  echo "[impl] Warning: branch cache write failed" >&2
  CACHE_STATUS="failed"
fi

# --- Role->model bindings and template versions (warn + "" on failure) -----
resolve_model_or_empty() {
  local role="$1" model
  if model=$(resolve_model_for_role "$role" 2>/dev/null) && [[ -n "$model" ]]; then
    printf '%s' "$model"
  else
    echo "[impl] Warning: no model binding resolved for role '$role'" >&2
    printf ''
  fi
}

template_version_or_empty() {
  local label="$1" path="$2" tv
  if [[ -n "$path" ]] && tv=$(bash "$SCRIPT_DIR/template-version.sh" "$path" 2>/dev/null) && [[ -n "$tv" ]]; then
    printf '%s' "$tv"
  else
    echo "[impl] Warning: template-version.sh failed for $label template" >&2
    printf ''
  fi
}

LEAD_MODEL=$(resolve_model_or_empty lead)
WORKER_MODEL=$(resolve_model_or_empty worker)
ADVISOR_MODEL=$(resolve_model_or_empty advisor)

LEAD_TV=$(template_version_or_empty lead "$LORE_REPO_DIR/skills/implement/SKILL.md")
WORKER_TV=$(template_version_or_empty worker "$(resolve_agent_template worker 2>/dev/null || true)")
ADVISOR_TV=$(template_version_or_empty advisor "$(resolve_agent_template advisor 2>/dev/null || true)")

# --- Assemble and emit the start struct -------------------------------------
PAYLOAD=$(python3 - "$ITEM_DIR" "$SLUG" "$ARCHIVED" "$PHASES" "$UNCHECKED" \
  "$CACHE_STATUS" "$CURRENT_BRANCH" \
  "$LEAD_MODEL" "$WORKER_MODEL" "$ADVISOR_MODEL" \
  "$LEAD_TV" "$WORKER_TV" "$ADVISOR_TV" <<'PYEOF'
import json
import os
import sys

(item_dir, slug, archived, phases, unchecked, cache_status, branch,
 lead_m, worker_m, advisor_m, lead_tv, worker_tv, advisor_tv) = sys.argv[1:14]

with open(os.path.join(item_dir, "_meta.json")) as f:
    meta = json.load(f)

title = meta.get("title") or slug
anchor = meta.get("intent_anchor") or None

claims_path = os.path.join(item_dir, "task-claims.jsonl")
by_task = {}
by_file = {}
total = 0
if os.path.isfile(claims_path):
    with open(claims_path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError("not an object")
            except ValueError:
                print(f"[impl] Warning: skipping malformed line {lineno} "
                      f"in task-claims.jsonl", file=sys.stderr)
                continue
            total += 1
            task_id = row.get("task_id") or "unknown"
            by_task.setdefault(task_id, []).append(row)
            file_path = row.get("file")
            if file_path:
                by_file.setdefault(file_path, []).append(row.get("claim_id"))

print(json.dumps({
    "slug": slug,
    "archived": archived == "true",
    "title": title,
    "intent_anchor": anchor,
    "plan": {"phases": int(phases or 0), "unchecked_tasks": int(unchecked or 0)},
    "branch_cache": {"status": cache_status, "branch": branch or None},
    "prior_claims": {"total": total, "by_task": by_task, "by_file": by_file},
    "models": {"lead": lead_m, "worker": worker_m, "advisor": advisor_m},
    "template_versions": {"lead": lead_tv, "worker": worker_tv, "advisor": advisor_tv},
}))
PYEOF
)

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$PAYLOAD"
fi

python3 - "$PAYLOAD" <<'PYEOF'
import json
import sys

d = json.loads(sys.argv[1])
m = d["models"]
tv = d["template_versions"]
p = d["plan"]
print(f"[impl start] {d['title']}")
print(f"Slug: {d['slug']}  (archived: {str(d['archived']).lower()})")
print(f"Models: lead={m['lead']}  worker={m['worker']}  advisor={m['advisor']}")
print(f"Template versions: lead={tv['lead']}  worker={tv['worker']}  advisor={tv['advisor']}")
print(f"Phases: {p['phases']} with {p['unchecked_tasks']} unchecked tasks")
total = d["prior_claims"]["total"]
if total:
    print(f"Prior Tier 2 claims: {total} rows loaded from task-claims.jsonl")
else:
    print("Prior Tier 2 claims: none — first run")
bc = d["branch_cache"]
if bc["status"] == "written":
    print(f"Branch cache: written ('{bc['branch']}' -> '{d['slug']}')")
else:
    print(f"Branch cache: {bc['status']}")
anchor = d["intent_anchor"]
if anchor:
    print("Intent anchor:")
    print(anchor)
else:
    print("Intent anchor: none")
PYEOF
