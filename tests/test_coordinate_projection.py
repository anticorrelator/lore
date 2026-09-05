#!/usr/bin/env python3
import concurrent.futures
import contextlib
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

    def arc(self, name='a', members=None, status='active', rows=None):
        home = self.store / p.ARC_ROOT / name
        home.mkdir(parents=True, exist_ok=True)
        (home / '_meta.json').write_text(json.dumps({'slug': name, 'title': name, 'status': status,
                                                    'members': members or [], 'opened': '2026-01-01T00:00:00Z'}))
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
