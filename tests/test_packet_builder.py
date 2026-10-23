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


def _entry(path, title, body, footer):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"# {title}\n{body}\n<!-- learned: 2026-09-01 | confidence: high | scale: subsystem | {footer} -->\n")


def _activity_store(tmp_path):
    """A store whose preferences cover every grouping case: one and two activities, untagged, retired, README."""
    store = tmp_path / 'store'
    (store / '_work/fixture-item').mkdir(parents=True)
    (store / '_work/fixture-item/_meta.json').write_text('{"title": "Fixture", "status": "active"}')
    prefs = store / 'preferences'
    _entry(prefs / 'announce.md', 'Announce the wake', 'Say what woke you.\n- [[knowledge:conventions/widget#Widget boundary]]',
           'activity: coordination | status: current')
    _entry(prefs / 'model.md', 'Name the model', 'Every spawn names its model.', 'activity: coordination, model-routing | status: current')
    _entry(prefs / 'loose.md', 'Loose rule', 'Filed before activities.', 'status: current')
    _entry(prefs / 'old.md', 'Old rule', 'No longer held.', 'activity: coordination | status: retired')
    (prefs / 'README.md').write_text('# preferences/\n')
    _entry(store / 'conventions/widget.md', 'Widget boundary', 'The widget boundary preserves identity.', 'status: current')
    return store


def _session_row(packet_id):
    return {'packet_id': packet_id, 'packet_scope': 'session', 'session_id': None, 'work_item': 'fixture-item',
            'task_id': None, 'phase': None, 'arm': None, 'task_scale_set': 'subsystem'}


def _stored(store, packet_id):
    rows = [json.loads(line) for line in (store / '_packets/packets.jsonl').read_text().splitlines() if line.strip()]
    return [row for row in rows if row['packet_id'] == packet_id][-1]


