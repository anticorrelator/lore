#!/usr/bin/env bash
# prefetch-knowledge.sh — Search knowledge store and output formatted context for agent prompts
# Usage: bash prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all] [--exclude-backlinks <paths>]
#
# --format prompt   (default) Full resolved sections for embedding in agent prompts
# --format summary  Headings + snippets for display
# --limit N         Max results (default: 5)
# --type            Filter by source type: knowledge, work, or all (default: all)
# --exclude-backlinks  Comma-separated backlink paths to exclude from results (deduplication
#                      with pre-resolved knowledge already in task descriptions)
#
# Output: Clean markdown block (## Prior Knowledge) or empty string on zero results.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Defaults ---
FORMAT="prompt"
LIMIT=5
TYPE="knowledge"
QUERY=""
EXCLUDE_BACKLINKS=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --type)
      TYPE="$2"
      shift 2
      ;;
    --exclude-backlinks)
      EXCLUDE_BACKLINKS="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "Usage: prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all]" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  # No knowledge store — silent exit (clean no-op)
  exit 0
fi

LORE_SEARCH="$SCRIPT_DIR/pk_cli.py"

if [[ ! -f "$LORE_SEARCH" ]]; then
  exit 0
fi
check_fts_available
if [[ $USE_FTS -eq 0 ]]; then
  exit 0
fi

# --- Build search command ---
SEARCH_ARGS=("search" "$KNOWLEDGE_DIR" "$QUERY" "--limit" "$LIMIT" "--json")
if [[ "$TYPE" != "all" ]]; then
  SEARCH_ARGS+=("--type" "$TYPE")
fi

# --- Run search ---
RESULTS=$(python3 "$LORE_SEARCH" "${SEARCH_ARGS[@]}" 2>/dev/null || true)

if [[ -z "$RESULTS" || "$RESULTS" == "[]" ]]; then
  # Zero results — output nothing
  exit 0
fi

# --- Format output ---
export _PK_RESULTS="$RESULTS"
export _PK_EXCLUDE_BACKLINKS="$EXCLUDE_BACKLINKS"
python3 - "$KNOWLEDGE_DIR" "$FORMAT" "$QUERY" "$LORE_SEARCH" <<'PYEOF'
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys

knowledge_dir = sys.argv[1]
fmt = sys.argv[2]
query = sys.argv[3]
pk_search_path = sys.argv[4]

results = json.loads(os.environ["_PK_RESULTS"])

if not results:
    sys.exit(0)


# --- Load see-also data from concordance_results ---
see_also_map = {}  # (abs_file_path, heading) -> [(rel_path, heading, score)]
db_path = os.path.join(knowledge_dir, ".pk_search.db")
if os.path.exists(db_path):
    try:
        sa_conn = sqlite3.connect(db_path)
        sa_rows = sa_conn.execute(
            "SELECT file_path, heading, similar_entry_path, similar_entry_heading, similarity_score "
            "FROM concordance_results WHERE result_type = 'see_also' "
            "ORDER BY similarity_score DESC"
        ).fetchall()
        sa_conn.close()
        for fp, heading, sim_fp, sim_heading, score in sa_rows:
            key = (fp, heading)
            try:
                sim_rel = os.path.relpath(sim_fp, knowledge_dir)
            except ValueError:
                sim_rel = sim_fp
            # Build backlink-style reference
            target = sim_rel
            if target.endswith(".md"):
                target = target[:-3]
            see_also_map.setdefault(key, []).append(
                f"[[knowledge:{target}#{sim_heading}]]"
            )
    except (sqlite3.OperationalError, sqlite3.DatabaseError):
        pass


# --- Staleness scoring (optional — graceful fallback if unavailable) ---
_staleness_mod = None
_repo_root = None

