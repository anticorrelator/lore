"""Lore transcript provider package.

Per `adapters/transcripts/README.md` (T46–T56), every Lore consumer of
session transcripts (digest, plan-persistence, ceremony detection,
novelty review) reads through the provider boundary defined here
rather than importing from `scripts/transcript.py` directly.

Public API:

    from adapters.transcripts import (
        # Shared helpers (T56) — pure functions over the closed
        # normalized message-dict schema. Identical implementation
        # across providers; not provider operations.
        count_tool_uses,
        has_recent_capture,
        extract_text_blocks,
        # Provider resolution (T52–T54, T57 will use this)
        get_provider,
    )

The provider resolver dispatches on the active framework
(`resolve_active_framework` from `scripts/lib.sh`) to one of the
per-harness modules:

    claude-code → adapters.transcripts.claude_code      (T50)
    opencode    → adapters.transcripts.opencode         (T51)
    codex       → adapters.transcripts.codex            (T51)

T50 ships only the claude-code provider; opencode and codex stubs
land in T51. Calling `get_provider()` on an unsupported framework
raises `UnsupportedFrameworkError`; callers MUST catch it and
exit 0 with the documented stderr notice (per the
"Consumer behavior on degraded support" contract in the README).
"""

from __future__ import annotations

import importlib
import os
import subprocess
from typing import Any, Iterable


# ---------------------------------------------------------------------------
# Shared helpers (T56)
#
# These three helpers are pure functions over the closed normalized
# message-dict schema documented in the provider README. They are NOT
# provider operations — every provider's `parse_transcript` output
# already supports them. Documenting them as operations would force
# every adapter to copy/paste identical Python; the shared module
# preserves the "schema is closed; helpers are derived" distinction.
# ---------------------------------------------------------------------------

def count_tool_uses(messages: Iterable[dict]) -> int:
    """Count messages whose `has_tool_use` is true.

    Mirrors `scripts/transcript.py::count_tool_uses` byte-for-byte
    (T50 hard-requirement: byte-equivalent output on the same input).
    """
    return sum(1 for m in messages if m.get("has_tool_use"))


def has_recent_capture(messages: Iterable[dict]) -> bool:
    """Return True if `lore capture` was already invoked this session.

    Mirrors `scripts/transcript.py::has_recent_capture` byte-for-byte.
    Detection is text-block-based (substring scan) plus a tool-use
    sweep — both are needed because some sessions invoke capture via
    Bash tool while others mention it in assistant prose.
    """
    for msg in messages:
        for text in msg.get("text_blocks", []):
            if "lore capture" in text and "--insight" in text:
                return True
            if "[capture] Filed to" in text:
                return True
        if msg.get("has_tool_use"):
            for text in msg.get("text_blocks", []):
                if "lore capture" in text:
                    return True
    return False


def extract_text_blocks(messages: Iterable[dict]) -> list[tuple[int, str]]:
    """Return `[(message_index, text), ...]` for every text_block in
    every message.

    Consolidates the `for m in messages: for text in m["text_blocks"]:`
    pattern that appears repeatedly across `stop-novelty-check.py`
    (T56 observation). Iteration order matches the message order
    returned by `parse_transcript`.
    """
    out: list[tuple[int, str]] = []
    for msg in messages:
        idx = msg.get("index", 0)
        for text in msg.get("text_blocks", []):
            out.append((idx, text))
    return out


# ---------------------------------------------------------------------------
# Provider resolution
# ---------------------------------------------------------------------------

class UnsupportedFrameworkError(RuntimeError):
    """Raised when `get_provider` is asked for a framework that has no
    transcript provider implementation.

    Per the consumer-behavior-on-degraded-support contract, callers MUST
    catch this and exit 0 with a `[lore] degraded: <consumer> via
    transcript_provider=unavailable; skipping` stderr notice — never a
    silent skip and never a non-zero exit (these consumers fire from
    hooks where a non-zero exit interrupts the user session).
    """


# Module name lookup — keep in sync with adapters/capabilities.json
# frameworks.<fw>.transcript_provider cells.
_PROVIDER_MODULES = {
    "claude-code": "adapters.transcripts.claude_code",
    # T51 will register:
    # "opencode": "adapters.transcripts.opencode",
    # "codex": "adapters.transcripts.codex",
}


def _resolve_active_framework_via_lib() -> str:
    """Shell out to `scripts/lib.sh::resolve_active_framework` so this
    Python module agrees with the bash side on the active framework.

    The Go side has its own `config.ResolveActiveFramework`; both must
    return the same value for an active session. We deliberately avoid
    re-implementing the resolution logic in Python to keep the source
    of truth in one place (T7 dual-impl contract).
    """
    # Honor LORE_FRAMEWORK env override the same way lib.sh does.
    env_override = os.environ.get("LORE_FRAMEWORK", "").strip()
    if env_override:
        return env_override

    # Locate scripts/lib.sh via LORE_DATA_DIR/scripts symlink (the
    # install.sh-managed path) or fall back to the lore-managed default.
    data_dir = os.environ.get(
        "LORE_DATA_DIR",
        os.path.join(os.path.expanduser("~"), ".lore"),
    )
    lib_sh = os.path.join(data_dir, "scripts", "lib.sh")
    if not os.path.isfile(lib_sh):
        # No installed lib.sh → assume legacy install (default to
        # claude-code per the invariant in notes.md 2026-05-04T07:50).
        return "claude-code"

    try:
        result = subprocess.run(
            ["bash", "-c", f"source {lib_sh} && resolve_active_framework"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            return result.stdout.strip() or "claude-code"
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return "claude-code"


def get_provider(framework: str | None = None) -> Any:
    """Return the transcript provider module for the active framework.

    Args:
        framework: Optional explicit framework id. When None (default),
            resolves via `scripts/lib.sh::resolve_active_framework` so
            this matches what `cli/lore` and the orchestration adapter
            see. Pass a string to override (used by tests and for
            cross-harness validation).

    Returns:
        The provider module (with `parse_transcript`,
        `extract_file_paths`, `previous_session_path`, `provider_status`,
        `read_raw_lines`, `session_metadata`, `tool_use_timestamps`).

    Raises:
        UnsupportedFrameworkError: if no provider is registered for
            the requested framework.
    """
    fw = framework or _resolve_active_framework_via_lib()
    module_name = _PROVIDER_MODULES.get(fw)
    if module_name is None:
        raise UnsupportedFrameworkError(
            f"no transcript provider registered for framework '{fw}'"
        )
    return importlib.import_module(module_name)


__all__ = [
    "count_tool_uses",
    "has_recent_capture",
    "extract_text_blocks",
    "get_provider",
    "UnsupportedFrameworkError",
]
