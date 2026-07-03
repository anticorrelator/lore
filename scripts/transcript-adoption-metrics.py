#!/usr/bin/env python3
"""Per-session adoption metrics over the transcript corpus.

Measures whether sessions consult a knowledge surface before raw
exploration, using only mechanical tool-call ordering — no relevance
judgment. What counts as a "retrieval event" and an "exploration
event" comes entirely from a JSON patterns file (--patterns), so any
protocol can run the same graduation test by supplying its own event
definitions. The patterns file's sha256 is stamped on every output
row; comparisons across runs are only valid when the hash matches.

Per session the harness emits one JSONL row with:
  - model id(s) seen on non-sidechain assistant lines
  - session class: skill-driven / mixed / interactive (position of the
    first skill invocation relative to the first exploration event)
  - lore_first: whether any retrieval event precedes the first
    exploration event (null when the session has no exploration)
  - burst consistency: covered bursts / total bursts, where a burst is
    a maximal run of exploration events with no intervening retrieval
    event and no gap over burst.max_gap_messages messages, and a burst
    is covered iff a retrieval event falls between the end of the
    previous burst (or session start) and the burst's first event

Reads transcripts through adapters/transcripts (provider gate first;
degraded harnesses get the documented stderr notice, never a stack
trace). Events are detected on non-sidechain lines only, via the
two-pass pattern: parse_transcript for ordering/tool names, then
read_raw_lines()[msg.index] for tool inputs, model ids, sidechain
flags, and skill-invocation tags.

Optionally appends an era-conditioned volume summary from a retrieval
log (--retrieval-log + --era-boundary). That section is a proxy with
no denominator: the log records searches that happened, not bypasses.

Usage:
  python3 scripts/transcript-adoption-metrics.py \
      --patterns event-patterns-v1.json \
      [--cwd DIR] [--framework FW] \
      [--since 2026-07-03T07:23:54Z] [--until 2026-07-03T07:23:54Z] \
      [--rows-out rows.jsonl] [--report-out report.md] \
      [--retrieval-log _meta/retrieval-log.jsonl --era-boundary 2026-05-03]

--since/--until bound the sweep by session *start* in UTC (first
timestamped transcript entry; file-mtime fallback): since is
inclusive, until is exclusive. Measurement-window experiments use
them to split pre/post-cutoff corpora.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, date, timezone

# realpath, not abspath: this script may be invoked via the
# ~/.lore/scripts symlink and must still find adapters/ at the repo root.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from adapters.transcripts import get_provider, UnsupportedFrameworkError  # noqa: E402

CONSUMER = "transcript-adoption-metrics"


# ---------------------------------------------------------------------------
# Event patterns (data, not code)
# ---------------------------------------------------------------------------

def load_patterns(path: str) -> tuple[dict, str]:
    """Return (patterns dict, sha256 of the file bytes)."""
    with open(path, "rb") as f:
        raw = f.read()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


class CompiledPatterns:
    """Compiled form of the --patterns JSON.

    Schema (version 1):
      retrieval_events: [{"tool": str, "input_field": str, "regex": str}, ...]
      exploration_events:
        tools: [str, ...]                       # tool_use names counted directly
        agent_tools: [str, ...]                 # agent-spawn tool names
        agent_type_field: str                   # input field naming the agent type
        agent_types: [str, ...]                 # agent types that count
      skill_invocation: {"regex": str}          # matched against user text; group 1 = command
      burst: {"max_gap_messages": int}
    """

    def __init__(self, patterns: dict):
        self.retrieval = [
            (spec["tool"], spec["input_field"], re.compile(spec["regex"]))
            for spec in patterns.get("retrieval_events", [])
        ]
        expl = patterns.get("exploration_events", {})
        self.exploration_tools = set(expl.get("tools", []))
        self.agent_tools = set(expl.get("agent_tools", []))
        self.agent_type_field = expl.get("agent_type_field", "subagent_type")
        self.agent_types = set(expl.get("agent_types", []))
        self.skill_re = re.compile(
            patterns.get("skill_invocation", {}).get(
                "regex", r"<command-name>([^<]+)</command-name>"
            )
        )
        self.max_gap = int(patterns.get("burst", {}).get("max_gap_messages", 20))


# ---------------------------------------------------------------------------
# Per-session event extraction (pure over messages + raw lines)
# ---------------------------------------------------------------------------

def _raw_entry(raw_lines: list[str], line_index: int) -> dict | None:
    if line_index < 0 or line_index >= len(raw_lines):
        return None
    try:
        entry = json.loads(raw_lines[line_index])
    except (json.JSONDecodeError, ValueError):
        return None
    return entry if isinstance(entry, dict) else None


def _to_utc(when: datetime) -> datetime:
    if when.tzinfo is None:
        when = when.astimezone()  # naive values are local time (e.g. mtime fallback)
    return when.astimezone(timezone.utc)


def session_start_utc(raw_lines: list[str], meta: dict) -> datetime | None:
    """Session start in UTC: the first timestamped transcript entry.

    Falls back to the provider's session_date, which may be a file-mtime
    value — mtime tracks last write, not session start, so the scan of
    timestamped entries is preferred whenever one exists.
    """
    for line in raw_lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if not isinstance(entry, dict):
            continue
        ts = entry.get("timestamp")
        if not ts:
            continue
        try:
            when = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        except (ValueError, TypeError):
            continue
        return _to_utc(when)
    when = meta.get("session_date")
    return _to_utc(when) if when else None


def detect_events(messages: list[dict], raw_lines: list[str], cp: CompiledPatterns) -> dict:
    """Scan a session and return its event positions.

    Returns dict with:
      retrieval, exploration: lists of (ordinal, block_index) positions
      skills: list of (ordinal, command) for skill invocations
      models: Counter of model ids on non-sidechain assistant lines
      message_count: non-sidechain user/assistant messages seen

    `ordinal` is the message's position in the parse_transcript list, so
    burst gaps are measured in messages, not raw file lines. Events come
    only from assistant tool_use blocks; skill tags only from user text
    that is not a tool result — inlined skill prose and tool outputs must
    never count as agent behavior.
    """
    retrieval: list[tuple[int, int]] = []
    exploration: list[tuple[int, int]] = []
    skills: list[tuple[int, str]] = []
    models: Counter = Counter()
    message_count = 0

    for ordinal, msg in enumerate(messages):
        entry = _raw_entry(raw_lines, msg.get("index", -1))
        if entry is None:
            continue
        if entry.get("isSidechain") is True:
            continue
        etype = entry.get("type", "")
        if etype not in ("user", "assistant"):
            continue
        message_count += 1
        message = entry.get("message") or {}

        if etype == "assistant":
            model = message.get("model", "")
            if model:
                models[model] += 1
            content = message.get("content")
            if not isinstance(content, list):
                continue
            for block_index, block in enumerate(content):
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                name = block.get("name", "")
                block_input = block.get("input") or {}
                if not isinstance(block_input, dict):
                    block_input = {}
                pos = (ordinal, block_index)
                matched_retrieval = False
                for tool, field, regex in cp.retrieval:
                    if name == tool and regex.search(str(block_input.get(field, ""))):
                        retrieval.append(pos)
                        matched_retrieval = True
                        break
                if matched_retrieval:
                    continue
                if name in cp.exploration_tools:
                    exploration.append(pos)
                elif (
                    name in cp.agent_tools
                    and block_input.get(cp.agent_type_field, "") in cp.agent_types
                ):
                    exploration.append(pos)

        else:  # user
            if msg.get("is_tool_result"):
                continue
            content = message.get("content")
            texts: list[str] = []
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        texts.append(block.get("text", ""))
            for text in texts:
                for m in cp.skill_re.finditer(text):
                    skills.append((ordinal, m.group(1).strip()))

    return {
        "retrieval": retrieval,
        "exploration": exploration,
        "skills": skills,
        "models": models,
        "message_count": message_count,
    }


# ---------------------------------------------------------------------------
# Burst rule and classification (deterministic; definitions fixed by the
# patterns file + this code, stamped by patterns_sha256)
# ---------------------------------------------------------------------------

def compute_bursts(
    exploration: list[tuple[int, int]],
    retrieval: list[tuple[int, int]],
    max_gap: int,
) -> tuple[int, int]:
    """Return (total_bursts, covered_bursts).

    A burst is a maximal run of exploration events with no intervening
    retrieval event and no ordinal gap over max_gap between consecutive
    events. A burst is covered iff at least one retrieval event falls
    strictly after the previous burst's last event (or anywhere before,
    for the first burst) and strictly before the burst's first event.
    A single early retrieval does not cover later bursts.
    """
    expl = sorted(exploration)
    retr = sorted(retrieval)
    if not expl:
        return (0, 0)

    bursts: list[tuple[tuple[int, int], tuple[int, int]]] = []
    first = last = expl[0]
    for pos in expl[1:]:
        gap = pos[0] - last[0]
        intervening = any(last < r < pos for r in retr)
        if gap > max_gap or intervening:
            bursts.append((first, last))
            first = pos
        last = pos
    bursts.append((first, last))

    covered = 0
    prev_end: tuple[int, int] | None = None
    for burst_first, burst_last in bursts:
        if any(
            (prev_end is None or r > prev_end) and r < burst_first
            for r in retr
        ):
            covered += 1
        prev_end = burst_last
    return (len(bursts), covered)


def classify_session(events: dict) -> str:
    """Return skill-driven / mixed / interactive per the fixed rule.

    skill-driven: a skill invocation precedes the first exploration
    event (or the session has skill invocations but no exploration);
    mixed: skill invocations appear only after the first exploration;
    interactive: no skill invocation at all.
    """
    skills = events["skills"]
    exploration = events["exploration"]
    if not skills:
        return "interactive"
    if not exploration:
        return "skill-driven"
    first_skill = min(ordinal for ordinal, _ in skills)
    first_expl = min(exploration)[0]
    return "skill-driven" if first_skill < first_expl else "mixed"


def build_row(
    session_path: str,
    meta: dict,
    events: dict,
    cp: CompiledPatterns,
    patterns_sha256: str,
    framework: str,
) -> dict | None:
    """Assemble one adoption row; None when the session has no
    non-sidechain user/assistant messages (e.g., a pure agent sidechain)."""
    if events["message_count"] == 0:
        return None

    retrieval = events["retrieval"]
    exploration = events["exploration"]

    lore_first: bool | None
    if not exploration:
        lore_first = None
    elif not retrieval:
        lore_first = False
    else:
        lore_first = min(retrieval) < min(exploration)

    total, covered = compute_bursts(exploration, retrieval, cp.max_gap)
    consistency = (covered / total) if total else None

    session_date = meta.get("session_date")
    models = events["models"]
    # Dominant model: highest count, ties broken deterministically by name.
    model_id = ""
    if models:
        model_id = sorted(models.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]

    seen: list[str] = []
    for _, cmd in events["skills"]:
        if cmd not in seen:
            seen.append(cmd)

    return {
        "session_id": meta.get("session_id", "unknown"),
        "session_path": session_path,
        "session_date": session_date.isoformat() if session_date else None,
        "harness": framework,
        "models": dict(models),
        "model_id": model_id or "(unknown)",
        "session_class": classify_session(events),
        "skill_commands": seen,
        "message_count": events["message_count"],
        "retrieval_events": len(retrieval),
        "exploration_events": len(exploration),
        "lore_first": lore_first,
        "bursts_total": total,
        "bursts_covered": covered,
        "burst_consistency": consistency,
        "patterns_sha256": patterns_sha256,
    }


# ---------------------------------------------------------------------------
# Aggregation and report
# ---------------------------------------------------------------------------

def _stats(values: list[float]) -> dict:
    ordered = sorted(values)
    n = len(ordered)
    return {
        "n": n,
        "mean": sum(ordered) / n,
        "median": ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2,
        "min": ordered[0],
        "max": ordered[-1],
    }


def aggregate(rows: list[dict]) -> dict:
    """Group rows by (model_id, session_class) and overall by class."""
    groups: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        groups.setdefault((row["model_id"], row["session_class"]), []).append(row)

    out = {}
    for key, group in sorted(groups.items()):
        lore_first = [r["lore_first"] for r in group if r["lore_first"] is not None]
        consistency = [
            r["burst_consistency"] for r in group if r["burst_consistency"] is not None
        ]
        out[key] = {
            "sessions": len(group),
            "with_exploration": len(lore_first),
            "lore_first_rate": (sum(lore_first) / len(lore_first)) if lore_first else None,
            "consistency": _stats(consistency) if consistency else None,
        }
    return out


def _fmt(value, digits=2) -> str:
    if value is None:
        return "—"
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def render_report(
    rows: list[dict],
    skipped: int,
    patterns_path: str,
    patterns_sha256: str,
    framework: str,
    status: tuple[str, str],
    era_summary: dict | None,
    window_note: str | None = None,
) -> str:
    agg = aggregate(rows)
    dates = sorted(r["session_date"] for r in rows if r["session_date"])
    lines = [
        "# Transcript Adoption Report",
        "",
        f"- Generated: {datetime.now().isoformat(timespec='seconds')}",
        f"- Harness: {framework} (transcript_provider={status[0]})",
        f"- Event patterns: `{patterns_path}` sha256=`{patterns_sha256}`",
        f"- Sessions measured: {len(rows)} (skipped {skipped} with no "
        "non-sidechain user/assistant messages)",
        f"- Corpus window: {dates[0][:10] if dates else '—'} → {dates[-1][:10] if dates else '—'}",
    ]
    if window_note:
        lines.append(window_note)
    lines += [
        "",
        "## Adoption by model × session class",
        "",
        "| model | class | sessions | w/ exploration | lore-first rate "
        "| consistency mean | median | min–max | n(consistency) |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for (model, cls), g in agg.items():
        c = g["consistency"]
        lines.append(
            f"| {model} | {cls} | {g['sessions']} | {g['with_exploration']} "
            f"| {_fmt(g['lore_first_rate'])} "
            f"| {_fmt(c['mean']) if c else '—'} | {_fmt(c['median']) if c else '—'} "
            f"| {_fmt(c['min']) + '–' + _fmt(c['max']) if c else '—'} "
            f"| {c['n'] if c else 0} |"
        )

    lines += ["", "## Totals by session class", ""]
    lines += [
        "| class | sessions | w/ exploration | lore-first rate | consistency mean | n(consistency) |",
        "|---|---|---|---|---|---|",
    ]
    by_class: dict[str, list[dict]] = {}
    for row in rows:
        by_class.setdefault(row["session_class"], []).append(row)
    for cls in ("interactive", "skill-driven", "mixed"):
        group = by_class.get(cls, [])
        lore_first = [r["lore_first"] for r in group if r["lore_first"] is not None]
        consistency = [
            r["burst_consistency"] for r in group if r["burst_consistency"] is not None
        ]
        lines.append(
            f"| {cls} | {len(group)} | {len(lore_first)} "
            f"| {_fmt(sum(lore_first) / len(lore_first)) if lore_first else '—'} "
            f"| {_fmt(sum(consistency) / len(consistency)) if consistency else '—'} "
            f"| {len(consistency)} |"
        )

    if era_summary is not None:
        lines += [
            "",
            "## Retrieval-log volume summary (era-conditioned) — proxy, no denominator",
            "",
            "This section is a volume proxy only: the retrieval log records",
            "searches that happened, not bypasses, and carries no per-session",
            "denominator. It cannot support an adoption rate.",
            "",
            "| era | search events | active days | events/active day | caller mix |",
            "|---|---|---|---|---|",
        ]
        for era_name, era in era_summary.items():
            mix = ", ".join(
                f"{caller}: {count}" for caller, count in era["callers"].most_common(5)
            ) or "—"
            per_day = era["events"] / era["active_days"] if era["active_days"] else 0
            lines.append(
                f"| {era_name} | {era['events']} | {era['active_days']} "
                f"| {per_day:.1f} | {mix} |"
            )

    lines += [
        "",
        "## Notes",
        "",
        "- These numbers are evidence for a one-time keep/graduate verdict,",
        "  not an ongoing optimization target.",
        "- Qualitative check (never replaced by a number): _slot — answered",
        "  in the verdict: did sessions feel like they used the store as",
        "  readily?_",
        "",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Retrieval-log era summary
# ---------------------------------------------------------------------------

def summarize_retrieval_log(log_path: str, boundary: date) -> dict:
    """Split search events at `boundary` and summarize volume per era.

    Only rows with event == "search" count; older rows in the log are
    knowledge-load telemetry with a different shape and no event field.
    """
    eras = {
        f"pre {boundary.isoformat()}": {"events": 0, "days": set(), "callers": Counter()},
        f"{boundary.isoformat()} onward": {"events": 0, "days": set(), "callers": Counter()},
    }
    pre_key, post_key = list(eras)
    try:
        with open(log_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if row.get("event") != "search":
                    continue
                ts = row.get("timestamp", "")
                try:
                    when = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
                except (ValueError, TypeError):
                    continue
                era = eras[pre_key] if when.date() < boundary else eras[post_key]
                era["events"] += 1
                era["days"].add(when.date())
                era["callers"][row.get("caller") or "(none)"] += 1
    except OSError:
        pass

    return {
        name: {
            "events": era["events"],
            "active_days": len(era["days"]),
            "callers": era["callers"],
        }
        for name, era in eras.items()
    }


# ---------------------------------------------------------------------------
# Main (canonical provider-consumer flow)
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--patterns", required=True, help="event-pattern definitions (JSON)")
    parser.add_argument("--cwd", default=os.getcwd(), help="project directory whose sessions to measure")
    parser.add_argument("--framework", default=None, help="override active framework (tests)")
    parser.add_argument("--since", help="include only sessions starting at/after this instant (ISO-8601; naive means UTC)")
    parser.add_argument("--until", help="include only sessions starting before this instant (ISO-8601; naive means UTC)")
    parser.add_argument("--rows-out", help="write per-session JSONL rows here (default: stdout)")
    parser.add_argument("--report-out", help="write the aggregate markdown report here")
    parser.add_argument("--retrieval-log", help="retrieval-log.jsonl for the era-conditioned volume proxy")
    parser.add_argument("--era-boundary", help="ISO date splitting eras (required with --retrieval-log)")
    args = parser.parse_args(argv)

    if args.retrieval_log and not args.era_boundary:
        parser.error("--retrieval-log requires --era-boundary")

    def _parse_instant(value: str) -> datetime:
        when = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return when

    since = _parse_instant(args.since) if args.since else None
    until = _parse_instant(args.until) if args.until else None

    try:
        provider = get_provider(args.framework)
    except UnsupportedFrameworkError:
        print(
            f"[lore] degraded: {CONSUMER} via transcript_provider=unavailable; skipping",
            file=sys.stderr,
        )
        return 0

    status = provider.provider_status()
    if status[0] == "unavailable":
        print(
            f"[lore] degraded: {CONSUMER} via transcript_provider=unavailable; skipping",
            file=sys.stderr,
        )
        return 0
    if status[0] == "partial":
        print(
            f"[lore] degraded: {CONSUMER} via transcript_provider=partial "
            f"(missing: {status[1]})",
            file=sys.stderr,
        )

    patterns, patterns_sha256 = load_patterns(args.patterns)
    cp = CompiledPatterns(patterns)
    framework = args.framework or _resolve_framework_label()

    session_paths = provider.list_session_paths(args.cwd)
    if not session_paths:
        print(f"[lore] {CONSUMER}: no sessions enumerable for {args.cwd}; nothing to measure", file=sys.stderr)
        return 0

    rows: list[dict] = []
    skipped = 0
    excluded_window = 0
    for path in session_paths:
        try:
            messages = provider.parse_transcript(path)
            raw_lines = provider.read_raw_lines(path)
            meta = provider.session_metadata(path)
            start = session_start_utc(raw_lines, meta)
            if start is not None:
                if since and start < since:
                    excluded_window += 1
                    continue
                if until and start >= until:
                    excluded_window += 1
                    continue
            events = detect_events(messages, raw_lines, cp)
            row = build_row(path, meta, events, cp, patterns_sha256, framework)
        except Exception as exc:  # a malformed session must not sink the sweep
            print(f"[lore] {CONSUMER}: skipping {path}: {exc}", file=sys.stderr)
            skipped += 1
            continue
        if row is None:
            skipped += 1
        else:
            row["session_start_utc"] = start.isoformat() if start else None
            rows.append(row)

    rows.sort(key=lambda r: (r["session_date"] or "", r["session_id"]))

    rows_text = "".join(json.dumps(r) + "\n" for r in rows)
    if args.rows_out:
        with open(args.rows_out, "w", encoding="utf-8") as f:
            f.write(rows_text)
    else:
        sys.stdout.write(rows_text)

    era_summary = None
    if args.retrieval_log:
        boundary = date.fromisoformat(args.era_boundary)
        era_summary = summarize_retrieval_log(args.retrieval_log, boundary)

    window_note = None
    if since or until:
        window_note = (
            f"- Session-start bound (UTC): "
            f"{since.isoformat() if since else '—'} ≤ start < "
            f"{until.isoformat() if until else '—'}; "
            f"{excluded_window} sessions excluded as outside the bound"
        )

    if args.report_out:
        report = render_report(
            rows, skipped, args.patterns, patterns_sha256, framework, status,
            era_summary, window_note,
        )
        with open(args.report_out, "w", encoding="utf-8") as f:
            f.write(report)

    print(
        f"[lore] {CONSUMER}: {len(rows)} rows ({skipped} skipped, "
        f"{excluded_window} outside window) from {len(session_paths)} sessions",
        file=sys.stderr,
    )
    return 0


def _resolve_framework_label() -> str:
    env = os.environ.get("LORE_FRAMEWORK", "").strip()
    if env:
        return env
    data_dir = os.environ.get("LORE_DATA_DIR", os.path.join(os.path.expanduser("~"), ".lore"))
    lib_sh = os.path.join(data_dir, "scripts", "lib.sh")
    if os.path.isfile(lib_sh):
        try:
            result = subprocess.run(
                ["bash", "-c", f"source {lib_sh} && resolve_active_framework"],
                capture_output=True, text=True, timeout=2,
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except (subprocess.TimeoutExpired, OSError):
            pass
    return "claude-code"


if __name__ == "__main__":
    sys.exit(main())
