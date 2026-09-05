"""Read recorded position identities without assigning historical fallback hashes."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys


def validate_reference(value):
    if not isinstance(value, dict) or set(value) != {'manifest_path', 'manifest_sha256'}:
        raise ValueError('position_dispatch must contain manifest_path and manifest_sha256')
    path, sha = value['manifest_path'], value['manifest_sha256']
    if not isinstance(path, str) or not Path(path).is_absolute() or '\x00' in path or Path(path).name != 'manifest.json':
        raise ValueError('position_dispatch.manifest_path must be an absolute manifest.json path')
    if not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha):
        raise ValueError('position_dispatch.manifest_sha256 must be 64 lowercase hex characters')


def report_record(text):
    labels = {'Position-dispatch-manifest': 'manifest_path', 'Position-dispatch-sha256': 'manifest_sha256',
              'Compiled-position': 'position', 'Template-id': 'template_id', 'Template-version': 'producer_template_version',
              'Producer-role': 'report_producer_role',
              'Report-id': 'report_id', 'Work-item': 'work_item', 'Revision-id': 'revision_id',
              'Dispatch-attempt-id': 'dispatch_attempt_id', 'Packet-id': 'packet_id'}
    record, reference = {}, {}
    for line in text.splitlines():
        match = re.match(r'^(?:\*\*)?([A-Za-z][\w-]*):(?:\*\*)?[ \t]*(.*)$', line)
        if not match or match[1] not in labels:
            continue
        key = labels[match[1]]
        target = reference if key.startswith('manifest_') else record
        value = match[2].strip()
        if key in target and target[key] != value:
            record['attribution_error'] = f'conflicting {match[1]} headers'
        target[key] = value
    if reference:
        record['position_dispatch'] = reference
    return record


def resolve_reference(reference, *, expected=None):
    """Return the existing binder's validated manifest and archive-aware paths."""
    validate_reference(reference)
    spec = importlib.util.spec_from_file_location('_lore_position_bind', Path(__file__).with_name('position-bind.py'))
    binder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(binder)
    return binder.resolve_dispatch(**reference, expected=expected)


def legacy_role(attribution):
    """Map a resolved position onto the existing evidence producer vocabulary."""
    position = attribution.get('position')
    if position == 'designer':
        return 'advisor' if attribution.get('bindings', {}).get('mode') == 'consultation' else 'spec-lead'
    return {'investigator': 'researcher', 'worker': 'worker', 'reviewer': 'advisor'}.get(position)


def project(record, *, expected=None):
    result = dict.fromkeys(('position_dispatch', 'template_id', 'template_version', 'template_path',
                            'position', 'framework', 'bindings', 'wrapper'))
    present = ('position_dispatch' in record or 'producer_attribution' in record or
               'attribution_error' in record or record.get('position') is not None or
               str(record.get('template_id', '')).startswith('position/'))
    if not present:
        return dict(result, status='legacy', reason='no compiled producer metadata')
    result['position_dispatch'] = record.get('position_dispatch')
    try:
        if record.get('attribution_error'):
            raise ValueError(record['attribution_error'])
        validate_reference(result['position_dispatch'])
        resolved = resolve_reference(result['position_dispatch'], expected=expected)
        manifest = resolved['manifest']
        producer = manifest['producer']
        for key in ('position', 'template_id'):
            if key in record and record[key] != producer[key]:
                raise ValueError(f'recorded {key} does not match dispatch')
        if 'producer_template_version' in record and record['producer_template_version'] != producer['template_version']:
            raise ValueError('report template version does not match dispatch')
        if 'report_producer_role' in record and record['report_producer_role'] != producer['position']:
            raise ValueError('report producer role does not match position')
        for key in ('work_item', 'report_id', 'revision_id', 'packet_id', 'dispatch_attempt_id'):
            if key in record and record[key] != manifest['bindings'][key]:
                raise ValueError(f'report {key} does not match dispatch')
        if 'producer_role' in record and record['producer_role'] != legacy_role(dict(producer, bindings=manifest['bindings'])):
            raise ValueError('evidence producer role does not match position')
        result.update({key: producer[key] for key in ('position', 'framework', 'template_id', 'template_version')})
        result.update(template_path=manifest['native']['source_path'], bindings=manifest['bindings'], wrapper=manifest['wrapper'])
        return dict(result, status='resolved', reason=None)
    except (ValueError, OSError, KeyError, TypeError, ImportError, AttributeError) as exc:
        return dict(result, status='unknown', reason=str(exc))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--expected', default='{}')
    args = parser.parse_args()
    record = report_record(args.report.read_text()) if args.report else json.load(sys.stdin)
    print(json.dumps(project(record, expected=json.loads(args.expected))))


if __name__ == '__main__':
    main()
