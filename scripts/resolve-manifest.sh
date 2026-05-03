#!/usr/bin/env bash
# resolve-manifest.sh — Resolve a phase's retrieval_directive into a ## Prior Knowledge bundle
# Usage: bash resolve-manifest.sh <slug> <phase_number>
#
# <slug>          Work item slug (must have a tasks.json in $KDIR/_work/<slug>/)
# <phase_number>  1-based phase index (must correspond to a phase in tasks.json)
#
# Stdout: A ## Prior Knowledge markdown block.
#   - Legacy flat directive: passes through `lore query --format prompt` (single section).
#   - v2 directive (version: 2): fans out one BM25 OR query per topic via `lore query --json`,
#     emits sectioned `### Focal: <topic>` / `### Adjacent: <topic>` blocks with per-section
#     budgeting, full→snippet→backlink degradation, and per-section telemetry.
#
# Stderr: Diagnostic messages on error conditions.
# Exit 0: success
# Exit non-zero: missing tasks.json, invalid JSON, bad phase number, null directive,
#                empty seeds (legacy), missing scale_set (legacy), v2 invariants violated.
#
# On each successful resolve, appends a manifest_load event to $KDIR/_meta/retrieval-log.jsonl.
# Fail-open: log write errors do not block stdout. v2 records per-section fields (topic,
# section_role, requested_k, raw_count, served_count, deduped_count, served_paths, chars_used,
# chars_budget, render_mode_counts, content_degraded, shrunk_for_budget, entry_count_before_budget)
# and per-call records add query_kind (topic|activity).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Validate arguments ---
if [[ $# -lt 2 ]]; then
  echo "Usage: resolve-manifest.sh <slug> <phase_number>" >&2
  exit 1
fi

SLUG="$1"
PHASE_NUMBER="$2"

if ! [[ "$PHASE_NUMBER" =~ ^[0-9]+$ ]] || [[ "$PHASE_NUMBER" -lt 1 ]]; then
  echo "Error: phase_number must be a positive integer, got: '$PHASE_NUMBER'" >&2
  exit 1
fi

# --- Resolve knowledge dir and tasks.json path ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
TASKS_FILE="$KNOWLEDGE_DIR/_work/$SLUG/tasks.json"

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "Error: tasks.json not found for slug '$SLUG' (expected: $TASKS_FILE)" >&2
  exit 1
fi

# --- Extract retrieval_directive for the requested phase ---
PHASE_INDEX=$(( PHASE_NUMBER - 1 ))

DIRECTIVE_JSON=$(python3 - "$TASKS_FILE" "$PHASE_INDEX" <<'EXTRACT_PY'
import json, sys

tasks_file = sys.argv[1]
phase_index = int(sys.argv[2])

try:
    with open(tasks_file) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"Error: tasks.json is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

phases = data.get("phases", [])
if phase_index >= len(phases):
    print(f"Error: phase_number {phase_index + 1} out of range (tasks.json has {len(phases)} phases)", file=sys.stderr)
    sys.exit(1)

phase = phases[phase_index]
directive = phase.get("retrieval_directive")

if directive is None:
    print("null")
else:
    print(json.dumps(directive))
EXTRACT_PY
) || exit 1

if [[ "$DIRECTIVE_JSON" == "null" ]]; then
  echo "Error: phase $PHASE_NUMBER of '$SLUG' has no retrieval_directive; a scale-declared directive is required." >&2
  exit 1
fi

# --- Branch on directive version ---
DIRECTIVE_VERSION=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('version', 1))
" "$DIRECTIVE_JSON" 2>/dev/null || echo "1")

if [[ "$DIRECTIVE_VERSION" == "2" ]]; then
  # ============================================================
  # v2 grouped path — per-topic fan-out, sectioned output
  # ============================================================
  export _RM_DIRECTIVE_JSON="$DIRECTIVE_JSON"
  export _RM_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
  export _RM_SLUG="$SLUG"
  export _RM_PHASE_NUMBER="$PHASE_NUMBER"
  export _RM_PK_CLI="$SCRIPT_DIR/pk_cli.py"

  python3 - <<'V2_PY'
import json
import os
import re
import subprocess
import sys
import datetime

# Constants from D3/D5
GLOBAL_CHAR_CEILING = 12000
GLOBAL_ENTRY_CEILING = 35
FOCAL_FLOOR_K = 5
ACTIVITY_RESERVED_FOCAL = 2
ACTIVITY_RESERVED_ADJACENT = 1
MANIFEST_VERSION = 2

# Render-mode budgets — chars per entry block headroom.
# A "full" entry is the resolved entry text + heading; snippet is short; backlink is single-line.
SNIPPET_CHAR_LIMIT = 600

directive = json.loads(os.environ["_RM_DIRECTIVE_JSON"])
knowledge_dir = os.environ["_RM_KNOWLEDGE_DIR"]
slug = os.environ["_RM_SLUG"]
phase_number = int(os.environ["_RM_PHASE_NUMBER"])
pk_cli = os.environ["_RM_PK_CLI"]

topics = directive.get("topics", [])
if not topics:
    print(f"Error: v2 directive in phase {phase_number} of '{slug}' has empty topics list.", file=sys.stderr)
    sys.exit(1)

# --- Helpers ---

_KNOWLEDGE_BL_RE = re.compile(r"\[\[knowledge:([^\]#]+)(#[^\]]+)?\]\]")
_WORK_BL_RE = re.compile(r"\[\[work:([^\]#]+)(#[^\]]+)?\]\]")


def _backlink_to_vocab(seed: str) -> str:
    """Resolve a backlink seed to its title/path-vocabulary tokens.

    Raw `[[knowledge:foo/bar/baz]]` would tokenize as a single literal and miss the index.
    Strip brackets and split path components into searchable tokens.
    """
    m = _KNOWLEDGE_BL_RE.match(seed.strip())
    if m:
        path = m.group(1)
        # Split on '/', '-', '_' — path vocabulary
        tokens = re.split(r"[\s/\-_]+", path)
        return " ".join(t for t in tokens if t)
    m = _WORK_BL_RE.match(seed.strip())
    if m:
        path = m.group(1)
        tokens = re.split(r"[\s/\-_]+", path)
        return " ".join(t for t in tokens if t)
    return seed.strip()


def _build_query(topic: dict) -> str:
    """Build the BM25 OR query from a topic. Honor literal `query:` if set."""
    if topic.get("query"):
        return topic["query"]
    parts: list[str] = []
    if topic.get("topic"):
        parts.append(topic["topic"])
    for seed in topic.get("seeds", []):
        resolved = _backlink_to_vocab(seed)
        if resolved:
            parts.append(resolved)
    return " ".join(parts).strip()


def _run_lore_query(query: str, scale_set: list[str], limit: int, caller: str) -> list[dict]:
    """Issue one BM25 OR query through ``pk_cli.py search`` and return the JSON entries.

    ``pk_cli.py search`` uses ``Searcher.search()`` which is the single authority for
    scale filtering and the two scale-bypass rules (Worker-1's consolidation). Calling
    pk_cli.py directly (rather than ``lore query``) is intentional: it exposes
    ``--limit`` and ``--caller`` as first-class flags. The OR-default ranking and
    scale-bypass rules are identical because both paths route through Searcher.
    """
    if not query.strip():
        return []
    if not scale_set:
        return []
    args = [
        "python3", pk_cli, "search", knowledge_dir, query,
        "--scale-set", ",".join(scale_set),
        "--limit", str(limit),
        "--json",
        "--caller", caller,
    ]
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=15)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []
    if proc.returncode != 0:
        return []
    out = proc.stdout.strip()
    if not out or out == "[]":
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict) and "full" in data:
        entries = data["full"]
    elif isinstance(data, list):
        entries = data
    else:
        entries = []
    return [e for e in entries if isinstance(e, dict)]


