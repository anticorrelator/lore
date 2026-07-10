#!/usr/bin/env bash
# spec-start.sh — Read-only /spec startup assembly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
BRANCH=""
MODEL_OVERRIDE=""
TRACK="full"
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore spec start <input> [--branch <name>] [--model <name>] [--short] [--json]

Assemble the read-only state needed to choose the next /spec branch. A
previously unseen input returns resolved=false; an ambiguous input exits 2.
EOF
}

fail() {
  local message="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    python3 - "$message" <<'PY'
import json, sys
print(json.dumps({"error": sys.argv[1]}, ensure_ascii=False))
PY
  else
    echo "[spec start] Error: $message" >&2
  fi
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "--branch requires a value"; BRANCH="$2"; shift 2 ;;
    --branch=*) BRANCH="${1#--branch=}"; [[ -n "$BRANCH" ]] || fail "--branch requires a value"; shift ;;
    --model) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "--model requires a value"; MODEL_OVERRIDE="$2"; shift 2 ;;
    --model=*) MODEL_OVERRIDE="${1#--model=}"; [[ -n "$MODEL_OVERRIDE" ]] || fail "--model requires a value"; shift ;;
    --short) TRACK="short"; shift ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) fail "unknown flag: $1" ;;
    *)
      [[ -z "$REF" ]] || fail "unexpected extra argument: $1"
      REF="$1"; shift ;;
  esac
done

[[ -n "$REF" ]] || { usage; fail "missing required argument: <input>"; }
[[ -z "$MODEL_OVERRIDE" ]] || export LORE_MODEL_LEAD="$MODEL_OVERRIDE"

KDIR=$(resolve_knowledge_dir)
RESOLVER_KDIR="$KDIR"
RESOLVER_TMP=""
# resolve-work-ref.sh self-heals a missing durable _index.json. Read verbs may
# not take that write, so give the canonical resolver an ephemeral projection
# when the index is absent. Exact-directory probes and every fuzzy tier remain
# available; only the repair target moves out of the knowledge store.
if [[ ! -f "$KDIR/_work/_index.json" ]]; then
  RESOLVER_TMP=$(mktemp -d)
  mkdir -p "$RESOLVER_TMP/_work"
  python3 - "$KDIR" "$RESOLVER_TMP/_work/_index.json" <<'PY'
import json, os, pathlib, sys
kdir, output = sys.argv[1:]
cache_path = os.path.join(kdir, "_branch_cache.json")
try: cache = json.load(open(cache_path, encoding="utf-8"))
except Exception: cache = {}
branches = {}
for branch, row in (cache.items() if isinstance(cache, dict) else []):
    slug = row.get("slug") if isinstance(row, dict) else None
    if slug: branches.setdefault(slug, []).append(branch)

def rows(root):
    out=[]
    if not os.path.isdir(root): return out
    for child in sorted(pathlib.Path(root).iterdir(), key=lambda p:p.name):
        meta_path=child / "_meta.json"
        if not child.is_dir() or not meta_path.is_file(): continue
        try: meta=json.load(open(meta_path, encoding="utf-8"))
        except Exception: continue
        out.append({"slug":child.name, "title":meta.get("title") or child.name,
                    "tags":meta.get("tags") or [], "branches":branches.get(child.name, []),
                    "updated":meta.get("updated") or meta.get("updated_at") or ""})
    return out
json.dump({"plans":rows(os.path.join(kdir,"_work")),
           "archived":rows(os.path.join(kdir,"_work","_archive"))}, open(output,"w"))
PY
  RESOLVER_KDIR="$RESOLVER_TMP"
fi
trap '[[ -z "$RESOLVER_TMP" ]] || rm -rf "$RESOLVER_TMP"' EXIT

RESOLVE_ARGS=("$REF" --include-archived)
[[ -z "$BRANCH" ]] || RESOLVE_ARGS+=(--branch "$BRANCH")
set +e
RESOLVED_OUTPUT=$(LORE_KNOWLEDGE_DIR="$RESOLVER_KDIR" bash "$SCRIPT_DIR/resolve-work-ref.sh" "${RESOLVE_ARGS[@]}" 2>&1)
RESOLVE_RC=$?
set -e

