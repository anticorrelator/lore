#!/usr/bin/env bash
# prefetch-knowledge.sh — Search knowledge store and output formatted context for agent prompts
# Usage: bash prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all] [--exclude-backlinks <paths>] [--scale-set <bucket>] [--work-item <slug>]
#
# --format prompt   (default) Full resolved sections for embedding in agent prompts
# --format summary  Headings + snippets for display
# --limit N         Max results (default: 5)
# --type            Filter by source type: knowledge, work, or all (default: all)
# --exclude-backlinks  Comma-separated backlink paths to exclude from results (deduplication
#                      with pre-resolved knowledge already in task descriptions)
# --scale-set <bucket>     Required. Declared retrieval scale bucket: one of abstract,
#                          architecture, subsystem, implementation. No default; missing = error.
# --work-item <slug>       Work item slug (from _work/<slug>/_meta.json). Used only for
#                          scope_pointers injection; no longer used for scale computation.
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
SCALE_SET=""
WORK_ITEM=""
NO_PREFERENCES=0

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
      echo "Warning: --scale-context is deprecated; use --scale-set <bucket> instead." >&2
      shift 2
      ;;
    --scale-set)
      SCALE_SET="$2"
      shift 2
      ;;
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --no-preferences)
      NO_PREFERENCES=1
      shift
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
  echo "Usage: prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all] [--scale-context <role>] [--scale-set <set>] [--work-item <slug>]" >&2
  exit 1
fi

if [[ -z "$SCALE_SET" ]]; then
  echo "Error: --scale-set <bucket> is required. Declare your retrieval scale before fetching." >&2
  echo "  Use: prefetch-knowledge.sh <query> --scale-set <bucket>" >&2
  echo "  Buckets: abstract, architecture, subsystem, implementation" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  # No knowledge store — silent exit (clean no-op)
  exit 0
fi

# --- Scale-context resolution ---
# SCALE_SET is a comma-delimited requested-label set (e.g. "subsystem" or
# "subsystem,implementation"). The set is passed verbatim to pk_cli.py for
# in-search filtering and exported to the Python block for own/other tier
# classification (set-intersection semantics; no adjacent tier).
LORE_SEARCH="$SCRIPT_DIR/pk_cli.py"

if [[ ! -f "$LORE_SEARCH" ]]; then
  exit 0
fi
check_fts_available
if [[ $USE_FTS -eq 0 ]]; then
  exit 0
fi

# --- Preferences side-channel (always-on; --no-preferences opts out) ---
PREF_RESULTS="[]"
if [[ $NO_PREFERENCES -eq 0 ]]; then
  PREF_RESULTS=$(python3 "$LORE_SEARCH" search-preferences "$KNOWLEDGE_DIR" "$QUERY" --json --caller prefetch 2>/dev/null || true)
  if [[ -z "$PREF_RESULTS" ]]; then
    PREF_RESULTS="[]"
  fi
fi

# --- Build search command ---
SEARCH_ARGS=("search" "$KNOWLEDGE_DIR" "$QUERY" "--limit" "$LIMIT" "--json" "--caller" "prefetch")
if [[ "$TYPE" != "all" ]]; then
  SEARCH_ARGS+=("--type" "$TYPE")
fi
SEARCH_ARGS+=("--scale-set" "$SCALE_SET")

# --- Run search ---
RESULTS=$(python3 "$LORE_SEARCH" "${SEARCH_ARGS[@]}" 2>/dev/null || true)

if [[ -z "$RESULTS" ]]; then
  RESULTS="[]"
fi

# Exit early only when BOTH pools are empty
if [[ "$RESULTS" == "[]" && "$PREF_RESULTS" == "[]" ]]; then
  exit 0
fi

# --- Format output ---
export _PK_RESULTS="$RESULTS"
export _PK_PREF_RESULTS="$PREF_RESULTS"
export _PK_EXCLUDE_BACKLINKS="$EXCLUDE_BACKLINKS"
export _PK_SCRIPT_DIR="$SCRIPT_DIR"
export _PK_REQUESTED_SCALES="$SCALE_SET"
export _PK_SCALE_CONTEXT="$SCALE_SET"
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
from pk_search import render_trust_stamp, _CORRECTIONS_FIELD_RE