def _entry_path(entry: dict) -> str:
    return entry.get("path") or entry.get("file_path") or ""


def _entry_heading(entry: dict) -> str:
    return entry.get("heading") or entry.get("title") or ""


def _entry_full_block(entry: dict, topic_label: str) -> str:
    heading = _entry_heading(entry)
    path = _entry_path(entry)
    content = entry.get("content") or entry.get("body") or entry.get("snippet") or ""
    block = f"\n#### {heading} (from {path})\n{content}\n"
    return block


def _entry_snippet_block(entry: dict) -> str:
    heading = _entry_heading(entry)
    path = _entry_path(entry)
    snippet = (entry.get("snippet") or entry.get("content") or "")[:SNIPPET_CHAR_LIMIT]
    block = f"\n#### {heading} (from {path})\n{snippet}\n"
    return block


def _entry_backlink_block(entry: dict) -> str:
    heading = _entry_heading(entry)
    path = _entry_path(entry)
    target = path
    if target.endswith(".md"):
        target = target[:-3]
    bl = f"[[knowledge:{target}#{heading}]]" if heading else f"[[knowledge:{target}]]"
    return f"\n- {bl}\n"


# --- Per-call telemetry buffer ---
call_log: list[dict] = []


def _log_call(topic_label: str, scale_set: list[str], query_kind: str, query: str, raw_count: int):
    call_log.append({
        "topic": topic_label,
        "scale_set": scale_set,
        "query_kind": query_kind,
        "query": query,
        "raw_count": raw_count,
    })


