#!/usr/bin/env python3
"""
Assess context-packet deliveries against the session transcript that
received them, and emit one verdict JSON object per assessed packet.

Runs from the SessionStart hook chain with previous-session semantics
(the mine-retrieval-misses run_hook_mode shape: transcript-provider
enumeration, own state-file dedupe in _meta/packet-assessor-state.json).
Assessment is prospective-only — packets are joined to a transcript at
the first session boundary after it, while the transcript still exists;
there is deliberately no retrospective corpus-sweep mode.

Packet join and dispatch confirmation:
  - session-scope rows join by session_id equality with the transcript's
    session id; the join is the confirmation (load-knowledge.sh emits the
    row for the session it just loaded into).
  - task-scope rows join by a literal `Packet-id: <id>` marker in the
    transcript (the /implement dispatch prompt carries it); the marker is
    the confirmation. Task rows carry session_id null, so there is no id
    join for them by design — never invent a second identity scheme.
  - rows with no id/marker join whose delivered_at falls inside the
    transcript's timestamp window are assessed as dispatch-unconfirmed:
    dispatch_confirmed=false, all verdict classes null with a row-level
    not_assessable_reason.

Verdict classes (empty array = assessed, no finding; null = class not
assessable, with a <class>_not_assessable_reason):
  unused[]      delivered entries never referenced in assistant text or
                in non-dispatch tool inputs (Task/Agent inputs carry the
                packet itself and are excluded from the usage scan).
  harmful[]     delivered entries the session verified contradicted
                (`lore verify <path> contradicted` Bash invocations).
  missing[]     matched `lore search` invocations whose pooled retrieval-
                log rows all missed — demand neither the packet nor the
                store satisfied. Gap text is under "query" (the miner's
                object-field contract).
  unattributed_retrieval[]  in-window retrieval-log rows attributable
                neither to a transcript retrieval call (query + timestamp
                window, sidechain included) nor to packet-assembly
                machinery (callerless rows, machinery callers,
                manifest_load rows whose task_id matches a confirmed
                task packet).
missing[] and unattributed_retrieval[] are session-level evidence and
attach to the latest confirmed session-scope packet; other packets carry
per-class not-assessable reasons pointing at that carrier.

Write discipline: this script writes nothing durable except its own
state file. Verdicts route through adapters, each owning one write
boundary:
  - every verdict     -> packet-assessment-append.sh (sole writer of
                         _packets/assessments.jsonl; /retro D2/D3 reader)
  - missing[] gaps    -> mine-retrieval-misses.py --packet-verdicts -
                         (sole writer of _pending_captures/)
Scorecard escalation is a separate, deliberate adapter and is never
invoked from here. In hook mode stdout stays silent — SessionStart
stdout is injected into session context and assessment rows must never
reach an agent prompt ($KDIR/_packets/README.md) — so metrics go to
stderr. Runner mode (--transcript PATH) prints verdict JSON to stdout
and performs no handoff and no state write.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import timedelta, datetime

_SCRIPTS_DIR = os.path.dirname(os.path.realpath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


def _import_by_path(module_name, filename):
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(
        module_name, os.path.join(_SCRIPTS_DIR, filename)
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


# Single source of truth for the transcript/retrieval-log join mechanics
# (parse_ts, RawLineCache, extract_retrieval_calls, join_calls_to_log,
# row_is_miss, provider gating) and for packet-row validation.
miner = _import_by_path("mine_retrieval_misses", "mine-retrieval-misses.py")
packet_schema = _import_by_path("packet_schema", "packet_schema.py")

STATE_FILENAME = "packet-assessor-state.json"
STATE_KEEP = 200

# Packet ids are pkt-<hex>; the charset is restricted so a marker scanned
# from raw JSONL text never swallows escape sequences.
MARKER_RE = re.compile(r"Packet-id:\s*([A-Za-z0-9._-]+)")
CONTRADICTED_RE = re.compile(
    r"\blore\s+verify\s+['\"]?([^'\"\s]+)['\"]?\s+contradicted\b"
)

# Tool inputs that carry the packet content itself (dispatch prompts) —
# excluded from the usage scan so delivery never counts as use.
DISPATCH_TOOLS = frozenset({"Task", "Agent"})

# Retrieval-log callers that are background machinery, never agent demand
# (same set /retro's declaration_coverage excludes).
MACHINERY_CALLERS = frozenset({"lore-query", "resolve-manifest"})

WINDOW_PAD = timedelta(seconds=2)


def assessor_schema_sha():
    """sha256 of this file's bytes — the assessor_schema_sha stamp."""
    with open(os.path.realpath(__file__), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# --- packet rows -----------------------------------------------------------

def load_packets(knowledge_dir):
    """Read + validate packets.jsonl per the reader contract: corrupt rows
    warn on stderr and are excluded, never silently counted."""
    path = os.path.join(knowledge_dir, "_packets", "packets.jsonl")
    rows, corrupt = [], 0
    try:
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as exc:
                    corrupt += 1
                    print(
                        f"[packet] warning: packets.jsonl:{lineno} corrupt — {exc}",
                        file=sys.stderr,
                    )
                    continue
                errors = packet_schema.validate_packet_row(row)
                if errors:
                    corrupt += 1
                    print(
                        f"[packet] warning: packets.jsonl:{lineno} corrupt — {errors[0]}",
                        file=sys.stderr,
                    )
                    continue
                rows.append(row)
    except OSError:
        pass
    return rows, corrupt


def norm_entry_path(path):
    """Suffix-normalize an entry path: packet rows store .md-suffixed
    KDIR-relative paths but retrieval-log loaded_paths keep a historical
    mixed form, so joins compare the stem."""
    if isinstance(path, str) and path.endswith(".md"):
        return path[:-3]
    return path


# --- transcript scan -------------------------------------------------------

def scan_raw(raw_cache, raw_lines):
    """One pass over raw lines: timestamp window, sidechain presence,
    Packet-id markers."""
    lo = hi = None
    has_sidechain = False
    markers = set()
    for i, line in enumerate(raw_lines):
        for m in MARKER_RE.finditer(line):
            markers.add(m.group(1))
        entry = raw_cache.entry(i)
        if not entry:
            continue
        if entry.get("isSidechain"):
            has_sidechain = True
        ts = miner.parse_ts(entry.get("timestamp"))
        if ts is not None:
            lo = ts if lo is None or ts < lo else lo
            hi = ts if hi is None or ts > hi else hi
    return lo, hi, has_sidechain, markers


def build_corpora(messages, raw_cache):
    """Usage corpus (assistant text + non-dispatch tool inputs, sidechain
    included), Bash command list, and every retrieval call (sidechain
    included — attribution must see worker searches the miner's
    non-sidechain extraction skips)."""
    patterns = miner.load_event_patterns()
    usage_parts = []
    bash_commands = []
    retrieval_calls = []
    for msg in messages:
        idx = msg["index"]
        if msg.get("role") == "assistant":
            usage_parts.extend(msg.get("text_blocks") or [])
        if not msg.get("has_tool_use"):
            continue
        entry = raw_cache.entry(idx)
        ts = miner.parse_ts(entry.get("timestamp")) if entry else None
        for block in raw_cache.tool_use_blocks(idx):
            name = block.get("name", "")
            if name in DISPATCH_TOOLS:
                continue
            block_input = block.get("input", {})
            try:
                usage_parts.append(json.dumps(block_input, ensure_ascii=False))
            except (TypeError, ValueError):
                pass
            if name != patterns["bash_tool"]:
                continue
            command = block_input.get("command", "")
            if not isinstance(command, str):
                continue
            bash_commands.append(command)
            for kind, regex in patterns["command_regexes"].items():
                for m in regex.finditer(command):
                    query = next((g for g in m.groups() if g), None)
                    if query:
                        retrieval_calls.append({"ts": ts, "query": query, "kind": kind})
    return {
        "usage_text": "\n".join(usage_parts),
        "bash_commands": bash_commands,
        "retrieval_calls": retrieval_calls,
    }


def entry_referenced(rel_path, usage_text):
    stem = norm_entry_path(rel_path)
    return re.search(re.escape(stem) + r"(?:\.md)?(?![\w-])", usage_text) is not None


def contradicted_entry_paths(bash_commands):
    paths = set()
    for command in bash_commands:
        for m in CONTRADICTED_RE.finditer(command):
            paths.add(norm_entry_path(m.group(1).lstrip("/")))
    return paths


# --- packet selection ------------------------------------------------------

def _in_window(ts, window):
    if ts is None or window[0] is None or window[1] is None:
        return False
    return window[0] - WINDOW_PAD <= ts <= window[1] + WINDOW_PAD


def select_packets(packets, session_id, window, markers):
    """Return [(row, dispatch_confirmed, join_kind)] for packets this
    transcript can be assessed against."""
    joined = []
    joinable_sid = session_id not in ("", "unknown", None)
    for row in packets:
        scope = row.get("packet_scope")
        row_sid = row.get("session_id")
        delivered = miner.parse_ts(row.get("delivered_at"))
        if scope == "session":
            if joinable_sid and row_sid == session_id:
                joined.append((row, True, "session-id"))
            elif row_sid in (None, "unknown") and _in_window(delivered, window):
                joined.append((row, False, "window-only"))
        elif scope == "task":
            if row.get("packet_id") in markers:
                joined.append((row, True, "marker"))
            elif _in_window(delivered, window):
                joined.append((row, False, "window-only"))
    return joined


# --- retrieval evidence ----------------------------------------------------

def load_log_rows(knowledge_dir):
    log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
    rows = []
    try:
        with open(log_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return rows


def build_missing_gaps(messages, raw_cache, knowledge_dir, patterns):
    """Needed-but-missing gaps: the miner's own extraction + join (non-
    sidechain, exact query + window, pooled-row miss semantics)."""
    calls = miner.extract_retrieval_calls(messages, raw_cache, patterns)
    log_index, _ = miner.load_log_index(knowledge_dir)
    matched, _ = miner.join_calls_to_log(calls, log_index)
    gaps = []
    for call, rows in matched:
        if not all(miner.row_is_miss(r) for r in rows):
            continue
        ts = rows[0].get("timestamp")
        gaps.append({
            "query": call["query"],
            "evidence": (
                f"lore search missed across {len(rows)} pool(s) at {ts}; "
                "the delivered packet did not cover this need"
            ),
        })
    return gaps


def build_unattributed(log_rows, window, retrieval_calls, confirmed_task_ids):
    """In-window retrieval-log rows with no transcript-call or packet-
    assembly attribution. Callerless rows are session-startup machinery
    (they produced the session packet); machinery callers never count."""
    call_index = {}
    for call in retrieval_calls:
        if call["ts"] is not None:
            call_index.setdefault(call["query"], []).append(call["ts"])

    def matches_call(query, ts):
        if not query or ts is None:
            return False
        for call_ts in call_index.get(query, []):
            if call_ts - timedelta(seconds=miner.JOIN_SKEW_SECONDS) <= ts \
                    <= call_ts + timedelta(seconds=miner.JOIN_WINDOW_SECONDS):
                return True
        return False

    unattributed = []
    for row in log_rows:
        event = row.get("event")
        if event not in ("search", "prefetch", "manifest_load"):
            continue
        ts = miner.parse_ts(row.get("timestamp"))
        if not _in_window(ts, window):
            continue
        if event == "manifest_load":
            if row.get("task_id") is not None and str(row["task_id"]) in confirmed_task_ids:
                continue
            unattributed.append({
                "event": event,
                "caller": row.get("caller"),
                "task_id": row.get("task_id"),
                "timestamp": row.get("timestamp"),
                "evidence": "manifest_load inside the session window not matching "
                            "any confirmed task packet's task_id",
            })
            continue
        caller = row.get("caller")
        if caller is None or caller in MACHINERY_CALLERS:
            continue
        if matches_call(row.get("query"), ts):
            continue
        unattributed.append({
            "event": event,
            "caller": caller,
            "query": row.get("query"),
            "timestamp": row.get("timestamp"),
            "evidence": "agent-caller retrieval row inside the session window with "
                        "no matching transcript retrieval call",
        })
    return unattributed


# --- verdict assembly ------------------------------------------------------

def _base_verdict(row, session_id, transcript_path, sha):
    return {
        "packet_id": row["packet_id"],
        "packet_scope": row.get("packet_scope"),
        "session_id": session_id,
        "source_transcript": transcript_path,
        "assessor_schema_sha": sha,
    }


def assess_transcript(provider, transcript_path, knowledge_dir):
    """Assess every packet joinable to this transcript.
    Returns (verdicts, metrics). Pure: no writes of any kind."""
    raw_lines = provider.read_raw_lines(transcript_path)
    raw_cache = miner.RawLineCache(raw_lines)
    messages = provider.parse_transcript(transcript_path)
    session_id = provider.session_metadata(transcript_path).get("session_id", "unknown")

    lo, hi, has_sidechain, markers = scan_raw(raw_cache, raw_lines)
    window = (lo, hi)

    packets, corrupt = load_packets(knowledge_dir)
    joined = select_packets(packets, session_id, window, markers)

    metrics = {
        "packets_total": len(packets),
        "packets_corrupt": corrupt,
        "packets_joined": len(joined),
        "dispatch_confirmed": sum(1 for _, ok, _ in joined if ok),
        "unused_findings": 0,
        "harmful_findings": 0,
        "missing_gaps": 0,
        "unattributed_rows": 0,
        "retrieval_rows_uncarried": 0,
    }
    if not joined:
        return [], metrics

    sha = assessor_schema_sha()
    patterns = miner.load_event_patterns()
    corpora = build_corpora(messages, raw_cache)
    contradicted = contradicted_entry_paths(corpora["bash_commands"])

    missing_gaps = build_missing_gaps(messages, raw_cache, knowledge_dir, patterns)
    confirmed_task_ids = {
        str(row["task_id"]) for row, ok, _ in joined
        if ok and row.get("packet_scope") == "task" and row.get("task_id") is not None
    }
    unattributed = build_unattributed(
        load_log_rows(knowledge_dir), window, corpora["retrieval_calls"],
        confirmed_task_ids,
    )

    # Session-level retrieval evidence attaches to one carrier: the latest
    # confirmed session-scope packet (append-supersede: latest delivery wins).
    carrier_id = None
    carrier_ts = None
    for row, ok, _ in joined:
        if not ok or row.get("packet_scope") != "session":
            continue
        delivered = miner.parse_ts(row.get("delivered_at"))
        if carrier_ts is None or (delivered is not None and delivered >= carrier_ts):
            carrier_id = row["packet_id"]
            carrier_ts = delivered

    verdicts = []
    for row, confirmed, join_kind in joined:
        verdict = _base_verdict(row, session_id, transcript_path, sha)
        verdict["dispatch_confirmed"] = confirmed

        if not confirmed:
            if row.get("packet_scope") == "task":
                reason = ("delivered_at falls inside this transcript's window but "
                          "no Packet-id marker was found — dispatch unconfirmed "
                          "for this transcript")
            else:
                reason = ("packet session_id is unknown — no transcript join "
                          "possible; window overlap only")
            verdict["not_assessable_reason"] = reason
            for cls in packet_schema.VERDICT_CLASSES:
                verdict[cls] = None
            verdicts.append(verdict)
            continue

        # unused / harmful: per-packet, over the delivered entries.
        task_worker_elsewhere = (
            row.get("packet_scope") == "task" and not has_sidechain
        )
        if task_worker_elsewhere:
            reason = ("dispatching transcript contains no sidechain worker "
                      "activity; the receiving worker ran as a separate session")
            verdict["unused"] = None
            verdict["unused_not_assessable_reason"] = reason
            verdict["harmful"] = None
            verdict["harmful_not_assessable_reason"] = reason
        else:
            unused, harmful = [], []
            for entry in row.get("delivered_entries") or []:
                path = entry.get("path")
                if not path:
                    continue
                if not entry_referenced(path, corpora["usage_text"]):
                    unused.append({
                        "path": path,
                        "render_mode": entry.get("render_mode"),
                        "evidence": "entry never referenced in assistant text "
                                    "or non-dispatch tool inputs",
                    })
                if norm_entry_path(path) in contradicted:
                    harmful.append({
                        "path": path,
                        "evidence": "session ran `lore verify ... contradicted` "
                                    "against this delivered entry",
                    })
            verdict["unused"] = unused
            verdict["harmful"] = harmful
            metrics["unused_findings"] += len(unused)
            metrics["harmful_findings"] += len(harmful)

        if row["packet_id"] == carrier_id:
            verdict["missing"] = missing_gaps
            verdict["unattributed_retrieval"] = unattributed
            metrics["missing_gaps"] = len(missing_gaps)
            metrics["unattributed_rows"] = len(unattributed)
        else:
            if carrier_id is not None:
                reason = ("session-level retrieval evidence attaches to the "
                          f"session-scope packet {carrier_id}")
            else:
                reason = ("no confirmed session-scope packet joined this "
                          "transcript to carry session-level retrieval evidence")
            verdict["missing"] = None
            verdict["missing_not_assessable_reason"] = reason
            verdict["unattributed_retrieval"] = None
            verdict["unattributed_retrieval_not_assessable_reason"] = reason

        verdicts.append(verdict)

    if carrier_id is None and (missing_gaps or unattributed):
        metrics["retrieval_rows_uncarried"] = len(missing_gaps) + len(unattributed)

    return verdicts, metrics


# --- state file: sanctioned writer is this script --------------------------

def _state_path(knowledge_dir):
    return os.path.join(knowledge_dir, "_meta", STATE_FILENAME)


def load_state(knowledge_dir):
    try:
        with open(_state_path(knowledge_dir), encoding="utf-8") as f:
            state = json.load(f)
        if isinstance(state, dict) and isinstance(state.get("assessed"), dict):
            return state
    except (OSError, json.JSONDecodeError):
        pass
    return {"version": 1, "assessed": {}}


def save_state(knowledge_dir, state):
    assessed = state["assessed"]
    if len(assessed) > STATE_KEEP:
        for key in sorted(assessed, key=assessed.get)[: len(assessed) - STATE_KEEP]:
            del assessed[key]
    path = _state_path(knowledge_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
        f.write("\n")


# --- adapters --------------------------------------------------------------

def handoff_to_miner(verdicts, knowledge_dir, cwd):
    """missing[] gaps -> the sole _pending_captures/ writer."""
    proc = subprocess.run(
        [sys.executable, os.path.join(_SCRIPTS_DIR, "mine-retrieval-misses.py"),
         "--packet-verdicts", "-", "--knowledge-dir", knowledge_dir, "--cwd", cwd],
        input=json.dumps(verdicts, ensure_ascii=False),
        capture_output=True, text=True, timeout=60,
    )
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    return proc.returncode == 0


def append_assessments(verdicts, knowledge_dir):
    """Every verdict -> the sole assessments.jsonl writer. Returns
    (appended, failures)."""
    appended = failures = 0
    append_sh = os.path.join(_SCRIPTS_DIR, "packet-assessment-append.sh")
    for verdict in verdicts:
        try:
            proc = subprocess.run(
                ["bash", append_sh, "--kdir", knowledge_dir],
                input=json.dumps(verdict, ensure_ascii=False),
                capture_output=True, text=True, timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures += 1
            print(f"[packet-assessor] append failed: {exc}", file=sys.stderr)
            continue
        if proc.returncode == 0:
            appended += 1
        else:
            failures += 1
            tail = (proc.stderr or "").strip().splitlines()
            detail = tail[-1] if tail else f"exit {proc.returncode}"
            print(f"[packet-assessor] append failed: {detail}", file=sys.stderr)
    return appended, failures


def format_metrics(metrics, label):
    fields = " ".join(f"{k}={v}" for k, v in metrics.items())
    return f"[packet-assessor] {label} {fields}"


# --- entry points ----------------------------------------------------------

def run_hook_mode(args):
    knowledge_dir = args.knowledge_dir or miner._resolve_knowledge_dir(cwd=args.cwd)
    if not knowledge_dir or not os.path.exists(knowledge_dir):
        return
    if not os.path.isfile(os.path.join(knowledge_dir, "_manifest.json")):
        return
    # Definite hook condition: packets exist to assess.
    if not os.path.isfile(os.path.join(knowledge_dir, "_packets", "packets.jsonl")):
        return

    provider = miner.resolve_gated_provider(args.framework, consumer="packet-assess")
    if provider is None:
        return

    prev_session_path = provider.previous_session_path(args.cwd)
    if not prev_session_path:
        return

    session_key = os.path.basename(prev_session_path)
    state = load_state(knowledge_dir)
    if session_key in state["assessed"]:
        return

    verdicts, metrics = assess_transcript(provider, prev_session_path, knowledge_dir)

    if verdicts:
        if any(v.get("missing") for v in verdicts):
            metrics["miner_handoff"] = int(
                handoff_to_miner(verdicts, knowledge_dir, args.cwd)
            )
        appended, failures = append_assessments(verdicts, knowledge_dir)
        metrics["rows_appended"] = appended
        metrics["append_failures"] = failures

    state["assessed"][session_key] = (
        datetime.now().astimezone().isoformat(timespec="seconds")
    )
    save_state(knowledge_dir, state)

    # stderr: SessionStart stdout is injected into session context, and
    # assessment content must never reach an agent prompt.
    print(format_metrics(metrics, f"session={session_key}"), file=sys.stderr)


def run_transcript_mode(args):
    """Pure runner: verdict JSON to stdout, no handoff, no state write."""
    knowledge_dir = args.knowledge_dir or miner._resolve_knowledge_dir(cwd=args.cwd)
    if not knowledge_dir or not os.path.exists(knowledge_dir):
        print(f"Error: cannot resolve knowledge dir for {args.cwd}", file=sys.stderr)
        sys.exit(1)

    provider = miner.resolve_gated_provider(args.framework, consumer="packet-assess")
    if provider is None:
        sys.exit(1)

    verdicts, metrics = assess_transcript(provider, args.transcript, knowledge_dir)
    for verdict in verdicts:
        print(json.dumps(verdict, ensure_ascii=False))
    print(format_metrics(metrics, f"transcript={os.path.basename(args.transcript)}"),
          file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Assess packet deliveries against the receiving transcript"
    )
    parser.add_argument("--knowledge-dir", help="Path to knowledge directory")
    parser.add_argument("--cwd", default=os.getcwd(), help="Current working directory")
    parser.add_argument("--framework", help="Override active framework (for testing)")
    parser.add_argument("--transcript",
                        help="Assess this transcript and print verdict JSON to "
                             "stdout (no adapter handoff, no state write)")
    args = parser.parse_args()

    if args.transcript:
        run_transcript_mode(args)
        return

    # Hook-chain mode: never break a session start — fail open with a notice.
    try:
        run_hook_mode(args)
    except Exception as e:
        print(f"[hook] packet-assess: {e}", file=sys.stderr)
    sys.exit(0)


if __name__ == "__main__":
    main()
