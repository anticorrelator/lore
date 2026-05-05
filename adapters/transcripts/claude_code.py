"""Claude Code transcript provider (T50).

Reference implementation of the transcript-provider contract documented
in `adapters/transcripts/README.md`. Wraps the existing parsers in
`scripts/transcript.py` and `scripts/extract-session-digest.py` so the
claude-code path produces output byte-equivalent to today's behavior —
the load-bearing claim of the claude-code-baseline invariant
(notes.md 2026-05-04T07:50).

Design choices:

- **Wrap, don't reimplement.** Every operation calls into the existing
  `scripts/transcript.py` helpers via dynamic import. This minimizes
  diff surface and means anything T50 didn't touch (e.g., the JSONL
  parsing edge cases for malformed lines) keeps its existing behavior
  by construction.

- **Module name uses underscore (`claude_code.py`).** The
  `adapters/transcripts/README.md` and the work-item plan reference
  this provider as `claude-code.py` — that is the *adapter id* form,
  matching the framework name in capabilities.json. Python module
  names cannot contain hyphens, so the on-disk filename is
  `claude_code.py`. The import path is
  `adapters.transcripts.claude_code`; the framework id mapping in
  `adapters/transcripts/__init__.py::_PROVIDER_MODULES` translates
  the hyphenated framework name to the underscored module name.

- **No `tool_names` reads in T50.** The plan decision (notes.md
  2026-05-04T07:55) places `builtin_plan_mode_tool` and
  `slash_command_tool` under `frameworks.<fw>.tool_names` in
  capabilities.json. Per the lead's T50 routing, the keys do NOT
  exist yet — T53 and T54 add them. T50 therefore does not read
  capabilities.json for tool names; the consumers (T53/T54) will.

- **`previous_session_path` returns the file at index 1, not 0.**
  T47 observation: `find_previous_session_file` in
  `extract-session-digest.py` returns the *second*-most-recent
  JSONL because the most-recent IS the current session at
  SessionStart hook time. Regressing to `[0]` would silently
  re-digest the current session every restart.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Source-script resolution
# ---------------------------------------------------------------------------
#
# The provider wraps `scripts/transcript.py` and
# `scripts/extract-session-digest.py`. Both live in the lore repo
# under `scripts/`, accessed at runtime via the
# ~/.lore/scripts/ install-path symlink.
#
# We use importlib.spec_from_file_location because:
# - `scripts/extract-session-digest.py` has a hyphen in its filename
#   (not importable via the dotted-import path).
# - Both modules import from each other and from `transcript.py`, so we
#   need to register them in sys.modules under names that will resolve
#   when those imports fire.

def _resolve_scripts_dir() -> Path:
    """Return the lore-managed scripts directory.

    The installation symlink at `~/.lore/scripts/` (or `$LORE_DATA_DIR/scripts/`
    when overridden) points at the lore repo's `scripts/` directory.
    Tests may override LORE_DATA_DIR to point at a temporary tree.
    """
    data_dir = os.environ.get(
        "LORE_DATA_DIR",
        os.path.join(os.path.expanduser("~"), ".lore"),
    )
    return Path(data_dir) / "scripts"


def _import_by_path(module_name: str, file_path: Path) -> Any:
    """Import a Python file as a named module and register it in sys.modules.

    We register in sys.modules so subsequent `from <name> import ...`
    statements inside the loaded file work as the source script's
    intra-package imports expect.
    """
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, str(file_path))
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {module_name} from {file_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _load_transcript_module() -> Any:
    """Load `scripts/transcript.py` as the `transcript` module."""
    scripts_dir = _resolve_scripts_dir()
    return _import_by_path("transcript", scripts_dir / "transcript.py")


def _load_digest_module() -> Any:
    """Load `scripts/extract-session-digest.py`.

    The filename has a hyphen; the module is registered as
    `extract_session_digest` so its `from transcript import ...`
    statement resolves through the transcript module loaded above.
    """
    scripts_dir = _resolve_scripts_dir()
    # Make sure transcript is loaded first so the digest's import works.
    _load_transcript_module()
    # Add scripts_dir to sys.path so `from transcript import ...` and
    # the dynamic stop-novelty-check import inside the digest both
    # resolve. This mirrors how the digest script is run today.
    scripts_str = str(scripts_dir)
    if scripts_str not in sys.path:
        sys.path.insert(0, scripts_str)
    return _import_by_path(
        "extract_session_digest",
        scripts_dir / "extract-session-digest.py",
    )


# ---------------------------------------------------------------------------
# T46 minimum operations
# ---------------------------------------------------------------------------

def parse_transcript(path: str) -> list[dict]:
    """Parse a JSONL transcript file into normalized message dicts.

    Pure passthrough to `scripts/transcript.py::parse_transcript`.
    Output schema (closed; per provider README):
        index, role, text_blocks, has_tool_use, is_tool_result, tool_names
    """
    transcript = _load_transcript_module()
    return transcript.parse_transcript(path)


def extract_file_paths(path: str) -> list[tuple[str, int]]:
    """Return `[(file_path, message_index), ...]` from Read/Edit/Write/Glob
    tool_use blocks, in transcript order.

    Pure passthrough to `scripts/transcript.py::extract_file_paths`.
    """
    transcript = _load_transcript_module()
    return transcript.extract_file_paths(path)


def previous_session_path(cwd: str) -> str | None:
    """Return the path to the second-most-recent JSONL session for `cwd`.

    Wraps `extract-session-digest.py::find_project_dir` +
    `find_previous_session_file`. Returns `None` when no previous
    session exists (fresh install or only-one-session-this-cwd cases).

    The "second-most-recent" semantic is load-bearing — at SessionStart
    hook time, the most-recent JSONL IS the current session, so
    digesting it would re-digest in-flight content (T47 observation).
    """
    digest = _load_digest_module()
    project_dir = digest.find_project_dir(cwd)
    if project_dir is None:
        return None
    prev = digest.find_previous_session_file(project_dir)
    return str(prev) if prev is not None else None


def provider_status() -> tuple[str, str]:
    """Return `(support_level, reason)` for the active provider.

    Claude Code's transcript provider is `full` per
    `adapters/capabilities.json.frameworks.claude-code.capabilities.transcript_provider`.
    The reason string is empty on `full` providers; non-empty on
    `partial`/`unavailable` per the README contract.
    """
    return ("full", "")


# ---------------------------------------------------------------------------
# T47 digest extensions
# ---------------------------------------------------------------------------

def read_raw_lines(path: str) -> list[str]:
    """Return the raw JSONL lines of `path`, in file order.

    Used by `extract-session-digest.py`'s windowed debugging-evidence
    extraction (`scan_for_debugging` + `extract_debug_evidence`),
    which needs positional adjacency around debug-pattern matches.

    The alignment invariant `read_raw_lines(p)[i] === parse_transcript(p)[i]`
    holds for claude-code because both helpers iterate the same JSONL
    lines in the same order — `scripts/transcript.py::parse_transcript`
    enumerates lines via `enumerate(f)` and assigns `index = i`, and
    this function reads via `f.readlines()` preserving that order.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.readlines()
    except OSError:
        return []


