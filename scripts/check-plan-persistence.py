#!/usr/bin/env python3
"""Stop hook: detect plan mode usage without persistence to _work/.

Reads the session transcript through the active framework's transcript
provider, finds the last builtin-plan-mode tool use and its timestamp,
and verifies that the plan was persisted to the knowledge store's
_work/ directory after that timestamp. If not, blocks stopping and
instructs the operator to persist.

Routing follows the canonical consumer pattern documented in
conventions/canonical-consumer-pattern-transcript-provider.md:
  get_provider() -> catch UnsupportedFrameworkError -> provider_status()
  gate -> operation calls. The per-harness builtin-plan-mode tool name
  comes from `adapters/capabilities.json.frameworks.<fw>.builtin_plan_mode_tool`;
  harnesses declaring `null` (no documented builtin plan mode) skip the
  check entirely with a degraded-capability stderr notice.

Input: JSON on stdin (Stop hook format — includes transcript_path, stop_hook_active)
Output: JSON on stdout with decision:"block" if persistence gap detected
"""

import json
import os
import sys
from datetime import datetime

# Shared knowledge-dir resolution + fail_open decorator (still used).
_SCRIPTS_DIR = os.path.dirname(os.path.realpath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
from transcript import resolve_knowledge_dir, fail_open

# Provider boundary. Add the repo root so `adapters` resolves the same way
# extract-session-digest.py does.
_REPO_ROOT = os.path.dirname(_SCRIPTS_DIR)
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)
from adapters.transcripts import get_provider, UnsupportedFrameworkError


