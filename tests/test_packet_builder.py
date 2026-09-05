import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import packet_builder
import pk_manifest


def test_assembly_equals_manifest_for_same_v2_directive(tmp_path):
    root = Path(__file__).resolve().parents[1]
    store = tmp_path / 'store'
    subprocess.run(['bash', str(root / 'tests/fixtures/retrieval/build_store.sh'), str(store)], check=True)
    directive = json.loads((store / '_work/fixture-item/tasks.json').read_text())['phases'][0]['retrieval_directive']
    snapshot = tmp_path / 'direct.json'
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert pk_manifest.resolve_v2(str(store), directive, 'fixture-item', task_id='task-1', delivery_json_path=str(snapshot)) == 0
    body, actual = packet_builder.assemble(store, 'fixture-item', directive, 'task-1')
    assert body == output.getvalue()
    assert actual == json.loads(snapshot.read_text())
    logs = [json.loads(line) for line in (store / '_meta/retrieval-log.jsonl').read_text().splitlines()]
    events = [r for r in logs if r.get('event') == 'manifest_load']
    assert len(events) == 2
    assert events[-1]['loaded_paths'] == events[-2]['loaded_paths']
    assert events[-1]['sections'] == events[-2]['sections']
    assert events[-1]['calls'] == events[-2]['calls']


def test_large_norm_population_appends_without_whitespace_copy_stall(tmp_path):
    row = {'packet_id': 'pkt-large', 'packet_scope': 'session', 'delivery_stage': 'assembled',
           'session_id': None, 'work_item': None, 'phase': None, 'task_id': None,
           'arm': None, 'task_scale_set': None, 'delivered_entries': [],
           'empty_reason': 'fixture has no retrieved entries',
           'budget': {'chars_used': 0, 'chars_budget': None},
           'norms': [{'label': 'widget', 'path': 'conventions/widget.md'}] * 8000}
    proc = subprocess.run(['bash', str(packet_builder.SCRIPTS / 'packet-append.sh'), '--kdir', str(tmp_path)],
                          input=json.dumps(row), capture_output=True, text=True, timeout=15)
    assert proc.returncode == 0, proc.stderr
    stored = json.loads((tmp_path / '_packets/packets.jsonl').read_text())
    assert stored['norms'] == row['norms']
