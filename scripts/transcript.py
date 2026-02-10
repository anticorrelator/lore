"""Shared JSONL transcript parser and knowledge-dir resolution for lore hooks.

Provides:
    parse_transcript(path) — parse JSONL into structured messages
    resolve_knowledge_dir(cwd) — Python-native repo resolution (no subprocess)
    fail_open(func) — decorator: catch all exceptions, exit 0

Used by: stop-novelty-check.py, check-plan-persistence.py, extract-session-digest.py
"""

import json
import os
import re
import subprocess
import sys


# ---------------------------------------------------------------------------
# Transcript parsing
# ---------------------------------------------------------------------------

def parse_transcript(transcript_path):
    """Parse JSONL transcript into structured messages.

    Returns list of dicts with keys:
        index, role, text_blocks (list of str), has_tool_use, tool_names (list of str),
        is_tool_result (bool)
    """
    messages = []
    try:
        with open(transcript_path, "r") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                msg = entry.get("message", {})
                role = msg.get("role", "")
                content = msg.get("content", [])

                text_blocks = []
                has_tool_use = False
                has_tool_result = False
                tool_names = []

                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "text":
                            text_blocks.append(block.get("text", ""))
                        elif block.get("type") == "tool_use":
                            has_tool_use = True
                            tool_names.append(block.get("name", ""))
                        elif block.get("type") == "tool_result":
                            has_tool_result = True
                            text_blocks.append(str(block.get("content", "")))
                elif isinstance(content, str):
                    text_blocks.append(content)

                messages.append({
                    "index": i,
                    "role": role,
                    "text_blocks": text_blocks,
                    "has_tool_use": has_tool_use,
                    "is_tool_result": has_tool_result,
                    "tool_names": tool_names,
                })
    except (OSError, Exception):
        return []

    return messages


def count_tool_uses(messages):
    """Count total number of messages with tool_use blocks."""
    return sum(1 for m in messages if m["has_tool_use"])


def has_recent_capture(messages):
    """Check if 'lore capture' was already run this session."""
    for msg in messages:
        for text in msg["text_blocks"]:
            if "lore capture" in text and "--insight" in text:
                return True
            if "[capture] Filed to" in text:
                return True
        if msg["has_tool_use"]:
            for text in msg["text_blocks"]:
                if "lore capture" in text:
                    return True
    return False


# ---------------------------------------------------------------------------
# Knowledge directory resolution (Python-native)
# ---------------------------------------------------------------------------

def _normalize_remote_url(url):
    """Normalize a git remote URL to a path-style string.

    Examples:
        https://github.com/user/repo.git -> github.com/user/repo
        git@github.com:user/repo.git -> github.com/user/repo
    """
    normalized = url

    # Strip protocol
    for prefix in ("https://", "http://", "git://"):
        if normalized.startswith(prefix):
            normalized = normalized[len(prefix):]
            break

    # Strip SSH user prefix (git@)
    if "@" in normalized.split("/")[0]:
        normalized = normalized.split("@", 1)[1]

    # Convert SSH colon to slash (github.com:user/repo -> github.com/user/repo)
    normalized = normalized.replace(":", "/", 1) if ":" in normalized else normalized

    # Strip .git suffix and trailing slash
    if normalized.endswith(".git"):
        normalized = normalized[:-4]
    normalized = normalized.rstrip("/")

    # Strip auth credentials
    if "@" in normalized:
        normalized = normalized.split("@", 1)[1]

    return normalized.lower()


def resolve_knowledge_dir(cwd=None):
    """Resolve the knowledge directory for the current project.

    Python-native equivalent of resolve-repo.sh. Returns the absolute path
    to the knowledge directory, or None if resolution fails.

    Resolution order:
        1. LORE_KNOWLEDGE_DIR env var (test override)
        2. Git remote URL -> ~/.lore/repos/<normalized-url>/
        3. Git repo without remote -> ~/.lore/repos/local/<repo-name>/
        4. Non-git directory -> ~/.lore/repos/local/<dir-name>/
    """
    # Short-circuit: env var override
    env_dir = os.environ.get("LORE_KNOWLEDGE_DIR", "")
    if env_dir:
        return env_dir

    if cwd is None:
        cwd = os.getcwd()

    data_dir = os.environ.get("LORE_DATA_DIR", os.path.join(os.path.expanduser("~"), ".lore"))
    base_dir = os.path.join(data_dir, "repos")

    # Try git remote URL
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            remote_url = result.stdout.strip()
            if remote_url:
                normalized = _normalize_remote_url(remote_url)
                remote_path = os.path.join(base_dir, normalized)

                # Also compute local path for migration check
                repo_root_result = subprocess.run(
                    ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                    capture_output=True, text=True, timeout=5,
                )
                repo_name = os.path.basename(repo_root_result.stdout.strip()) if repo_root_result.returncode == 0 else ""
                local_path = os.path.join(base_dir, "local", repo_name) if repo_name else ""

                # Prefer local path if it has data but remote path doesn't
                if (local_path
                        and not os.path.isfile(os.path.join(remote_path, "_manifest.json"))
                        and os.path.isfile(os.path.join(local_path, "_manifest.json"))):
                    return local_path

                return remote_path
    except Exception:
        pass

    # Fallback: git repo without remote
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            repo_name = os.path.basename(result.stdout.strip())
            return os.path.join(base_dir, "local", repo_name)
    except Exception:
        pass

    # Fallback: not a git repo
    dir_name = os.path.basename(os.path.abspath(cwd))
    return os.path.join(base_dir, "local", dir_name)


# ---------------------------------------------------------------------------
# Fail-open decorator
# ---------------------------------------------------------------------------

def fail_open(func):
    """Decorator that catches all exceptions and exits 0 (allows stop).

    Use on main() functions in stop hooks to ensure they never block
    the user from stopping due to bugs in the hook itself.
    """
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception:
            sys.exit(0)
    return wrapper
