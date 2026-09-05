#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
KDIR=$(resolve_knowledge_dir)
python3 - "$SCRIPT_DIR" "$KDIR" "$@" <<'PY'
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import sys
import tempfile

scripts, root = Path(sys.argv[1]), Path(sys.argv[2])
api = runpy.run_path(str(scripts / 'work-evidence.py'))
canonical, sha = api['canonical'], api['sha256']

def sync(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def publish(directory, files):
    stage = Path(tempfile.mkdtemp(prefix='.' + directory.name + '-', dir=directory.parent))
    try:
        for name, raw in files.items():
            with open(stage / name, 'wb') as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
        sync(stage)
        if os.environ.get('LORE_PLAN_REVIEW_FAIL_AT') == directory.name:
            raise ValueError('injected review publication failure')
        os.rename(stage, directory)
        sync(directory.parent)
    finally:
        if stage.exists():
            shutil.rmtree(stage)

def read_json(path):
    return json.loads(Path(path).read_text())

def snapshot(item, row, name):
    source = api['read_file'](item / row[name + '_path'], item)
    if source['state'] != 'read' or source['sha256'] != row[name + '_sha256']:
        raise ValueError('committed ' + name + ' snapshot unavailable or hash mismatch')
    return source['content'].encode()

def citations(item, judgments):
    ids = sorted({rid for j in judgments['judgments'] for rid in j['result_ids']})
    result = {'schema_version': 1, 'result_ids': ids, 'execution_evidence': 'cited' if ids else 'none',
              'reason': None if ids else 'No executed result is cited; these are authored review judgments.', 'results': []}
    if not ids:
        return result
    source = api['read_ledger'](item / 'results.jsonl', item, {'1'})
    api['validate_records'](source, 'results')
    if source['state'] != 'read':
        raise ValueError('cited result history unavailable')
    for rid in ids:
        rows = [r for r in source['rows'] if r.get('result_id') == rid]
        if len(rows) != 1:
            raise ValueError('cited result must name exactly one canonical row: ' + rid)
        artifacts = api['references'](rows[0], item, item)
        if any(a['state'] != 'read' for a in artifacts):
            raise ValueError('cited result output unavailable or hash mismatch: ' + rid)
        result['results'].append({'row': rows[0], 'artifacts': artifacts})
    return result

parser = argparse.ArgumentParser(description='Preserve and seal immutable review evidence.')
sub = parser.add_subparsers(dest='operation', required=True)
prepare = sub.add_parser('prepare')
prepare.add_argument('slug')
prepare.add_argument('--attempt-id', required=True)
prepare.add_argument('--ceremony', choices=['spec-design', 'spec-post-plan'], required=True)
prepare.add_argument('--revision', required=True)
prepare.add_argument('--purpose', choices=sorted(api['REVIEW_PURPOSES']), required=True)
prepare.add_argument('--execution-worktree')
prepare.add_argument('--json', action='store_true')
seal = sub.add_parser('seal')
seal.add_argument('slug')
seal.add_argument('--attempt-id', required=True)
seal.add_argument('--output', required=True)
seal.add_argument('--dispositions', required=True)
seal.add_argument('--evaluator-manifest', required=True)
seal.add_argument('--json', action='store_true')
args = parser.parse_args(sys.argv[3:])
try:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', args.attempt_id):
        raise ValueError('attempt-id must be a safe token of at most 128 characters')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', args.slug):
        raise ValueError('invalid work item slug')
    item = root / '_work' / args.slug
    if not (item / '_meta.json').is_file():
        raise ValueError('active work item unavailable')
    reviews = item / 'reviews'
    reviews.mkdir(exist_ok=True)
    if reviews.is_symlink():
        raise ValueError('reviews directory must not be a symlink')
    # Lock the directory itself so review publication creates no identity-changing lock file.
    fd = os.open(reviews, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        base = reviews / args.attempt_id
        if base.is_symlink():
            raise ValueError('review attempt must not be a symlink')
        if args.operation == 'prepare':
            if args.purpose == 'integration' and not args.execution_worktree:
                raise ValueError('integration review requires --execution-worktree')
            if args.purpose != 'integration' and args.execution_worktree:
                raise ValueError('--execution-worktree applies only to integration review')
            selected = str(Path(args.execution_worktree).resolve()) if args.execution_worktree else None
            request = {'ceremony': args.ceremony, 'revision_id': args.revision, 'purpose': args.purpose,
                       'execution_worktree': selected}
            if base.exists():
                prepared = api['review_prepared'](item, args.attempt_id)
                if prepared.get('request') != request:
                    raise ValueError('attempt-id collision: prepared review has different inputs')
                status = 'reused'
            else:
                history = api['read_ledger'](item / 'revisions.jsonl', item, {'1'})
                api['validate_records'](history, 'revisions')
                if history['state'] != 'read':
                    raise ValueError('committed revision history unavailable')
                row = next((r for r in history['rows'] if r.get('record_type', 'revision') == 'revision' and r.get('revision_id') == args.revision), None)
                if row is None:
                    raise ValueError('selected revision is not committed')
                plan, tasks = snapshot(item, row, 'plan'), snapshot(item, row, 'tasks')
                anchor = read_json(item / '_meta.json').get('intent_anchor')
                if not isinstance(anchor, str) or not anchor.strip():
                    raise ValueError('original intent anchor unavailable')
                source = api['code_identity'](selected, excluded_paths=(base,)) if selected else None
                if source is not None and source['state'] != 'read':
                    raise ValueError('integration source identity unavailable')
                prepared = {'schema_version': 1, 'record_type': 'review-input', 'attempt_id': args.attempt_id,
                            'revision_id': args.revision, 'ceremony': args.ceremony, 'purpose': args.purpose,
                            'request': request, 'source_identity': source,
                            'source_exclusions': [str(base)] if source else [],
                            'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat()}
                files = {'plan.md': plan, 'tasks.json': tasks, 'anchor.md': anchor.encode()}
                for name, filename in (('plan', 'plan.md'), ('tasks', 'tasks.json'), ('anchor', 'anchor.md')):
                    prepared[name + '_path'] = f'reviews/{args.attempt_id}/{filename}'
                    prepared[name + '_sha256'] = sha(files[filename])
                files['prepared.json'] = canonical(prepared) + b'\n'
                publish(base, files)
                status = 'prepared'
            response = {'schema_version': 1, 'status': status, 'prepared': prepared,
                        'prepared_path': str(base / 'prepared.json')}
        else:
            prepared = api['review_prepared'](item, args.attempt_id)
            output = Path(args.output).read_bytes()
            if not output.decode('utf-8').strip():
                raise ValueError('review output must be nonempty UTF-8 text')
            raw_judgments = Path(args.dispositions).read_bytes()
            judgments = api['validate_review_judgments'](json.loads(raw_judgments), prepared['purpose'])
            evaluator = api['validate_review_evaluator'](read_json(args.evaluator_manifest))
            sealed_dir = base / 'sealed'
            if sealed_dir.exists():
                _, sealed, _ = api['review_sealed'](item, args.attempt_id)
                if sealed['output_sha256'] != sha(output) or sealed['disposition_ledger_sha256'] != sha(raw_judgments) or sealed['evaluator'] != evaluator:
                    raise ValueError('attempt-id collision: sealed review has different output or judgments')
                status = 'reused'
            else:
                frozen = citations(item, judgments)
                files = {'output.md': output, 'dispositions.json': raw_judgments,
                         'cited-results.json': canonical(frozen) + b'\n'}
                sealed = {'schema_version': 1, 'record_type': 'review-seal', 'attempt_id': args.attempt_id,
                          'revision_id': prepared['revision_id'], 'ceremony': prepared['ceremony'], 'purpose': prepared['purpose'],
                          'evaluator': evaluator, 'prepared_path': f'reviews/{args.attempt_id}/prepared.json',
                          'prepared_sha256': sha((base / 'prepared.json').read_bytes()),
                          'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat()}
                for key, filename in (('output', 'output.md'), ('disposition_ledger', 'dispositions.json'), ('cited_results', 'cited-results.json')):
                    sealed[key + '_path'] = f'reviews/{args.attempt_id}/sealed/{filename}'
                    sealed[key + '_sha256'] = sha(files[filename])
                files['seal.json'] = canonical(sealed) + b'\n'
                publish(sealed_dir, files)
                status = 'sealed'
            manifest, _, _, _ = api['review_evidence'](item, args.attempt_id)
            response = {'schema_version': 1, 'status': status, 'evidence_manifest': manifest,
                        'seal_path': str(sealed_dir / 'seal.json')}
        print(json.dumps(response, ensure_ascii=False))
    finally:
        os.close(fd)
except (ValueError, OSError, KeyError, TypeError) as exc:
    print(json.dumps({'schema_version': 1, 'status': 'refused', 'error': str(exc)}, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(1)
PY