# --- Step 1: Per-topic fan-out + activity-pass merging ---

def _resolve_topic(topic: dict) -> dict:
    """Run topic + (optional) activity queries; merge with reserved-slot policy.

    Returns a dict with: role, topic, requested_k, raw_count, deduped_count,
    candidates (list of dicts with `entry`, `query_kind`).
    """
    role = topic.get("role", "adjacent")
    label = topic.get("topic", "")
    scale_set = topic.get("scale_set", [])
    requested_k = int(topic.get("limit") or (8 if role == "focal" else 4))
    activity_vocab = topic.get("activity_vocab") or []

    # Topical query
    query = _build_query(topic)
    raw_topical = _run_lore_query(query, scale_set, max(requested_k * 2, requested_k + 4), caller="resolve-manifest")
    _log_call(label, scale_set, "topic", query, len(raw_topical))

    # Activity query (optional)
    raw_activity: list[dict] = []
    if activity_vocab:
        activity_query = " ".join(activity_vocab)
        raw_activity = _run_lore_query(activity_query, scale_set, max(requested_k, 4), caller="resolve-manifest")
        _log_call(label, scale_set, "activity", activity_query, len(raw_activity))

    # Dedup activity hits against topical hits already selected.
    selected_topical: list[dict] = []
    seen_paths: set[str] = set()
    for e in raw_topical:
        p = _entry_path(e)
        if not p or p in seen_paths:
            continue
        seen_paths.add(p)
        selected_topical.append({"entry": e, "query_kind": "topic"})

    # Reserved activity slots
    reserved = ACTIVITY_RESERVED_FOCAL if role == "focal" else ACTIVITY_RESERVED_ADJACENT
    activity_unique: list[dict] = []
    for e in raw_activity:
        p = _entry_path(e)
        if not p or p in seen_paths:
            continue
        seen_paths.add(p)
        activity_unique.append({"entry": e, "query_kind": "activity"})

    # Selection: take up to (requested_k - reserved) topical, then up to `reserved` activity,
    # then roll any unused reserved slots back to remaining topical.
    base_topical_slots = max(requested_k - reserved, 0)
    chosen: list[dict] = []
    chosen.extend(selected_topical[:base_topical_slots])
    activity_to_take = min(reserved, len(activity_unique))
    chosen.extend(activity_unique[:activity_to_take])
    rollback = reserved - activity_to_take
    # Rollback unused reserved slots to additional topical.
    extras = selected_topical[base_topical_slots:base_topical_slots + rollback]
    chosen.extend(extras)
    # If we still have headroom (unlikely given oversample), top up.
    while len(chosen) < requested_k:
        # Pull any remaining topical first, then activity.
        consumed_topical = base_topical_slots + len(extras)
        if consumed_topical < len(selected_topical):
            chosen.append(selected_topical[consumed_topical])
            base_topical_slots += 1
            continue
        consumed_activity = activity_to_take
        if consumed_activity < len(activity_unique):
            chosen.append(activity_unique[consumed_activity])
            activity_to_take += 1
            continue
        break

    raw_count = len(raw_topical) + len(raw_activity)
    deduped_count = len(selected_topical) + len(activity_unique)
    return {
        "role": role,
        "topic": label,
        "requested_k": requested_k,
        "raw_count": raw_count,
        "deduped_count": deduped_count,
        "candidates": chosen[:requested_k],
    }


resolved_topics = [_resolve_topic(t) for t in topics]

# Cross-section dedup: an entry that appears in both focal and adjacent stays in focal.
seen_global: set[str] = set()
for sec in resolved_topics:
    if sec["role"] == "focal":
        for c in sec["candidates"]:
            p = _entry_path(c["entry"])
            if p:
                seen_global.add(p)
