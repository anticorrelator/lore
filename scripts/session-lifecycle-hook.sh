#!/usr/bin/env bash
# session-lifecycle-hook.sh — Journal a lore-hosted session's own turn edges.
#
# Usage: session-lifecycle-hook.sh <framework>   (harness hook payload on stdin)
#
# The session host installs this script as an async hook in the sessions it
# launches, on the native events that frameworks.<framework>.session_lifecycle_hooks
# in adapters/capabilities.json declares, and only when that cell is above
# `none`. Each call writes at most one row through scripts/session-event-append.sh:
# the declared entry whose hook_event equals the payload's hook_event_name (and
# whose matcher, when it has one, names the payload's tool_name) gives the event
# (needs_input or resumed) and activity, and its payload_links copy named
# payload fields into the row's links. The row carries links.authority=hook-row,
# so readers can tell it from the host's screen edge for the same transition.
# A hook the cell does not declare writes nothing.
#
# Identity comes from the pane environment: LORE_SESSION_SLUG, LORE_SESSION_TYPE,
# LORE_SESSION_GENERATION, LORE_SESSION_STORE_ROOT and LORE_SESSION_INSTANCE.
# actor_instance names the live instance whose registry row lists this slug with
# this generation (a row heartbeated within 30 seconds, with a live pid; the
# newest revision when several qualify), because a session adopted by a later
# host outlives the instance it was launched under. LORE_SESSION_INSTANCE is the
# fallback and rides along as links.spawn_instance.
#
# Contract with the harness: the script prints nothing, always exits 0, and
# returns within five seconds even when the journal writer hangs or stdin never
# closes. Async hooks get no harness timeout, and on Claude Code anything a hook
# prints is handed to the model on its next turn. It does nothing when
# LORE_AGENT_DISABLED=1 or when the slug, generation or store root is unset. A
# failure writes no row and appends one line to _sessions/hooks.log in the
# session's store; the host's screen observation keeps reporting the session.

exec >/dev/null 2>&1

[[ "${LORE_AGENT_DISABLED:-}" == "1" ]] && exit 0

