#!/usr/bin/env python3
import concurrent.futures
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import coordinate_projection as p

LEDGER = '| Stream | Step | Depends on | Tree | Status | Verdict |\n|---|---|---|---|---|---|\n'


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Path(self.tmp.name).resolve() / 'store'
        self.store.mkdir()
        self.data = Path(self.tmp.name) / 'data'
        (self.data / 'config').mkdir(parents=True)
        (self.data / 'config/settings.json').write_text('{"version":1,"coordination":{"max_concurrency":2}}')
        self.env = {**os.environ, 'LORE_DATA_DIR': str(self.data), 'COORDINATION_MAX_CONCURRENCY': '2'}

    def arc(self, name='a', members=None, status='active', rows=None, opened=None, closed_at=None):
        home = self.store / p.ARC_ROOT / name
        home.mkdir(parents=True, exist_ok=True)
        meta = {'schema_version': 1, 'slug': name, 'title': name, 'status': status,
                'members': members or [], 'opened': p.stamp() if opened is None else opened}
        if closed_at is not None:
            meta['closed_at'] = closed_at
        (home / '_meta.json').write_text(json.dumps(meta))
        if rows is not None:
            (home / 'coordination.md').write_text(LEDGER + rows)
        return home

    def append(self, events):
        path = self.store / '_sessions/events.jsonl'
        path.parent.mkdir(exist_ok=True)
        with path.open('ab') as out:
            for event in events:
                out.write(json.dumps(event).encode() + b'\n')
        return path

    def refresh(self, arc='a', **kwargs):
        p.maintenance(self.store, arc, force=True, ceiling=2, **kwargs)
        return p.snapshot(self.store, arc)

    def full(self):
        proc = subprocess.run(['bash', str(ROOT/'scripts/coordinate-status.sh'), '--kdir', str(self.store), '--json'],
                              env=self.env, capture_output=True, text=True, check=True)
        return json.loads(proc.stdout)

    def assertParity(self, arc='a'):
        narrow, full = self.refresh(arc), self.full()
        self.assertEqual(narrow['coordination_arcs'], [r for r in full['coordination_arcs'] if r['status']!='archived' or r['arc']==arc])
        expected = [r for r in full['coordination_streams'] if r['arc_status']=='active' or r['arc']==arc]
        self.assertEqual([r for r in narrow['coordination_streams'] if r['arc_status']=='active' or r['arc']==arc], expected)
        self.assertEqual(narrow['coordination_dispatch'], full['coordination_dispatch'])
        for key in narrow['buckets']:
            rows = [r for r in full['buckets'][key] if r['kind'].startswith('coordination-') or r['observed_facts'].get('arc')]
            self.assertEqual(narrow['buckets'][key], rows)
        self.assertNotIn('work_evidence', narrow)
        return narrow

    def test_full_status_parity_and_capacity(self):
        self.arc(rows='| 1 | [[work:x]] | — | writer | pending | — |\n| 2 | child | 1 | read-only | pending | — |\n')
        self.arc('offscreen', rows='| 1 | busy | — | writer | in-flight | — |\n')
        self.arc('closed', status='closed', rows='| 1 | done | — | writer | done | full |\n')
        self.assertParity('closed')
        self.arc('offscreen', rows='| 1 | done | — | writer | done | partial |\n| 2 | child | 1 | writer | pending | — |\n')
        self.assertParity()
        self.arc(rows='| 1 | invalid | 2 | writer | pending | — |\n| 2 | cycle | 1 | writer | pending | — |\n')
        self.assertParity()

    def test_empty_absent_and_malformed_parity(self):
        self.assertParity('')
        self.arc(rows='')
        self.assertParity()
        home = self.arc('bad', rows='| no | fewer | cells |\n')
        self.assertParity()
        (home / '_meta.json').write_text('{broken')
        self.assertParity()

    def test_attempt_ownership_and_settings(self):
        self.arc(rows='| 1 | ready | — | writer | pending | — |\n')
        path = self.store / '_coordination/reconciliation/a/streams.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({'streams':[{'stream_id':'1','attempts':[{'status':'allocated'}]}]}))
        snap = self.assertParity()
        self.assertEqual(snap['coordination_dispatch']['active_attempts'], 1)
        path.write_text(json.dumps({'streams':[{'stream_id':'1','attempts':[{'status':'coord_report_accepted'}]}]}))
        self.assertParity()
        p.maintenance(self.store, force=True, ceiling=7)
        self.assertEqual(p.snapshot(self.store)['coordination_dispatch']['concurrency_ceiling'], 7)

    def test_member_top_eight_dual_key_and_timestamp_maximum(self):
        self.arc(members=['x', 'y'], rows='')
        events = [{'event':'spawned','slug':'x','links':{'work_item':'y'},'ts':'2099-01-01T00:00:00Z','n':0}]
        events += [{'event':'closed','slug':'x','n':i,'ts':'2026-01-01T00:00:00Z'} for i in range(1,10001)]
        self.append(events)
        for _ in range(30):
            snap = self.refresh()
            if snap['coverage']['journal']['behind_bytes']==0: break
        self.assertEqual([e['n'] for e in snap['events']], list(range(9993,10001)))
        self.assertEqual(snap['activity']['a'], '2099-01-01T00:00:00Z')
        db = p.connect(self.store/'_coordination/display.sqlite3')
        self.assertLessEqual(db.execute('SELECT count(*) FROM events').fetchone()[0], 16)
        db.close()
        self.arc('new', members=['y'], rows='')
        snap = self.refresh('new')
        self.assertEqual([e['n'] for e in snap['events']], [0])

    def test_partial_malformed_oversized_and_restart(self):
        self.arc(members=['x'], rows='')
        path = self.append([{'event':'spawned','slug':'x','n':1}])
        with path.open('ab') as out:
            out.write(b'{invalid}\n' + b'x'*(p.MAX_ROW+100) + b'\n' + b'{"event":"closed","slug":"x","n":2')
        positions = []
        for _ in range(20):
            snap = self.refresh(budget=65536)
            positions.append(snap['coverage']['journal']['offset'])
            self.assertLessEqual(snap['last_work']['journal_bytes'], 65536)
        journal = snap['coverage']['journal']
        self.assertEqual(journal['malformed_rows'], 2)
        self.assertLess(journal['offset'], path.stat().st_size)
        with path.open('ab') as out: out.write(b'}\n')
        result = subprocess.run([sys.executable, str(ROOT/'scripts/coordinate_projection.py'), '--kdir', str(self.store), '--arc','a','--reconcile'], env=self.env, text=True, capture_output=True, check=True)
        snap = json.loads(result.stdout)
        self.assertEqual([e['n'] for e in snap['events']], [1,2])
        self.assertEqual(snap['coverage']['state'], 'degraded')
        self.assertEqual(positions, sorted(positions))

    def test_replacement_truncation_and_missing_journal(self):
        self.arc(members=['x'], rows='')
        path = self.append([{'event':'spawned','slug':'x','n':1,'ts':'2099-01-01T00:00:00Z'}])
        self.refresh()
        replacement = path.with_suffix('.new')
        replacement.write_text(json.dumps({'event':'closed','slug':'x','n':2})+'\n')
        replacement.replace(path)
        snap = self.refresh(budget=8)
        self.assertEqual(snap['events'][0]['n'], 1)
        for _ in range(20):
            snap = self.refresh(budget=8)
            if not snap['coverage']['journal']['behind_bytes']: break
        self.assertEqual([e['n'] for e in snap['events']], [2])
        self.assertNotIn('a', snap['activity'])
        path.write_bytes(b'')
        self.assertEqual(self.refresh()['events'], [])
        path.unlink()
        self.assertEqual(self.refresh()['coverage']['journal']['offset'], 0)

    def test_stat_open_swap_rolls_back(self):
        self.arc(members=['x'], rows='')
        path = self.append([{'event':'spawned','slug':'x'}])
        self.refresh()
        self.append([{'event':'closed','slug':'x'}])
        original = Path.open
        changed = False
        def swap(target, *args, **kwargs):
            nonlocal changed
            if target == path and args and args[0]=='rb' and not changed:
                changed = True
                replacement = path.with_suffix('.swap')
                replacement.write_text('{"event":"closed","slug":"x"}\n')
                replacement.replace(path)
            return original(target, *args, **kwargs)
        before = p.snapshot(self.store)['generation']
        with patch.object(Path, 'open', swap):
            with self.assertRaises(OSError): self.refresh()
        self.assertEqual(p.snapshot(self.store)['generation'], before)
        self.assertEqual(self.refresh()['events'][0]['event'], 'closed')

    def test_cache_recovery_and_rebuild_preserves_export(self):
        self.arc(rows='')
        self.refresh()
        cache = self.store/'_coordination/display.sqlite3'
        cache.unlink()
        self.refresh()
        self.assertGreater(p.snapshot(self.store)['generation'], 0)
        for suffix in ('-wal','-shm'): Path(str(cache)+suffix).unlink(missing_ok=True)
        cache.write_bytes(b'damaged')
        self.refresh()
        db = p.connect(cache, True)
        p.put(db, 'version', -1); db.commit(); db.close()
        self.refresh()
        self.assertEqual(p.snapshot(self.store)['schema_version'], '1')
        old = json.loads((self.store/'_coordination/display.json').read_text())
        self.append([{'event':'closed','slug':'x','pad':'x'*1000} for _ in range(300)])
        self.refresh(rebuild=True, budget=100)
        exported = json.loads((self.store/'_coordination/display.json').read_text())
        self.assertEqual(exported['epoch'], old['epoch'])
        self.assertEqual(exported['coverage']['state'], 'rebuilding')

    def test_resumable_metadata_and_direct_resurrection(self):
        for i in range(p.META_BATCH*2+1): self.arc(str(i), status='archived', rows='')
        first = self.refresh('')
        self.assertEqual(first['coordination_dispatch']['ledger_scan']['arcs_scanned'], p.META_BATCH)
        self.assertIsNotNone(first['coverage']['metadata_sweep'])
        self.refresh(''); final = self.refresh('')
        self.assertEqual(final['coordination_dispatch']['ledger_scan']['arcs_scanned'], p.META_BATCH*2+1)
        self.assertEqual(final['arcs'], [])
        self.arc('0', status='active', rows='| 1 | ready | — | writer | pending | — |\n')
        for _ in range(3): snap = self.refresh('')
        self.assertEqual(snap['coordination_dispatch']['ready_total'], 1)

    def test_warm_history_growth_opens_no_history(self):
        self.arc(rows='')
        results = []
        for scale in (1,10,100):
            for rel in ('_packets/packets.jsonl','_scorecards/rows.jsonl','_work/_archive/old/evidence.jsonl'):
                path = self.store/rel; path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text('{}\n' * (1000*scale))
            journal = self.store / '_sessions/events.jsonl'
            journal.parent.mkdir(exist_ok=True)
            journal.write_text('{"event":"closed","slug":"unrelated"}\n' * (1000*scale))
            while self.refresh()['coverage']['journal']['behind_bytes']:
                pass
            opened = []
            original = Path.open
            def traced(path, *args, **kwargs):
                if str(path).startswith(str(self.store)) and '_coordination/display' not in str(path):
                    opened.append(str(path.relative_to(self.store)))
                return original(path, *args, **kwargs)
            with patch.object(Path, 'open', traced):
                for _ in range(20): p.snapshot(self.store, 'a')
                p.maintenance(self.store)
            self.assertFalse(opened, opened)
            warm = self.refresh()
            self.assertEqual(warm['last_work']['source_bytes'], 0)
            self.assertEqual(warm['last_work']['journal_bytes'], 0)
            results.append({'scale':scale, 'display_source_opens':len(opened), 'warm_source_bytes':warm['last_work']['source_bytes']})
        print('HISTORY_SCALE '+json.dumps(results))

    def test_crashed_ingestion_commits_neither_cursor_nor_rows(self):
        self.arc(members=['x'], rows='')
        self.append([{'event':'spawned','slug':'x','n':1}]); before = self.refresh()
        self.append([{'event':'closed','slug':'x','n':2}])
        code = "import os,sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); import coordinate_projection as p; original=p.ingest\ndef crash(*args):\n original(*args); os._exit(9)\np.ingest=crash; p.maintenance(Path(sys.argv[2]),force=True)"
        proc = subprocess.run([sys.executable,'-c',code,str(ROOT/'scripts'),str(self.store)])
        self.assertEqual(proc.returncode,9)
        unchanged = p.snapshot(self.store,'a')
        self.assertEqual(unchanged['generation'],before['generation'])
        self.assertEqual(unchanged['coverage']['journal']['offset'],before['coverage']['journal']['offset'])
        self.assertEqual([e['n'] for e in unchanged['events']],[1])
        self.assertEqual([e['n'] for e in self.refresh()['events']],[1,2])

    def test_typed_event_errors_are_isolated(self):
        self.arc(members=['x'], rows='')
        invalid = [{'event':'closed','slug':'x',key:value} for key,value in (
            ('spend',{'value':float('inf')}),('unknown',float('nan')),('ts',123),('event_id',[]),('option','one'),('option',True),('option',2**80),
            ('actor_instance',3),('request_id',{}),('session_type',4),('links',{'work_item':3}),('reason',False))]
        self.append(invalid + [{'event':'closed','slug':'x','ts':'2026-01-01T00:00:00Z'}])
        snap = self.refresh()
        self.assertEqual(len(snap['events']),1)
        self.assertEqual(snap['coverage']['journal']['malformed_rows'],len(invalid))
        self.assertEqual(snap['coverage']['state'],'degraded')
        self.assertIn('reason',snap['coverage']['journal']['last_error'])

    def test_archive_catalog_is_separate_and_warm_cpu_is_bounded(self):
        self.arc(rows='')
        measurements = []
        for size in (1,10,100):
            for i in range(size): self.arc('history-'+str(i),status='archived',rows='')
            self.refresh('')
            calls = 0
            original = json.loads
            def counted(*args,**kwargs):
                nonlocal calls
                calls += 1
                return original(*args,**kwargs)
            with patch.object(json,'loads',counted):
                snap = p.snapshot(self.store)
            exported = (self.store/'_coordination/display.json').stat().st_size
            self.assertEqual([a['Slug'] for a in snap['arcs']],['a'])
            catalog = original((self.store/'_coordination/display-archive.json').read_text())
            self.assertEqual(len(catalog['arcs']),size)
            measurements.append({'archived_arcs':size,'json_loads':calls,'export_bytes':exported})
        self.assertEqual(len({m['json_loads'] for m in measurements}),1)
        self.assertLess(max(m['export_bytes'] for m in measurements)-min(m['export_bytes'] for m in measurements),100)
        print('ARCHIVE_SCALE '+json.dumps(measurements))
        self.assertTrue(self.refresh('history-99')['details']['history-99']['loaded'])

    def test_archive_export_removal_and_corruption_repair(self):
        self.arc(rows=''); self.arc('history',status='archived',rows='')
        self.refresh('')
        path = self.store/'_coordination/display-archive.json'
        expected = json.loads(path.read_text())
        for action in ('remove','corrupt'):
            if action == 'remove': path.unlink()
            else: path.write_bytes(b'{broken')
            snap = self.refresh('')
            self.assertEqual(json.loads(path.read_text()),expected)
            self.assertEqual(snap['archive_state'],'ready')

    def test_many_consumer_cold_warm_and_busy(self):
        self.arc(rows='')
        results = []
        argv = [sys.executable,str(ROOT/'scripts/coordinate_projection.py'),'--kdir',str(self.store),'--refresh']
        for count in (1,5,20):
            cache = self.store/'_coordination/display.sqlite3'
            for suffix in ('','-wal','-shm'): Path(str(cache)+suffix).unlink(missing_ok=True)
            started = time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(count) as pool:
                out = list(pool.map(lambda _: subprocess.run(argv,env=self.env,text=True,capture_output=True,check=True), range(count)))
            elapsed = time.monotonic()-started
            snap = p.snapshot(self.store)
            self.assertEqual(snap['work_counts']['maintenance'], 1)
            self.assertEqual(snap['work_counts']['source_opens'], 2)
            before = snap['work_counts']
            with concurrent.futures.ThreadPoolExecutor(count) as pool:
                list(pool.map(lambda _: subprocess.run(argv,env=self.env,capture_output=True,check=True),range(count)))
            self.assertEqual(p.snapshot(self.store)['work_counts'], before)
            results.append({'consumers':count,'cold_python_processes':count,'elapsed_seconds':round(elapsed,4),**before})
        with (self.store/'_coordination/display.lock').open('a+b') as lease:
            fcntl.flock(lease,fcntl.LOCK_EX)
            self.assertFalse(p.maintenance(self.store,force=True))
            self.assertEqual(p.snapshot(self.store)['work_counts'], before)
        print('PYTHON_CONSUMERS '+json.dumps(results))

    def test_busy_writer_crash_and_distinct_selection_fairness(self):
        for i in range(20): self.arc(str(i), status='closed', members=[str(i)], rows='')
        self.refresh('')
        for i in range(20): p.request_selection(self.store,str(i))
        self.append([{'event':'closed','slug':str(i)} for i in range(20)])
        for _ in range(3): p.maintenance(self.store,force=True)
        exported = json.loads((self.store/'_coordination/display.json').read_text())
        self.assertEqual(len(exported['details']),20)
        self.assertTrue(all(v['loaded'] and len(v['events'])==1 for v in exported['details'].values()))
        before = p.snapshot(self.store)['generation']
        code = "import sys,sqlite3; d=sqlite3.connect(sys.argv[1]); d.execute('BEGIN IMMEDIATE'); d.execute(\"DELETE FROM arcs\"); print('locked',flush=True); sys.stdin.read()"
        child = subprocess.Popen([sys.executable,'-c',code,str(self.store/'_coordination/display.sqlite3')],stdout=subprocess.PIPE,stdin=subprocess.PIPE,text=True)
        self.assertEqual(child.stdout.readline().strip(),'locked')
        self.assertEqual(p.snapshot(self.store)['generation'],before)
        with self.assertRaises(sqlite3.OperationalError): p.maintenance(self.store,force=True)
        child.kill(); child.wait(); child.stdout.close(); child.stdin.close()
        self.assertEqual(len(self.refresh('')['arcs']),20)

    def days_ago(self, days):
        return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).isoformat().replace('+00:00', 'Z')

    def status_of(self, name):
        return json.loads((self.store / p.ARC_ROOT / name / '_meta.json').read_text())['status']

    def archive_log(self, refuse=''):
        log = Path(self.tmp.name) / 'archive.log'
        script = Path(self.tmp.name) / 'arc-archive.sh'
        script.write_text('printf "%s\\n" "$1" >> ' + str(log) + '\n'
                          'case "$1" in ' + (refuse or '__none__') + ') echo "[arc] Error: refused $1" >&2; exit 1 ;; esac\n'
                          'exec bash ' + str(ROOT / 'scripts/arc-archive.sh') + ' "$@"\n')
        patcher = patch.object(p, 'ARCHIVE_SCRIPT', script)
        patcher.start()
        self.addCleanup(patcher.stop)
        return lambda: log.read_text().split() if log.exists() else []

    def test_archivable_matches_the_arc_list_week(self):
        now = dt.datetime(2026, 7, 29, 9, 0).timestamp()
        local = lambda *parts: dt.datetime(*parts).astimezone().isoformat()
        closed = lambda **fields: {'status': 'closed', 'opened': local(2026, 7, 29, 8, 0), **fields}
        cases = [
            ('closed three weeks back', closed(closed_at=local(2026, 7, 8, 9, 0)), True),
            ('closed a moment past the boundary', closed(closed_at=local(2026, 7, 22, 23, 59)), True),
            ('closed six days back', closed(closed_at=local(2026, 7, 23, 0, 0)), False),
            ('closed this morning', closed(closed_at=local(2026, 7, 29, 7, 0)), False),
            ('closed long ago, date only', closed(closed_at='2026-06-01'), True),
            ('closed long ago, fractional seconds', closed(closed_at='2026-06-01T00:00:00.123456789Z'), True),
            ('no close falls back to an old open', {'status': 'closed', 'opened': '2026-06-01T00:00:00Z'}, True),
            ('no declared instant', {'status': 'closed'}, False),
            ('unreadable close never falls back to the open', {'status': 'closed', 'opened': '2026-01-01T00:00:00Z', 'closed_at': 'whenever'}, False),
            ('a zoneless time is not readable', closed(closed_at='2026-06-01T00:00:00'), False),
            ('a non-string close is not readable', closed(closed_at=20260601), False),
            ('live past the week', {'status': 'active', 'opened': '2026-01-01T00:00:00Z'}, False),
            ('already archived', {'status': 'archived', 'closed_at': '2026-01-01T00:00:00Z'}, False),
        ]
        for name, meta, want in cases:
            self.assertEqual(p.archivable(meta, now), want, name)

    def test_refresh_archives_aged_closed_arcs_only(self):
        self.arc(rows='')
        self.arc('aged', status='closed', opened=self.days_ago(1), closed_at=self.days_ago(30), rows='')
        self.arc('fresh', status='closed', opened=self.days_ago(40), closed_at=self.days_ago(1), rows='')
        self.arc('stale-live', status='active', opened=self.days_ago(400), rows='')
        self.arc('dateless', status='closed', opened='', rows='')
        self.arc('unreadable', status='closed', opened=self.days_ago(400), closed_at='whenever', rows='')
        calls = self.archive_log()
        result = subprocess.run([sys.executable, str(ROOT/'scripts/coordinate_projection.py'), '--kdir', str(self.store), '--refresh', '--json'],
                                env=self.env, text=True, capture_output=True, check=True)
        snap = json.loads(result.stdout)
        self.assertEqual(self.status_of('aged'), 'archived')
        for name, status in (('fresh', 'closed'), ('stale-live', 'active'), ('dateless', 'closed'), ('unreadable', 'closed')):
            self.assertEqual(self.status_of(name), status, name)
        self.assertNotIn('aged', [a['Slug'] for a in snap['arcs']])
        catalog = json.loads((self.store/'_coordination/display-archive.json').read_text())
        self.assertEqual([a['Slug'] for a in catalog['arcs']], ['aged'])
        self.assertEqual(snap['archive_identity'], catalog['identity'])
        self.assertEqual(snap['archive_refusals'], {})
        for _ in range(3):
            self.refresh('')
        self.assertEqual(calls(), [])

    def test_stale_cache_never_archives_a_live_arc(self):
        self.arc('live', status='active', opened=self.days_ago(400), rows='')
        self.refresh('')
        calls = self.archive_log()
        db = p.connect(self.store/'_coordination/display.sqlite3', True)
        stale = {'slug': 'live', 'status': 'closed', 'opened': self.days_ago(400), 'closed_at': self.days_ago(300)}
        db.execute("UPDATE arcs SET status='closed', meta=? WHERE name='live'", (json.dumps(stale),))
        db.commit()
        self.assertEqual(p.archive_aged(db, self.store, time.time()), [])
        db.close()
        self.assertEqual(calls(), [])
        self.assertEqual(self.status_of('live'), 'active')

    def test_archive_is_bounded_per_pass_and_drains(self):
        for i in range(5):
            self.arc(f'aged-{i}', status='closed', closed_at=self.days_ago(30 - i), rows='')
        calls = self.archive_log()
        passes = []
        for _ in range(4):
            self.refresh('')
            passes.append(len(calls()))
        self.assertEqual(passes, [p.ARCHIVE_BATCH, 2 * p.ARCHIVE_BATCH, 5, 5])
        self.assertEqual(calls(), [f'aged-{i}' for i in range(5)])
        self.assertTrue(all(self.status_of(f'aged-{i}') == 'archived' for i in range(5)))

    def test_lease_holder_alone_archives(self):
        self.arc('aged', status='closed', closed_at=self.days_ago(30), rows='')
        self.refresh('')
        self.arc('later', status='closed', closed_at=self.days_ago(30), rows='')
        calls = self.archive_log()
        with (self.store/'_coordination/display.lock').open('a+b') as lease:
            fcntl.flock(lease, fcntl.LOCK_EX)
            self.assertFalse(p.maintenance(self.store, force=True))
        self.assertEqual(calls(), [])
        self.assertEqual(self.status_of('later'), 'closed')

    def test_refusal_is_remembered_until_metadata_changes(self):
        self.arc('stuck', status='closed', closed_at=self.days_ago(60), rows='')
        for i in range(2):
            self.arc(f'aged-{i}', status='closed', closed_at=self.days_ago(30), rows='')
        calls = self.archive_log(refuse='stuck')
        snap = self.refresh('')
        self.assertEqual(calls(), ['stuck', 'aged-0'])
        refusal = snap['archive_refusals']['stuck']
        self.assertEqual((refusal['exit'], refusal['error']), (1, '[arc] Error: refused stuck'))
        self.assertEqual(refusal['fingerprint'], p.fingerprint(self.store/p.ARC_ROOT/'stuck/_meta.json'))
        snap = self.refresh('')
        self.assertEqual(calls(), ['stuck', 'aged-0', 'aged-1'])
        for _ in range(3):
            snap = self.refresh('')
        self.assertEqual(calls(), ['stuck', 'aged-0', 'aged-1'])
        self.assertEqual(self.status_of('stuck'), 'closed')
        self.assertIn('stuck', [a['Slug'] for a in snap['arcs']])
        meta = self.store/p.ARC_ROOT/'stuck/_meta.json'
        replacement = meta.with_suffix('.new')
        replacement.write_bytes(meta.read_bytes())
        replacement.replace(meta)
        self.refresh('')
        self.assertEqual(calls(), ['stuck', 'aged-0', 'aged-1', 'stuck'])
        self.assertEqual(self.status_of('stuck'), 'closed')
        self.archive_log()
        snap = self.refresh('')
        self.assertEqual(self.status_of('stuck'), 'closed')
        meta.write_text(meta.read_text())
        snap = self.refresh('')
        self.assertEqual(self.status_of('stuck'), 'archived')
        self.assertEqual(snap['archive_refusals'], {})

    def test_hung_archive_is_killed_and_remembered(self):
        self.arc('hung', status='closed', closed_at=self.days_ago(30), rows='')
        log = Path(self.tmp.name) / 'hang.log'
        script = Path(self.tmp.name) / 'hang.sh'
        script.write_text('echo "$1" >> ' + str(log) + '\nsleep 60 &\nwait\n')
        with patch.object(p, 'ARCHIVE_SCRIPT', script), patch.object(p, 'ARCHIVE_TIMEOUT', 0.5):
            started = time.monotonic()
            snap = self.refresh('')
            self.assertLess(time.monotonic() - started, 5)
        refusal = snap['archive_refusals']['hung']
        self.assertEqual(refusal['exit'], None)
        self.assertIn('timed out', refusal['error'])
        self.assertEqual(self.status_of('hung'), 'closed')
        with patch.object(p, 'ARCHIVE_SCRIPT', script), patch.object(p, 'ARCHIVE_TIMEOUT', 0.5):
            self.refresh('')
        self.assertEqual(log.read_text().split(), ['hung'])
        with patch.object(time, 'time', lambda: refusal['retry_after'] + 1):
            self.refresh('')
        self.assertEqual(self.status_of('hung'), 'archived')


if __name__ == '__main__':
    unittest.main(verbosity=2)
