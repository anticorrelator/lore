#!/usr/bin/env bash
# prefetch-knowledge.sh — Search knowledge store and output formatted context for agent prompts
# Usage: bash prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all] [--exclude-backlinks <paths>] [--scale-context <role>] [--work-item <slug>]
#
# --format prompt   (default) Full resolved sections for embedding in agent prompts
# --format summary  Headings + snippets for display
# --limit N         Max results (default: 5)
# --type            Filter by source type: knowledge, work, or all (default: all)
# --exclude-backlinks  Comma-separated backlink paths to exclude from results (deduplication
#                      with pre-resolved knowledge already in task descriptions)
# --scale-context <role>   Role name (worker|researcher|advisor|spec-lead|implement-lead|retro).
#                          When provided, returns own-scale entries in full and adjacent-scale
#                          entries as synopses. Entries without scale field default to own-scale.
#                          Also applies per-role status filtering:
#                            worker     → status=current only
#                            spec-lead  → status=current; notes suppressed historical count
#                            retro      → all statuses (current, historical, superseded)
#                            others     → all statuses
# --work-item <slug>       Work item slug (from _work/<slug>/_meta.json). Used to resolve
#                          the work-item scope for scale computation. Defaults to subsystem.
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
SCALE_CONTEXT=""
WORK_ITEM=""

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
    --scale-context)
      SCALE_CONTEXT="$2"
      shift 2
      ;;
    --work-item)
      WORK_ITEM="$2"
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
  echo "Usage: prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all] [--scale-context <role>] [--work-item <slug>]" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  # No knowledge store — silent exit (clean no-op)
  exit 0
fi

# --- Scale-context resolution ---
# Resolved values exported as env vars for the Python block.
# OWN_SCALE: the role's absolute scale id (e.g. "implementation")
# ADJ_SCALE_BELOW: scale id one step narrower (may be empty)
# ADJ_SCALE_ABOVE: scale id one step broader (may be empty)
OWN_SCALE=""
ADJ_SCALE_BELOW=""
ADJ_SCALE_ABOVE=""

if [[ -n "$SCALE_CONTEXT" ]]; then
  # Map role → default slot (canonical capture slot per role × slot matrix)
  case "$SCALE_CONTEXT" in
    worker)         DEFAULT_SLOT="Observations" ;;
    researcher)     DEFAULT_SLOT="Assertions" ;;
    advisor)        DEFAULT_SLOT="Guidance" ;;
    spec-lead)      DEFAULT_SLOT="Synthesis" ;;
    implement-lead) DEFAULT_SLOT="Synthesis" ;;
    retro)          DEFAULT_SLOT="Reflection" ;;
    *)
      echo "Warning: unknown role '$SCALE_CONTEXT' for --scale-context; ignoring scale-context" >&2
      SCALE_CONTEXT=""
      ;;
  esac

  if [[ -n "$SCALE_CONTEXT" ]]; then
    # Resolve work-item scope
    WORK_SCOPE="subsystem"
    if [[ -n "$WORK_ITEM" ]]; then
      META_PATH="$KNOWLEDGE_DIR/_work/$WORK_ITEM/_meta.json"
      if [[ -f "$META_PATH" ]]; then
        ITEM_SCOPE=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('scope',''))" "$META_PATH" 2>/dev/null || true)
        if [[ -n "$ITEM_SCOPE" ]]; then
          WORK_SCOPE="$ITEM_SCOPE"
        fi
      fi
    fi

    # Compute absolute scale via scale-compute.sh
    COMPUTE_OUT=$(bash "$SCRIPT_DIR/scale-compute.sh" --work-scope "$WORK_SCOPE" --role "$SCALE_CONTEXT" --slot "$DEFAULT_SLOT" 2>/dev/null || true)
    if [[ -n "$COMPUTE_OUT" ]]; then
      OWN_SCALE="$COMPUTE_OUT"

      # Get adjacent scale ids
      ADJ_OUT=$(bash "$SCRIPT_DIR/scale-registry.sh" get-adjacency "$OWN_SCALE" 2>/dev/null || true)
      ADJ_SCALE_BELOW=$(echo "$ADJ_OUT" | sed -n '1p')
      ADJ_SCALE_ABOVE=$(echo "$ADJ_OUT" | sed -n '2p')
    else
      echo "Warning: scale-compute.sh failed for role '$SCALE_CONTEXT', slot '$DEFAULT_SLOT', scope '$WORK_SCOPE'; ignoring scale-context" >&2
      SCALE_CONTEXT=""
    fi
  fi
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
SEARCH_ARGS=("search" "$KNOWLEDGE_DIR" "$QUERY" "--limit" "$LIMIT" "--json" "--caller" "prefetch")
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
export _PK_SCRIPT_DIR="$SCRIPT_DIR"
export _PK_OWN_SCALE="$OWN_SCALE"
export _PK_ADJ_SCALE_BELOW="$ADJ_SCALE_BELOW"
export _PK_ADJ_SCALE_ABOVE="$ADJ_SCALE_ABOVE"
export _PK_SCALE_CONTEXT="$SCALE_CONTEXT"
python3 - "$KNOWLEDGE_DIR" "$FORMAT" "$QUERY" "$LORE_SEARCH" <<'PYEOF'
import datetime
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys

# Import helpers from pk_resolve and pk_search
script_dir = os.environ.get("_PK_SCRIPT_DIR", "")
if script_dir:
    sys.path.insert(0, script_dir)
from pk_resolve import build_backlink_from_result
from pk_search import render_trust_stamp

knowledge_dir = sys.argv[1]
fmt = sys.argv[2]
query = sys.argv[3]
pk_search_path = sys.argv[4]

results = json.loads(os.environ["_PK_RESULTS"])

if not results:
    sys.exit(0)


def _log_prefetch(served_results):
    """Append a prefetch event to retrieval-log.jsonl."""
    log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    loaded_paths = [r["file_path"] for r in served_results if r.get("file_path")]
    log_line = json.dumps({"timestamp": ts, "event": "prefetch", "loaded_paths": loaded_paths})
    try:
        with open(log_path, "a") as _lf:
            _lf.write(log_line + "\n")
    except OSError:
        pass


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


# build_backlink function now imported from pk_resolve above


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
            bl = build_backlink_from_result(r).strip("[]")
            # Match exact backlink or base (without heading fragment)
            base = bl.split("#")[0]
            if bl not in exclude_set and base not in exclude_set:
                filtered.append(r)
        results = filtered
    if not results:
        _log_prefetch(results)
        sys.exit(0)


# --- Scale-context classification ---
own_scale = os.environ.get("_PK_OWN_SCALE", "")
adj_below = os.environ.get("_PK_ADJ_SCALE_BELOW", "")
adj_above = os.environ.get("_PK_ADJ_SCALE_ABOVE", "")
scale_context = os.environ.get("_PK_SCALE_CONTEXT", "")

_SCALE_META_RE = re.compile(r"\|\s*scale:\s*(?P<scale>[^\s|]+)", re.IGNORECASE)

def _parse_entry_scale(file_path_rel: str) -> str:
    """Read the scale field from an entry's HTML comment metadata. Returns '' if not present."""
    abs_path = os.path.join(knowledge_dir, file_path_rel)
    try:
        text = open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return ""
    m = _SCALE_META_RE.search(text)
    if m:
        return m.group("scale").strip().lower()
    return ""


def _scale_tier(entry_scale: str) -> str:
    """Classify an entry relative to own_scale. Returns 'own', 'adjacent', or 'other'."""
    if not own_scale:
        return "own"
    if not entry_scale or entry_scale == "unknown":
        # Unclassified entries surface at own-scale by default
        return "own"
    if entry_scale == own_scale:
        return "own"
    if entry_scale in (adj_below, adj_above):
        return "adjacent"
    return "other"


def _synopsis(snippet: str) -> str:
    """Return first 2 non-empty lines of snippet as a synopsis."""
    lines = [l for l in snippet.splitlines() if l.strip()]
    return "\n".join(lines[:2])


