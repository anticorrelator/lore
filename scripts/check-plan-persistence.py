#!/usr/bin/env python3
"""Stop hook: detect plan mode usage without persistence to _work/.

Reads the session transcript, checks for ExitPlanMode tool uses, and verifies
that the plan was persisted to the knowledge store's _work/ directory.
If not, blocks stopping and instructs Claude to persist.

Input: JSON on stdin (Stop hook format — includes transcript_path, stop_hook_active)
Output: JSON on stdout with decision:"block" if persistence gap detected
"""

import json
import os
import sys
from datetime import datetime

# Shared transcript infrastructure
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transcript import resolve_knowledge_dir, fail_open


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, Exception):
        sys.exit(0)

    # Prevent infinite loops — if we already blocked once, let it through
    if hook_input.get("stop_hook_active", False):
        sys.exit(0)

    transcript_path = hook_input.get("transcript_path", "")
    if not transcript_path or not os.path.exists(transcript_path):
        sys.exit(0)

    # Fast path: raw string check before any JSON parsing
    try:
        with open(transcript_path, "r") as f:
            raw = f.read()
        if "ExitPlanMode" not in raw:
            sys.exit(0)
    except Exception:
        sys.exit(0)

    # Find the LAST ExitPlanMode entry and its timestamp
    # Uses raw JSONL scan because we need entry-level timestamps
    last_plan_mode_ts = None
    with open(transcript_path, "r") as f:
        for line in f:
            try:
                entry = json.loads(line)
                msg_data = entry.get("message", {})
                content = msg_data.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if (
                            isinstance(block, dict)
                            and block.get("name") == "ExitPlanMode"
                        ):
                            ts = entry.get("timestamp", "")
                            if ts:
                                last_plan_mode_ts = ts
            except (json.JSONDecodeError, Exception):
                continue

    if not last_plan_mode_ts:
        sys.exit(0)

    # Parse the timestamp
    try:
        plan_mode_time = datetime.fromisoformat(
            last_plan_mode_ts.replace("Z", "+00:00")
        )
        plan_mode_epoch = plan_mode_time.timestamp()
    except (ValueError, Exception):
        sys.exit(0)

    # Resolve knowledge directory
    knowledge_dir = resolve_knowledge_dir()
    if not knowledge_dir or not os.path.isdir(knowledge_dir):
        # No knowledge dir — can't verify, but still warn
        json.dump(
            {
                "decision": "block",
                "reason": (
                    "You used builtin plan mode (ExitPlanMode) this session but no knowledge store "
                    "was found to verify persistence. The builtin plan file at ~/.claude/plans/ is "
                    "ephemeral. Please persist the plan to `_work/` using `/work create`."
                ),
            },
            sys.stdout,
        )
        return

    plans_dir = os.path.join(knowledge_dir, "_work")

    # Check if any _work/ subdirectory has files modified after the ExitPlanMode
    persistence_found = False
    if os.path.isdir(plans_dir):
        for entry in os.listdir(plans_dir):
            subdir = os.path.join(plans_dir, entry)
            # Skip non-directories and internal dirs (_archive, _index.json, etc.)
            if not os.path.isdir(subdir) or entry.startswith("_"):
                continue
            for fname in ("plan.md", "_meta.json", "notes.md"):
                fpath = os.path.join(subdir, fname)
                if os.path.exists(fpath):
                    mtime = os.path.getmtime(fpath)
                    if mtime >= plan_mode_epoch:
                        persistence_found = True
                        break
            if persistence_found:
                break

    if persistence_found:
        sys.exit(0)

    # Plan mode was used but no persistence detected
    json.dump(
        {
            "decision": "block",
            "reason": (
                "You used builtin plan mode (ExitPlanMode) this session but the plan was not "
                "persisted to `_work/`. The builtin plan file at `~/.claude/plans/` is ephemeral "
                "and will be lost across sessions.\n\n"
                "Persist the plan now:\n"
                "1. Use `/work create` to persist via the skill, OR\n"
                "2. Manually create `_work/<slug>/` with `_meta.json` and `plan.md`\n\n"
                "If you intentionally chose not to persist this plan (e.g., quick scratch planning), "
                "tell the user and they can dismiss."
            ),
        },
        sys.stdout,
    )


if __name__ == "__main__":
    fail_open(main)()