if [[ $RESOLVE_RC -eq 2 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    set +e
    LORE_KNOWLEDGE_DIR="$RESOLVER_KDIR" bash "$SCRIPT_DIR/resolve-work-ref.sh" "${RESOLVE_ARGS[@]}" --json
    rc=$?
    set -e
    exit "$rc"
  fi
  printf '%s\n' "$RESOLVED_OUTPUT" >&2
  exit 2
fi
if [[ $RESOLVE_RC -ne 0 && $RESOLVE_RC -ne 1 ]]; then
  fail "work-item resolution failed (exit $RESOLVE_RC)"
fi

FRAMEWORK=$(resolve_active_framework) || fail "active framework could not be resolved"
LEAD_MODEL=$(resolve_model_for_role lead spec 2>/dev/null) || fail "lead model could not be resolved for the spec ceremony"
LEAD_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$LORE_REPO_DIR/skills/spec/SKILL.md" 2>/dev/null) \
  || fail "spec lead template version could not be resolved"

if [[ $RESOLVE_RC -eq 1 ]]; then
  PAYLOAD=$(python3 - "$REF" "$FRAMEWORK" "$LEAD_MODEL" "$TRACK" "$LEAD_TEMPLATE_VERSION" <<'PY'
import json, sys
raw, framework, model, track, template = sys.argv[1:]
print(json.dumps({
    "schema_version": 1,
    "resolved": False,
    "slug": None,
    "archived": False,
    "plan_state": "none",
    "intent_anchor": None,
    "strategy_present": False,
    "active_framework": framework,
    "effective_lead_model": model,
    "track": track,
    "lead_template_version": template,
    "provenance": {"input": raw, "sources": []},
}, ensure_ascii=False))
PY
  )
else
  SLUG=$(printf '%s\n' "$RESOLVED_OUTPUT" | head -1)
  ARCHIVED=$(printf '%s\n' "$RESOLVED_OUTPUT" | sed -n '2p')
  if [[ "$ARCHIVED" == "true" ]]; then
    ITEM_DIR="$KDIR/_work/_archive/$SLUG"
  else
    ITEM_DIR="$KDIR/_work/$SLUG"
  fi
  PAYLOAD=$(python3 - "$ITEM_DIR" "$SLUG" "$ARCHIVED" "$FRAMEWORK" "$LEAD_MODEL" "$TRACK" "$LEAD_TEMPLATE_VERSION" "$REF" <<'PY'
import hashlib, json, os, re, sys
item, slug, archived, framework, model, track, template, raw = sys.argv[1:]
meta_path = os.path.join(item, "_meta.json")
plan_path = os.path.join(item, "plan.md")
with open(meta_path, encoding="utf-8") as f:
    meta = json.load(f)
plan = ""
if os.path.isfile(plan_path):
    with open(plan_path, encoding="utf-8") as f:
        plan = f.read()

def section(name):
    m = re.search(rf"(?ms)^## {re.escape(name)}\s*$\n(.*?)(?=^## |\Z)", plan)
    return m.group(1).strip() if m else ""

if not plan:
    state = "none"
else:
    questions = section("Open Questions")
    meaningful_questions = any(
        line.strip().startswith("-") and line.strip().lower() not in {"- none", "- none."}
        for line in questions.splitlines()
    )
    if meaningful_questions:
        state = "follow-up-needed"
    elif re.search(r"(?m)^## Phases\s*$", plan) and re.search(r"(?m)^\s*- \[[ xX]\] ", plan):
        state = "synthesis-complete"
    elif re.search(r"(?m)^## Investigations\s*$", plan):
        state = "investigations-only"
    else:
        state = "incomplete"

sources = []
for label, path in (("meta", meta_path), ("plan", plan_path)):
    if os.path.isfile(path):
        data = open(path, "rb").read()
        sources.append({"source_id": label, "path": path, "sha256": hashlib.sha256(data).hexdigest()})
    else:
        sources.append({"source_id": label, "path": path, "sha256": None})

print(json.dumps({
    "schema_version": 1,
    "resolved": True,
    "slug": slug,
    "archived": archived == "true",
    "plan_state": state,
    "intent_anchor": meta.get("intent_anchor") or None,
    "strategy_present": bool(re.search(r"(?m)^## Strategy\s*$", plan)),
    "active_framework": framework,
    "effective_lead_model": model,
    "track": track,
    "lead_template_version": template,
    "provenance": {"input": raw, "sources": sources},
}, ensure_ascii=False))
PY
  )
fi

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$PAYLOAD"
else
  python3 - "$PAYLOAD" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if not d["resolved"]:
    print(f"[spec start] Unresolved input: {d['provenance']['input']}")
    print(f"Track: {d['track']}  Framework: {d['active_framework']}  Lead model: {d['effective_lead_model']}")
else:
    print(f"[spec start] {d['slug']}")
    print(f"Archived: {str(d['archived']).lower()}  Plan state: {d['plan_state']}  Track: {d['track']}")
    print(f"Framework: {d['active_framework']}  Lead model: {d['effective_lead_model']}")
    print(f"Strategy present: {str(d['strategy_present']).lower()}")
PY
fi