for sec in resolved_topics:
    if sec["role"] != "focal":
        sec["candidates"] = [c for c in sec["candidates"] if _entry_path(c["entry"]) not in seen_global]
        for c in sec["candidates"]:
            p = _entry_path(c["entry"])
            if p:
                seen_global.add(p)


# --- Step 2: Per-section budget allocation ---
# Allocate the 12k char ceiling: focal gets ~40%, adjacent split the remaining ~60%.

focal_sections = [s for s in resolved_topics if s["role"] == "focal"]
adjacent_sections = [s for s in resolved_topics if s["role"] == "adjacent"]

if focal_sections:
    focal_budget = int(GLOBAL_CHAR_CEILING * 0.40)
else:
    focal_budget = 0

if adjacent_sections:
    adjacent_total = GLOBAL_CHAR_CEILING - focal_budget
    adjacent_per = adjacent_total // len(adjacent_sections)
else:
    adjacent_per = 0

for sec in resolved_topics:
    if sec["role"] == "focal":
        sec["chars_budget"] = focal_budget
    else:
        sec["chars_budget"] = adjacent_per


# --- Step 3: Render with full → snippet → backlink degradation per section ---

def _render_section(sec: dict) -> dict:
    """Render a section under its char budget, degrading entries as needed.

    Returns a dict with: rendered (str), served_count, chars_used, render_mode_counts,
    content_degraded, shrunk_for_budget, entry_count_before_budget, served_paths.
    """
    candidates = sec["candidates"]
    budget = sec["chars_budget"]
    role = sec["role"]
    label = sec["topic"]
    floor = FOCAL_FLOOR_K if role == "focal" else 1

    entry_count_before_budget = len(candidates)
    # Header line is part of the section; count it.
    header_line = f"\n### {role.capitalize()}: {label}\n"
    header_chars = len(header_line)

    # Try at full mode first.
    blocks_full = [(c, _entry_full_block(c["entry"], label)) for c in candidates]
    total_full = header_chars + sum(len(b) for _, b in blocks_full)

    served = candidates[:]
    rendered_blocks: list[tuple[dict, str, str]] = []  # (cand, mode, block)
    for c, b in blocks_full:
        rendered_blocks.append((c, "full", b))

    content_degraded = False
    shrunk_for_budget = False

    # Iteratively shrink until under budget or floor reached.
    def _total_chars(rb: list) -> int:
        return header_chars + sum(len(b) for _, _, b in rb)

    while _total_chars(rendered_blocks) > budget and rendered_blocks:
        # Step down the largest current block: full -> snippet -> backlink.
        # Iterate from worst-priority (last) entry forward.
        downgraded = False
        for i in range(len(rendered_blocks) - 1, -1, -1):
            cand, mode, _ = rendered_blocks[i]
            if mode == "full":
                rendered_blocks[i] = (cand, "snippet", _entry_snippet_block(cand["entry"]))
                content_degraded = True
                downgraded = True
                break
            if mode == "snippet":
                rendered_blocks[i] = (cand, "backlink", _entry_backlink_block(cand["entry"]))
                content_degraded = True
                downgraded = True
                break
        if downgraded:
            continue
        # All blocks at backlink mode; if still over budget, drop entries from the bottom
        # until at floor or under budget.
        if len(rendered_blocks) > floor:
            rendered_blocks.pop()
            shrunk_for_budget = True
            continue
        # Cannot shrink further.
        break

    served_count = len(rendered_blocks)
    chars_used = _total_chars(rendered_blocks)
    render_mode_counts = {"full": 0, "snippet": 0, "backlink": 0}
    for _, m, _ in rendered_blocks:
        render_mode_counts[m] += 1

    served_paths = [_entry_path(c["entry"]) for c, _, _ in rendered_blocks if _entry_path(c["entry"])]

    rendered = header_line + "".join(b for _, _, b in rendered_blocks)

    return {
        "rendered": rendered,
        "served_count": served_count,
        "chars_used": chars_used,
        "render_mode_counts": render_mode_counts,
        "content_degraded": content_degraded,
        "shrunk_for_budget": shrunk_for_budget,
        "entry_count_before_budget": entry_count_before_budget,
        "served_paths": served_paths,
    }