def session_metadata(path: str) -> dict:
    """Return `{"session_id": str, "session_date": datetime | None}`
    from the first parseable entry in the transcript.

    Reproduces `extract-session-digest.py::parse_jsonl_file`'s
    metadata-extraction path (lines 84–90, 117–119) without
    re-parsing the entire file. Falls back to file mtime for
    `session_date` when no `timestamp` field is present in the
    first line.
    """
    import json
    from datetime import datetime

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
                # First parseable line wins.
                session_id = data.get("sessionId", "unknown")
                ts = data.get("timestamp")
                if ts:
                    try:
                        session_date = datetime.fromisoformat(
                            ts.replace("Z", "+00:00")
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


# ---------------------------------------------------------------------------
# T48 plan-persistence extension
# ---------------------------------------------------------------------------

def tool_use_timestamps(path: str, tool_name: str) -> list[tuple[int, str]]:
    """Return `[(message_index, timestamp_iso8601_str), ...]` for entries
    whose `tool_use` blocks invoke `tool_name`, in transcript order.

    Used by `check-plan-persistence.py` to find the *last* ExitPlanMode
    invocation and its timestamp, which the consumer compares against
    `_work/<slug>/{plan.md,_meta.json,notes.md}` mtimes to verify
    persistence happened *after* plan mode.

    Returns an empty list when `tool_name` is never invoked. The
    consumer treats an empty list as "tool was not used in this
    session" and exits without enforcement.
    """
    import json

    out: list[tuple[int, str]] = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = entry.get("message", {})
                content = msg.get("content", [])
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("name") != tool_name:
                        continue
                    ts = entry.get("timestamp", "")
                    if ts:
                        out.append((i, ts))
                    break  # one match per entry is enough
    except OSError:
        return []
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
