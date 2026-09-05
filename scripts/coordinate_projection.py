#!/usr/bin/env python3
"""Disposable coordination display state. Canonical status remains an audit."""
import argparse
import contextlib
import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
import uuid

from coordinate_reducer import (ArcReduction, ARC_ROOT, make_row, parse_ledger,
                                reconciliation_projection, dispatch_reason)

VERSION = 1
BATCH_BYTES = 256 * 1024
MAX_ROW = 1024 * 1024
UPDATE_SECONDS = 5
RECONCILE_SECONDS = 30
META_BATCH = 128
SELECTION_BATCH = 8


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def fingerprint(path):
    try:
        st = path.stat()
        return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
    except FileNotFoundError:
        return None


def get(db, key, default=None):
    row = db.execute('SELECT value FROM state WHERE key=?', (key,)).fetchone()
    return json.loads(row[0]) if row else default


def put(db, key, value):
    db.execute('INSERT OR REPLACE INTO state VALUES (?,?)', (key, json.dumps(value)))


def connect(path, writable=False):
    db = sqlite3.connect(str(path) if writable else path.as_uri()+'?mode=ro',
                         uri=not writable, timeout=0)
    db.row_factory = sqlite3.Row
    return db


def initialize(db, store):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS arcs(name TEXT PRIMARY KEY, status TEXT, meta TEXT,
            fingerprint TEXT, summary TEXT, sources TEXT);
        CREATE INDEX IF NOT EXISTS arc_status ON arcs(status);
        CREATE TABLE IF NOT EXISTS events(epoch TEXT, member TEXT, pos INTEGER, body TEXT,
            PRIMARY KEY(epoch,member,pos));
        CREATE TABLE IF NOT EXISTS activity(epoch TEXT, member TEXT, instant REAL, ts TEXT, pos INTEGER,
            PRIMARY KEY(epoch,member));
    ''')
    if get(db, 'version') is None:
        put(db, 'version', VERSION)
        put(db, 'store', str(store))
        put(db, 'epoch', uuid.uuid4().hex)
        put(db, 'generation', 0)
        db.commit()
    if get(db, 'version') != VERSION or get(db, 'store') != str(store):
        raise ValueError('incompatible coordination cache')


def arc_metadata(db, store, name, counts):
    path = store / ARC_ROOT / name / '_meta.json'
    sig = fingerprint(path)
    old = db.execute('SELECT * FROM arcs WHERE name=?', (name,)).fetchone()
    if old and json.loads(old['fingerprint']) == sig:
        return old
    meta = None
    if sig:
        try:
            data = path.read_bytes()
            counts['source_opens'] += 1
            counts['source_bytes'] += len(data)
            meta = json.loads(data)
            if not isinstance(meta, dict):
                raise ValueError('arc metadata must be an object')
            for field in ('slug', 'title', 'status', 'project', 'opened', 'closed_at'):
                if meta.get(field) is not None and not isinstance(meta[field], str):
                    raise ValueError(f'{field} must be a string')
            members = meta.get('members')
            if members is not None and (not isinstance(members, list) or any(not isinstance(member, str) for member in members)):
                raise ValueError('members must be a string list')
        except (OSError, ValueError):
            meta = None
    status = meta.get('status') if meta else 'invalid'
    if status not in {'active', 'closed', 'archived'}:
        status = 'invalid'
    counts_by_status = get(db, 'arc_counts', {})
    if old:
        counts_by_status[old['status']] = counts_by_status.get(old['status'], 0) - 1
    counts_by_status[status] = counts_by_status.get(status, 0) + 1
    put(db, 'arc_counts', counts_by_status)
    if status == 'archived' or (old and old['status'] == 'archived'):
        put(db, 'archive_dirty', True)
    db.execute('INSERT OR REPLACE INTO arcs VALUES (?,?,?,?,?,?)',
               (name, status, json.dumps(meta), json.dumps(sig), None, None))
    return db.execute('SELECT * FROM arcs WHERE name=?', (name,)).fetchone()


def reconcile(db, store, counts):
    root = store / ARC_ROOT
    if fingerprint(store / '_coordination/display-archive.json') != get(db, 'archive_fingerprint'):
        put(db, 'archive_pending', True)
    sweep = get(db, 'sweep')
    if not sweep:
        scan = {'locator': ARC_ROOT, 'read_status': 'absent', 'error': None}
        try:
            names = sorted(p.name for p in root.iterdir()
                           if p.is_dir() and not p.name.startswith(('.', '_')))
            counts['discoveries'] += 1
            scan['read_status'] = 'ok'
        except FileNotFoundError:
            names = []
        except OSError as exc:
            scan.update(read_status='error', error=str(exc))
            put(db, 'scan', scan)
            return
        sweep = {'names': names, 'position': 0, 'started_at': stamp(), 'scan': scan}
    names, position = sweep['names'], sweep['position']
    for name in names[position:position + META_BATCH]:
        arc_metadata(db, store, name, counts)
    sweep['position'] = min(position + META_BATCH, len(names))
    if sweep['position'] == len(names):
        present = set(names)
        for row in db.execute('SELECT name,status FROM arcs').fetchall():
            if row['name'] not in present:
                db.execute('DELETE FROM arcs WHERE name=?', (row['name'],))
                counts_by_status = get(db, 'arc_counts', {})
                counts_by_status[row['status']] -= 1
                put(db, 'arc_counts', counts_by_status)
                if row['status'] == 'archived':
                    put(db, 'archive_dirty', True)
        put(db, 'scan', sweep['scan'])
        put(db, 'reconciled_at', stamp())
        put(db, 'reconcile_due', time.time() + RECONCILE_SECONDS)
        put(db, 'sweep', None)
        if get(db, 'archive_dirty', True):
            catalog = [listing(row['name'], json.loads(row['meta'])) for row in db.execute("SELECT name,meta FROM arcs WHERE status='archived' ORDER BY name")]
            identity = hashlib.sha256(json.dumps(catalog, sort_keys=True).encode()).hexdigest()
            put(db, 'archive_catalog', {'store': str(store), 'identity': identity, 'arcs': catalog})
            put(db, 'archive_identity', identity)
            put(db, 'archive_pending', True)
            put(db, 'archive_dirty', False)
    else:
        put(db, 'sweep', sweep)


def request_selection(store, selected):
    if not selected:
        return
    root = store / '_coordination/display-requests'
    root.mkdir(parents=True, exist_ok=True)
    try:
        (root / selected).touch(exist_ok=False)
    except FileExistsError:
        pass


def pending_selections(store):
    root = store / '_coordination/display-requests'
    if not root.is_dir():
        return []
    rows = []
    for path in root.iterdir():
        try:
            if path.is_file() and not path.name.startswith(('.', '_')):
                rows.append((path.stat().st_mtime_ns, path.name))
        except FileNotFoundError:
            pass
    return [name for _, name in sorted(rows)[:SELECTION_BATCH]]


def listing(name, meta):
    return {'Slug': name, 'Title': meta.get('title', ''), 'Status': meta['status'],
            'Project': meta.get('project', ''), 'Members': [m for m in (meta.get('members') or []) if isinstance(m, str)],
            'Opened': meta.get('opened', ''), 'ClosedAt': meta.get('closed_at', '')}


def publish(store, result, filename='display.json'):
    path = store / '_coordination' / filename
    if result.get('coverage', {}).get('state') == 'catching-up' and path.is_file():
        try:
            previous = json.loads(path.read_text())
            if previous.get('epoch') != result['epoch'] and previous.get('store') == str(store):
                previous['coverage']['state'] = 'rebuilding'
                previous['next_update'] = result['next_update']
                result = previous
        except (OSError, ValueError):
            pass
    tmp = path.with_suffix('.json.tmp')
    with tmp.open('w', encoding='utf-8') as stream:
        json.dump(result, stream, ensure_ascii=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)


def reduce_arc(db, store, row, counts):
    name = row['name']
    meta = json.loads(row['meta'])
    ledger = store / ARC_ROOT / name / 'coordination.md'
    attempt = store / '_coordination/reconciliation' / name / 'streams.json'
    sig = [fingerprint(ledger), fingerprint(attempt)]
    if row['summary'] and json.loads(row['sources']) == sig:
        return
    reduction = ArcReduction(store)
    if meta and sig[0]:
        # The reducer owns parsing and diagnostics; counting its input sizes does
        # not require a second read of the files.
        counts['source_opens'] += 1 + int(sig[1] is not None and meta.get('status') == 'active')
        counts['source_bytes'] += sig[0][2] + (sig[1][2] if sig[1] and meta.get('status') == 'active' else 0)
        reduction.project({'arc': name, 'status': meta.get('status'),
                           'ledger_path': ledger}, meta.get('status') == 'active')
    summary = {'streams': reduction.streams, 'buckets': reduction.buckets,
               'active': reduction.active, 'candidates': reduction.candidates,
               'scan': reduction.scan}
    db.execute('UPDATE arcs SET summary=?, sources=? WHERE name=?',
               (json.dumps(summary), json.dumps(sig), name))


def event_instant(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            return None
        return parsed.timestamp()
    except (ValueError, OverflowError):
        return None


def ingest(db, epoch, pos, data, journal):
    try:
        event = json.loads(data)
        if not isinstance(event, dict) or not isinstance(event.get('event'), str):
            raise ValueError('expected event object')
        string_fields = ('event_id', 'ts', 'event', 'actor_instance', 'target_instance', 'slug',
                         'session_type', 'initiator', 'request_id', 'registration_id', 'reason',
                         'modal_signature', 'step_id', 'step_label')
        for field in string_fields:
            if event.get(field) is not None and not isinstance(event[field], str):
                raise ValueError(f'{field} must be a string or null')
        if event.get('option') is not None and (type(event['option']) is not int or not -(2**63) <= event['option'] < 2**63):
            raise ValueError('option must be a signed 64-bit integer or null')
        links = event.get('links')
        if links is None:
            links = {}
        if not isinstance(links, dict) or any(not isinstance(v, str) for v in links.values()):
            raise ValueError('links must map strings to strings')
        members = {value for value in (event.get('slug'), links.get('work_item')) if isinstance(value, str) and value}
        event['links'] = links
        body = json.dumps(event, allow_nan=False)
        instant = event_instant(event.get('ts'))
        for member in members:
            db.execute('INSERT OR REPLACE INTO events VALUES (?,?,?,?)', (epoch, member, pos, body))
            db.execute('DELETE FROM events WHERE epoch=? AND member=? AND pos NOT IN '
                       '(SELECT pos FROM events WHERE epoch=? AND member=? ORDER BY pos DESC LIMIT 8)',
                       (epoch, member, epoch, member))
            if instant is not None:
                db.execute('INSERT INTO activity VALUES (?,?,?,?,?) ON CONFLICT(epoch,member) '
                           'DO UPDATE SET instant=excluded.instant, ts=excluded.ts, pos=excluded.pos '
                           'WHERE excluded.instant>activity.instant', (epoch, member, instant, event['ts'], pos))
    except (ValueError, TypeError, UnicodeError, RecursionError, OverflowError) as exc:
        journal['malformed_rows'] += 1
        journal['last_error'] = f'byte {pos}: {exc}'


def catch_up(db, store, counts, budget):
    path = store / '_sessions/events.jsonl'
    sig = fingerprint(path)
    journal = get(db, 'journal', {})
    old = journal.get('identity')
    # Same-size rewrites are observable without hashing the prefix. Edits to an
    # already consumed prefix followed by growth require explicit --rebuild.
    reset = not journal or (sig is None) != (old is None) or (sig and old and (
        sig[:2] != old[:2] or sig[2] < journal['read_offset'] or
        (sig[2] == old[2] and sig[3:] != old[3:])))
    if reset:
        abandoned = journal.get('epoch')
        if abandoned and abandoned != get(db, 'published_journal'):
            put(db, 'garbage_epochs', list(dict.fromkeys(get(db, 'garbage_epochs', []) + [abandoned])))
        journal = {'epoch': uuid.uuid4().hex, 'identity': sig, 'offset': 0, 'read_offset': 0,
                   'pending': '', 'oversized': False, 'malformed_rows': 0, 'last_error': None}
    if sig:
        with path.open('rb') as stream:
            # Only open the journal when bytes remain. The outer caller avoids
            # this branch entirely for an unchanged, fully consumed source.
            actual = os.fstat(stream.fileno())
            if [actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns, actual.st_ctime_ns] != sig:
                raise OSError('journal replaced during observation; retrying')
            stream.seek(journal['read_offset'])
            data = stream.read(budget)
            counts['journal_opens'] += 1
            counts['journal_bytes'] += len(data)
        pending = base64.b64decode(journal['pending'])
        start = journal['offset']
        consumed = 0
        for chunk in data.splitlines(keepends=True):
            consumed += len(chunk)
            if not journal['oversized']:
                pending += chunk
                if len(pending) > MAX_ROW:
                    pending = b''
                    journal['oversized'] = True
            if chunk.endswith(b'\n'):
                if journal['oversized']:
                    journal['malformed_rows'] += 1
                    journal['last_error'] = f'byte {start}: row exceeds {MAX_ROW} bytes'
                elif pending.strip():
                    ingest(db, journal['epoch'], start, pending, journal)
                start = journal['read_offset'] + consumed
                journal['offset'] = start
                pending = b''
                journal['oversized'] = False
        journal['read_offset'] += len(data)
        journal['pending'] = base64.b64encode(pending).decode()
    journal['identity'] = sig
    journal['size'] = sig[2] if sig else 0
    journal['behind_bytes'] = journal['size'] - journal['offset']
    journal['observed_at'] = stamp()
    if journal['behind_bytes'] == 0:
        published = get(db, 'published_journal')
        if published and published != journal['epoch']:
            put(db, 'garbage_epochs', list(dict.fromkeys(get(db, 'garbage_epochs', []) + [published])))
        put(db, 'published_journal', journal['epoch'])
    put(db, 'journal', journal)


def journal_update(db, store, counts, budget):
    journal = get(db, 'journal')
    sig = fingerprint(store / '_sessions/events.jsonl')
    if journal and sig == journal.get('identity') and journal['read_offset'] == (sig[2] if sig else 0):
        journal['observed_at'] = stamp()
        put(db, 'journal', journal)
    else:
        catch_up(db, store, counts, budget)


def maintenance(store, selected='', force=False, rebuild=False, budget=BATCH_BYTES, lease_fd=None, ceiling=1):
    store = store.resolve()
    cache = store / '_coordination' / 'display.sqlite3'
    cache.parent.mkdir(parents=True, exist_ok=True)
    if selected:
        try:
            exported = json.loads((store / '_coordination/display.json').read_text())
            needed = not exported.get('details', {}).get(selected, {}).get('loaded') or time.time() >= exported.get('next_update', 0)
        except (OSError, ValueError):
            needed = True
        if needed or force:
            request_selection(store, selected)
    with (os.fdopen(os.dup(lease_fd), 'a+b') if lease_fd is not None else
          (cache.parent / 'display.lock').open('a+b')) as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        db = None
        try:
            try:
                db = connect(cache, True)
                if rebuild:
                    raise ValueError('explicit rebuild')
                initialize(db, store)
                expected = {'arcs': {'name','status','meta','fingerprint','summary','sources'},
                            'events': {'epoch','member','pos','body'},
                            'activity': {'epoch','member','instant','ts','pos'}}
                for table, columns in expected.items():
                    if {row[1] for row in db.execute(f'PRAGMA table_info({table})')} != columns:
                        raise ValueError('incompatible coordination cache table ' + table)
            except (sqlite3.DatabaseError, ValueError) as exc:
                if isinstance(exc, sqlite3.OperationalError) and ("locked" in str(exc) or "busy" in str(exc)):
                    raise
                if db:
                    db.close()
                for suffix in ('', '-wal', '-shm', '-journal'):
                    Path(str(cache)+suffix).unlink(missing_ok=True)
                db = connect(cache, True)
                initialize(db, store)
            db.execute('PRAGMA journal_mode=WAL')
            now = time.time()
            requests = pending_selections(store)
            selection_due = bool(requests)
            if not force and not rebuild and now < get(db, 'update_due', 0) and not selection_due and (store / '_coordination/display.json').is_file():
                return False
            db.execute('BEGIN IMMEDIATE')
            counts = {'maintenance': 1, 'discoveries': 0, 'source_opens': 0, 'source_bytes': 0,
                      'journal_opens': 0, 'journal_bytes': 0}
            full_update = force or rebuild or now >= get(db, 'update_due', 0)
            if full_update:
                if force or get(db, 'sweep') or now >= get(db, 'reconcile_due', 0):
                    reconcile(db, store, counts)
                for row in db.execute("SELECT name FROM arcs WHERE status='active'").fetchall():
                    arc_metadata(db, store, row['name'], counts)
                journal_update(db, store, counts, budget)
                journal = get(db, 'journal', {})
                catching_up = journal.get('read_offset', 0) < journal.get('size', 0) or get(db, 'sweep')
                put(db, 'update_due', now + (0.25 if catching_up else UPDATE_SECONDS))
                put(db, 'observed_at', stamp())
            selected_cache = get(db, 'selected_cache', {})
            for name in requests:
                if (store / ARC_ROOT / name).is_dir():
                    arc_metadata(db, store, name, counts)
                selected_cache[name] = now
            # Recently requested detail is bounded independently of historical
            # identity listings. Outstanding requests are drained oldest first.
            selected_cache = dict(sorted(selected_cache.items(), key=lambda pair: pair[1], reverse=True)[:64])
            put(db, 'selected_cache', selected_cache)
            for row in db.execute("SELECT * FROM arcs WHERE status='active'").fetchall():
                reduce_arc(db, store, row, counts)
            for name in requests:
                row = db.execute('SELECT * FROM arcs WHERE name=?', (name,)).fetchone()
                if row:
                    reduce_arc(db, store, row, counts)
            garbage = get(db, 'garbage_epochs', [])
            if garbage:
                old_epoch = garbage[0]
                for table in ('events', 'activity'):
                    db.execute(f'DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} WHERE epoch=? LIMIT 256)', (old_epoch,))
                if not any(db.execute(f'SELECT 1 FROM {table} WHERE epoch=? LIMIT 1', (old_epoch,)).fetchone() for table in ('events', 'activity')):
                    put(db, 'garbage_epochs', garbage[1:])
            put(db, 'ceiling', ceiling)
            put(db, 'generation', get(db, 'generation', 0) + 1)
            total = get(db, 'work_counts', {key: 0 for key in counts})
            put(db, 'work_counts', {key: total[key] + count for key, count in counts.items()})
            put(db, 'last_work', counts)
            db.commit()
            if get(db, 'archive_pending') and get(db, 'archive_catalog') is not None:
                publish(store, get(db, 'archive_catalog'), 'display-archive.json')
                put(db, 'archive_pending', False)
                put(db, 'archive_fingerprint', fingerprint(store / '_coordination/display-archive.json'))
                db.commit()
            result = snapshot(store, ceiling=ceiling)
            publish(store, result)
            for name in requests:
                (store / '_coordination/display-requests' / name).unlink(missing_ok=True)
            return True
        finally:
            if db:
                db.close()


def snapshot(store, selected='', ceiling=None):
    store = store.resolve()
    cache = store / '_coordination/display.sqlite3'
    with contextlib.closing(connect(cache)) as db:
        db.execute('BEGIN')
        if get(db, 'version') != VERSION or get(db, 'store') != str(store):
            raise ValueError('incompatible coordination cache')
        ceiling = get(db, 'ceiling', 1) if ceiling is None else ceiling
        reduction = ArcReduction(store)
        scan = get(db, 'scan', {'locator': ARC_ROOT, 'read_status': 'absent', 'error': None})
        scan.update(arcs_scanned=0, arcs_active=0, ledgers_read=0, streams_read=0)
        arcs, listings, selected_members = [], [], []
        skipped = 0
        epoch = get(db, 'published_journal', '')
        activity = {}
        details = {}
        selected_cache = get(db, 'selected_cache', {})
        if selected:
            selected_cache[selected] = time.time()
        visible = {row['name']: row for row in db.execute("SELECT * FROM arcs WHERE status IN ('active','closed','invalid')")}
        for name in selected_cache:
            row = db.execute('SELECT * FROM arcs WHERE name=?', (name,)).fetchone()
            if row:
                visible[name] = row
        scan['arcs_scanned'] = sum(get(db, 'arc_counts', {}).values())
        for row in sorted(visible.values(), key=lambda r: r['name']):
            name, meta = row['name'], json.loads(row['meta'])
            if meta is None:
                skipped += 1
                reduction.buckets['reconcile'].append(make_row(
                    'reconcile', 'work-index', 'coordination-arc-record-invalid',
                    f'{name}: arc record lacks readable metadata', {'arc': name, 'metadata': None},
                    f'{ARC_ROOT}/{name}/_meta.json', name, 'reconcile.work.action-evidence-gap'))
                continue
            arcs.append({'arc': name, 'status': meta.get('status')})
            members = [m for m in (meta.get('members') or []) if isinstance(m, str)]
            if name == selected:
                selected_members = members
            if meta.get('status') in {'active', 'closed', 'archived'}:
                listings.append(listing(name, meta))
            else:
                skipped += 1
            if meta.get('status') == 'active':
                scan['arcs_active'] += 1
            if row['summary'] and (meta.get('status') == 'active' or name in selected_cache):
                summary = json.loads(row['summary'])
                reduction.streams.extend(summary['streams'])
                if meta.get('status') == 'active':
                    reduction.active.extend(summary['active'])
                    reduction.candidates.extend(summary['candidates'])
                    for key in reduction.buckets:
                        reduction.buckets[key].extend(summary['buckets'][key])
                    for key in ('ledgers_read', 'streams_read'):
                        scan[key] += summary['scan'][key]
            if meta.get('status') == 'active' or name in selected_cache:
                recent = {}
                for member in members:
                    for event in db.execute('SELECT pos,body FROM events WHERE epoch=? AND member=? ORDER BY pos DESC LIMIT 8', (epoch, member)):
                        recent[event['pos']] = json.loads(event['body'])
                detail_errors = [r['observed_facts'].get('error', '') for r in json.loads(row['summary'])['buckets']['reconcile'] if r['kind'] == 'coordination-ledger-invalid'] if row['summary'] else []
                details[name] = {'events': [recent[pos] for pos in sorted(recent)[-8:]], 'loaded': bool(row['summary']), 'error': '; '.join(detail_errors), 'source_fingerprints': json.loads(row['sources']) if row['sources'] else None}
            if members and meta.get('status') == 'active':
                latest = [db.execute('SELECT instant,ts,pos FROM activity WHERE epoch=? AND member=?',
                                     (epoch, m)).fetchone() for m in members]
                latest = [r for r in latest if r]
                if latest:
                    activity[name] = max(latest, key=lambda r: (r['instant'], -r['pos']))['ts']
        for name in selected_cache:
            if not any(arc['arc'] == name for arc in arcs):
                details[name] = {'events': [], 'loaded': True}
        events = {}
        for member in selected_members:
            for row in db.execute('SELECT pos,body FROM events WHERE epoch=? AND member=? ORDER BY pos DESC LIMIT 8',
                                  (epoch, member)):
                events[row['pos']] = json.loads(row['body'])
        capacity = reduction.dispatch(ceiling)
        for rows in reduction.buckets.values():
            rows.sort(key=lambda r: (r['source_id'], r['id']))
        journal = get(db, 'journal', {})
        coverage = {'mode': 'periodic-reconciliation', 'reconciled_at': get(db, 'reconciled_at'),
                    'observed_at': get(db, 'observed_at'), 'journal': {k: v for k, v in journal.items() if k not in {'pending'}},
                    'reconcile_due': get(db, 'reconcile_due', 0),
                    'state': 'ready', 'limitations': 'Direct metadata edits converge at reconciliation; journal prefix edits with growth require explicit rebuild. Display is not dispatch or code-freshness evidence.'}
        sweep = get(db, 'sweep')
        coverage['metadata_sweep'] = {k: v for k, v in sweep.items() if k != 'names'} if sweep else None
        if sweep or journal.get('behind_bytes', 0):
            coverage['state'] = 'catching-up'
        elif journal.get('malformed_rows', 0) or scan.get('read_status') == 'error' or reduction.buckets['reconcile']:
            coverage['state'] = 'degraded'
        elif time.time() > get(db, 'update_due', 0) + UPDATE_SECONDS:
            coverage['state'] = 'stale'
        return {'schema_version': '1', 'reducer_version': VERSION, 'store': str(store),
                'epoch': get(db, 'epoch'), 'generation': get(db, 'generation'), 'coverage': coverage,
                'next_update': get(db, 'update_due', 0), 'details': details,
                'archive_identity': get(db, 'archive_identity', ''),
                'archive_state': 'loading' if get(db, 'archive_pending') else 'ready',
                'observed_at': get(db, 'observed_at'), 'arcs': listings, 'skipped': skipped,
                'coordination_arcs': arcs, 'coordination_streams': reduction.streams,
                'buckets': reduction.buckets, 'activity': activity,
                'selected': selected, 'events': [events[p] for p in sorted(events)[-8:]],
                'coordination_dispatch': {'concurrency_ceiling': ceiling, 'active_attempts': len(reduction.active),
                    'capacity': capacity, 'ready_total': len(reduction.candidates),
                    'eager_dispatch_count': min(capacity, len(reduction.candidates)),
                    'ledger_scan': {**scan, 'reason': dispatch_reason(scan, len(reduction.candidates))}},
                'work_counts': get(db, 'work_counts', {}), 'last_work': get(db, 'last_work', {})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kdir', required=True)
    parser.add_argument('--arc', default='')
    parser.add_argument('--refresh', action='store_true', help='nonblocking, coalesced maintenance before reading')
    parser.add_argument('--reconcile', action='store_true', help='explicit metadata reconciliation and one bounded catch-up batch')
    parser.add_argument('--rebuild', action='store_true', help='discard derived state and start bounded recovery')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--lease-fd', type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    store = Path(args.kdir).resolve()
    if not store.is_dir() or (args.arc and (Path(args.arc).name != args.arc or args.arc in {'.', '..'})):
        parser.error('existing store and plain arc identity required')
    error = None
    if args.refresh or args.reconcile or args.rebuild:
        try:
            ceiling = max(1, int(os.environ.get('COORDINATION_MAX_CONCURRENCY', '1')))
            maintenance(store, args.arc, args.reconcile, args.rebuild, lease_fd=args.lease_fd, ceiling=ceiling)
        except (OSError, sqlite3.Error, ValueError) as exc:
            error = str(exc)
    try:
        ceiling = max(1, int(os.environ.get('COORDINATION_MAX_CONCURRENCY', '1')))
        result = json.loads((store / '_coordination/display.json').read_text())
        if result.get('store') != str(store) or result.get('reducer_version') != VERSION:
            raise ValueError('incompatible coordination snapshot')
        result['selected'] = args.arc
        result['events'] = result.get('details', {}).get(args.arc, {}).get('events', [])
        if error:
            result['coverage'].update(state='stale', error=error)
    except (OSError, sqlite3.Error, ValueError) as exc:
        result = {'schema_version': '1', 'store': str(store), 'generation': 0,
                  'coverage': {'state': 'loading', 'error': error or str(exc)}}
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    if error:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