# Render in priority order: focal first, then adjacent. Track chars used so the
# global ceiling shrinks adjacent before focal if combined output exceeds the cap.
output_parts: list[str] = ["## Prior Knowledge\n"]
total_chars = len(output_parts[0])
section_records: list[dict] = []

# Build initial renderings
for sec in resolved_topics:
    sec["render_result"] = _render_section(sec)

# Sum up actual chars (post-section render); shrink adjacent if combined exceeds ceiling.
combined_chars = total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics)
if combined_chars > GLOBAL_CHAR_CEILING:
    # Shrink adjacent sections first by reducing their budget proportionally and re-rendering.
    overflow = combined_chars - GLOBAL_CHAR_CEILING
    for sec in resolved_topics:
        if sec["role"] != "adjacent":
            continue
        # Reduce this section's budget by its share of overflow until it fits.
        new_budget = max(sec["chars_budget"] - overflow, 200)
        sec["chars_budget"] = new_budget
        sec["render_result"] = _render_section(sec)
        combined_chars = total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics)
        if combined_chars <= GLOBAL_CHAR_CEILING:
            break

# Last-resort: if still over after shrinking adjacent, shrink focal — but not below floor K.
if total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics) > GLOBAL_CHAR_CEILING:
    for sec in resolved_topics:
        if sec["role"] != "focal":
            continue
        sec["chars_budget"] = int(sec["chars_budget"] * 0.7)
        sec["render_result"] = _render_section(sec)
        if total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics) <= GLOBAL_CHAR_CEILING:
            break

# Emit final output
for sec in resolved_topics:
    output_parts.append(sec["render_result"]["rendered"])
    section_records.append({
        "manifest_version": MANIFEST_VERSION,
        "topic": sec["topic"],
        "section_role": sec["role"],
        "requested_k": sec["requested_k"],
        "raw_count": sec["raw_count"],
        "served_count": sec["render_result"]["served_count"],
        "deduped_count": sec["deduped_count"],
        "served_paths": sec["render_result"]["served_paths"],
        "chars_used": sec["render_result"]["chars_used"],
        "chars_budget": sec["chars_budget"],
        "render_mode_counts": sec["render_result"]["render_mode_counts"],
        "content_degraded": sec["render_result"]["content_degraded"],
        "shrunk_for_budget": sec["render_result"]["shrunk_for_budget"],
        "entry_count_before_budget": sec["render_result"]["entry_count_before_budget"],
    })

print("".join(output_parts), end="")

# --- _RM_PATHS stdout side-channel contract (supported, documented) ---
# Shape: a single trailing line of the exact form `<!-- _RM_PATHS=<csv> -->`
# appended after the ## Prior Knowledge body, where <csv> is the unquoted
# comma-separated list of served manifest paths resolved during this
# invocation. Paths may not contain commas (the CSV is unquoted, no escaping).
# An empty `<csv>` means no served paths; absence of the line means the v2
# path did not run (legacy flat path emits no marker — it exports
# RESOLVE_MANIFEST_PATHS directly from JSON at the env-var step below).
#
# Canonical consumer: env-export-via-stdout-reparse — a caller that sources
# or captures this script's stdout extracts the CSV from the marker line and
# exports it as `RESOLVE_MANIFEST_PATHS` (mirroring the legacy flat path's
# behavior at the `RESOLVE_MANIFEST_PATHS=$(python3 -c …)` block below).
# Inside this script the v2 telemetry block uses `all_paths` directly rather
# than reparsing the marker, so the marker is currently a forward-compatible
# export surface; an audit at the time this comment was written
# (grep -rn "RESOLVE_MANIFEST_PATHS\|_RM_PATHS\|source.*resolve-manifest"
# across scripts/, cli/, skills/, agents/) found NO external strict-stdout-
# parsing consumers — the marker exists for that pattern but no caller
# currently relies on it.
#
# Stability: the marker is treated as a documented stdout contract. Future
# edits MUST preserve the literal `<!-- _RM_PATHS=` prefix and ` -->` suffix
# and the unquoted-CSV body so any future env-export-via-stdout-reparse
# consumer keeps working. Do not migrate this side channel to a sidecar
# file (D3 in the wider-net-phase-retrieval-surfaced-concerns-follow plan
# explicitly rejects that direction): a sidecar adds a second IO surface,
# a write-race failure mode, and a stale-leftover removal path for
# consumers that do not exist.
all_paths: list[str] = []
for sec in section_records:
    all_paths.extend(sec["served_paths"])
