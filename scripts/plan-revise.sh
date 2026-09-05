#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
KDIR=$(resolve_knowledge_dir)
python3 - "$SCRIPT_DIR" "$KDIR" "$@" <<'PY'
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys

scripts, root = Path(sys.argv[1]), Path(sys.argv[2])
evidence = runpy.run_path(str(scripts / 'work-evidence.py'))
canonical = evidence['canonical']
def sha(raw):
    return hashlib.sha256(raw).hexdigest()
def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()
def fail(message):
    raise ValueError(message)
def durable(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    sync_dir(path.parent)
def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
def immutable(path, raw):
    if path.exists():
        if path.read_bytes() != raw:
            fail('immutable snapshot collision: ' + str(path))
    else:
        durable(path, raw)
def checkpoint(name):
    if os.environ.get('LORE_PLAN_REVISE_FAIL_AT') == name:
        fail('injected publication failure: ' + name)
def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)
def tasks(data):
    return data.get('tasks', [t for p in data.get('phases', []) for t in p.get('tasks', [])])
def payload(data):
    return {k: v for k, v in data.items() if k not in {'revision_id', 'generated_at'}}
def normalized_plan(raw):
    return re.sub(rb'(?m)^(\s*- \[)[ xX](\] )', rb'\1 \2', raw)

def validate_decisions(data, task_ids):
    if not isinstance(data, dict) or set(data) - {'anchor_coverage', 'review_requirement', 'dispatch_decision'}:
        fail('decisions must be an object containing anchor_coverage, review_requirement, or dispatch_decision')
    allowed = {'anchor_coverage': {'covered', 'not-covered', 'pending'},
               'review_requirement': {'required', 'not-required', 'pending'},
               'dispatch_decision': {'proceed', 'wait', 'reuse'}}
    for key, value in data.items():
        if not isinstance(value, dict) or value.get('disposition') not in allowed[key]:
            fail('invalid ' + key + ' disposition')
        if any(not isinstance(value.get(k), str) or not value[k].strip() for k in ('by', 'note')):
            fail(key + ' requires authored by and note')
        fields = {'disposition', 'by', 'note'}
        if key in {'review_requirement', 'dispatch_decision'}:
            fields.add('prior_review_refs')
            refs = value.get('prior_review_refs', [])
            if not isinstance(refs, list) or any(not isinstance(r, str) or not r.strip() for r in refs):
                fail('prior_review_refs must contain nonempty references')
        if key == 'dispatch_decision':
            fields.add('task_ids')
            ids = value.get('task_ids')
            if not isinstance(ids, list) or not ids or len(ids) != len(set(ids)) or set(ids) - task_ids:
                fail('dispatch_decision task_ids must name distinct tasks in the selected revision')
            if value['disposition'] == 'reuse' and not value.get('prior_review_refs'):
                fail('reuse requires prior_review_refs and an applicability note')
        if set(value) - fields:
            fail('unknown fields in ' + key)
    return data

def read_history(item, repair=False):
    path = item / 'revisions.jsonl'
    raw = path.read_bytes() if path.exists() else b''
    if raw and not raw.endswith(b'\n'):
        prefix, _, tail = raw.rpartition(b'\n')
        matches = []
        for candidate in (item / 'revisions' / '.transactions').glob('*/*/commit.json'):
            expected = candidate.read_bytes()
            if expected.startswith(tail):
                matches.append(expected)
        if not repair or len(matches) != 1:
            fail('incomplete revision ledger tail; no unique staged transaction proves recovery')
        candidate_rows = [json.loads(line) for line in prefix.splitlines()] + [json.loads(matches[0])]
        check = {'state': 'read', 'reason': '', 'rows': candidate_rows, 'errors': []}
        evidence['validate_records'](check, 'revisions')
        if check['state'] != 'read':
            fail('staged tail does not extend the committed predecessor; manual repair required')
        candidate = candidate_rows[-1]
        if candidate.get('record_type', 'revision') == 'revision':
            snapshot(item, candidate)
        with open(path, 'ab') as stream:
            stream.write(matches[0][len(tail):])
            stream.flush()
            os.fsync(stream.fileno())
    source = evidence['read_ledger'](path, root, {'1'})
    evidence['validate_records'](source, 'revisions')
    if source['state'] not in {'read', 'absent'}:
        fail('revision history ' + str(source['reason']))
    return source.get('rows', [])