def _resolve_builtin_plan_mode_tool():
    """Read the active harness's builtin_plan_mode_tool key from capabilities.json.

    Returns the tool-name string (e.g. "ExitPlanMode") or None when the
    harness declares no builtin plan mode. Returns the sentinel string
    "__missing__" when capabilities.json itself is unreadable so callers
    can distinguish "harness has no plan mode" from "config error."
    """
    capabilities_file = os.path.join(_REPO_ROOT, "adapters", "capabilities.json")
    if not os.path.isfile(capabilities_file):
        # Fall back to the symlinked install.
        data_dir = os.environ.get(
            "LORE_DATA_DIR",
            os.path.join(os.path.expanduser("~"), ".lore"),
        )
        scripts_dir = os.path.join(data_dir, "scripts")
        capabilities_file = os.path.join(
            os.path.dirname(scripts_dir), "adapters", "capabilities.json"
        )
    if not os.path.isfile(capabilities_file):
        return "__missing__"
    try:
        with open(capabilities_file, "r") as f:
            caps = json.load(f)
    except (OSError, json.JSONDecodeError):
        return "__missing__"

    # Resolve active framework via the same env override the rest of Lore uses.
    fw = os.environ.get("LORE_FRAMEWORK", "").strip()
    if not fw:
        # Honor user config when the env var is absent.
        data_dir = os.environ.get(
            "LORE_DATA_DIR",
            os.path.join(os.path.expanduser("~"), ".lore"),
        )
        config_file = os.path.join(data_dir, "config", "framework.json")
        if os.path.isfile(config_file):
            try:
                with open(config_file, "r") as cf:
                    fw = (json.load(cf).get("framework") or "").strip()
            except (OSError, json.JSONDecodeError):
                fw = ""
    if not fw:
        fw = "claude-code"

    framework_block = (caps.get("frameworks") or {}).get(fw) or {}
    # Missing key => assume the legacy claude-code default (ExitPlanMode) only
    # for claude-code; for other harnesses, missing-key is treated identically
    # to explicit-null and the check skips with a degraded notice.
    if "builtin_plan_mode_tool" not in framework_block:
        return "ExitPlanMode" if fw == "claude-code" else None
    return framework_block.get("builtin_plan_mode_tool")


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, Exception) as e:
        print(f"[hook] check-plan-persistence: Failed to parse hook input: {e}", file=sys.stderr)
        sys.exit(0)

    # Prevent infinite loops — if we already blocked once, let it through.
    if hook_input.get("stop_hook_active", False):
        sys.exit(0)

    transcript_path = hook_input.get("transcript_path", "")
    if not transcript_path or not os.path.exists(transcript_path):
        sys.exit(0)

    # Resolve the provider. Catch UnsupportedFrameworkError per the canonical
    # consumer pattern; exit 0 with a degraded-capability stderr notice.
    try:
        provider = get_provider()
    except UnsupportedFrameworkError:
        print(
            "[lore] degraded: check-plan-persistence via transcript_provider=unavailable; skipping",
            file=sys.stderr,
        )
        sys.exit(0)

    # Provider-status gate. unavailable -> skip; partial -> proceed with notice;
    # full -> proceed silently.
    support_level, degraded_reason = provider.provider_status()
    if support_level == "unavailable":
        print(
            "[lore] degraded: check-plan-persistence via transcript_provider=unavailable; skipping",
            file=sys.stderr,
        )
        sys.exit(0)

    # Per-harness builtin plan mode tool name. None means "this harness has
    # no documented builtin plan mode" (opencode, codex). Skip with a
    # degraded:none notice — there is no work for this hook to do.
    plan_mode_tool = _resolve_builtin_plan_mode_tool()
    if plan_mode_tool is None:
        print(
            "[lore] degraded: check-plan-persistence via builtin_plan_mode_tool=none; "
            "skipping (no builtin plan mode on active harness)",
            file=sys.stderr,
        )
        sys.exit(0)
    if plan_mode_tool == "__missing__":
        # Config error — exit 0 (hook must not fail loudly) but warn so the
        # operator can investigate.
        print(
            "[lore] degraded: check-plan-persistence via builtin_plan_mode_tool=no-evidence; "
            "skipping (capabilities.json not readable)",
            file=sys.stderr,
        )
        sys.exit(0)

    if support_level == "partial":
        # Partial providers may not surface per-entry timestamps reliably;
        # tool_use_timestamps may return [] even when the tool was used.
        # Proceed but emit the named-fields degraded notice so downstream
        # operators can correlate any "plan persisted late" surprises.
        print(
            f"[lore] degraded: check-plan-persistence via transcript_provider=partial "
            f"({degraded_reason})",
            file=sys.stderr,
        )

    # Find every invocation of the builtin plan-mode tool with its timestamp.
    try:
        tool_uses = provider.tool_use_timestamps(transcript_path, plan_mode_tool)
    except Exception as e:
        print(
            f"[hook] check-plan-persistence: provider.tool_use_timestamps failed: {e}",
            file=sys.stderr,
        )
        sys.exit(0)

    if not tool_uses:
        # Tool was not invoked this session — nothing to enforce.
        sys.exit(0)

    # Last invocation wins (operator may run plan mode multiple times in one
    # session; only the most-recent one is what could still be unpersisted).
    _last_idx, last_plan_mode_ts = tool_uses[-1]
    if not last_plan_mode_ts:
        sys.exit(0)

    # Parse the timestamp.
    try:
        plan_mode_time = datetime.fromisoformat(
            last_plan_mode_ts.replace("Z", "+00:00")
        )
        plan_mode_epoch = plan_mode_time.timestamp()
    except (ValueError, Exception):
        sys.exit(0)

    # Resolve knowledge directory.
    knowledge_dir = resolve_knowledge_dir()
    if not knowledge_dir or not os.path.isdir(knowledge_dir):
        # No knowledge dir — can't verify, but still warn.
        json.dump(
            {
                "decision": "block",
                "reason": (
                    "You used builtin plan mode this session but no knowledge store "
                    "was found to verify persistence. The builtin plan file at the "
                    "harness's ephemeral plans directory is ephemeral. Please persist "
                    "the plan to `_work/` using `/work create`."
                ),
            },
            sys.stdout,
        )
        return

    plans_dir = os.path.join(knowledge_dir, "_work")

    # Check if any _work/ subdirectory has files modified after the plan-mode invocation.
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

    # Plan mode was used but no persistence detected.
    json.dump(
        {
            "decision": "block",
            "reason": (
                "You used builtin plan mode this session but the plan was not "
                "persisted to `_work/`. The harness's builtin plan file is ephemeral "
                "and will be lost across sessions.\n\n"
                "Persist the plan now:\n"
                "1. Use `/work create` to create a work item and persist the plan, OR\n"
                "2. Tell the user you used plan mode and let them decide.\n\n"
                "If you intentionally chose not to persist this plan (e.g., quick scratch planning), "
                "tell the user and they can dismiss."
            ),
        },
        sys.stdout,
    )


if __name__ == "__main__":
    try:
        fail_open(main)()
    except Exception as e:
        print(f"[hook] check-plan-persistence: {e}", file=sys.stderr)
        sys.exit(0)