print(f"\n<!-- _RM_PATHS={','.join(all_paths)} -->")

# --- Telemetry: manifest_load event with per-section + per-call records (fail-open) ---
log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
try:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    record = {
        "timestamp": ts,
        "event": "manifest_load",
        "slug": slug,
        "phase": phase_number,
        "task_id": None,
        "manifest_version": MANIFEST_VERSION,
        "loaded_paths": all_paths,
        "sections": section_records,
        "calls": call_log,
    }
    with open(log_path, "a") as lf:
        lf.write(json.dumps(record) + "\n")
except OSError:
    pass
V2_PY
  exit 0
fi

# ============================================================
# Legacy flat path — single `lore query` call, single section
# ============================================================

SEEDS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
seeds = d.get('seeds', [])
print(','.join(seeds))
" "$DIRECTIVE_JSON" 2>/dev/null || true)

HOP_BUDGET=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('hop_budget', 1))
" "$DIRECTIVE_JSON" 2>/dev/null || echo "1")

SCALE_SET=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
ss = d.get('scale_set', [])
print(','.join(ss) if ss else '')
" "$DIRECTIVE_JSON" 2>/dev/null || true)

FILTER_TYPE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
f = d.get('filters', {})
print(f.get('type', '') if isinstance(f, dict) else '')
" "$DIRECTIVE_JSON" 2>/dev/null || true)

FILTER_EXCLUDE_CATEGORY=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
f = d.get('filters', {})
print(f.get('exclude_category', '') if isinstance(f, dict) else '')
" "$DIRECTIVE_JSON" 2>/dev/null || true)

if [[ -z "$SEEDS" ]]; then
  echo "Error: phase $PHASE_NUMBER of '$SLUG' has a retrieval_directive with no seeds; seeds are required." >&2
  exit 1
fi

if [[ -z "$SCALE_SET" ]]; then
  echo "Error: phase $PHASE_NUMBER of '$SLUG' has a retrieval_directive with no scale_set; declare a scale before fetching." >&2
  exit 1
fi

QUERY_ARGS=("query" "--seeds" "$SEEDS" "--hop-budget" "$HOP_BUDGET" "--scale-set" "$SCALE_SET")
if [[ -n "$FILTER_TYPE" ]]; then
  QUERY_ARGS+=("--type" "$FILTER_TYPE")
fi
if [[ -n "$FILTER_EXCLUDE_CATEGORY" ]]; then
  QUERY_ARGS+=("--exclude-category" "$FILTER_EXCLUDE_CATEGORY")
fi

JSON_RESULT=$(lore "${QUERY_ARGS[@]}" --format json 2>/dev/null || true)

if [[ -n "$JSON_RESULT" && "$JSON_RESULT" != "[]" ]]; then
  RESOLVE_MANIFEST_PATHS=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
if isinstance(data, dict) and 'full' in data:
    entries = data['full']
else:
    entries = data if isinstance(data, list) else []
paths = [e.get('path', e.get('file_path', '')) for e in entries if e.get('path') or e.get('file_path')]
print(','.join(p for p in paths if p))
" "$JSON_RESULT" 2>/dev/null || true)
  export RESOLVE_MANIFEST_PATHS
else
  export RESOLVE_MANIFEST_PATHS=""
fi

PROMPT_OUTPUT=$(lore "${QUERY_ARGS[@]}" --format prompt 2>/dev/null || true)
if [[ -n "$PROMPT_OUTPUT" ]]; then
  printf '%s\n' "$PROMPT_OUTPUT"
fi

# Legacy telemetry: manifest_load event without per-section fields.
python3 - "$KNOWLEDGE_DIR" "$SLUG" "$PHASE_NUMBER" "$RESOLVE_MANIFEST_PATHS" <<'LOG_PY'
import json, os, sys, datetime

knowledge_dir = sys.argv[1]
slug = sys.argv[2]
phase = int(sys.argv[3])
paths_csv = sys.argv[4]

log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
loaded_paths = [p for p in paths_csv.split(",") if p] if paths_csv else []

record = json.dumps({
    "timestamp": ts,
    "event": "manifest_load",
    "slug": slug,
    "phase": phase,
    "task_id": None,
    "manifest_version": 1,
    "loaded_paths": loaded_paths,
})

try:
    with open(log_path, "a") as lf:
        lf.write(record + "\n")
except OSError:
    pass
LOG_PY
