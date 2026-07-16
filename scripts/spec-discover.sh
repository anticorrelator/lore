#!/usr/bin/env bash
# spec-discover.sh — Enumerate /spec discovery candidates without applicability judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
JSON_MODE=0
SEEDS=()

usage() {
  cat >&2 <<'EOF'
Usage: lore spec discover <ref> [--seed <token>]... [--json]

Enumerate source-manifested external skill/agent and preference/convention
candidates. Results retain source-native ordering and are not matched, bound,
reranked across sources, or interpreted for applicability.
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
    echo "[spec discover] Error: $message" >&2
  fi
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --seed)
      [[ $# -ge 2 && -n "$2" ]] || fail "--seed requires a non-empty token"
      SEEDS+=("$2")
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    --*) fail "unknown flag: $1" ;;
    *) [[ -z "$REF" ]] || fail "unexpected extra argument: $1"; REF="$1"; shift ;;
  esac
done
[[ -n "$REF" ]] || { usage; fail "missing required argument: <ref>"; }

set +e
START_STATE=$(bash "$SCRIPT_DIR/spec-start.sh" "$REF" --json 2>&1)
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then printf '%s\n' "$START_STATE" >&2; exit "$RESOLVE_RC"; fi
if [[ "$(jq -r '.resolved' <<<"$START_STATE")" != "true" ]]; then
  fail "no work item matches reference '$REF'"
fi
SLUG=$(jq -r '.slug' <<<"$START_STATE")
ARCHIVED=$(jq -r '.archived' <<<"$START_STATE")
KDIR=$(resolve_knowledge_dir)
if [[ "$ARCHIVED" == "true" ]]; then ITEM_DIR="$KDIR/_work/_archive/$SLUG"; else ITEM_DIR="$KDIR/_work/$SLUG"; fi

FRAMEWORK=$(resolve_active_framework) || fail "active framework could not be resolved"
SKILLS_ROOT=$(resolve_harness_install_path skills "$FRAMEWORK" 2>/dev/null) || SKILLS_ROOT=""
AGENTS_ROOT=$(resolve_harness_install_path agents "$FRAMEWORK" 2>/dev/null) || AGENTS_ROOT=""
[[ "$SKILLS_ROOT" == "unsupported" ]] && SKILLS_ROOT=""
[[ "$AGENTS_ROOT" == "unsupported" ]] && AGENTS_ROOT=""

TITLE=$(python3 - "$ITEM_DIR/_meta.json" "$SLUG" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("title") or sys.argv[2])
except Exception:
    print(sys.argv[2])
PY
)

