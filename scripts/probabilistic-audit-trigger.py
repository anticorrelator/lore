#!/usr/bin/env python3
"""probabilistic-audit-trigger.py — Stop hook for Phase 5 probabilistic audits.

Runs at session stop. Detects ceremony completions (/implement, /spec,
/pr-review, /pr-self-review) in the transcript; for each, rolls against
its configured probability `p`; logs every roll (fired and not-fired) to
`$KDIR/_scorecards/trigger-log.jsonl`; and, when fired, records the
intent to audit the ceremony's artifact.

**Foreground-safe dispatch.** On fire, the hook dispatches `lore audit`
without blocking the Stop-hook path. Two dispatch paths are probed in
order: (1) the background-queue substrate (task-28) when available,
(2) a detached `subprocess.Popen` spawn with `start_new_session=True`
(task-29 fallback). The Stop-hook always returns within milliseconds
regardless of how long the audit takes. The trigger-log row records
*the roll*; `dispatch_audit()` controls *how the audit runs*. A
dispatch failure is surfaced on stderr but does not block the Stop
hook — task-42's zero-rows-despite-triggers health check is the
canonical signal that dispatch is breaking silently.

Configuration:
    $LORE_HOME/config/settlement-config.json — per-ceremony p values,
    enabled flag, dry_run flag.

Input (Stop hook JSON on stdin):
    {
      "transcript_path": "<path to session JSONL>",
      "stop_hook_active": false,
      "cwd": "<project dir>"
    }

Output: exits 0 silently (does not block the Stop). Emits a bracketed
`[lore-trigger]` line to stderr when a ceremony triggers fire, so the
user sees a minimal audit trail without noise during dry quiet sessions.

Ceremony detection:
    The hook looks at the last SlashCommand tool use in the transcript.
    Recognized commands (case-insensitive, with or without leading "/"):
      /implement        → ceremony="implement"
      /pr-self-review   → ceremony="pr-self-review"
      /pr-review        → ceremony="pr-review"
      /spec             → ceremony="spec"
    If the transcript has no matching SlashCommand, the hook exits
    silently (nothing to sample).

Artifact-id resolution:
    On fire, the hook attempts to resolve the artifact id in order:
      1. Current git branch name (if non-empty and not main/master/HEAD)
      2. The work-item slug inferred from `$KDIR/_work/<slug>/` where
         `<slug>` shares the git branch
      3. Fallback: "<ceremony>-<timestamp>" — caller can resolve later
    The resolved id is recorded in the trigger-log row's artifact_id
    field and will be picked up by the background-queue (task-28) when
    it dispatches the audit.
"""

from __future__ import annotations

import json
import os
import random
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Shared infrastructure
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transcript import parse_transcript, resolve_knowledge_dir, fail_open

CEREMONY_COMMANDS = {
    "implement": "implement",
    "pr-self-review": "pr-self-review",
    "pr-review": "pr-review",
    "spec": "spec",
}

DEFAULT_CONFIG = {
    "schema_version": "1",
    "probabilistic_triggers": {
        "implement": 0.3,
        "pr-self-review": 0.3,
        "pr-review": 0.2,
        "spec": 0.2,
    },
    "enabled": True,
    "dry_run": False,
}


