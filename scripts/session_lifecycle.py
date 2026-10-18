"""Decide what one hosted session generation is doing from its hook rows and its screen.

A session lore hosts reports each turn edge twice. Its harness's lifecycle hooks
journal needs_input and resumed rows marked links.authority=hook-row
(scripts/session-lifecycle-hook.sh), and the session host journals needs_input,
resumed and modal_blocked rows from what the screen shows. Readers ask this
module what the session is doing now, and whether a park row they are about to
act on is a new park or one already reported.

The rules, applied to one session generation:

1. Process exit stands.
2. A park row corroborates the generation's latest non-corroborating edge when
   that edge is a park, no resumed, interrupt or closed row lies between them in
   journal order, and either the two come from different sources or one is the
   host's modal_blocked and the other a blocked needs_input. A corroborating row
   is evidence for the park it joins, not a new park.
3. A row whose edge time (links.fired_at on a hook row, links.observed_at on a
   screen row) is older than an edge already in the journal landed late; it is
   superseded and kept as evidence. A park followed by a newer non-corroborating
   edge or a closed row is superseded too. Rows without an edge time are ordered
   by the journal.
4. The newest remaining edge decides. A park keeps the authority, matcher and
   block_signature of the edge that established it for as long as it lasts.
5. An unknown or starting screen never overrides a hook edge: a hook park keeps
   its activity, and beside a hook working edge the activity stays the
   screen's unknown.
6. When the deciding edge is the screen's, the screen stands; a hook was missed.
7. When the deciding edge is a hook's and the screen shows a different known
   activity, the hook's activity stands and the screen's view is recorded under
   evidence.disagreement.
8. A hook row from a generation other than the current one is evidence only.
   While no live owner lists the session, the current generation is unknown and
   hook rows decide nothing.

docs/session-observation.md describes what readers see.
"""
import calendar
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import time

# A scan that has read this many journal bytes without finding where the
# session's current state began reports itself truncated instead of guessing.
SCAN_LIMIT_BYTES = 16 * 1024 * 1024
SCAN_CHUNK_BYTES = 256 * 1024
# How far back past a timed resumed row the scan looks for an edge that would
# show the resumed row landed late. Late rows trail by seconds, not megabytes.
LATE_WINDOW_BYTES = 1024 * 1024
OWNER_FRESH_SECONDS = 30
CHECKPOINT_ROLES = frozenset({'session-host-spawn', 'session-spawn'})
INTERRUPT_EVENTS = frozenset({'interrupt_sent', 'interrupt_uncertain'})
BOUNDARY_EVENTS = frozenset({'spawned', 'recovered'})
UNSETTLED_SCREEN = frozenset({'unknown', 'starting'})

_TARGET = None
_STAMP = re.compile(r'(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})')


