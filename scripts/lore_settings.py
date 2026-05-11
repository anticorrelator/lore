"""Unified settings loader for ~/.lore/config/settings.json (D5/D5a).

Bash counterpart: scripts/settings.sh (settings_get/section/path/patch/fallbacks).
Go counterpart: tui/internal/config/settings.go.

Read contract (D5):
    - get(path) returns the JSON value at the dot-separated path rooted at the
      unified document, or None if the key is absent. Explicit JSON null is
      indistinguishable from absence at the get() level — callers needing to
      disambiguate should use section() and check key membership.
    - section(name) returns the named top-level object as a dict, or {} if
      absent.
    - path() returns the resolved settings.json absolute path.
    - fallbacks() returns an empty list. Runtime settings no longer read
      legacy fragmented files.

Write contract (D5a):
    - set(path, value) acquires an exclusive flock on
      <data_dir>/config/.settings.lock (the same lock file the bash loader
      uses), reads the full document, modifies only the targeted dot-path,
      and writes the document back atomically (tmpfile + os.replace).
      Unrelated keys, sections, and any keys the writer doesn't recognize
      are preserved verbatim. The lock covers read+modify+write so a
      concurrent reader cannot observe a partial document.

Failure handling:
    - Missing settings.json is NOT an error: get() returns None, section()
      returns {}, fallbacks() returns [].
    - Malformed JSON is a hard error (SettingsError) with an actionable
      message.

Parity vs the bash loader's missing-key surface:
    - bash settings_get returns empty stdout on absence.
    - Python get() returns None on absence.
    Callers must not pun on truthiness across stacks; check `is None`
    explicitly when distinguishing absence from a falsy explicit value.

Environment:
    - LORE_DATA_DIR overrides ~/.lore (matches scripts/lib.sh).

Settlement:
    - The settlement processor reads the `settlement` section through this
      unified file shape. Missing settlement keys fail closed in the processor:
      enabled=False, max_concurrency=1, batch_size=12,
      batch_recompute_min_interval_seconds=60, concordance_window_size=8.
"""

from __future__ import annotations

import errno
import fcntl
import json
import os
import tempfile
from typing import Any


class SettingsError(Exception):
    """Raised when settings.json is unreadable or malformed."""


SETTLEMENT_DEFAULTS: dict[str, Any] = {
    "enabled": False,
    "max_concurrency": 1,
    "batch_size": 12,
    "batch_recompute_min_interval_seconds": 60,
    "concordance_window_size": 8,
}


def _data_dir() -> str:
    return os.environ.get("LORE_DATA_DIR") or os.path.join(os.path.expanduser("~"), ".lore")


def _config_dir() -> str:
    return os.path.join(_data_dir(), "config")


def path() -> str:
    """Return the resolved absolute path to settings.json."""
    return os.path.join(_config_dir(), "settings.json")


def _lock_path() -> str:
    return os.path.join(_config_dir(), ".settings.lock")


def _load_document() -> dict:
    """Read settings.json into a dict. Missing file → {}; malformed → raise."""
    p = path()
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (json.JSONDecodeError, ValueError) as e:
        raise SettingsError(
            f"invalid JSON in {p}: {e} — run `lore doctor` to diagnose"
        ) from e
    if not isinstance(data, dict):
        raise SettingsError(
            f"invalid JSON in {p}: top-level value is not an object"
        )
    return data


def _resolve_dot_path(doc: dict, dot_path: str) -> Any:
    """Walk a dot-separated path through nested dicts. Return None on absence."""
    if not dot_path:
        return None
    node: Any = doc
    for segment in dot_path.split("."):
        if not isinstance(node, dict) or segment not in node:
            return None
        node = node[segment]
    return node


def get(dot_path: str) -> Any:
    """Read the value at a dot-separated path. None on absence.

    Bash parity: `bash scripts/settings.sh get <dot_path>` returns empty
    stdout for the same absence; Python returns None. Distinguish absence
    from a falsy value by checking `is None`.
    """
    return _resolve_dot_path(_load_document(), dot_path)


def section(name: str) -> dict:
    """Return the named top-level object, or {} if absent.

    A non-dict top-level value is treated as absence rather than an error.
    """
    doc = _load_document()
    val = doc.get(name)
    if isinstance(val, dict):
        return val
    return {}


def fallbacks() -> list[tuple[str, str]]:
    """Return legacy settings fallback rows.

    Runtime settings now read only the unified settings document, so there
    are no fallback rows to report.
    """
    _load_document()
    return []


def _set_dot_path(doc: dict, dot_path: str, value: Any) -> None:
    """In-place: assign value at dot_path, creating intermediate dicts.

    Raises SettingsError if an intermediate segment exists but is not a dict
    (e.g., trying to set "a.b" when "a" is a string) — overwriting a non-dict
    intermediate would silently destroy unrelated data.
    """
    if not dot_path:
        raise SettingsError("set(): empty path")
    segments = dot_path.split(".")
    node = doc
    for segment in segments[:-1]:
        if segment not in node:
            node[segment] = {}
        elif not isinstance(node[segment], dict):
            raise SettingsError(
                f"set(): cannot descend into non-object at '{segment}' "
                f"(path: {dot_path})"
            )
        node = node[segment]
    node[segments[-1]] = value


def set(dot_path: str, value: Any) -> None:  # noqa: A001 — public API name per D5
    """Atomically write value at dot_path under exclusive lock.

    Implements the D5a write contract: acquire flock on
    <data_dir>/config/.settings.lock, read the full document, modify only
    the targeted path, write back atomically via os.replace. Unrelated keys
    and sections are preserved byte-for-byte at the JSON-value level.

    Concurrency: the lock covers read+modify+write so two parallel writers
    targeting different paths both land — neither overwrites the other.
    """
    config_dir = _config_dir()
    os.makedirs(config_dir, exist_ok=True)
    lock_path = _lock_path()
    settings_path = path()

    # Open the lock file (create if missing) and acquire LOCK_EX.
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        # Read fresh under the lock so concurrent writers compose.
        if os.path.exists(settings_path):
            try:
                with open(settings_path, "r", encoding="utf-8") as f:
                    doc = json.load(f)
            except (json.JSONDecodeError, ValueError) as e:
                raise SettingsError(
                    f"invalid JSON in {settings_path}: {e} — run "
                    f"`lore doctor` to diagnose"
                ) from e
            if not isinstance(doc, dict):
                raise SettingsError(
                    f"invalid JSON in {settings_path}: top-level value is "
                    f"not an object"
                )
        else:
            doc = {}

        _set_dot_path(doc, dot_path, value)

        # Atomic write: tmpfile in same dir, then os.replace.
        fd, tmp_path = tempfile.mkstemp(
            prefix=".settings.", suffix=".tmp", dir=config_dir
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=2, sort_keys=True)
                f.write("\n")
            os.replace(tmp_path, settings_path)
        except OSError:
            try:
                os.unlink(tmp_path)
            except OSError as e:
                if e.errno != errno.ENOENT:
                    raise
            raise
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)