def _get_or_synthesize_synopsis(entry_id: str, scale: str, snippet: str, script_dir: str) -> str:
    """Return a synopsis for entry_id at scale, using cache or synthesis."""
    synopsis_script = os.path.join(script_dir, "edge-synopsis.sh")
    synth_script = os.path.join(script_dir, "synthesize-synopsis.sh")

    # Try cache first
    if os.path.isfile(synopsis_script):
        try:
            proc = subprocess.run(
                [synopsis_script, "get", entry_id, scale],
                capture_output=True, text=True, timeout=5
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip()
        except (subprocess.TimeoutExpired, OSError):
            pass

    # Cache miss: attempt synthesis (includes fallback internally; budget=2s curl + overhead)
    if os.path.isfile(synth_script):
        try:
            proc = subprocess.run(
                [synth_script, entry_id, scale],
                capture_output=True, text=True, timeout=10
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip()
        except (subprocess.TimeoutExpired, OSError):
            pass

    # Final fallback: 2-line truncation
    return _synopsis(snippet)


# --- Status-aware filtering ---
_STATUS_META_RE = re.compile(r"\|\s*status:\s*(?P<status>[^\s|>]+)", re.IGNORECASE)

def _parse_entry_status(file_path_rel: str) -> str:
    """Read the status field from an entry's HTML comment metadata. Returns 'current' if absent."""
    abs_path = os.path.join(knowledge_dir, file_path_rel)
    try:
        text = open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return "current"
    m = _STATUS_META_RE.search(text)
    if m:
        return m.group("status").strip().lower()
    # No status field → treat as current (pre-status-field entries)
    return "current"


def _status_visible(entry_status: str, role: str) -> bool:
    """Return True if an entry with entry_status should be shown for the given role.

    - worker: current only
    - spec-lead: current only by default (historical counted separately for note)
    - retro: all statuses
    - other roles / no scale-context: all statuses
    """
    if not role:
        return True
    if role == "worker":
        return entry_status == "current"
    if role == "spec-lead":
        return entry_status == "current"
    if role == "retro":
        return True
    # researcher, advisor, implement-lead: all statuses
    return True


if fmt == "summary":
    print(f'## Prior Knowledge')
    if scale_context:
        print(f'Results from knowledge store for: "{query}" (scale-context: {scale_context}, own-scale: {own_scale})')
    else:
        print(f'Results from knowledge store for: "{query}"')
    print()
    suppressed_historical = 0
    for r in results:
        tier = "own"
        if scale_context and r.get("source_type") == "knowledge":
            entry_scale = _parse_entry_scale(r["file_path"])
            tier = _scale_tier(entry_scale)
        if tier == "other":
            continue
        # Status filter
        if scale_context and r.get("source_type") == "knowledge":
            entry_status = _parse_entry_status(r["file_path"])
            if not _status_visible(entry_status, scale_context):
                if entry_status in ("historical", "superseded"):
                    suppressed_historical += 1
                continue
        snippet = r.get("snippet", "")[:200]
        if len(r.get("snippet", "")) > 200:
            snippet += "..."
        score = r.get("score", 0)
        tier_tag = f" [{tier}-scale]" if scale_context and tier == "adjacent" else ""
        print(f'- **{r["heading"]}**{tier_tag} ({r["file_path"]}, score: {score}): {snippet}')
    if suppressed_historical > 0 and scale_context == "spec-lead":
        print(f'\n_{suppressed_historical} historical/superseded {"entry" if suppressed_historical == 1 else "entries"} suppressed — add --include-status=historical to expand._')
    _log_prefetch(results)
    sys.exit(0)

# prompt format — resolve each result to full content
print(f'## Prior Knowledge')
if scale_context:
    print(f'Results from knowledge store for: "{query}" (scale-context: {scale_context}, own-scale: {own_scale})')
else:
    print(f'Results from knowledge store for: "{query}"')

# Budget: own-scale entries consume first; adjacent-scale synopses fill remaining.
# Default 8000 chars; only enforced in the scale-context path.
PREFETCH_BUDGET = 8000

def _resolve_content(backlink: str) -> str:
    """Return full resolved content for backlink, or '' on failure."""
    try:
        proc = subprocess.run(
            ["python3", pk_search_path, "resolve", knowledge_dir, backlink, "--json"],
            capture_output=True, text=True, timeout=10
        )
        if proc.returncode == 0 and proc.stdout.strip():
            resolved = json.loads(proc.stdout.strip())
            if resolved and isinstance(resolved, list) and resolved[0].get("resolved"):
                return resolved[0]["content"]
    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, IndexError):
        pass
    return ""


suppressed_historical = 0

if scale_context:
    # Two-pass budget-aware rendering:
    # Pass 1: accumulate own-scale entries up to budget.
    # Pass 2: add adjacent-scale synopses if budget remains.
    own_entries = []
    adj_entries = []

    for r in results:
        if r.get("source_type") == "knowledge":
            entry_scale = _parse_entry_scale(r["file_path"])
            tier = _scale_tier(entry_scale)
        else:
            tier = "own"
        if tier == "other":
            continue
        # Status filter
        if r.get("source_type") == "knowledge":
            entry_status = _parse_entry_status(r["file_path"])
            if not _status_visible(entry_status, scale_context):
                if entry_status in ("historical", "superseded"):
                    suppressed_historical += 1
                continue
        if tier == "adjacent":
            adj_entries.append(r)
        else:
            own_entries.append(r)

    budget_remaining = PREFETCH_BUDGET

    # Emit own-scale entries first, tracking char budget
    for r in own_entries:
        backlink = build_backlink_from_result(r)
        stale_tag = get_staleness_annotation(r["file_path"]) if r.get("source_type") == "knowledge" else ""
        abs_fp = os.path.join(knowledge_dir, r.get("file_path", ""))
        sa_key = (abs_fp, r["heading"])
        sa_entries = see_also_map.get(sa_key, [])
        sa_line = ("See also: " + ", ".join(sa_entries[:3])) if sa_entries else ""
        trust_line = render_trust_stamp(r)

        content = _resolve_content(backlink)
        if not content:
            content = r.get("snippet", "")
        block = f'\n### {r["heading"]} (from {r["file_path"]}){stale_tag}\n{trust_line}\n{content}'
        if sa_line:
            block += f'\n{sa_line}'
        print(block)
        budget_remaining -= len(block)

    # Emit adjacent-scale synopses only if budget remains
    for r in adj_entries:
        if budget_remaining <= 0:
            break
        stale_tag = get_staleness_annotation(r["file_path"]) if r.get("source_type") == "knowledge" else ""
        trust_line = render_trust_stamp(r)
        # Derive entry_id from file_path (strip .md suffix)
        entry_id = r.get("file_path", "")
        if entry_id.endswith(".md"):
            entry_id = entry_id[:-3]
        synopsis = _get_or_synthesize_synopsis(entry_id, own_scale, r.get("snippet", ""), script_dir)
        if not synopsis:
            continue
        block = f'\n### {r["heading"]} (from {r["file_path"]}, adjacent-scale){stale_tag}\n{trust_line}\n{synopsis}'
        print(block)
        budget_remaining -= len(block)

else:
    # Non-scale-context path: unchanged flat rendering
    for r in results:
        backlink = build_backlink_from_result(r)
        stale_tag = ""
        if r.get("source_type") == "knowledge":
            stale_tag = get_staleness_annotation(r["file_path"])
        sa_line = ""
        if r.get("source_type") == "knowledge":
            abs_fp = os.path.join(knowledge_dir, r["file_path"])
            sa_key = (abs_fp, r["heading"])
            sa_entries = see_also_map.get(sa_key, [])
            if sa_entries:
                sa_line = "See also: " + ", ".join(sa_entries[:3])

        trust_line = render_trust_stamp(r)

        content = _resolve_content(backlink)
        if content:
            print()
            print(f'### {r["heading"]} (from {r["file_path"]}){stale_tag}')
            print(trust_line)
            print(content)
            if sa_line:
                print(sa_line)
            continue

        snippet = r.get("snippet", "")
        if snippet:
            print()
            print(f'### {r["heading"]} (from {r["file_path"]}){stale_tag}')
            print(trust_line)
            print(snippet)
            if sa_line:
                print(sa_line)

if suppressed_historical > 0 and scale_context == "spec-lead":
    print(f'\n_{suppressed_historical} historical/superseded {"entry" if suppressed_historical == 1 else "entries"} suppressed — add --include-status=historical to expand._')

_log_prefetch(results)
PYEOF

# --- Scope pointers injection ---
# When --work-item is set, read scope_pointers.jsonl and emit entries whose
# target_scope_hint overlaps the query. This surfaces researcher 'Worker leads'
# and worker 'Surfaced concerns' routed via `lore off-scale route`.
if [[ -n "$WORK_ITEM" ]]; then
  SCOPE_POINTERS_FILE="$KNOWLEDGE_DIR/_work/$WORK_ITEM/scope_pointers.jsonl"
  if [[ -f "$SCOPE_POINTERS_FILE" ]]; then
    python3 - "$SCOPE_POINTERS_FILE" "$QUERY" <<'SPEOF'
import json
import sys

scope_pointers_path, query = sys.argv[1:3]
query_lower = query.lower()

rows = []
try:
    with open(scope_pointers_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                rows.append(row)
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    sys.exit(0)

if not rows:
    sys.exit(0)

# Match when: no scope hint (broad pointer), or query term appears in hint or payload
matched = []
for row in rows:
    hint = (row.get("target_scope_hint") or "").lower()
    payload = (row.get("payload") or "").lower()
    if not hint or query_lower in hint or query_lower in payload:
        matched.append(row)

if not matched:
    sys.exit(0)

print()
print("## Scope Pointers")
print("Pending researcher/worker concerns routed from off-scale sidecar:")
for row in matched:
    slot = row.get("protocol_slot", "")
    source = row.get("source", "")
    hint = row.get("target_scope_hint", "") or "(no scope hint)"
    payload = row.get("payload", "")
    route_id = row.get("route_id", "")
    print()
    print(f"- **[{slot}]** (source: {source}, scope: {hint}, route_id: {route_id})")
    print(f"  {payload}")
SPEOF
  fi
fi