FRAMEWORK="${1:-}"
STORE="${LORE_SESSION_STORE_ROOT:-}"
[[ -n "$FRAMEWORK" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_GENERATION:-}" ]] || exit 0
[[ -n "$STORE" && -d "$STORE" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
BOUND_SECONDS=5

hook_log() {
  mkdir -p "$STORE/_sessions" || return 0
  printf '%s session-lifecycle-hook framework=%s slug=%s generation=%s: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FRAMEWORK" "$LORE_SESSION_SLUG" \
    "$LORE_SESSION_GENERATION" "$1" >>"$STORE/_sessions/hooks.log"
}

if ! command -v python3 >/dev/null; then
  hook_log "no row written: python3 is not on PATH"
  exit 0
fi

# The program arrives on python's stdin, so the payload moves to fd 3.
exec 3<&0 0</dev/null
python3 - "$SCRIPT_DIR" "$FRAMEWORK" <<'PY' &
import json
import os
import re
import select
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

STARTED = time.monotonic()
FIRED_AT = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
BOUND = 4.0
READ_LIMIT = 2.0
LIVE_FOR = 30.0
LINK_LIMIT = 200
CHECKPOINT_ROLES = {'session-host-spawn', 'session-spawn'}

scripts_dir, framework = sys.argv[1], sys.argv[2]
env = os.environ
store = Path(env['LORE_SESSION_STORE_ROOT'])
slug = env['LORE_SESSION_SLUG']
generation_env = env['LORE_SESSION_GENERATION']
spawn_instance = env.get('LORE_SESSION_INSTANCE', '')
capabilities_path = Path(scripts_dir).parent / 'adapters' / 'capabilities.json'
hook_event = '?'
writer = None


def log(message):
    stamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    line = (f'{stamp} session-lifecycle-hook framework={framework} slug={slug} '
            f'generation={generation_env} hook_event={hook_event}: {message}')
    try:
        (store / '_sessions').mkdir(parents=True, exist_ok=True)
        with open(store / '_sessions' / 'hooks.log', 'a') as handle:
            handle.write(' '.join(line.split()) + '\n')
    except OSError:
        pass


def stop(signum, frame):
    if writer is not None:
        log(f'no row written: the journal writer had not finished after {BOUND:g}s and was stopped')
        try:
            os.killpg(writer.pid, signal.SIGKILL)
        except OSError:
            pass
    else:
        log(f'no row written: the hook stopped itself after {BOUND:g}s before reaching the journal writer')
    os._exit(0)


def read_payload():
    chunks = []
    deadline = STARTED + READ_LIMIT
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            ready, _, _ = select.select([3], [], [], remaining)
        except (OSError, ValueError):
            break
        if not ready:
            break
        chunk = os.read(3, 65536)
        if not chunk:
            break
        chunks.append(chunk)
        try:
            value = json.loads(b''.join(chunks))
        except ValueError:
            continue
        if isinstance(value, dict):
            return value, None
    data = b''.join(chunks)
    try:
        value = json.loads(data)
    except ValueError:
        value = None
    if isinstance(value, dict):
        return value, None
    return None, len(data)


def clean(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return ''
    text = ''.join(ch for ch in ' '.join(str(value).split()) if ch.isprintable())
    return text[:LINK_LIMIT]


EXACT_MATCHER = re.compile(r'[A-Za-z0-9_\- ,|]+')


def applies(matcher, tool_name):
    if matcher in (None, '', '*'):
        return True
    if not isinstance(tool_name, str) or not tool_name:
        return False
    if EXACT_MATCHER.fullmatch(matcher):
        return tool_name in {part.strip() for part in re.split(r'[|,]', matcher)}
    try:
        return re.search(matcher, tool_name) is not None
    except re.error:
        return False


def alive(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def current_owner():
    sys.path.insert(0, scripts_dir)
    from session_target import generation

    def same_launch(entry):
        try:
            return entry.get('slug') == slug and generation(entry) == generation_env
        except (AttributeError, TypeError, ValueError):
            return False

    best = None
    now = time.time()
    for path in (store / '_sessions' / 'instances').glob('*.json'):
        try:
            mtime = path.stat().st_mtime
            if now - mtime > LIVE_FOR:
                continue
            row = json.loads(path.read_text())
            name = row.get('name')
            if not isinstance(name, str) or not name or row.get('role') in CHECKPOINT_ROLES:
                continue
            if not alive(row.get('pid')):
                continue
            if not any(same_launch(entry) for entry in row.get('sessions') or [] if isinstance(entry, dict)):
                continue
            revision = row.get('revision')
            key = (revision if isinstance(revision, int) and not isinstance(revision, bool) else 0, mtime)
            if best is None or key > best[0]:
                best = (key, name)
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    return best[1] if best else ''


def main():
    global hook_event, writer
    payload, size = read_payload()
    if payload is None:
        log(f'no row written: the hook payload on stdin was not a JSON object ({size} bytes before end of input or the {READ_LIMIT:g}s read limit)')
        return
    hook_event = clean(payload.get('hook_event_name'))
    if not hook_event:
        hook_event = '?'
        log('no row written: the hook payload names no hook_event_name')
        return
    try:
        block = json.loads(capabilities_path.read_text())['frameworks'][framework]['session_lifecycle_hooks']
        events = block['events']
        if not isinstance(events, list):
            raise TypeError('events is not a list')
    except (OSError, ValueError, KeyError, TypeError) as error:
        log(f'no row written: cannot read frameworks.{framework}.session_lifecycle_hooks.events from {capabilities_path} ({type(error).__name__}: {error})')
        return
    tool_name = payload.get('tool_name')
    entry = next((candidate for candidate in events
                  if isinstance(candidate, dict) and candidate.get('hook_event') == hook_event
                  and applies(candidate.get('matcher'), tool_name)), None)
    if entry is None:
        named = f' with tool_name {clean(tool_name)}' if clean(tool_name) else ''
        log(f'no row written: frameworks.{framework}.session_lifecycle_hooks in {capabilities_path} declares no event for {hook_event}{named}; the launch installed a hook that block does not map')
        return

    links = {
        'authority': 'hook-row',
        'hook_event': hook_event,
        'activity': clean(entry.get('activity')),
        'generation': generation_env,
        'fired_at': FIRED_AT,
        'framework': framework,
        'spawn_instance': spawn_instance,
    }
    payload_links = entry.get('payload_links') or {}
    if isinstance(payload_links, dict):
        for link, field in payload_links.items():
            if link in links or not isinstance(field, str):
                continue
            links[link] = clean(payload.get(field))
    row = {
        'event': clean(entry.get('event')),
        'slug': slug,
        'session_type': env.get('LORE_SESSION_TYPE', ''),
        'actor_instance': current_owner() or spawn_instance,
        'links': {key: value for key, value in links.items() if value},
    }

    writer_path = Path(scripts_dir) / 'session-event-append.sh'
    try:
        writer = subprocess.Popen(
            ['bash', str(writer_path), '--kdir', str(store), '--row', json.dumps(row)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            start_new_session=True)
    except OSError as error:
        log(f'no row written: the journal writer {writer_path} could not be started ({error})')
        return
    _, errors = writer.communicate()
    if writer.returncode != 0:
        lines = [line.strip() for line in errors.decode(errors='replace').splitlines() if line.strip()]
        reason = lines[-1] if lines else 'no diagnostic'
        log(f'no row written: the journal writer refused the row (exit {writer.returncode}): {reason}')


signal.signal(signal.SIGALRM, stop)
signal.setitimer(signal.ITIMER_REAL, BOUND)
try:
    main()
except Exception as error:
    log(f'no row written: unexpected {type(error).__name__}: {error}')
os._exit(0)
PY
worker=$!
exec 3<&-

(
  trap 'kill "$nap" 2>/dev/null; exit 0' TERM
  sleep "$BOUND_SECONDS" &
  nap=$!
  wait "$nap"
  kill -KILL "$worker" 2>/dev/null && hook_log "no row written: the hook was stopped after ${BOUND_SECONDS}s"
) &
watchdog=$!
wait "$worker"
kill -TERM "$watchdog" 2>/dev/null
wait "$watchdog"
exit 0