SEED_QUERY=""
if [[ ${#SEEDS[@]} -gt 0 ]]; then
  SEED_QUERY=$(IFS=' '; printf '%s' "${SEEDS[*]}")
fi

PAYLOAD=$(python3 - "$SLUG" "$TITLE" "$KDIR" "$SKILLS_ROOT" "$AGENTS_ROOT" "$LORE_REPO_DIR" "$SCRIPT_DIR/pk_cli.py" "$HOME/.codex/plugins/cache" "$FRAMEWORK" "$SEED_QUERY" <<'PY'
import glob, json, os, pathlib, subprocess, sys

slug, title, kdir, skills_root, agents_root, repo, pk_cli, plugin_cache, framework, seed_query = sys.argv[1:]

canonical_skills = {p.name for p in pathlib.Path(repo, "skills").iterdir() if p.is_dir()} if os.path.isdir(os.path.join(repo, "skills")) else set()
canonical_agents = {p.stem for p in pathlib.Path(repo, "agents").glob("*.md")}

coverage = []
candidates = []

def add_source(source_id, kind, root, paths, *, query=None, rows=None, missing_reason=None):
    if rows is None:
        if not root or not os.path.isdir(root):
            status = "missing"
            paths = []
            gap = missing_reason or "source root is absent"
        elif not os.access(root, os.R_OK):
            status = "unreadable"
            paths = []
            gap = "source root is unreadable"
        else:
            status = "scanned"
            gap = None
        for path in paths:
            candidates.append({
                "source_id": source_id, "kind": kind, "path": path,
                "query": query, "source_rank": None, "source_score": None,
                "metadata": {},
            })
    else:
        status = "scanned" if rows is not None else "missing"
        gap = missing_reason
        for rank, row in enumerate(rows, 1):
            path = row.get("file_path") or row.get("path")
            if not path or not path.startswith(("preferences/", "conventions/", "cross-cutting-conventions/")):
                continue
            candidates.append({
                "source_id": source_id, "kind": kind, "path": path,
                "query": query, "source_rank": rank,
                "source_score": row.get("score"),
                "metadata": {k: v for k, v in row.items() if k not in {"file_path", "path", "score"}},
            })
    count = sum(1 for row in candidates if row["source_id"] == source_id)
    coverage.append({"source_id": source_id, "kind": kind, "root": root or None,
                     "status": status, "candidate_count": count, "gap_reason": gap})

if skills_root and os.path.isdir(skills_root):
    root_skill_paths = sorted(glob.glob(os.path.join(skills_root, "*", "SKILL.md")))
    root_skill_paths = [p for p in root_skill_paths if pathlib.Path(p).parent.name not in canonical_skills]
else:
    root_skill_paths = []
add_source("harness-skills-root", "skill", skills_root, root_skill_paths)

system_root = os.path.join(skills_root, ".system") if skills_root else ""
system_paths = sorted(glob.glob(os.path.join(system_root, "*", "SKILL.md"))) if system_root else []
system_paths = [p for p in system_paths if pathlib.Path(p).parent.name not in canonical_skills]
add_source("harness-skills-system", "skill", system_root, system_paths)

plugin_paths = sorted(glob.glob(os.path.join(plugin_cache, "**", "skills", "**", "SKILL.md"), recursive=True)) if os.path.isdir(plugin_cache) else []
plugin_paths = [p for p in plugin_paths if pathlib.Path(p).parent.name not in canonical_skills]
add_source("harness-skills-plugins", "skill", plugin_cache, plugin_paths)

agent_paths = sorted(glob.glob(os.path.join(agents_root, "*.md"))) if agents_root and os.path.isdir(agents_root) else []
agent_paths = [p for p in agent_paths if pathlib.Path(p).stem not in canonical_agents]
add_source("harness-agents", "agent", agents_root, agent_paths)

for source_id, dirname in (("preferences-tree", "preferences"), ("conventions-tree", "conventions"),
                           ("cross-cutting-conventions-tree", "cross-cutting-conventions")):
    root = os.path.join(kdir, dirname)
    paths = sorted(str(p.relative_to(kdir)) for p in pathlib.Path(root).rglob("*.md")) if os.path.isdir(root) else []
    add_source(source_id, "knowledge", root, paths)

for source_id, scales, limit in (
    ("bm25-subsystem-implementation", "subsystem,implementation", "10"),
    ("bm25-abstract-architecture", "abstract,architecture", "5"),
):
    query = seed_query or title
    try:
        proc = subprocess.run([sys.executable, pk_cli, "search", kdir, query,
                               "--scale-set", scales, "--caller", "spec-discover", "--json", "--limit", limit],
                              text=True, capture_output=True, check=False)
        if proc.returncode == 0:
            rows = json.loads(proc.stdout or "[]")
            add_source(source_id, "knowledge-search", kdir, [], query=query, rows=rows)
        else:
            coverage.append({"source_id": source_id, "kind": "knowledge-search", "root": kdir,
                             "status": "unreadable", "candidate_count": 0,
                             "gap_reason": (proc.stderr or f"search exited {proc.returncode}").strip()})
    except Exception as exc:
        coverage.append({"source_id": source_id, "kind": "knowledge-search", "root": kdir,
                         "status": "unreadable", "candidate_count": 0, "gap_reason": str(exc)})

payload = {
    "schema_version": 1,
    "coverage": coverage,
    "candidates": candidates,
    "provenance": {
        "slug": slug,
        "active_framework": framework,
        "ordering": "source-native",
        "applicability_decided": False,
    },
}
if seed_query:
    payload["provenance"]["query_seed"] = seed_query
print(json.dumps(payload, ensure_ascii=False))
PY
)

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$PAYLOAD"
else
  python3 - "$PAYLOAD" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print(f"[spec discover] {d['provenance']['slug']}")
print(f"Sources: {len(d['coverage'])}  Raw candidates: {len(d['candidates'])}")
for row in d["coverage"]:
    print(f"- {row['source_id']}: {row['status']} ({row['candidate_count']})")
PY
fi