def _last_corrected_line(file_path_rel: str) -> str:
    """Return 'Last corrected: <date> — <evidence>' for most recent correction, or ''."""
    abs_path = os.path.join(knowledge_dir, file_path_rel)
    try:
        text = open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return ""
    m = _CORRECTIONS_FIELD_RE.search(text)
    if not m:
        return ""
    try:
        items = json.loads(m.group(1))
        if not items:
            return ""
        # Most recent by date
        latest = max(
            (it for it in items if isinstance(it, dict) and it.get("date")),
            key=lambda it: it["date"],
            default=None,
        )
        if not latest:
            return ""
        date = latest.get("date", "")
        evidence = latest.get("evidence", "").strip()
        if evidence:
            return f"Last corrected: {date} — {evidence}"
        return f"Last corrected: {date}"
    except (json.JSONDecodeError, TypeError):
        return ""

knowledge_dir = sys.argv[1]
fmt = sys.argv[2]
query = sys.argv[3]
pk_search_path = sys.argv[4]

results = json.loads(os.environ["_PK_RESULTS"])
pref_results = json.loads(os.environ.get("_PK_PREF_RESULTS", "[]"))

# D5: dedupe preferences out of main pool by (file_path, heading)
if pref_results:
    pref_keys = {(r["file_path"], r["heading"]) for r in pref_results}
    results = [r for r in results if (r.get("file_path"), r.get("heading")) not in pref_keys]

if not results and not pref_results:
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
# Requested scales: a set parsed from the comma-delimited --scale-set argument.
# An entry is classified `own` when its parsed scale set intersects this set;
# everything else (including empty/unknown entry scales when a filter is active)
# is `other`. There is no `adjacent` tier under set-membership semantics.
def _csv_to_set(value: str) -> set:
    return {part.strip().lower() for part in value.split(",") if part.strip()} if value else set()


requested_scales = _csv_to_set(os.environ.get("_PK_REQUESTED_SCALES", ""))
scale_context = os.environ.get("_PK_SCALE_CONTEXT", "")

_SCALE_META_RE = re.compile(r"\|\s*scale:\s*(?P<scale>[^|]+?)\s*(?:\||-->)", re.IGNORECASE)

def _parse_entry_scale(file_path_rel: str) -> set:
    """Read the scale field from an entry's HTML comment metadata as a set of labels.

    Splits on ',', lowercases, strips whitespace. Returns the empty set when the field
    is missing, empty, or 'unknown'.
    """
    abs_path = os.path.join(knowledge_dir, file_path_rel)
    try:
        text = open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return set()
    m = _SCALE_META_RE.search(text)
    if not m:
        return set()
    raw = m.group("scale").strip().lower()
    if raw == "" or raw == "unknown":
        return set()
    return {part.strip() for part in raw.split(",") if part.strip()}


def _scale_tier(entry_scale_set: set) -> str:
    """Classify an entry relative to requested_scales. Returns 'own' or 'other'.

    `own` when the entry's parsed scale set intersects `requested_scales`;
    `other` otherwise. Entries with empty parsed sets fail when a filter is active.
    """
    if not requested_scales:
        return "own"
    if not entry_scale_set:
        return "other"
    if entry_scale_set & requested_scales:
        return "own"
    return "other"


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


_requested_label = ",".join(sorted(requested_scales)) if requested_scales else ""


def _render_preferences_block_summary(prefs):
    """Render the Preferences block for summary format. Bypasses scale/status filters."""
    if not prefs:
        return
    print(f'## Preferences')
    print(f'Scoped working-style guidance matching: "{query}"')
    print()
    for r in prefs:
        snippet = r.get("snippet", "")[:200]
        if len(r.get("snippet", "")) > 200:
            snippet += "..."
        score = r.get("score", 0)
        print(f'- **{r["heading"]}** ({r["file_path"]}, score: {score}): {snippet}')
    print()


def _render_preferences_block_prompt(prefs):
    """Render the Preferences block for prompt format. Bypasses scale/status filters."""
    if not prefs:
        return
    print(f'## Preferences')
    print(f'Scoped working-style guidance matching: "{query}"')
    for r in prefs:
        backlink = build_backlink_from_result(r)
        trust_line = render_trust_stamp(r, knowledge_dir)
        content = _resolve_content_pref(backlink) or r.get("snippet", "")
        print(f'\n### {r["heading"]} (from {r["file_path"]})')
        print(trust_line)
        print(content)
    print()