def head_of(rows):
    return next((r for r in reversed(rows) if r.get('record_type', 'revision') == 'revision'), None)
def snapshot(item, row):
    values = []
    for name in ('plan', 'tasks'):
        rel = Path(row[name + '_path'])
        path = (item / rel).resolve()
        if rel.is_absolute() or not path.is_relative_to(item.resolve()):
            fail('snapshot outside work item')
        raw = path.read_bytes()
        if sha(raw) != row[name + '_sha256']:
            fail('committed ' + name + ' snapshot digest mismatch')
        values.append(raw)
    return values

def effective(rows, revision_id):
    row = next(r for r in rows if r.get('record_type', 'revision') == 'revision' and r['revision_id'] == revision_id)
    result = {k: row.get(k) for k in ('anchor_coverage', 'review_requirement', 'dispatch_decision')}
    for decision in rows:
        if decision.get('record_type') == 'decision' and decision['revision_id'] == revision_id:
            result.update({k: decision[k] for k in result if k in decision})
    return result

def commit(item, row):
    token = row.get('decision_id', row['revision_id'])
    raw = canonical(row) + b'\n'
    stage = item / 'revisions' / '.transactions' / row.get('record_type', 'revision') / token / 'commit.json'
    immutable(stage, raw)
    with open(item / 'revisions.jsonl', 'ab') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    sync_dir(item)

def install(item, row):
    snapshot(item, row)
    checkpoint('before-tasks')
    run(['bash', str(scripts / 'regen-tasks.sh'), item.name, '--quiet',
         '--install-revision', row['revision_id']], stdout=sys.stderr,
        env={**os.environ, 'LORE_PLAN_PUBLICATION_LOCK_FD': str(lock.fileno())},
        pass_fds=(lock.fileno(),))
    immutable(item / 'revisions' / '.transactions' / 'revision' / row['revision_id'] / 'published.json',
              canonical({'revision_id': row['revision_id'], 'tasks_sha256': row['tasks_sha256']}) + b'\n')

def changes(old, new, semantic):
    before, after = ({t['id']: t for t in tasks(d)} for d in (old or {}, new))
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    result = {key: [] for key in ('task', 'edge', 'file', 'constraint', 'output-contract', 'criterion')}
    fields = {'edge': ['blockedBy'], 'file': ['file_targets'], 'constraint': ['norms', 'retrieval_directive', 'scope'],
              'output-contract': ['deliverable', 'description'], 'criterion': ['close_criteria']}
    def constraint_text(task):
        description = task.get('description', '')
        return re.findall(r'(?ms)^\*\*(?:Scope|Consultations required|Plan verification \(plan-owned close criteria\)):\*\*.*?(?=^\*\*|^## |\Z)', description)
    for tid in changed:
        a, b = before.get(tid, {}), after.get(tid, {})
        if constraint_text(a) != constraint_text(b):
            result['constraint'].append(tid)
        if not a or not b or a.get('subject') != b.get('subject'):
            result['task'].append(tid)
        for kind, keys in fields.items():
            if tid not in result[kind] and any(a.get(k) != b.get(k) for k in keys):
                result[kind].append(tid)
    # Plan-wide intent/verification edits affect every surviving task even
    # when generation does not copy those bytes into each task description.
    if semantic and not changed:
        changed = sorted(after)
        result['constraint'] = changed
    return changed, result

