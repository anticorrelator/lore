#!/usr/bin/env python3
"""
Mine retrieval misses from a session transcript and emit capture candidates.

Runs from the SessionStart hook chain with previous-session semantics (same
as extract-session-digest.py: at hook time the most-recent transcript IS the
current session, so we mine the second-most-recent). With --experiment it
instead sweeps a bounded sample of the historical corpus and writes
candidates to --output-dir, never the live queue.

Pairing model: `lore search` Bash tool calls found in the transcript are
joined to _meta/retrieval-log.jsonl rows by exact query string + timestamp
window. One CLI invocation logs one row per search pool (main + work), so
a call matches the in-window row set when the rows' source_types are
pairwise distinct; duplicated source_types mean overlapping invocations
and are quarantined as ambiguous, never guessed. A matched invocation
whose rows all miss (row["miss"] when present; rows that predate miss
enrichment fall back to result_count == 0) and that is followed in the
same session by derivation activity (the "derivation" pattern set in
scripts/event-patterns.json: non-sidechain Grep/Glob/Read or Explore-agent
spawns) produces one candidate file for /remember Step 0a. Every run
prints join-audit metrics so silent under-matching is visible.

Write discipline: this script is the sanctioned writer of _pending_captures/
(succeeding the retired stop-novelty-check.py) and of
_meta/miss-miner-state.json. It only reads retrieval-log.jsonl
(pk_search.py's file) and never writes knowledge entries. No dedup, no
novelty scoring, no value judgment at mine time — the /remember 4-condition
gate owns precision. Candidate filenames are content-hashed so re-emitting
the same candidate is an idempotent overwrite, and the state file prevents
re-mining a session whose candidates were already adjudicated and deleted.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timedelta

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from adapters.transcripts import get_provider, UnsupportedFrameworkError

_SCRIPTS_DIR = os.path.dirname(os.path.realpath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
from transcript import resolve_knowledge_dir as _resolve_knowledge_dir

TRIGGER = "retrieval-miss"

# A log row joins a transcript call when its timestamp falls in
# [call_ts - JOIN_SKEW, call_ts + JOIN_WINDOW]. The message timestamp
# precedes Bash execution (permission prompts can delay it), so the
# window is wide forward and near-zero backward.
JOIN_SKEW_SECONDS = 2
JOIN_WINDOW_SECONDS = 300

RELATED_FILES_LIMIT = 8
STATE_FILENAME = "miss-miner-state.json"
STATE_KEEP = 200
DEFAULT_MAX_SESSIONS = 30

EVENT_PATTERNS_PATH = os.path.join(_SCRIPTS_DIR, "event-patterns.json")


def load_event_patterns():
    with open(EVENT_PATTERNS_PATH, encoding="utf-8") as f:
        sets = json.load(f)["pattern_sets"]
    retrieval = sets["retrieval-call"]
    derivation = sets["derivation"]
    return {
        "bash_tool": retrieval["tool"],
        "command_regexes": {
            kind: re.compile(pattern)
            for kind, pattern in retrieval["command_regexes"].items()
        },
        "derivation_tools": frozenset(derivation["tool_names"]),
        "agent_tools": frozenset(derivation["agent_tool_names"]),
        "agent_subagent_types": frozenset(derivation["agent_subagent_types"]),
    }


def parse_ts(value):
    """Parse a transcript ('...Z') or retrieval-log ('...-0400') timestamp."""
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        try:
            return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S%z")
        except ValueError:
            return None


def load_log_index(knowledge_dir):
    """Index retrieval-log search rows by exact query string.

    Returns ({query: [(ts, row), ...] in file order}, corrupt_row_count).
    Corrupt rows are excluded with a warning count, never guessed at.
    """
    log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
    index = {}
    skipped = 0
    try:
        with open(log_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    skipped += 1
                    continue
                if row.get("event") != "search" or "query" not in row:
                    continue
                ts = parse_ts(row.get("timestamp"))
                if ts is None:
                    skipped += 1
                    continue
                index.setdefault(row["query"], []).append((ts, row))
    except OSError:
        pass
    return index, skipped


class RawLineCache:
    """Lazy JSON parse of raw transcript lines, aligned with
    parse_transcript indices (message["index"] == raw line number)."""

    def __init__(self, raw_lines):
        self._raw = raw_lines
        self._cache = {}

    def entry(self, index):
        if index in self._cache:
            return self._cache[index]
        parsed = None
        if 0 <= index < len(self._raw):
            try:
                parsed = json.loads(self._raw[index])
            except (json.JSONDecodeError, TypeError):
                parsed = None
        self._cache[index] = parsed
        return parsed

    def is_sidechain(self, index):
        entry = self.entry(index)
        return bool(entry and entry.get("isSidechain"))

    def tool_use_blocks(self, index):
        entry = self.entry(index)
        if not entry:
            return []
        content = entry.get("message", {}).get("content")
        if not isinstance(content, list):
            return []
        return [
            b for b in content
            if isinstance(b, dict) and b.get("type") == "tool_use"
        ]


def extract_retrieval_calls(messages, raw_cache, patterns):
    """Find lore search/prefetch Bash invocations on non-sidechain
    assistant messages. Returns [{index, ts, query, kind}, ...] in order."""
    calls = []
    for msg in messages:
        if msg.get("role") != "assistant" or not msg.get("has_tool_use"):
            continue
        if patterns["bash_tool"] not in msg.get("tool_names", []):
            continue
        idx = msg["index"]
        if raw_cache.is_sidechain(idx):
            continue
        entry = raw_cache.entry(idx)
        ts = parse_ts(entry.get("timestamp")) if entry else None
        for block in raw_cache.tool_use_blocks(idx):
            if block.get("name") != patterns["bash_tool"]:
                continue
            command = block.get("input", {}).get("command", "")
            if not isinstance(command, str):
                continue
            for kind, regex in patterns["command_regexes"].items():
                for m in regex.finditer(command):
                    query = next((g for g in m.groups() if g), None)
                    if query:
                        calls.append(
                            {"index": idx, "ts": ts, "query": query, "kind": kind}
                        )
    return calls


def join_calls_to_log(calls, log_index):
    """Join search calls to log rows by exact query + timestamp window.

    One CLI `lore search` invocation logs one row per search pool (main
    pool source_type null, work pool source_type "work") with the same
    query and second, so a single call legitimately faces a small row
    set. In-window unclaimed rows with pairwise-distinct source_type are
    that fan-out and match as a set; any duplicated source_type means
    more than one invocation is in the window → ambiguous (quarantined,
    no candidate). Zero rows → unmatched. Returns
    (matched [(call, rows)], counts dict).
    """
    counts = {"matched": 0, "unmatched": 0, "ambiguous": 0}
    matched = []
    claimed = set()
    for call in calls:
        if call["kind"] != "search":
            continue
        if call["ts"] is None:
            counts["unmatched"] += 1
            continue
        lo = call["ts"] - timedelta(seconds=JOIN_SKEW_SECONDS)
        hi = call["ts"] + timedelta(seconds=JOIN_WINDOW_SECONDS)
        rows = log_index.get(call["query"], [])
        in_window = [
            (pos, row) for pos, (ts, row) in enumerate(rows)
            if (call["query"], pos) not in claimed and lo <= ts <= hi
        ]
        source_types = [row.get("source_type") for _, row in in_window]
        if not in_window:
            counts["unmatched"] += 1
        elif len(set(source_types)) == len(source_types):
            for pos, _ in in_window:
                claimed.add((call["query"], pos))
            matched.append((call, [row for _, row in in_window]))
            counts["matched"] += 1
        else:
            counts["ambiguous"] += 1
    return matched, counts


def row_is_miss(row):
    """Miss per the log row. Rows predating pk_search miss enrichment
    have no "miss" field; for them zero results is the only definite miss."""
    if "miss" in row:
        return bool(row["miss"])
    return row.get("result_count") == 0


def detect_derivation(messages, raw_cache, start_index, patterns):
    """Count derivation tool events on non-sidechain assistant messages
    after start_index. Returns ({tool_label: count}, last_event_index)."""
    tool_counts = {}
    last_index = start_index
    for msg in messages:
        idx = msg["index"]
        if idx <= start_index or msg.get("role") != "assistant":
            continue
        names = msg.get("tool_names", [])
        plain = [n for n in names if n in patterns["derivation_tools"]]
        agent_candidates = [n for n in names if n in patterns["agent_tools"]]
        if not plain and not agent_candidates:
            continue
        if raw_cache.is_sidechain(idx):
            continue
        for name in plain:
            tool_counts[name] = tool_counts.get(name, 0) + 1
            last_index = idx
        if agent_candidates:
            for block in raw_cache.tool_use_blocks(idx):
                if block.get("name") not in patterns["agent_tools"]:
                    continue
                subagent = block.get("input", {}).get("subagent_type", "")
                if subagent in patterns["agent_subagent_types"]:
                    label = f"{block['name']}({subagent})"
                    tool_counts[label] = tool_counts.get(label, 0) + 1
                    last_index = idx
    return tool_counts, last_index


def related_files_after(file_path_tuples, raw_cache, start_index):
    """Unique non-sidechain file paths touched after start_index."""
    seen = []
    for path, idx in file_path_tuples:
        if idx <= start_index or path in seen:
            continue
        if raw_cache.is_sidechain(idx):
            continue
        seen.append(path)
        if len(seen) >= RELATED_FILES_LIMIT:
            break
    return seen


def candidate_filename(query, session_id):
    key = TRIGGER + query + session_id
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12] + ".md"


def build_candidate(call, rows, tool_counts, last_index, related_files, session_id):
    # Representative row for display: the main-pool row when the
    # invocation fanned out across pools.
    row = next((r for r in rows if r.get("source_type") is None), rows[0])
    scale = row.get("scale_declared") or "undeclared"
    total_results = sum(r.get("result_count") or 0 for r in rows)
    activity = ", ".join(f"{name} x{n}" for name, n in sorted(tool_counts.items()))
    related = ", ".join(related_files) if related_files else "none"
    lines = [
        f"# Capture Candidate: {TRIGGER}",
        "",
        f"**Trigger:** {TRIGGER}",
        f"**Context:** `lore search \"{call['query']}\"` (scale: {scale}) returned "
        f"{total_results} results across {len(rows)} search pool(s) at "
        f"{row.get('timestamp')}; the session then "
        f"explored source directly: {activity}",
        f"**Query:** {call['query']}",
        f"**Session:** {session_id}",
        f"**Transcript region:** messages {call['index']}-{last_index}",
        f"**Related files:** {related}",
        "",
        "**Evaluate:** Does this meet the capture gate? (Reusable, Non-obvious, Stable, High-confidence)",
        "",
        "**Synthesis check:** Does this insight combine information from multiple sources "
        "(files, sessions, or components), or could it be read from a single file? "
        "(Synthesis = high loading priority, single-source = searchable tier)",
        "",
        "**Miss guidance:** This candidate marks a demand-verified knowledge gap: a lore "
        "retrieval missed and the session derived the answer from source. If the "
        "exploration surfaced a reusable insight, capture it phrased so the query above "
        "would find it. The related files show where the derivation looked.",
        "",
    ]
    return "\n".join(lines)


def mine_session(provider, transcript_path, log_index, patterns):
    """Mine one session. Returns (candidates [(filename, text)], metrics)."""
    raw_cache = RawLineCache(provider.read_raw_lines(transcript_path))
    messages = provider.parse_transcript(transcript_path)
    session_id = provider.session_metadata(transcript_path).get("session_id", "unknown")

    calls = extract_retrieval_calls(messages, raw_cache, patterns)
    matched, counts = join_calls_to_log(calls, log_index)

    metrics = {
        "retrieval_calls": sum(1 for c in calls if c["kind"] == "search"),
        "prefetch_calls": sum(1 for c in calls if c["kind"] == "prefetch"),
        **counts,
        "misses": 0,
        "miss_rows_paired": 0,
        "candidates_emitted": 0,
    }

    candidates = []
    file_path_tuples = None
    for call, rows in matched:
        # The agent saw the pools' combined output, so the invocation
        # missed only if every pooled row missed.
        if not all(row_is_miss(r) for r in rows):
            continue
        metrics["misses"] += 1
        tool_counts, last_index = detect_derivation(
            messages, raw_cache, call["index"], patterns
        )
        if not tool_counts:
            continue
        metrics["miss_rows_paired"] += 1
        if file_path_tuples is None:
            file_path_tuples = provider.extract_file_paths(transcript_path)
        related = related_files_after(file_path_tuples, raw_cache, call["index"])
        text = build_candidate(call, rows, tool_counts, last_index, related, session_id)
        candidates.append((candidate_filename(call["query"], session_id), text))
    return candidates, metrics


def write_candidates(pending_dir, candidates):
    emitted = 0
    os.makedirs(pending_dir, exist_ok=True)
    for filename, text in candidates:
        try:
            with open(os.path.join(pending_dir, filename), "w", encoding="utf-8") as f:
                f.write(text)
            emitted += 1
        except OSError:
            continue
    return emitted


def format_metrics(metrics, label):
    fields = " ".join(f"{k}={v}" for k, v in metrics.items())
    return f"[miss-miner] {label} {fields}"


# --- state file: sanctioned writer is this script -------------------------

def _state_path(knowledge_dir):
    return os.path.join(knowledge_dir, "_meta", STATE_FILENAME)


def load_state(knowledge_dir):
    try:
        with open(_state_path(knowledge_dir), encoding="utf-8") as f:
            state = json.load(f)
        if isinstance(state, dict) and isinstance(state.get("mined"), dict):
            return state
    except (OSError, json.JSONDecodeError):
        pass
    return {"version": 1, "mined": {}}


def save_state(knowledge_dir, state):
    mined = state["mined"]
    if len(mined) > STATE_KEEP:
        for key in sorted(mined, key=mined.get)[: len(mined) - STATE_KEEP]:
            del mined[key]
    path = _state_path(knowledge_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
        f.write("\n")


# --- entry points ----------------------------------------------------------

def resolve_gated_provider(framework, consumer="mine-retrieval-misses"):
    """get_provider + status gate per the canonical consumer pattern.
    Returns the provider or None (degraded notice already printed)."""
    try:
        provider = get_provider(framework or None)
    except UnsupportedFrameworkError:
        print(
            f"[lore] degraded: {consumer} via transcript_provider=unavailable; skipping",
            file=sys.stderr,
        )
        return None
    support_level, reason = provider.provider_status()
    if support_level == "unavailable":
        print(
            f"[lore] degraded: {consumer} via transcript_provider=unavailable; skipping",
            file=sys.stderr,
        )
        return None
    if support_level == "partial":
        # Mining joins a cwd-scoped session to the project's retrieval log;
        # partial providers cannot guarantee cwd-scoped session identity
        # (same reasoning as extract-session-digest).
        print(
            f"[lore] degraded: {consumer} via transcript_provider=partial ({reason}); skipping",
            file=sys.stderr,
        )
        return None
    return provider


def run_hook_mode(args):
    knowledge_dir = args.knowledge_dir or _resolve_knowledge_dir(cwd=args.cwd)
    if not knowledge_dir or not os.path.exists(knowledge_dir):
        return
    if not os.path.isfile(os.path.join(knowledge_dir, "_manifest.json")):
        return

    provider = resolve_gated_provider(args.framework)
    if provider is None:
        return

    prev_session_path = provider.previous_session_path(args.cwd)
    if not prev_session_path:
        return

    session_key = os.path.basename(prev_session_path)
    state = load_state(knowledge_dir)
    if session_key in state["mined"]:
        return

    patterns = load_event_patterns()
    log_index, log_rows_skipped = load_log_index(knowledge_dir)
    candidates, metrics = mine_session(provider, prev_session_path, log_index, patterns)
    metrics["log_rows_skipped"] = log_rows_skipped

    if candidates:
        pending_dir = os.path.join(knowledge_dir, "_pending_captures")
        metrics["candidates_emitted"] = write_candidates(pending_dir, candidates)

    state["mined"][session_key] = datetime.now().astimezone().isoformat(timespec="seconds")
    save_state(knowledge_dir, state)

    # stderr: SessionStart stdout is injected into session context and the
    # [capture] trigger line from load-knowledge.sh already owns that surface.
    print(format_metrics(metrics, f"session={session_key}"), file=sys.stderr)


def select_sessions(paths, max_sessions):
    """Evenly-spaced deterministic sample across the mtime-ordered corpus."""
    if len(paths) <= max_sessions:
        return list(paths)
    step = len(paths) / max_sessions
    return [paths[int(i * step)] for i in range(max_sessions)]


def run_experiment_mode(args):
    if not args.output_dir:
        print("Error: --experiment requires --output-dir (never the live queue)", file=sys.stderr)
        sys.exit(1)
    knowledge_dir = args.knowledge_dir or _resolve_knowledge_dir(cwd=args.cwd)
    if not knowledge_dir or not os.path.exists(knowledge_dir):
        print(f"Error: cannot resolve knowledge dir for {args.cwd}", file=sys.stderr)
        sys.exit(1)

    provider = resolve_gated_provider(args.framework)
    if provider is None:
        return

    if args.transcripts:
        paths = args.transcripts
    else:
        paths = provider.list_session_paths(args.cwd)
    paths = select_sessions(paths, args.max_sessions)

    patterns = load_event_patterns()
    log_index, log_rows_skipped = load_log_index(knowledge_dir)

    totals = {}
    for path in paths:
        candidates, metrics = mine_session(provider, path, log_index, patterns)
        if candidates:
            metrics["candidates_emitted"] = write_candidates(args.output_dir, candidates)
        print(format_metrics(metrics, f"session={os.path.basename(path)}"))
        for key, value in metrics.items():
            totals[key] = totals.get(key, 0) + value
    totals["sessions_mined"] = len(paths)
    totals["log_rows_skipped"] = log_rows_skipped
    print(format_metrics(totals, "TOTAL"))


def main():
    parser = argparse.ArgumentParser(
        description="Mine retrieval misses into _pending_captures/ candidates"
    )
    parser.add_argument("--knowledge-dir", help="Path to knowledge directory")
    parser.add_argument("--cwd", default=os.getcwd(), help="Current working directory")
    parser.add_argument("--framework", help="Override active framework (for testing)")
    parser.add_argument("--experiment", action="store_true",
                        help="Historical corpus sweep; writes to --output-dir")
    parser.add_argument("--transcripts", nargs="*",
                        help="Explicit transcript paths (experiment mode)")
    parser.add_argument("--output-dir", help="Candidate output dir (experiment mode)")
    parser.add_argument("--max-sessions", type=int, default=DEFAULT_MAX_SESSIONS,
                        help="Session cap for experiment mode")
    args = parser.parse_args()

    if args.experiment:
        run_experiment_mode(args)
        return

    # Hook mode: never break a session start — fail open with a notice.
    try:
        run_hook_mode(args)
    except Exception as e:
        print(f"[hook] mine-retrieval-misses: {e}", file=sys.stderr)
    sys.exit(0)


if __name__ == "__main__":
    main()