def _load_staleness():
    global _staleness_mod, _repo_root
    if _staleness_mod is not None:
        return
    script_dir = os.path.dirname(pk_search_path)
    ss_path = os.path.join(script_dir, "staleness-scan.py")
    if not os.path.isfile(ss_path):
        _staleness_mod = False
        return
    try:
        spec = importlib.util.spec_from_file_location("staleness_scan", ss_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _staleness_mod = mod
    except Exception:
        _staleness_mod = False
        return
    # Find repo root
    d = os.getcwd()
    while True:
        if os.path.isdir(os.path.join(d, ".git")):
            _repo_root = d
            return
        parent = os.path.dirname(d)
        if parent == d:
            _repo_root = os.getcwd()
            return
        d = parent


def get_staleness_annotation(file_path_rel):
    """Score a knowledge entry and return a [STALE] annotation or empty string."""
    _load_staleness()
    if not _staleness_mod or _staleness_mod is False:
        return ""
    # Only annotate knowledge entries
    abs_path = os.path.join(knowledge_dir, file_path_rel)
    if not os.path.isfile(abs_path):
        return ""
    try:
        meta = _staleness_mod.parse_metadata(abs_path)
        file_drift = _staleness_mod.compute_file_drift(
            _repo_root, meta["learned"], meta["related_files"]
        )
        # Gate: only annotate when file_drift is available
        if not file_drift.get("available", False):
            return ""
        backlink_drift = _staleness_mod.compute_backlink_drift(abs_path, knowledge_dir)
        drift_score, status, signals = _staleness_mod.score_entry(
            file_drift, backlink_drift, meta["confidence"]
        )
        if status == "stale":
            reason = _staleness_mod._top_signal(signals)
            return f" [STALE — drift: {drift_score:.2f}, {reason}]"
    except Exception:
        pass
    return ""


def build_backlink(r):
    """Build a [[backlink]] string from a search result for resolve."""
    source_type = r["source_type"]
    file_path = r["file_path"]
    heading = r["heading"]

    if source_type == "knowledge":
        # file_path like "conventions.md" or "domains/auth.md"
        target = file_path
        if target.endswith(".md"):
            target = target[:-3]
    elif source_type in ("work", "plan"):
        # file_path like "_work/slug/plan.md"
        parts = file_path.split("/")
        # Find the slug: typically _work/<slug>/plan.md or _work/_archive/<slug>/plan.md
        if "_archive" in parts:
            idx = parts.index("_archive")
            target = parts[idx + 1] if idx + 1 < len(parts) else file_path
        elif "_work" in parts:
            idx = parts.index("_work")
            target = parts[idx + 1] if idx + 1 < len(parts) else file_path
        else:
            target = file_path
        source_type = "work"
    elif source_type == "thread":
        # v2: file_path like "_threads/slug/2026-02-06-s6.md"
        # v1: file_path like "_threads/slug.md"
        parts = file_path.split("/")
        if "_threads" in parts:
            idx = parts.index("_threads")
            target = parts[idx + 1] if idx + 1 < len(parts) else file_path
            if target.endswith(".md"):
                target = target[:-3]
        else:
            target = os.path.basename(file_path)
            if target.endswith(".md"):
                target = target[:-3]
    else:
        target = file_path

    if heading and heading != "(ungrouped)":
        return f"[[{source_type}:{target}#{heading}]]"
    else:
        return f"[[{source_type}:{target}]]"


# --- Filter out results matching excluded backlink paths ---
exclude_raw = os.environ.get("_PK_EXCLUDE_BACKLINKS", "")
if exclude_raw:
    exclude_set = set()
    for entry in exclude_raw.split(","):
        entry = entry.strip().strip("[]")
        if entry:
            exclude_set.add(entry)
    if exclude_set:
        filtered = []
        for r in results:
            bl = build_backlink(r).strip("[]")
            # Match exact backlink or base (without heading fragment)
            base = bl.split("#")[0]
            if bl not in exclude_set and base not in exclude_set:
                filtered.append(r)
        results = filtered
    if not results:
        sys.exit(0)


if fmt == "summary":
    print(f'## Prior Knowledge')
    print(f'Results from knowledge store for: "{query}"')
    print()
    for r in results:
        snippet = r.get("snippet", "")[:200]
        if len(r.get("snippet", "")) > 200:
            snippet += "..."
        score = r.get("score", 0)
        print(f'- **{r["heading"]}** ({r["file_path"]}, score: {score}): {snippet}')
    sys.exit(0)

# prompt format — resolve each result to full content
print(f'## Prior Knowledge')
print(f'Results from knowledge store for: "{query}"')

for r in results:
    backlink = build_backlink(r)
    # Compute staleness annotation for knowledge entries
    stale_tag = ""
    if r.get("source_type") == "knowledge":
        stale_tag = get_staleness_annotation(r["file_path"])
    # Build see-also line for this entry
    sa_line = ""
    if r.get("source_type") == "knowledge":
        abs_fp = os.path.join(knowledge_dir, r["file_path"])
        sa_key = (abs_fp, r["heading"])
        sa_entries = see_also_map.get(sa_key, [])
        if sa_entries:
            sa_line = "See also: " + ", ".join(sa_entries[:3])

    # Call pk_search.py resolve to get full content
    try:
        proc = subprocess.run(
            ["python3", pk_search_path, "resolve", knowledge_dir, backlink, "--json"],
            capture_output=True, text=True, timeout=10
        )
        if proc.returncode == 0 and proc.stdout.strip():
            resolved = json.loads(proc.stdout.strip())
            if resolved and isinstance(resolved, list) and resolved[0].get("resolved"):
                content = resolved[0]["content"]
                print()
                print(f'### {r["heading"]} (from {r["file_path"]}){stale_tag}')
                print(content)
                if sa_line:
                    print(sa_line)
                continue
    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, IndexError):
        pass

    # Fallback: use snippet from search results
    snippet = r.get("snippet", "")
    if snippet:
        print()
        print(f'### {r["heading"]} (from {r["file_path"]}){stale_tag}')
        print(snippet)
        if sa_line:
            print(sa_line)
PYEOF