parser = argparse.ArgumentParser(description='Publish a recoverable plan/task revision or an authored decision.')
parser.add_argument('slug')
parser.add_argument('--json', action='store_true', help='emit the publication identity as JSON (the default)')
parser.add_argument('--reason', default='record authored plan state')
parser.add_argument('--author-role', default='coordinator')
parser.add_argument('--kind', choices=['auto', 'semantic', 'progress'], default='auto')
parser.add_argument('--expected-predecessor')
parser.add_argument('--decisions', help='JSON file with authored coverage, review, and dispatch dispositions')
parser.add_argument('--decision-for', help='record metadata against an existing revision')
parser.add_argument('--decision-id', help='stable replay token for a metadata decision')
parser.add_argument('--complete-subject', help=argparse.SUPPRESS)
parser.add_argument('--allow-legacy-progress', action='store_true', help=argparse.SUPPRESS)
parser.add_argument('--reconcile', action='store_true', help='repair an adopted item; adopt a legacy item only on checksum drift')
args = parser.parse_args(sys.argv[3:])
try:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', args.slug):
        fail('invalid work item slug')
    item = root / '_work' / args.slug
    if not item.is_dir():
        archived = root / '_work' / '_archive' / args.slug
        if archived.is_dir():
            fail('work item is archived; immutable snapshots remain readable but publication requires an active item')
        fail('work item not found: ' + args.slug)
    plan_path = item / 'plan.md'
    live_plan = plan_path.read_bytes()
    ledger_path = item / 'revisions.jsonl'
    observed = ledger_path.read_bytes() if ledger_path.exists() else b''
    revision_dir = item / 'revisions'
    if args.reconcile and not observed:
        live_tasks = json.loads((item / 'tasks.json').read_bytes())
        if not isinstance(live_tasks.get('tasks'), list) and not isinstance(live_tasks.get('phases'), list):
            fail('tasks.json declares neither tasks nor phases; run: lore work regen-tasks ' + args.slug)
        if live_tasks.get('revision_id'):
            fail('revision-stamped tasks have no revision history')
        if (live_tasks.get('plan_checksum') == sha(live_plan) or
                args.allow_legacy_progress and live_tasks.get('plan_checksum') == sha(normalized_plan(live_plan))):
            print(json.dumps({'status': 'legacy-unbound', 'revision_id': None}))
            sys.exit(0)
    revision_dir.mkdir(exist_ok=True)
    with open(revision_dir / '.publication.lock', 'a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = read_history(item, repair=True)
        head = head_of(rows)
        old_id = head['revision_id'] if head else None
        current_raw = ledger_path.read_bytes() if ledger_path.exists() else b''
        if observed != current_raw and head and head['plan_sha256'] != sha(live_plan):
            fail('competing predecessor update; refresh the committed revision and retry')
        retry_expected = False
        expected = args.expected_predecessor
        if expected is not None and (None if expected == 'none' else expected) != old_id:
            if not (head and head['predecessor'] == (None if expected == 'none' else expected)
                    and head['plan_sha256'] == sha(live_plan)):
                fail('competing predecessor update; refresh --expected-predecessor and retry')
            retry_expected = True
        if plan_path.read_bytes() != live_plan:
            fail('live plan changed while waiting for publication; refresh and retry')
        if args.complete_subject:
            if head is None or args.kind != 'progress' or args.decision_for:
                fail('transactional checkbox completion requires an adopted progress revision')
            previous_plan, _ = snapshot(item, head)
            if normalized_plan(previous_plan) != normalized_plan(live_plan):
                fail('semantic plan bytes must be revised before recording task completion')
            run(['bash', str(scripts / 'update-plan-checkbox.sh'), args.slug, args.complete_subject],
                env={**os.environ, 'LORE_PLAN_CHECKBOX_LOCK_FD': str(lock.fileno())},
                pass_fds=(lock.fileno(),), stdout=sys.stderr)
            live_plan = plan_path.read_bytes()
        supplied = json.loads(Path(args.decisions).read_text()) if args.decisions else {}
        if args.decision_for:
            if not args.decisions or not args.decision_id or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}', args.decision_id):
                fail('decision operation requires --decisions and a stable --decision-id')
            target = next((r for r in rows if r.get('record_type', 'revision') == 'revision' and r['revision_id'] == args.decision_for), None)
            if target is None:
                fail('decision targets an unknown revision')
            _, target_tasks = snapshot(item, target)
            validate_decisions(supplied, {t['id'] for t in tasks(json.loads(target_tasks))})
            previous = next((r for r in rows if r.get('decision_id') == args.decision_id), None)
            if previous:
                if previous['revision_id'] != args.decision_for or {k: previous[k] for k in ('anchor_coverage', 'review_requirement', 'dispatch_decision') if k in previous} != supplied:
                    fail('decision-id replay conflicts with immutable input')
                status = 'current'
            else:
                commit(item, {'schema_version': 1, 'record_type': 'decision', 'revision_id': args.decision_for,
                              'decision_id': args.decision_id, **supplied,
                              'author_role': args.author_role, 'reason': args.reason, 'timestamp': now()})
                status = 'decision-recorded'
            print(json.dumps({'status': status, 'revision_id': args.decision_for}))
            sys.exit(0)
        if args.decision_id:
            fail('--decision-id requires --decision-for')
        if head:
            old_plan, old_tasks_raw = snapshot(item, head)
            # Restore only the task projection. A newer authored plan is never
            # replaced by recovery of the previous committed snapshot.
            published = item / 'revisions' / '.transactions' / 'revision' / old_id / 'published.json'
            if not published.exists() or not (item / 'tasks.json').exists() or sha((item / 'tasks.json').read_bytes()) != head['tasks_sha256']:
                install(item, head)
            if args.reconcile and head['plan_sha256'] == sha(live_plan):
                if supplied and any(effective(rows, old_id).get(k) != v for k, v in supplied.items()):
                    fail('unchanged revision; record decisions with --decision-for and --decision-id')
                print(json.dumps({'status': 'current', 'revision_id': old_id}))
                sys.exit(0)
            previous_tasks = item / head['tasks_path']
            old_tasks = json.loads(old_tasks_raw)
        else:
            old_plan, old_tasks = None, None
            previous_tasks = item / 'tasks.json'
            if previous_tasks.exists() and json.loads(previous_tasks.read_bytes()).get('revision_id'):
                fail('revision-stamped tasks have no revision history')
        run(['bash', str(scripts / 'verify-plan-intent-anchor.sh'), args.slug,
             '--work-dir', str(root / '_work')], stdout=sys.stderr)
        command = [sys.executable, str(scripts / 'generate-tasks.py'), str(plan_path),
                   '--knowledge-dir', str(root), '--slug', args.slug, '--include-completed']
        if previous_tasks.exists():
            command += ['--previous-tasks', str(previous_tasks)]
        generated = json.loads(run(command, stdout=subprocess.PIPE).stdout)
        if generated.get('plan_checksum') != sha(live_plan):
            fail('generated task checksum differs from selected plan bytes; refresh and retry')
        generated['schema_version'] = 1
        payload_sha = sha(canonical(payload(generated)))
        if head and sha(live_plan) == head['plan_sha256'] and payload_sha == head['tasks_payload_sha256']:
            if supplied and any(effective(rows, old_id).get(k) != v for k, v in supplied.items()):
                fail('unchanged revision; record decisions with --decision-for and --decision-id')
            print(json.dumps({'status': 'current', 'revision_id': old_id}))
            sys.exit(0)
        if retry_expected or observed != current_raw:
            fail('competing predecessor update changed the generation; refresh and retry')
        progress = old_plan is not None and normalized_plan(old_plan) == normalized_plan(live_plan)
        if args.kind == 'progress' and not progress:
            fail('semantic plan bytes cannot be recorded as progress')
        kind = 'progress' if progress and args.kind != 'semantic' else 'semantic'
        if kind == 'progress' and old_tasks is not None:
            # Estimates read current source sizes; they are advisory, even when
            # a checkoff regenerates them after the source was edited. Compiled
            # estimates also carry immutable dispatch references, which bind
            # the producer and must remain part of the semantic projection.
            def estimate_identity(value):
                if isinstance(value, list):
                    return [estimate_identity(v) for v in value]
                if isinstance(value, dict):
                    return value.get('dispatch_context', {}).get('position_dispatch')
                return None
            def without_progress(value):
                if isinstance(value, dict):
                    return {k: (estimate_identity(v) if k == 'context_cost_estimate' else without_progress(v))
                            for k, v in value.items()
                            if k not in {'plan_checksum', 'generated_at', 'revision_id', 'status', 'completed'}}
                if isinstance(value, list):
                    return [without_progress(v) for v in value]
                return value
            if without_progress(generated) != without_progress(old_tasks):
                if args.kind == 'progress':
                    fail('semantic generated-task change cannot be recorded as progress')
                kind = 'semantic'
        revision_id = sha(canonical({'hash_version': '1', 'plan_sha256': sha(live_plan),
                                     'tasks_payload_sha256': payload_sha, 'predecessor': old_id}))[:12]
        generated['revision_id'] = revision_id
        finalized = canonical(generated) + b'\n'
        ids = {t['id'] for t in tasks(generated)}
        validate_decisions(supplied, ids)
        changed, categories = changes(old_tasks, generated, kind == 'semantic')
        pending = {'disposition': 'pending', 'by': None, 'note': 'authored decision not recorded'}
        decisions = {'anchor_coverage': dict(pending), 'review_requirement': {**pending, 'prior_review_refs': []},
                     'dispatch_decision': None}
        inherited = None
        if kind == 'progress':
            decisions = effective(rows, old_id)
            inherited = old_id
        decisions.update(supplied)
        scope_match = re.search(r'^\*\*Scope delta:\*\*\s*(.*)$', live_plan.decode(), re.MULTILINE)
        head_run = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True)
        row = {'schema_version': 1, 'record_type': 'revision', 'hash_version': '1', 'revision_id': revision_id,
               'predecessor': old_id, 'plan_sha256': sha(live_plan), 'tasks_payload_sha256': payload_sha,
               'tasks_sha256': sha(finalized), 'old_plan_sha256': head['plan_sha256'] if head else None,
               'old_tasks_payload_sha256': head['tasks_payload_sha256'] if head else None,
               'old_tasks_sha256': head['tasks_sha256'] if head else None,
               'source_head': head_run.stdout.strip() if head_run.returncode == 0 else None,
               'author_role': args.author_role, 'timestamp': now(), 'generation_timestamp': generated.get('generated_at'), 'kind': kind, 'reason': args.reason,
               'scope_delta': scope_match.group(1) if scope_match else None, 'changed_task_ids': changed,
               'change_categories': categories, 'added_task_ids': sorted(ids - {t['id'] for t in tasks(old_tasks or {})}),
               'removed_task_ids': sorted({t['id'] for t in tasks(old_tasks or {})} - ids),
               'inherited_from_revision': inherited, 'decision_overrides': supplied, **decisions,
               'plan_path': f'revisions/{revision_id}/plan.md', 'tasks_path': f'revisions/{revision_id}/tasks.json'}
        staged = item / 'revisions' / '.transactions' / 'revision' / revision_id / 'commit.json'
        if staged.exists():
            prior = json.loads(staged.read_bytes())
            generated['generated_at'] = prior['generation_timestamp']
            finalized = canonical(generated) + b'\n'
            if prior['plan_sha256'] != sha(live_plan) or prior['tasks_sha256'] != sha(finalized):
                fail('staged revision conflicts with regenerated inputs')
            if any(prior.get(k) != row.get(k) for k in ('reason', 'author_role', 'anchor_coverage', 'review_requirement', 'dispatch_decision')):
                fail('staged revision decisions conflict; retry the original authored input')
            row = prior
        immutable(staged, canonical(row) + b'\n')
        immutable(item / row['plan_path'], live_plan)
        checkpoint('after-plan-snapshot')
        immutable(item / row['tasks_path'], finalized)
        checkpoint('after-staging')
        if plan_path.read_bytes() != live_plan:
            fail('live plan changed during staging; refresh and retry')
        commit(item, row)
        checkpoint('after-ledger')
        install(item, row)
        print(json.dumps({'status': 'published', 'revision_id': revision_id, 'kind': kind}))
except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
    print('[plan-revise] ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