def _session_target():
    global _TARGET
    if _TARGET is None:
        spec = importlib.util.spec_from_file_location(
            'session_target', Path(__file__).resolve().parent / 'session_target.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _TARGET = module
    return _TARGET


def edge_time(value):
    """Microseconds since the epoch for an ISO 8601 stamp, or None.

    Hook rows stamp six fractional digits; the host's stamps trim trailing zeros
    and may carry nine, which Python 3.9 cannot parse. Both are truncated to
    microseconds and compared as integers, never as strings.
    """
    match = _STAMP.fullmatch(value) if isinstance(value, str) else None
    if not match:
        return None
    year, month, day, hour, minute, second, fraction, zone = match.groups()
    try:
        moment = datetime.datetime(int(year), int(month), int(day), int(hour), int(minute), int(second))
    except ValueError:
        return None
    offset = 0
    if zone != 'Z':
        offset = (1 if zone[0] == '+' else -1) * (int(zone[1:3]) * 3600 + int(zone[4:6]) * 60)
    return (calendar.timegm(moment.timetuple()) - offset) * 1000000 + int((fraction or '').ljust(6, '0')[:6])


def _alive(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def current_owner(kdir, slug):
    """(instance name, session row) of the live registry row listing slug, or None.

    Live means heartbeated within the registry's freshness bound by a process
    that is still running; a launch checkpoint is not an owner. When several
    rows qualify, the newest registration wins: a host stamps each rewrite of
    its row with revision, a nanosecond clock reading, while every live host
    refreshes its row's mtime each second.
    """
    best = None
    now = time.time()
    for path in (Path(kdir) / '_sessions' / 'instances').glob('*.json'):
        try:
            written = path.stat().st_mtime
            if now - written > OWNER_FRESH_SECONDS:
                continue
            row = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(row, dict) or row.get('role') in CHECKPOINT_ROLES or not _alive(row.get('pid')):
            continue
        revision = row.get('revision')
        revision = revision if isinstance(revision, int) and not isinstance(revision, bool) else 0
        for entry in row.get('sessions') or []:
            if isinstance(entry, dict) and entry.get('slug') == slug:
                key = (revision, written)
                if best is None or key > best[0]:
                    best = (key, row.get('name') or path.stem, entry)
    return (best[1], best[2]) if best else None


def current_generation(kdir, slug):
    """The generation the live owner records for slug, or None in a restart window."""
    owner = current_owner(kdir, slug)
    if owner is None:
        return None
    try:
        return _session_target().generation(owner[1]) or None
    except (AttributeError, TypeError, ValueError):
        return None


def stale_generation(row, generation):
    """True for a hook row naming a generation other than a known current one."""
    links = row.get('links') if isinstance(row, dict) and isinstance(row.get('links'), dict) else {}
    return (generation is not None and links.get('authority') == 'hook-row'
            and bool(links.get('generation')) and links.get('generation') != generation)


def _embedded(row):
    links = row.get('links') if isinstance(row.get('links'), dict) else {}
    try:
        value = json.loads(links.get('observation') or '{}')
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _edge(row, start=None, end=None, generation=None):
    """The edge a journal row contributes, 'other-generation', or None for any other row."""
    event = row.get('event')
    links = row.get('links') if isinstance(row.get('links'), dict) else {}
    edge = dict(event=event, event_id=row.get('event_id'), start=start, end=end, row=row, at=None, stamp=None)
    if event in ('needs_input', 'resumed'):
        hook = links.get('authority') == 'hook-row'
        own = links.get('generation')
        if generation is not None and own and own != generation:
            return 'other-generation'
        activity = links.get('activity') or _embedded(row).get('activity')
        stamp = links.get('fired_at') if hook else links.get('observed_at')
        edge.update(source='hook' if hook else 'screen',
                    kind='park' if event == 'needs_input' else 'resume',
                    activity=activity or ('idle' if event == 'needs_input' else 'working'),
                    stamp=stamp, at=edge_time(stamp))
    elif event == 'modal_blocked':
        edge.update(source='screen', kind='park', activity='blocked')
    elif event in INTERRUPT_EVENTS:
        edge.update(source='lore', kind='interrupt', activity=None)
    elif event == 'closed' or event in BOUNDARY_EVENTS:
        edge.update(source='lore', kind='end', activity=None)
    else:
        return None
    edge['separator'] = edge['kind'] in ('resume', 'interrupt', 'end')
    return edge


def _needle(slug):
    quoted = json.dumps(slug)
    if quoted != '"' + slug + '"' or not slug.isascii():
        return None
    return quoted.encode()


def _rows_backward(path, slug, stats):
    """Yield (start, end, row) for slug's complete journal rows, newest first.

    Reads backward in chunks and parses only lines naming the slug. Stops after
    SCAN_LIMIT_BYTES (stats['capped']) or once every row above stats['floor'] has
    been read (stats['floor_reached']). stats['position'] is the offset above
    which every row has been examined.
    """
    needle = _needle(slug)
    try:
        stream = open(path, 'rb')
    except FileNotFoundError:
        stats['position'] = 0
        return
    with stream:
        tail = stream.seek(0, os.SEEK_END)
        stats['position'] = tail
        chunk = SCAN_CHUNK_BYTES
        trailing = True
        while tail > 0:
            floor = stats.get('floor')
            if floor is not None and tail <= floor:
                stats['floor_reached'] = True
                return
            budget = SCAN_LIMIT_BYTES - stats['scanned_bytes']
            if budget <= 0:
                stats['capped'] = True
                return
            start = tail - min(chunk, budget, tail)
            stream.seek(start)
            data = stream.read(tail - start)
            stats['scanned_bytes'] += len(data)
            if trailing:
                # A row still being appended has no newline yet; it is read once complete.
                last = data.rfind(b'\n')
                if last < 0 and start > 0:
                    chunk *= 2
                    continue
                tail = start + last + 1
                stats['position'] = tail
                data = data[:last + 1]
                trailing = False
                if not data:
                    continue
            if start > 0:
                head = data.find(b'\n')
                if head == len(data) - 1:
                    chunk *= 2
                    continue
                rows, floor_of_block = data[head + 1:], start + head + 1
            else:
                rows, floor_of_block = data, 0
            chunk = SCAN_CHUNK_BYTES
            lines = rows.split(b'\n')
            lines.pop()
            end = tail
            for line in reversed(lines):
                begin = end - len(line) - 1
                if needle is None or needle in line:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        row = None
                    if isinstance(row, dict) and row.get('slug') == slug:
                        stats['position'] = begin
                        yield begin, end, row
                end = begin
            tail = floor_of_block
            stats['position'] = tail


def edges(kdir, slug, generation):
    """Read the edges that decide slug's current state for one generation.

    Scans the journal backward for the slug and stops at its spawned or
    recovered row, at a resumed, interrupt or closed row that settles where the
    current state began, or at SCAN_LIMIT_BYTES. A scan that reaches the limit
    before finding any such row reports truncated=True; its edges must not
    change anyone's view of the session. generation None means the current
    generation is unknown; rows of every generation are then read.
    """
    stats = dict(scanned_bytes=0, capped=False, floor_reached=False, floor=None, position=None)
    found, stale = [], []
    boundary = None
    settled = False
    pending = None
    for begin, end, row in _rows_backward(Path(kdir) / '_sessions' / 'events.jsonl', slug, stats):
        if row.get('event') in BOUNDARY_EVENTS:
            boundary = dict(event=row.get('event'), event_id=row.get('event_id'), start=begin, end=end)
            settled = True
            break
        item = _edge(row, begin, end, generation)
        if item == 'other-generation':
            if (row.get('links') or {}).get('authority') == 'hook-row':
                stale.append(dict(_edge(row, begin, end, None), stale=True))
            continue
        if item is None:
            continue
        found.append(item)
        if item['at'] is not None and pending is not None:
            if item['at'] <= pending:
                settled = True
                break
            pending = None
            stats['floor'] = None
        if item['separator']:
            if item['at'] is None:
                settled = True
                break
            if pending is None:
                pending = item['at']
                stats['floor'] = max(0, begin - LATE_WINDOW_BYTES)
    else:
        settled = not stats['capped'] or pending is not None
    found.reverse()
    stale.reverse()
    return dict(slug=slug, generation=generation, generation_known=generation is not None,
                edges=found, stale=stale, boundary=boundary, truncated=not settled,
                examined_from=stats['position'], scanned_bytes=stats['scanned_bytes'], limit_bytes=SCAN_LIMIT_BYTES)


def _view(value):
    if isinstance(value, dict) and 'edges' in value:
        items = [item if isinstance(item, dict) and 'kind' in item else _edge(item)
                 for item in value.get('edges') or []]
        return dict(value, edges=[item for item in items if isinstance(item, dict)])
    items = [item if isinstance(item, dict) and 'kind' in item else _edge(item) for item in value or []]
    return dict(slug=None, generation=None, generation_known=True, stale=[], boundary=None,
                truncated=False, examined_from=None, edges=[item for item in items if isinstance(item, dict)])


def _modal_pair(first, second):
    events = {first['event'], second['event']}
    if events != {'modal_blocked', 'needs_input'}:
        return False
    other = first if first['event'] == 'needs_input' else second
    return other['activity'] == 'blocked'


def _annotate(items):
    """Classify each edge in journal order using only the edges before it."""
    notes = []
    latest = None
    ended = False
    newest_at = None
    for index, item in enumerate(items):
        if item['kind'] == 'end':
            ended = True
            notes.append(dict(late=False, corroborates=False, establishing=None))
            continue
        if item['at'] is not None and newest_at is not None and item['at'] < newest_at:
            notes.append(dict(late=True, corroborates=False, establishing=None))
            continue
        if item['at'] is not None:
            newest_at = item['at'] if newest_at is None else max(newest_at, item['at'])
        joined = False
        if item['kind'] == 'park' and latest is not None and not ended:
            prior = items[latest]
            joined = prior['kind'] == 'park' and (prior['source'] != item['source'] or _modal_pair(prior, item))
        if joined:
            notes.append(dict(late=False, corroborates=True, establishing=latest))
        else:
            notes.append(dict(late=False, corroborates=False, establishing=index if item['kind'] == 'park' else None))
            latest = index
            ended = False
    return notes


def _current(items, notes):
    """The deciding edge and, for a park, every edge that joined it."""
    decided = None
    for index, item in enumerate(items):
        if item['kind'] == 'end':
            decided = None
        elif not notes[index]['late'] and not notes[index]['corroborates']:
            decided = index
    if decided is None:
        return None, []
    return items[decided], [items[i] for i in range(decided, len(items))
                            if i == decided or notes[i]['establishing'] == decided and notes[i]['corroborates']]


def _locate(row, items, position):
    event_id = row.get('event_id') if isinstance(row, dict) else None
    for index, item in enumerate(items):
        if event_id and item.get('event_id') == event_id:
            return index
        if position is not None and item.get('end') == position:
            return index
    for index, item in enumerate(items):
        if item.get('row') is row or item.get('row') == row:
            return index
    return None


def _before_span(view, position):
    """True when a row the scan did not find lies before the span it read.

    A scan reads every row of the slug from examined_from to the end of the
    journal, so a row read before the scan and missing from it lies earlier.
    position, the row's end offset, says so directly when the caller has it.
    """
    examined = view.get('examined_from')
    if examined is None or view['truncated']:
        return False
    return position is None or position <= examined


def corroborates(row, prior_edges, position=None):
    """True when park row joins the park its prior edges establish (rule 2).

    prior_edges may be what edges() returned, read after row was, or a list of
    edges or journal rows in journal order. When row is among them only the
    edges before it count. A list is otherwise taken to precede row; a row an
    edges() scan did not find lies before its span, which a later edge ended.
    position is the row's end offset in the journal, when the caller has it.
    """
    view = _view(prior_edges)
    items = view['edges']
    index = _locate(row, items, position)
    if index is None:
        candidate = _edge(row, None, position, view['generation'])
        if not isinstance(candidate, dict) or candidate['kind'] != 'park' or _before_span(view, position):
            return False
        items, index = items + [candidate], len(items)
    if items[index]['kind'] != 'park':
        return False
    return _annotate(items)[index]['corroborates']


def superseded(row, edges, position=None):
    """True when row is no longer current for its generation (rule 3).

    A row that landed late, a park followed by a newer non-corroborating edge or
    a closed row, a row an edges() scan read after it did not find, and a row
    of another generation are all superseded. edges and position are read as
    corroborates() reads prior_edges and position.
    """
    view = _view(edges)
    items = view['edges']
    index = _locate(row, items, position)
    if index is None:
        candidate = _edge(row, None, position, view['generation'])
        if candidate == 'other-generation':
            return True
        if not isinstance(candidate, dict):
            return False
        if _before_span(view, position):
            return True
        items, index = items + [candidate], len(items)
    notes = _annotate(items)
    if notes[index]['late']:
        return True
    if items[index]['kind'] != 'park':
        return False
    return any(items[later]['kind'] == 'end' or not notes[later]['late'] and not notes[later]['corroborates']
               for later in range(index + 1, len(items)))


def hook_matcher(edge):
    """The evidence matcher a hook edge contributes, such as claude-code-hook-stop-failure-v1."""
    links = edge['row'].get('links') or {}
    words = re.sub(r'(?<=[a-z0-9])(?=[A-Z])', '-', links.get('hook_event') or 'unknown')
    words = re.sub(r'[^A-Za-z0-9]+', '-', words).strip('-').lower()
    return '{}-hook-{}-v1'.format(links.get('framework') or 'session', words or 'unknown')


def _hook_view(edge):
    links = edge['row'].get('links') or {}
    view = dict(event=edge['event'], hook_event=links.get('hook_event'), activity=edge['activity'],
                fired_at=edge['stamp'], event_id=edge['event_id'], framework=links.get('framework'))
    for key in ('error', 'tool_name'):
        if links.get(key):
            view[key] = links[key]
    return view


def _summary(edge):
    view = dict(event=edge['event'], source=edge['source'], activity=edge['activity'], event_id=edge['event_id'])
    if edge['stamp']:
        view['edge_time'] = edge['stamp']
    if edge['source'] == 'hook':
        view['hook_event'] = (edge['row'].get('links') or {}).get('hook_event')
    return view


def _screen_view(screen):
    evidence = screen.get('evidence') if isinstance(screen.get('evidence'), dict) else {}
    view = dict(activity=screen.get('activity') or 'unknown', authority=screen.get('authority') or 'none',
                observed_at=screen.get('observed_at'), matcher=evidence.get('matcher'), reason=evidence.get('reason'))
    if screen.get('block_signature'):
        view['block_signature'] = screen['block_signature']
    return view


def _known(screen):
    return screen.get('fresh') is True and screen.get('activity') not in UNSETTLED_SCREEN and bool(screen.get('activity'))


def _says(hook, screen):
    return 'hook says {} since {}; screen {}'.format(hook['activity'], hook['fired_at'], screen['activity'])


def _based(screen, view):
    out = dict(screen)
    out.setdefault('schema_version', 1)
    if not out.get('observed_at'):
        out['observed_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    out.setdefault('max_age_seconds', 5)
    if view.get('slug'):
        out.setdefault('session_handle', view['slug'])
        if not out.get('session_id'):
            out['session_id'] = view['slug']
    if not out.get('generation') and view.get('generation'):
        out['generation'] = view['generation']
    return out


def _disagreeing(park, decided):
    return [_summary(item) for item in park if item is not decided and item['activity'] != decided['activity']]


def _hook_decides(screen, decided, park, view, extra):
    hook = _hook_view(decided)
    seen = _screen_view(screen)
    evidence = dict(extra, hook=hook, screen=seen)
    if decided['kind'] == 'resume' and not _known(screen):
        out = dict(screen)
        out['evidence'] = dict(_evidence(screen), **evidence)
        out['evidence']['reason'] = _says(hook, seen)
        return out
    joined = [_summary(item) for item in park if item is not decided]
    if joined:
        evidence['corroborated_by'] = joined
    disagreement = _disagreeing(park, decided)
    if _known(screen) and screen.get('activity') != decided['activity']:
        disagreement.append(dict(source='screen', activity=seen['activity'], matcher=seen['matcher'],
                                 authority=seen['authority'], observed_at=seen['observed_at']))
    if disagreement:
        evidence['disagreement'] = disagreement
    evidence.update(matcher=hook_matcher(decided), reason=_says(hook, seen))
    out = _based(screen, view)
    out.update(activity=decided['activity'], authority='hook-row', fresh=True, evidence=evidence)
    out.pop('block_signature', None)
    return out


def _screen_park(screen, decided, park, view, extra):
    hooks = [item for item in park if item['source'] == 'hook']
    hook = _hook_view(hooks[-1])
    seen = _screen_view(screen)
    evidence = dict(extra, hook=hook, screen=seen, corroborated_by=[_summary(item) for item in park if item is not decided])
    disagreement = _disagreeing(park, decided)
    if disagreement:
        evidence['disagreement'] = disagreement
    if _known(screen):
        if screen.get('activity') != decided['activity']:
            return _with_evidence(screen, extra) if extra else screen
        out = dict(screen)
        out['evidence'] = dict(_evidence(screen), **evidence)
        return out
    embedded = _embedded(decided['row'])
    out = _based(screen, view)
    out.update(activity=decided['activity'], authority=embedded.get('authority') or 'screen-signature', fresh=True,
               evidence=dict(embedded.get('evidence') or {}, **evidence))
    out['evidence']['reason'] = _says(hook, seen)
    if embedded.get('block_signature'):
        out['block_signature'] = embedded['block_signature']
    else:
        out.pop('block_signature', None)
    return out


def _evidence(screen):
    return dict(screen['evidence']) if isinstance(screen.get('evidence'), dict) else {}


def _with_evidence(screen, extra):
    out = dict(screen)
    out['evidence'] = dict(_evidence(screen), **extra)
    return out


def merge(screen_observation, edges):
    """The session's observation once its edges are applied to what the screen shows.

    edges is what edges() returned for the session's current generation, or a
    list of edges or journal rows of one generation in journal order. Returns
    the screen observation itself, unchanged, when no hook row takes part, so a
    session without hook rows reads exactly as before. The screen keeps ready
    and can_accept_input in every case.
    """
    screen = screen_observation if isinstance(screen_observation, dict) else {}
    view = _view(edges)
    items = view['edges']
    if screen.get('activity') == 'exited':
        return screen
    if view['truncated']:
        return _with_evidence(screen, dict(truncated=True, journal_scan=dict(
            scanned_bytes=view.get('scanned_bytes'), limit_bytes=view.get('limit_bytes'),
            reason='the journal scan reached its bound before it found where the current state began; the previous lifecycle state stands')))
    hooks = [item for item in items if item['source'] == 'hook']
    extra = {}
    if view['stale']:
        extra['stale_hook_rows'] = [_summary(item) for item in view['stale'][-3:]]
    if not hooks:
        return _with_evidence(screen, extra) if extra else screen
    if not view['generation_known']:
        return _with_evidence(screen, dict(extra, hook_unconfirmed=dict(
            _hook_view(hooks[-1]), reason='no live owner lists this session, so its current generation is unknown')))
    decided, park = _current(items, _annotate(items))
    if decided is not None and decided['source'] == 'hook':
        return _hook_decides(screen, decided, park, view, extra)
    if decided is not None and decided['kind'] == 'park' and any(item['source'] == 'hook' for item in park):
        return _screen_park(screen, decided, park, view, extra)
    return _with_evidence(screen, extra) if extra else screen
