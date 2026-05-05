"""OpenCode transcript provider stub (T51).

Reads the Lore-side event accumulator file that `adapters/opencode/lore-hooks.ts`
writes at `~/.lore/sessions/opencode/<session-id>.jsonl`.  Each line is a
JSON-serialized OpenCode plugin event appended by the accumulator in
event-arrival order.

Capability cell: `transcript_provider=partial`
Gaps reported by `provider_status`:
  - `previous_session_path` — no atomic per-session file surface on OpenCode;
    cross-session digest is unavailable until T57's accumulator design settles.
  - `read_raw_lines` alignment — synthesized from the accumulator; alignment
    holds only if the accumulator write-protocol is append-only (one event =
    one line).  Until `adapters/opencode/lore-hooks.ts` ships and the invariant
    is verified, this is declared partial.

Design choices:
  - **No synthesis.**  Every operation that cannot be served returns the
    documented sentinel value (empty list, None, empty string, False).  The
    provider MUST NOT invent file paths, tool names, or text content — the
    capture commons integrity depends on never-falsified inputs (README §"Adapter
    Responsibilities", rule 5).
  - **Accumulator path.**  `~/.lore/sessions/opencode/<session-id>.jsonl` is
    the agreed write path per the T51 notes.  Tests may override via
    `LORE_DATA_DIR`.
  - **Role mapping.**  OpenCode plugin events carry speaker via `message.role`
    (values `"user"` / `"assistant"`); the normalized schema's `role` field is
    populated directly.  Events whose speaker is not determinable emit `""` and
    `is_tool_result=True` where applicable.
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any


_PARTIAL_REASON = (
    "previous_session_path unavailable (no atomic per-session file on OpenCode); "
    "read_raw_lines alignment unverified (accumulator write protocol pending T57); "
    "novelty-review: parse_transcript and extract_file_paths surface partial event "
    "coverage (role and tool-input field shapes degrade to sentinels — detection "
    "proceeds on available text but may miss role-filtered signals)"
)


# ---------------------------------------------------------------------------
# Accumulator path resolution
# ---------------------------------------------------------------------------

def _sessions_dir() -> Path:
    data_dir = os.environ.get(
        "LORE_DATA_DIR",
        os.path.join(os.path.expanduser("~"), ".lore"),
    )
    return Path(data_dir) / "sessions" / "opencode"


def _accumulator_path(session_id: str) -> Path:
    return _sessions_dir() / f"{session_id}.jsonl"


# ---------------------------------------------------------------------------
# Internal parsing helpers
# ---------------------------------------------------------------------------

def _read_events(path: str) -> list[dict]:
    """Return parsed event dicts from the accumulator file, in file order."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return []

    events: list[dict] = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def _event_to_message(index: int, event: dict) -> dict:
    """Translate one accumulator event to a normalized message dict.

    OpenCode `message.updated` events carry:
      event["type"] = "message.updated"
      event["message"]["role"] = "user" | "assistant"
      event["message"]["content"] = [{"type": "text", "text": "..."}, ...]
      event["message"]["tool_use"] = [{"name": "...", ...}, ...]  (optional)

    Tool-execution events (`tool.execute.before` / `tool.execute.after`) carry:
      event["type"] = "tool.execute.before"
      event["tool"]["name"] = "..."
      event["tool"]["input"] = {...}

    All other event types produce an empty-sentinel message.
    """
    role: str = ""
    text_blocks: list[str] = []
    has_tool_use: bool = False
    is_tool_result: bool = False
    tool_names: list[str] = []

    etype = event.get("type", "")

    if etype == "message.updated":
        msg = event.get("message", {}) or {}
        role = msg.get("role", "") or ""
        content = msg.get("content", []) or []
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    text = block.get("text", "")
                    if text:
                        text_blocks.append(text)
                elif block.get("type") == "tool_result":
                    is_tool_result = True
        tool_use_list = msg.get("tool_use", []) or []
        if isinstance(tool_use_list, list) and tool_use_list:
            has_tool_use = True
            for tu in tool_use_list:
                if isinstance(tu, dict):
                    name = tu.get("name", "")
                    if name:
                        tool_names.append(name)

    elif etype in ("tool.execute.before", "tool.execute.after"):
        tool = event.get("tool", {}) or {}
        name = tool.get("name", "")
        if name:
            has_tool_use = True
            tool_names.append(name)
        is_tool_result = etype == "tool.execute.after"

    return {
        "index": index,
        "role": role,
        "text_blocks": text_blocks,
        "has_tool_use": has_tool_use,
        "is_tool_result": is_tool_result,
        "tool_names": tool_names,
    }


# ---------------------------------------------------------------------------
# Provider operations (T46 minimum + T47 + T48 extensions)
# ---------------------------------------------------------------------------

def parse_transcript(path: str) -> list[dict]:
    """Parse the Lore-side OpenCode accumulator file into normalized message dicts.

    Returns an empty list when the accumulator does not exist yet (session has
    not written any events, or accumulator path does not match the convention).
    """
    events = _read_events(path)
    return [_event_to_message(i, ev) for i, ev in enumerate(events)]