def _show(store, packet_id):
    proc = subprocess.run([sys.executable, str(packet_builder.SCRIPTS / 'packet_builder.py'), '--kdir', str(store),
                           'show', packet_id], capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


BODY = '## Prior Knowledge\n\n### Focal: widget\n\n#### Widget boundary (from conventions/widget.md)\nThe widget boundary preserves identity.\n'


def test_activities_put_full_text_preferences_before_the_assembled_body(tmp_path):
    store = _activity_store(tmp_path)
    status = packet_builder.build_packet(store, _session_row('pkt-act'), assembly=(BODY, {}), scales=['subsystem'],
                                         activities=['Coordination', 'coordination,model-routing'])
    row = _stored(store, 'pkt-act')
    section, body = row['content'].split('## Prior Knowledge', 1)
    assert section.startswith('## Preferences\n\n')
    assert "The project's accumulated working style for coordination, model-routing, in full:" in section
    assert 'Preferences for coordination (2):\n- Announce the wake\n  Say what woke you.' in section
    assert 'Preferences for model-routing (1):\n- Name the model\n  Every spawn names its model.' in section
    assert 'Full set: lore search --preferences --activity coordination' in section
    assert 'Old rule' not in section and 'Loose rule' not in section
    assert '## Prior Knowledge' + body == BODY
    assert row['activities'] == status['activities'] == ['coordination', 'model-routing']
    # The stored norm rows stay the plain population; the grouping is never written to the row.
    assert row['norms'] == packet_builder.population(store)
    assert all(set(norm) == {'label', 'path', 'source_id'} for norm in row['norms'])


def test_no_activities_leaves_the_content_and_the_status_as_they_were(tmp_path):
    store = _activity_store(tmp_path)
    status = packet_builder.build_packet(store, _session_row('pkt-plain'), assembly=(BODY, {}), scales=['subsystem'])
    row = _stored(store, 'pkt-plain')
    assert row['content'] == BODY
    assert 'activities' not in row and 'activities' not in status


def test_an_activity_with_no_entries_says_none_filed_and_an_empty_body_keeps_only_the_section(tmp_path):
    store = _activity_store(tmp_path)
    packet_builder.build_packet(store, _session_row('pkt-none'), assembly=('', {}), scales=['subsystem'],
                                activities=['review-comments'])
    content = _stored(store, 'pkt-none')['content']
    assert content.startswith('## Preferences\n\n')
    assert content.endswith('Preferences for review-comments: none filed.\n')


def test_a_malformed_activity_name_is_refused_before_anything_is_appended(tmp_path):
    store = _activity_store(tmp_path)
    try:
        packet_builder.build_packet(store, _session_row('pkt-bad'), assembly=(BODY, {}), scales=['subsystem'],
                                    activities=['Bad Name!'])
    except ValueError as exc:
        assert 'not a valid activity name' in str(exc)
    else:
        raise AssertionError('a malformed activity name was accepted')
    assert not (store / '_packets/packets.jsonl').exists()


def test_show_groups_preference_norms_by_activity_and_keeps_conventions_flat(tmp_path):
    store = _activity_store(tmp_path)
    packet_builder.build_packet(store, _session_row('pkt-norms'), assembly=(BODY, {}), scales=['subsystem'])
    norms = _show(store, 'pkt-norms').split('\n## Norms\n', 1)[1]
    assert norms.splitlines() == [
        '### coordination',
        '- `announce` — preferences/announce.md',
        '- `model` — preferences/model.md',
        '### model-routing',
        '- `model` — preferences/model.md',
        '### untagged',
        '- `loose` — preferences/loose.md',
        '### not a live entry',
        '- `README` — preferences/README.md',
        '- `old` — preferences/old.md',
        '### conventions',
        '- `widget` — conventions/widget.md',
    ]


def test_show_without_preference_rows_renders_the_flat_norms_list(tmp_path):
    store = _activity_store(tmp_path)
    for path in (store / 'preferences').iterdir():
        path.unlink()
    packet_builder.build_packet(store, _session_row('pkt-flat'), assembly=(BODY, {}), scales=['subsystem'])
    assert _show(store, 'pkt-flat').split('\n## Norms\n', 1)[1].splitlines() == ['- `widget` — conventions/widget.md']


def test_synthesis_drops_delivered_blocks_and_leaves_the_preferences_section_leading(tmp_path):
    store = _activity_store(tmp_path)
    _entry(store / 'conventions/gadget.md', 'Gadget boundary', 'Separate from widgets.', 'status: current')
    trust = {'score': None, 'status': 'current', 'confidence': 'high', 'correction_recency': None}
    # The widget block is a backlink, and the coordination preference body quotes that same backlink line.
    widget = '\n- [[knowledge:conventions/widget#Widget boundary]]\n'
    gadget = '\n#### Gadget boundary (from conventions/gadget.md)\nSeparate from widgets.\n'
    entries = [{'path': 'conventions/widget.md', 'scale': 'subsystem', 'render_mode': 'backlink',
                'ranking_path': 'search-order', 'trust': trust, 'rendered': widget},
               {'path': 'conventions/gadget.md', 'scale': 'subsystem', 'render_mode': 'full',
                'ranking_path': 'search-order', 'trust': trust, 'rendered': gadget}]
    body = '## Prior Knowledge\n\n### Focal: widget\n' + widget + gadget
    packet_builder.build_packet(store, _session_row('pkt-syn'), assembly=(body, {'entries': entries}),
                                scales=['subsystem'], activities=['coordination'])
    section = _stored(store, 'pkt-syn')['content'].split('## Prior Knowledge', 1)[0]
    packet_builder.synthesize(store, 'pkt-syn', by='lead', dropped=[('conventions/widget.md', 'not needed')])
    content = _stored(store, 'pkt-syn')['content']
    assert content.startswith(section)
    assert '- [[knowledge:conventions/widget#Widget boundary]]' in section
    rest = content[len(section):]
    assert widget not in rest and gadget in rest
    assert rest.rstrip().endswith('- Widget boundary (from conventions/widget.md) — not needed')
