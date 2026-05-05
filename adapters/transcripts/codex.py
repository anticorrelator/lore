"""Codex transcript provider stub (T51).

Reads Codex session rollout files from the vendor-managed rollout directory.
The rollout file location is derived from the Codex session id, which is
carried in hook payloads.  The default rollout directory is
`~/.codex/sessions/<session-id>/rollout.jsonl` (format: one JSON entry per
line, append-only).

Capability cell: `transcript_provider=partial`
Gaps reported by `provider_status`:
  - Rollout file format coverage is incomplete — the exact per-entry shape is
    vendor-documented but not fully mapped to the normalized message-dict schema.
    Fields that cannot be reliably extracted emit the documented sentinel values.

Design choices:
  - **Rollout path convention.**  `~/.codex/sessions/<session-id>/rollout.jsonl`
    is the inferred path from the Codex CLI docs (see capabilities-evidence.md
    `codex-transcript-provider`).  Override via `LORE_DATA_DIR` is not
    applicable here; Codex session data lives under `$HOME/.codex/`.  Tests may
    set `CODEX_SESSIONS_DIR` to redirect to a temp tree.
  - **`previous_session_path` via mtime-scan.**  Codex rollout files are
    per-session discrete files, enabling the same mtime-ordering strategy as
    claude-code.  The rollout directory listing is sorted by mtime descending;
    the second-most-recent file is returned (same "second-most-recent" semantic
    as `claude_code.py:previous_session_path`).
  - **No synthesis.**  Operations that cannot map the rollout format to a
    required field emit sentinel values rather than invented content.
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any


_PARTIAL_REASON = (
    "rollout file format coverage incomplete: tool_input field shapes differ "
    "from Claude JSONL; role extraction from Codex rollout entries is partial; "
    "novelty-review: parse_transcript surfaces available text and tool names but "
    "role-filtered heuristic signals (user-correction, preference-signal) degrade "
    "when role is empty-sentinel — detection proceeds on unfiltered assistant text"
)


# ---------------------------------------------------------------------------
# Rollout path resolution
# ---------------------------------------------------------------------------

def _sessions_dir() -> Path:
    sessions_override = os.environ.get("CODEX_SESSIONS_DIR", "")
    if sessions_override:
        return Path(sessions_override)
    return Path(os.path.expanduser("~")) / ".codex" / "sessions"


def _rollout_path_for_session(session_id: str) -> Path:
    return _sessions_dir() / session_id / "rollout.jsonl"


def _find_rollout_files_for_cwd(cwd: str) -> list[Path]:
    """Return all rollout.jsonl files under the sessions directory, sorted by
    mtime descending.

    Codex does not natively index sessions by cwd, so this is a best-effort
    scan of the known rollout location.  The consumer `previous_session_path`
    returns index 1 (second-most-recent), matching the same semantics as
    `claude_code.py` and the README §"Previous-session selection" contract.
    """
    sessions_dir = _sessions_dir()
    if not sessions_dir.is_dir():
        return []
    files: list[Path] = []
    for session_dir in sessions_dir.iterdir():
        if not session_dir.is_dir():
            continue
        rollout = session_dir / "rollout.jsonl"
        if rollout.is_file():
            files.append(rollout)
    files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    return files


# ---------------------------------------------------------------------------
# Internal parsing helpers
# ---------------------------------------------------------------------------

def _read_rollout_events(path: str) -> list[dict]:
    """Return parsed rollout entries from `path`, in file order."""
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


def _rollout_entry_to_message(index: int, entry: dict) -> dict:
    """Translate one Codex rollout entry to a normalized message dict.

    Codex rollout entries are documented as carrying:
      entry["type"] = "message" | "tool_call" | "tool_result" | ...
      entry["role"] = "user" | "assistant"   (on message entries)
      entry["content"] = str | [{"type": "text", "text": "..."}, ...]
      entry["name"] = "<tool-name>"           (on tool_call entries)
      entry["input"] = {...}                  (on tool_call entries)

    The exact shape is vendor-documented; entries that do not match the
    expected structure emit sentinel values rather than raising.
    """
    role: str = ""
    text_blocks: list[str] = []
    has_tool_use: bool = False
    is_tool_result: bool = False
    tool_names: list[str] = []

    etype = entry.get("type", "")
    role_raw = entry.get("role", "")

    if role_raw in ("user", "human"):
        role = "user"
    elif role_raw in ("assistant", "model"):
        role = "assistant"

    if etype in ("message", ""):
        content = entry.get("content", "")
        if isinstance(content, str) and content:
            text_blocks.append(content)
        elif isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    text = block.get("text", "")
                    if text:
                        text_blocks.append(text)

    elif etype == "tool_call":
        has_tool_use = True
        name = entry.get("name", "")
        if name:
            tool_names.append(name)
        # Tool call content may also carry text.
        content = entry.get("content", "")
        if isinstance(content, str) and content:
            text_blocks.append(content)

    elif etype == "tool_result":
        is_tool_result = True
        content = entry.get("content", "")
        if isinstance(content, str) and content:
            text_blocks.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    text = block.get("text", "")
                    if text:
                        text_blocks.append(text)

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
    """Parse a Codex rollout file into normalized message dicts.

    Returns an empty list when the rollout file does not exist or cannot be
    parsed.  Callers should check `provider_status` before processing results
    to handle the partial-coverage case.
    """
    events = _read_rollout_events(path)
    return [_rollout_entry_to_message(i, ev) for i, ev in enumerate(events)]


def extract_file_paths(path: str) -> list[tuple[str, int]]:
    """Return `[(file_path, message_index), ...]` from Codex tool_call entries.

    Translates `tool_call` rollout entries whose `name` matches the
    Read/Edit/Write/Glob set.  `entry["input"]["file_path"]` or
    `entry["input"]["path"]` carries the target path.
    """
    _FILE_TOOLS = {"Read", "Edit", "Write", "Glob", "MultiEdit"}
    events = _read_rollout_events(path)
    out: list[tuple[str, int]] = []
    for i, ev in enumerate(events):
        if ev.get("type") != "tool_call":
            continue
        name = ev.get("name", "")
        if name not in _FILE_TOOLS:
            continue
        inp = ev.get("input", {}) or {}
        fp = inp.get("file_path", "") or inp.get("path", "")
        if fp:
            out.append((fp, i))
    return out


def previous_session_path(cwd: str) -> str | None:
    """Return the path to the second-most-recent Codex rollout file.

    Uses mtime-ordering across all rollout files found under the Codex
    sessions directory (vendor-managed location).  Returns None when fewer
    than two session directories exist.

    Note: Codex does not index sessions by cwd, so this is a global mtime
    scan rather than a cwd-scoped one.  The second-most-recent file is the
    best available approximation of "previous session for this project".
    """
    files = _find_rollout_files_for_cwd(cwd)
    if len(files) < 2:
        return None
    return str(files[1])


def provider_status() -> tuple[str, str]:
    """Return `("partial", <reason>)` for the Codex provider.

    Codex's `transcript_provider` capability cell is `partial` per
    `adapters/capabilities.json.frameworks.codex.capabilities.transcript_provider`.
    The reason names the rollout format coverage gap.
    """
    return ("partial", _PARTIAL_REASON)


def read_raw_lines(path: str) -> list[str]:
    """Return raw rollout lines, one per entry, index-aligned with `parse_transcript`.

    The alignment invariant (`read_raw_lines(p)[i]` parses to the same entry as
    `parse_transcript(p)[i]`) holds because both iterate the same JSONL lines in
    the same order.  This is the same trivial-alignment guarantee as
    `claude_code.py:read_raw_lines` — the file is line-delimited and
    append-only by the Codex rollout write protocol.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.readlines()
    except OSError:
        return []


def session_metadata(path: str) -> dict:
    """Return `{"session_id": str, "session_date": datetime | None}` from the
    first parseable rollout entry.

    Codex rollout entries carry `session_id` (from the hook payload) and a
    per-entry `timestamp` (ISO-8601).  Falls back to file mtime for
    `session_date` when no timestamp is present in the first entry.
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
                session_id = (
                    data.get("session_id", "")
                    or data.get("sessionId", "")
                    or "unknown"
                )
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
    """Return `[(message_index, timestamp_iso8601_str), ...]` for rollout
    entries whose tool name matches `tool_name`, in rollout order.

    Codex `tool_call` entries carry a per-entry `timestamp` field.  Returns
    an empty list when the tool was not invoked or no timestamp is available.
    """
    events = _read_rollout_events(path)
    out: list[tuple[int, str]] = []
    for i, ev in enumerate(events):
        if ev.get("type") != "tool_call":
            continue
        if ev.get("name") != tool_name:
            continue
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