def load_config() -> dict:
    """Load ~/.lore/config/settlement-config.json with defaults fallback."""
    path = Path.home() / ".lore" / "config" / "settlement-config.json"
    if not path.is_file():
        return DEFAULT_CONFIG
    try:
        with open(path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        # Shallow merge over defaults so missing keys still resolve.
        merged = dict(DEFAULT_CONFIG)
        merged.update(loaded)
        triggers = dict(DEFAULT_CONFIG["probabilistic_triggers"])
        triggers.update(loaded.get("probabilistic_triggers", {}))
        merged["probabilistic_triggers"] = triggers
        return merged
    except (OSError, json.JSONDecodeError):
        return DEFAULT_CONFIG


def detect_ceremony(transcript_path: str) -> str | None:
    """Return the ceremony name for the last matching SlashCommand, or None.

    Iterates messages in reverse order so the most recent invocation wins.
    """
    if not transcript_path or not os.path.isfile(transcript_path):
        return None
    messages = parse_transcript(transcript_path)
    # Find the last SlashCommand whose command-text starts with a ceremony.
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            entries = [json.loads(line) for line in f if line.strip()]
    except (OSError, json.JSONDecodeError):
        return None
    for entry in reversed(entries):
        msg = entry.get("message") or entry
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            if block.get("name") != "SlashCommand":
                continue
            args = block.get("input", {}) or {}
            # Claude Code SlashCommand input carries `command` like "/implement …"
            cmd_raw = str(args.get("command") or "").strip()
            if cmd_raw.startswith("/"):
                cmd_raw = cmd_raw[1:]
            # Take the first token after stripping leading slash.
            first_token = cmd_raw.split()[0].lower() if cmd_raw else ""
            if first_token in CEREMONY_COMMANDS:
                return CEREMONY_COMMANDS[first_token]
    return None


def resolve_artifact_id(ceremony: str, cwd: str, kdir: str) -> str:
    """Resolve the ceremony's artifact id: branch → slug match → fallback."""
    branch = get_git_branch(cwd)
    if branch and branch not in ("main", "master", "HEAD"):
        work_dir = Path(kdir) / "_work" / branch
        if work_dir.is_dir():
            return branch
        return branch
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{ceremony}-{ts}"


def get_git_branch(cwd: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            branch = result.stdout.strip()
            return branch or None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def append_trigger_log(kdir: str, row: dict) -> None:
    """Invoke trigger-log-append.sh via --row for schema validation."""
    script = Path(kdir).parent.parent.parent / "work" / "lore" / "scripts" / "trigger-log-append.sh"
    # Prefer the project's trigger-log-append.sh, falling back to the symlinked
    # ~/.lore/scripts/ copy if the project path is not resolvable.
    candidate = Path(__file__).parent / "trigger-log-append.sh"
    if candidate.is_file():
        script = candidate
    else:
        lore_home_script = Path.home() / ".lore" / "scripts" / "trigger-log-append.sh"
        if lore_home_script.is_file():
            script = lore_home_script
        else:
            # Last resort: write directly (and warn).
            print(
                "[lore-trigger] warning: trigger-log-append.sh not found; "
                "writing directly without validation",
                file=sys.stderr,
            )
            log_path = Path(kdir) / "_scorecards" / "trigger-log.jsonl"
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")
            return
    try:
        subprocess.run(
            [
                "bash",
                str(script),
                "append",
                "--kdir",
                kdir,
                "--row",
                json.dumps(row),
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"[lore-trigger] error invoking trigger-log-append.sh: {e}", file=sys.stderr)


def timestamp_iso_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def dispatch_audit(artifact_id: str, config: dict) -> str:
    """Dispatch `lore audit <artifact-id>` without blocking the Stop hook.

    Two dispatch paths, probed in order:

    1. **Background-queue (task-28).** When the queue substrate exists,
       enqueue the audit as a work-item request. The queue processes
       asynchronously outside the foreground loop. Probe: the
       settlement-config flag `background_queue.enabled` AND the queue's
       expected enqueue script is present on the symlinked scripts path.

    2. **run_in_background fallback (task-29).** Spawn `lore audit` as a
       detached child process (`subprocess.Popen` with
       `start_new_session=True` and redirected I/O). The child runs to
       completion independently; the Stop hook returns immediately. This
       is the MVP dispatch path until the background queue lands.

    Return value is a short human-readable status string used in the
    trigger's stderr notice ("queued (background queue)", "spawned
    (detached child)", or "dispatch skipped: <reason>"). The row in
    trigger-log.jsonl records that the roll *fired*; this function only
    controls how the audit *runs*.
    """
    # --- Path 1: background queue (task-28) ---
    queue_cfg = config.get("background_queue", {}) or {}
    if queue_cfg.get("enabled"):
        enqueue_script = Path.home() / ".lore" / "scripts" / "background-queue-enqueue.sh"
        if enqueue_script.is_file():
            try:
                subprocess.Popen(
                    [
                        "bash",
                        str(enqueue_script),
                        "--job",
                        f"lore audit {artifact_id}",
                        "--role",
                        "audit",
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                return "queued (background queue)"
            except OSError as e:
                # Fall through to subprocess fallback on enqueue failure.
                return _spawn_detached_audit(artifact_id, fallback_reason=f"queue enqueue failed: {e}")

    # --- Path 2: run_in_background fallback (task-29) ---
    return _spawn_detached_audit(artifact_id)


def _spawn_detached_audit(artifact_id: str, fallback_reason: str | None = None) -> str:
    """Spawn `lore audit <artifact-id>` as a detached child process.

    Uses `start_new_session=True` to disconnect from the parent's
    process group so the child survives Stop-hook termination. All
    stdio is redirected to /dev/null — the audit's output lands in
    its own persistence paths (verdicts/, scorecard-append, etc.).
    """
    try:
        subprocess.Popen(
            ["lore", "audit", artifact_id],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except (OSError, FileNotFoundError) as e:
        return f"dispatch skipped: could not spawn audit ({e})"
    if fallback_reason:
        return f"spawned (detached child; {fallback_reason})"
    return "spawned (detached child)"


@fail_open
def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, Exception) as e:
        print(f"[lore-trigger] failed to parse hook input: {e}", file=sys.stderr)
        return 0

    if hook_input.get("stop_hook_active", False):
        return 0

    cwd = hook_input.get("cwd") or os.getcwd()
    transcript_path = hook_input.get("transcript_path", "")

    config = load_config()
    if not config.get("enabled", True):
        return 0

    ceremony = detect_ceremony(transcript_path)
    if ceremony is None:
        return 0

    p_map = config.get("probabilistic_triggers", {})
    configured_p = p_map.get(ceremony)
    if not isinstance(configured_p, (int, float)) or configured_p <= 0.0:
        # Ceremony disabled (p=0 or missing).
        return 0

    rolled = random.random()
    fired = rolled < configured_p

    try:
        kdir = resolve_knowledge_dir(cwd)
    except Exception:
        return 0
    if not kdir:
        return 0

    dry_run = config.get("dry_run", False)

    artifact_id = resolve_artifact_id(ceremony, cwd, kdir) if fired else None

    row = {
        "schema_version": "1",
        "ceremony": ceremony,
        "configured_p": configured_p,
        "fired": fired and not dry_run,
        "rolled": round(rolled, 6),
        "triggered_at": timestamp_iso_utc(),
    }
    if fired and artifact_id:
        row["artifact_id"] = artifact_id

    append_trigger_log(kdir, row)

    if fired and not dry_run:
        dispatch_status = dispatch_audit(artifact_id, config)
        print(
            f"[lore-trigger] {ceremony} fired (p={configured_p}, "
            f"rolled={rolled:.3f}); artifact_id={artifact_id} "
            f"— {dispatch_status}",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
