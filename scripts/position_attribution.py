#!/usr/bin/env python3
"""Project the recorded producer behind a record, or say plainly that there is none.

Three statuses, and the difference between them is what a reader needs:

  legacy    the record carries no position-dispatch reference at all. Every
            record written before compiled positions existed reads this way,
            and so does every legacy dispatch route that is still supported.
            Identity fields are null because none was ever recorded.
  resolved  a reference was recorded, its bytes still validate, and the
            identity fields name the producer those bytes belong to.
  unknown   a reference was recorded but cannot be resolved to bytes — moved
            store, altered manifest, malformed pair. Identity fields are null.

`unknown` is never quietly turned into `legacy`, and neither is ever filled in
from the current `agents/worker.md`: a record whose producer cannot be
established is not eligible as some other producer's score. Resolution
delegates to position-bind.py, which owns immutable-bytes validation; nothing
here writes a ledger, a registry, or a report.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys

SCRIPTS = Path(__file__).resolve().parent
REFERENCE_FIELD = 'position_dispatch'
REFERENCE_KEYS = ('manifest_path', 'manifest_sha256')
IDENTITY = ('template_id', 'template_version', 'template_path', 'position', 'framework',
            'bindings', 'wrapper', 'dispatch_attempt_id', 'report_id')
# Both spellings of a report header line. The bold form is what a worker
# report actually carries; the plain form is what a log reduction copies.
HEADER = re.compile(r'^\s*(?:\*\*)?([A-Za-z][A-Za-z0-9-]*)\s*:(?:\*\*)?\s*(.*?)\s*$')
REPORT_HEADERS = ('Position-dispatch-manifest', 'Position-dispatch-sha256', 'Template-version',
                  'Template-id', 'Report-id', 'Compiled-position', 'Report-key', 'Producer-role')


def _binder():
    """Load position-bind.py by path; its filename is not an identifier."""
    spec = importlib.util.spec_from_file_location('lore_position_bind', SCRIPTS / 'position-bind.py')
    module = importlib.util.module_from_spec(spec)
    if str(SCRIPTS) not in sys.path:
        sys.path.insert(0, str(SCRIPTS))
    spec.loader.exec_module(module)
    return module


def validate_reference(value):
    """Raise on a malformed reference. Writers call this; readers do not have to."""
    if not isinstance(value, dict) or set(value) != set(REFERENCE_KEYS):
        raise ValueError(f'{REFERENCE_FIELD} must be an object with exactly '
                         f'{", ".join(REFERENCE_KEYS)}')
    path = value['manifest_path']
    if not isinstance(path, str) or not path.strip() or '\x00' in path or not Path(path).is_absolute():
        raise ValueError(f'{REFERENCE_FIELD}.manifest_path must be an absolute path')
    if Path(path).name != 'manifest.json':
        raise ValueError(f'{REFERENCE_FIELD}.manifest_path must name a dispatch manifest.json')
    if not isinstance(value['manifest_sha256'], str) or not re.fullmatch('[0-9a-f]{64}', value['manifest_sha256']):
        raise ValueError(f'{REFERENCE_FIELD}.manifest_sha256 must be 64 lowercase hex characters')
    return dict(value)


def _blank(status, reason, reference=None):
    projection = {'status': status, 'reason': reason, REFERENCE_FIELD: reference}
    projection.update({key: None for key in IDENTITY})
    return projection


def project(record, *, expected=None):
    """Read a record's producer identity without asserting anything it did not record."""
    reference = record.get(REFERENCE_FIELD) if isinstance(record, dict) else None
    if reference is None:
        return _blank('legacy', 'no position-dispatch reference recorded')
    try:
        reference = validate_reference(reference)
    except ValueError as exc:
        raw = reference if isinstance(reference, dict) else None
        return _blank('unknown', str(exc), raw)
    try:
        resolved = _binder().resolve_dispatch(reference['manifest_path'],
                                              reference['manifest_sha256'], expected=expected)
    except Exception as exc:  # a reader must stay readable whatever the reference does
        return _blank('unknown', f'{type(exc).__name__}: {exc}'.strip(), reference)
    m = resolved['manifest']
    producer, bindings = m['producer'], m['bindings']
    return {'status': 'resolved', 'reason': None, REFERENCE_FIELD: reference,
            'template_id': producer['template_id'], 'template_version': producer['template_version'],
            # The immutable compiled source, not the installed or current file.
            'template_path': m['native']['source_path'],
            'position': producer['position'], 'framework': producer['framework'],
            'bindings': bindings, 'wrapper': m.get('wrapper'),
            'dispatch_attempt_id': bindings.get('dispatch_attempt_id'),
            'report_id': bindings.get('report_id')}


def report_record(text):
    """Lift a report's identity headers into a record `project` can read.

    A report that carries one half of the reference pair is not treated as
    legacy — the omission is visible in `incomplete`, and the projection that
    follows says unknown rather than inventing the missing half.
    """
    headers = {}
    for line in (text or '').splitlines():
        match = HEADER.match(line)
        if match and match.group(1) in REPORT_HEADERS and match.group(1) not in headers:
            headers[match.group(1)] = match.group(2)
    path = headers.get('Position-dispatch-manifest')
    sha = headers.get('Position-dispatch-sha256')
    record = {'headers': headers, REFERENCE_FIELD: None,
              'incomplete': bool(path) != bool(sha),
              'compiled_claim': bool(headers.get('Compiled-position')
                                     or (headers.get('Template-id') or '').startswith('position/'))}
    if path and sha:
        record[REFERENCE_FIELD] = {'manifest_path': path, 'manifest_sha256': sha}
    elif record['incomplete'] or record['compiled_claim']:
        # A compiled claim without a resolvable pair is explicit unknown. Giving
        # it the legacy reading would hand it the long template's identity.
        record[REFERENCE_FIELD] = {'manifest_path': path or '', 'manifest_sha256': sha or ''}
    return record


def project_report(text, *, expected=None):
    record = report_record(text)
    projection = project(record, expected=expected)
    projection['headers'] = record['headers']
    projection['incomplete_reference'] = record['incomplete']
    return projection


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, help='project a report file instead of a JSON record on stdin')
    parser.add_argument('--expected', help='JSON object of binding values the reference must match')
    args = parser.parse_args()
    expected = json.loads(args.expected) if args.expected else None
    if expected is not None and not isinstance(expected, dict):
        raise ValueError('--expected must be a JSON object')
    if args.report is not None:
        result = project_report(args.report.read_text(encoding='utf-8'), expected=expected)
    else:
        result = project(json.load(sys.stdin), expected=expected)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as exc:
        sys.exit(f'position-attribution: {exc}')