def extract_file_paths(path: str) -> list[tuple[str, int]]:
    """Return `[(file_path, message_index), ...]` from tool-execute events.

    Translates OpenCode `tool.execute.before` events whose tool name matches
    the Read/Edit/Write/Glob set.  `tool["input"]["file_path"]` carries the
    target path when the harness surfaces it.  Returns `[]` when the
    accumulator is absent or no file-path tool calls are present.
    """
    _FILE_TOOLS = {"Read", "Edit", "Write", "Glob", "MultiEdit"}
    events = _read_events(path)
    out: list[tuple[str, int]] = []
    for i, ev in enumerate(events):
        if ev.get("type") != "tool.execute.before":
            continue
        tool = ev.get("tool", {}) or {}
        name = tool.get("name", "")
        if name not in _FILE_TOOLS:
            continue
        inp = tool.get("input", {}) or {}
        fp = inp.get("file_path", "") or inp.get("path", "")
        if fp:
            out.append((fp, i))
    return out


def previous_session_path(cwd: str) -> None:  # type: ignore[return]
    """Always returns None — cross-session continuity is unavailable on OpenCode.

    OpenCode does not expose an atomic per-session file surface; the accumulator
    path is keyed by session-id, not by cwd mtime-ordering.  Until T57's
    accumulator design adds a cwd-keyed session index, there is no reliable
    "second-most-recent session for this cwd" surface.  Consumers that call
    this MUST handle `None` per the README §"Consumer behavior on degraded
    support" contract (emit a degraded notice and skip the affected section).
    """
    return None


def provider_status() -> tuple[str, str]:
    """Return `("partial", <reason>)` for the OpenCode provider.

    OpenCode's `transcript_provider` capability cell is `partial` per
    `adapters/capabilities.json.frameworks.opencode.capabilities.transcript_provider`.
    The reason names the two permanent gaps.
    """
    return ("partial", _PARTIAL_REASON)


def read_raw_lines(path: str) -> list[str]:
    """Return raw accumulator lines, one per event, index-aligned with `parse_transcript`.

    The alignment invariant (`read_raw_lines(p)[i]` parses to the same event as
    `parse_transcript(p)[i]`) holds when the accumulator write-protocol is
    append-only (one event = one line, no rewriting).  This invariant is
    asserted by the accumulator design in `adapters/opencode/lore-hooks.ts`
    (T57).  Until that file ships and the invariant is integration-tested,
    callers should treat this as partial and not depend on windowed adjacency.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.readlines()
    except OSError:
        return []


def session_metadata(path: str) -> dict:
    """Return `{"session_id": str, "session_date": datetime | None}` from the
    first parseable accumulator event.

    OpenCode session uuid appears in the `session_id` field of plugin events.
    The event timestamp appears in `timestamp` (ISO-8601 string).
    Falls back to file mtime for `session_date` when no timestamp is present.
    """
    session_id = "unknown"
    session_date = None

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                session_id = data.get("session_id", "") or data.get("sessionId", "") or "unknown"
                ts = data.get("timestamp")
                if ts:
                    try:
                        session_date = datetime.fromisoformat(
                            str(ts).replace("Z", "+00:00")
                        )
                    except (ValueError, TypeError):
                        session_date = None
                break
    except OSError:
        return {"session_id": "unknown", "session_date": None}

    if session_date is None:
        try:
            session_date = datetime.fromtimestamp(os.path.getmtime(path))
        except OSError:
            session_date = None

    return {"session_id": session_id, "session_date": session_date}


def tool_use_timestamps(path: str, tool_name: str) -> list[tuple[int, str]]:
    """Return `[(message_index, timestamp_iso8601_str), ...]` for events whose
    tool name matches `tool_name`, in accumulator order.

    OpenCode `tool.execute.before` events carry a `timestamp` field.  Returns
    an empty list when the tool was not invoked or no timestamp is available.
    Consumers that depend on per-entry timestamp precision should note that the
    accumulator timestamp is at event-dispatch granularity, not turn granularity.
    """
    events = _read_events(path)
    out: list[tuple[int, str]] = []
    for i, ev in enumerate(events):
        etype = ev.get("type", "")
        if etype not in ("tool.execute.before", "tool.execute.after"):
            # Also check message.updated tool_use entries.
            if etype == "message.updated":
                msg = ev.get("message", {}) or {}
                for tu in (msg.get("tool_use", []) or []):
                    if isinstance(tu, dict) and tu.get("name") == tool_name:
                        ts = ev.get("timestamp", "")
                        if ts:
                            out.append((i, str(ts)))
                        break
            continue
        tool = ev.get("tool", {}) or {}
        if tool.get("name") == tool_name:
            ts = ev.get("timestamp", "")
            if ts:
                out.append((i, str(ts)))
    return out


__all__ = [
    "parse_transcript",
    "extract_file_paths",
    "previous_session_path",
    "provider_status",
    "read_raw_lines",
    "session_metadata",
    "tool_use_timestamps",
]