def _resolve_content_pref(backlink: str) -> str:
    """Return full resolved content for a preferences backlink, or '' on failure."""
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


if fmt == "summary":
    _render_preferences_block_summary(pref_results)
    print(f'## Prior Knowledge')
    if scale_context:
        print(f'Results from knowledge store for: "{query}" (scale-set: {_requested_label})')
    else:
        print(f'Results from knowledge store for: "{query}"')
    print()
    suppressed_historical = 0
    for r in results:
        tier = "own"
        if scale_context and r.get("source_type") == "knowledge":
            entry_scale_set = _parse_entry_scale(r["file_path"])
            tier = _scale_tier(entry_scale_set)
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
        print(f'- **{r["heading"]}** ({r["file_path"]}, score: {score}): {snippet}')
    if suppressed_historical > 0 and scale_context == "spec-lead":
        print(f'\n_{suppressed_historical} historical/superseded {"entry" if suppressed_historical == 1 else "entries"} suppressed — add --include-status=historical to expand._')
    _log_prefetch(results)
    sys.exit(0)

# prompt format — resolve each result to full content
_render_preferences_block_prompt(pref_results)
print(f'## Prior Knowledge')
if scale_context:
    print(f'Results from knowledge store for: "{query}" (scale-set: {_requested_label})')
else:
    print(f'Results from knowledge store for: "{query}"')

# Budget: own-scale entries consume up to PREFETCH_BUDGET chars.
# Default 12000 chars (v1 ceiling per wider-net-phase-retrieval design D3).
# Per-section enforcement lives in resolve-manifest.sh's v2 path; this single-pass
# global budget applies to the legacy/non-manifest prefetch caller.
PREFETCH_BUDGET = 12000

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

# Single-pass rendering: keep entries whose parsed scale set intersects
# requested_scales (own); drop the rest. Set-membership semantics retire the
# adjacent-tier render path along with the synopsis-cache fallback it used.
own_entries = []

for r in results:
    if r.get("source_type") == "knowledge":
        entry_scale_set = _parse_entry_scale(r["file_path"])
        tier = _scale_tier(entry_scale_set)
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
    own_entries.append(r)

budget_remaining = PREFETCH_BUDGET

# Emit own-scale entries with full → snippet → backlink degradation to fit the budget.
SNIPPET_LIMIT = 600

def _full_block(r, content, stale_tag, trust_line, corrected_line, sa_line):
    block = f'\n### {r["heading"]} (from {r["file_path"]}){stale_tag}\n{trust_line}'
    if corrected_line:
        block += f'\n{corrected_line}'
    block += f'\n{content}'
    if sa_line:
        block += f'\n{sa_line}'
    return block

def _snippet_block(r, snippet, stale_tag):
    return f'\n### {r["heading"]} (from {r["file_path"]}){stale_tag}\n{snippet[:SNIPPET_LIMIT]}'

def _backlink_block(r):
    target = r["file_path"]
    if target.endswith(".md"):
        target = target[:-3]
    return f'\n- [[knowledge:{target}#{r["heading"]}]]'

for r in own_entries:
    backlink = build_backlink_from_result(r)
    stale_tag = get_staleness_annotation(r["file_path"]) if r.get("source_type") == "knowledge" else ""
    abs_fp = os.path.join(knowledge_dir, r.get("file_path", ""))
    sa_key = (abs_fp, r["heading"])
    sa_entries = see_also_map.get(sa_key, [])
    sa_line = ("See also: " + ", ".join(sa_entries[:3])) if sa_entries else ""
    trust_line = render_trust_stamp(r, knowledge_dir)
    corrected_line = _last_corrected_line(r["file_path"]) if r.get("source_type") == "knowledge" else ""

    content = _resolve_content(backlink)
    if not content:
        content = r.get("snippet", "")
    block = _full_block(r, content, stale_tag, trust_line, corrected_line, sa_line)
    if len(block) > budget_remaining:
        snippet_block = _snippet_block(r, r.get("snippet", "") or content, stale_tag)
        if len(snippet_block) > budget_remaining:
            backlink_block = _backlink_block(r)
            if len(backlink_block) > budget_remaining:
                break
            print(backlink_block)
            budget_remaining -= len(backlink_block)
            continue
        print(snippet_block)
        budget_remaining -= len(snippet_block)
        continue
    print(block)
    budget_remaining -= len(block)

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
