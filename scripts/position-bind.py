#!/usr/bin/env python3
"""Publish and validate immutable prepared position dispatches."""
from __future__ import annotations

import argparse
import fcntl
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile

from position_compile import POSITIONS, digest, encoded, read, run, validate_descriptor
from packet_builder import pointer, show

SCRIPTS = Path(__file__).resolve().parent
FIELDS = ('work_item', 'task_id', 'revision_id', 'packet_id', 'packet_pointer',
          'dispatch_attempt_id', 'assignment', 'report_id', 'report_path',
          'execution_root', 'mode', 'consultation_id', 'domain', 'reply_destination')
CORE = ('work_item', 'dispatch_attempt_id', 'assignment', 'report_id', 'report_path', 'execution_root')
TASK_BINDINGS = ('task_id', 'revision_id', 'packet_id', 'packet_pointer')


def nonempty(value):
    return isinstance(value, str) and bool(value.strip()) and '\x00' not in value


def token(value, field):
    if not nonempty(value) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', value):
        raise ValueError(f'invalid {field}: expected a path-safe identity')
    return value


def absolute(value, field):
    if not nonempty(value) or not Path(value).is_absolute():
        raise ValueError(f'{field} must be an absolute path')
    return Path(value).resolve()


def validate_bindings(bindings, position, kdir, required=(), *, preparation=True):
    """Validate explicit identities against the canonical packet without inventing bindings."""
    if not isinstance(bindings, dict) or set(bindings) != {*FIELDS, 'absence_reasons'}:
        raise ValueError('bindings must contain every declared field and absence_reasons')
    reasons = bindings['absence_reasons']
    if not isinstance(reasons, dict) or set(reasons) - set(FIELDS):
        raise ValueError('invalid absence_reasons')
    if set(required) - set(FIELDS):
        raise ValueError('unknown required binding')
    required = set(CORE) | set(required)
    if position not in POSITIONS:
        raise ValueError('invalid position')
    if position == 'designer':
        if bindings['mode'] not in ('planning', 'consultation'):
            raise ValueError('designer requires explicit planning or consultation mode')
        required.add('mode')
        if bindings['mode'] == 'consultation':
            required.update(('consultation_id', 'domain', 'reply_destination'))
    elif bindings['mode'] is not None:
        raise ValueError('mode is valid only for designer')
    if bindings['mode'] != 'consultation' and any(bindings[f] is not None for f in ('consultation_id', 'domain', 'reply_destination')):
        raise ValueError('consultation fields require designer consultation mode')
    for field in FIELDS:
        value = bindings[field]
        if value is None:
            if field in required:
                raise ValueError(f'missing required binding: {field}')
            if not nonempty(reasons.get(field)):
                raise ValueError(f'absent {field} requires an explicit reason')
        elif not nonempty(value) or field in reasons:
            raise ValueError(f'invalid or conflicting binding: {field}')
    for field in ('work_item', 'dispatch_attempt_id', 'report_id'):
        token(bindings[field], field)
    if bindings['revision_id'] is not None and not re.fullmatch(r'[0-9a-f]{12}', bindings['revision_id']):
        raise ValueError('invalid revision_id')
    item = kdir.resolve() / '_work' / bindings['work_item']
    if not item.is_dir() or item.is_symlink():
        raise ValueError('work item must exist in the selected store')
    execution = absolute(bindings['execution_root'], 'execution_root')
    if preparation and (not execution.is_dir() or str(execution) != bindings['execution_root']):
        raise ValueError('execution_root must name the final physical directory')
    report = absolute(bindings['report_path'], 'report_path')
    if not report.is_relative_to(item) or str(report) != bindings['report_path']:
        raise ValueError('report_path must be inside the assigned work item')
    if report.is_relative_to(item / 'position-dispatch'):
        raise ValueError('report_path cannot overwrite prepared dispatch artifacts')
    if position == 'worker' and report != item / 'worker-reports' / (bindings['report_id'] + '.md'):
        raise ValueError('worker report_path must match worker-reports/<report_id>.md')
    packet = None
    if bindings['packet_id'] is not None:
        packet = show(kdir, bindings['packet_id'])
        for field in ('work_item', 'task_id', 'revision_id', 'dispatch_attempt_id'):
            if packet.get(field) != bindings[field]:
                raise ValueError(f'canonical packet {field} mismatch')
        if packet.get('recipient_role') != position:
            raise ValueError('canonical packet position mismatch')
        if bindings['packet_pointer'] != pointer(kdir, bindings['packet_id']):
            raise ValueError('canonical packet pointer mismatch')
    elif bindings['packet_pointer'] is not None:
        raise ValueError('packet_pointer requires packet_id')
    return packet


def file_record(path, data):
    return {'path': str(path), 'sha256': digest(data), 'bytes': len(data)}


def validate_dispatch(manifest_path, manifest_sha256=None, *, expected=None):
    """Resolve a prepared producer reference; this does not establish delivery or acceptance."""
    path = Path(manifest_path)
    raw = path.read_bytes()
    if manifest_sha256 is not None and digest(raw) != manifest_sha256:
        raise ValueError('dispatch manifest digest mismatch')
    m = json.loads(raw)
    if m['schema_version'] != 1 or m['state'] != 'prepared':
        raise ValueError('unsupported dispatch manifest')
    root = path.parent.resolve()
    if path.name != 'manifest.json' or root != Path(m['work_item_path']) / 'position-dispatch' / m['bindings']['dispatch_attempt_id']:
        raise ValueError('dispatch manifest location mismatch')
    if {p.name for p in root.iterdir()} != {'manifest.json', *m['files']}:
        raise ValueError('dispatch bundle membership mismatch')
    for name, record in m['files'].items():
        target = root / name
        if target.is_symlink() or target.resolve().parent != root or record != file_record(target, target.read_bytes()):
            raise ValueError(f'dispatch content mismatch: {name}')
    descriptor = json.loads((root / 'descriptor.json').read_bytes())
    validated = validate_descriptor(descriptor)
    if m['producer'] != {key: descriptor[key] for key in ('position', 'framework', 'template_id', 'template_version', 'descriptor_path', 'descriptor_sha256')}:
        raise ValueError('dispatch producer mismatch')
    if m['dependencies'] != validated['retained_files'] or m['contract_references'] != validated['contract_references']:
        raise ValueError('dispatch dependency references mismatch')
    if json.loads((root / 'bindings.json').read_bytes()) != m['bindings']:
        raise ValueError('dispatch bindings snapshot mismatch')
    if (root / 'native.md').read_bytes() != Path(validated['artifact_path']).read_bytes():
        raise ValueError('dispatch native definition mismatch')
    if m['native'] != {'path': str(root / 'native.md'), 'sha256': validated['artifact_sha256'],
                        'surface': validated['native_surface'], 'source_path': validated['artifact_path']}:
        raise ValueError('dispatch native reference mismatch')
    payload = (root / 'payload.md').read_bytes()
    if m['payload'] != file_record(root / 'payload.md', payload):
        raise ValueError('dispatch payload reference mismatch')
    offset = 0
    for component in m['accounting']['payload_components']:
        size = component['bytes']
        if not isinstance(size, int) or size <= 0 or digest(payload[offset:offset + size]) != component['sha256']:
            raise ValueError('dispatch component accounting mismatch')
        offset += size
    native_bytes = len((root / 'native.md').read_bytes()) if validated['native_surface']['consumption'] == 'agent-definition' else 0
    if offset != len(payload) or m['accounting']['payload_bytes'] != offset or m['accounting']['native_definition_bytes'] != native_bytes or m['accounting']['prepared_input_bytes'] != offset + native_bytes:
        raise ValueError('dispatch byte accounting mismatch')
    packet = validate_bindings(m['bindings'], m['producer']['position'], Path(m['kdir']), m['required_bindings'], preparation=False)
    if packet is not None and encoded(packet) != (root / 'packet.json').read_bytes():
        raise ValueError('canonical packet changed after preparation')
    for key, value in (expected or {}).items():
        actual = m['bindings'].get(key, m['producer'].get(key))
        if actual != value:
            raise ValueError(f'dispatch {key} mismatch')
    return m


def publish(descriptor, bindings, kdir, guidance, *, required=(), wrapper=None, prefix=b'', suffix=b'', contract_delivery='referenced'):
    """Freeze one composed payload and its native definition, or verify an identical retry."""
    if not re.fullmatch('[0-9a-f]{64}', descriptor.get('descriptor_sha256', '')):
        raise ValueError('descriptor_sha256 is required')
    d = validate_descriptor(descriptor)
    packet = validate_bindings(bindings, d['position'], kdir, required)
    if contract_delivery not in ('referenced', 'included'):
        raise ValueError('contract_delivery must be referenced or included')
    run(['bash', str(SCRIPTS / 'validate-dispatch-guidance.sh')], data=guidance)
    # The compiler normalizes its timestamp; dispatch preserves the admitted bytes.
    from position_compile import normalize_guidance
    if normalize_guidance(guidance) != read(Path(d['guidance_path'])):
        raise ValueError('guidance identity differs from selected compilation; compile with the admitted guidance')
    if not isinstance(prefix, bytes) or not isinstance(suffix, bytes):
        raise ValueError('prefix and suffix must be bytes')
    for content in (prefix, suffix):
        content.decode('utf-8')
        if b'\x00' in content or b'lore-dispatch-guidance:v1:' in content:
            raise ValueError('wrapper content cannot carry another guidance floor')
    if wrapper is not None:
        if set(wrapper) != {'template_id', 'template_version', 'path', 'sha256'} or not nonempty(wrapper['template_id']) or not re.fullmatch('[0-9a-f]{12}', wrapper['template_version']):
            raise ValueError('invalid wrapper identity')
        if digest(read(Path(wrapper['path']))) != wrapper['sha256']:
            raise ValueError('wrapper source digest mismatch')
    elif prefix or suffix:
        raise ValueError('wrapper content requires wrapper identity')
    root = kdir.resolve() / '_work' / bindings['work_item'] / 'position-dispatch' / bindings['dispatch_attempt_id']
    manifest_path = root / 'manifest.json'
    # A manifest cannot embed its own digest. Reports carry this path and the
    # digest returned after publication; all other identity fields are in-band.
    envelope = encoded({'position_dispatch': {'manifest_path': str(manifest_path),
                         'producer': {key: d[key] for key in ('position', 'framework', 'template_id', 'template_version')},
                         'bindings': bindings}})
    components = [('guidance', guidance), ('separator', b'\n')]
    if bindings['packet_pointer']:
        components.append(('packet_pointer', (bindings['packet_pointer'] + '\n').encode()))
    components.append(('wrapper_prefix', prefix))
    if d['native_surface']['consumption'] == 'prompt-text':
        components.append(('compiled_body', read(Path(d['body_path']))))
    components += [('identity_envelope', b'\n' + envelope), ('wrapper_suffix', suffix)]
    components = [(name, data) for name, data in components if data]
    if contract_delivery == 'included':
        components.append(('report_contract', b'\n' + read(Path(d['contract_references'][0]['path']))))
    payload = b''.join(data for _, data in components)
    files = {'payload.md': payload, 'descriptor.json': encoded(descriptor), 'bindings.json': encoded(bindings),
             'guidance.md': guidance, 'native.md': read(Path(d['artifact_path']))}
    if packet is not None:
        files['packet.json'] = encoded(packet)
    if wrapper is not None:
        files['wrapper-source.md'] = read(Path(wrapper['path']))
    for name, data in (('wrapper-prefix.md', prefix), ('wrapper-suffix.md', suffix)):
        if data:
            files[name] = data
    m = {'schema_version': 1, 'state': 'prepared', 'kdir': str(kdir.resolve()), 'work_item_path': str(root.parent.parent),
         'producer': {key: descriptor[key] for key in ('position', 'framework', 'template_id', 'template_version', 'descriptor_path', 'descriptor_sha256')},
         'wrapper': wrapper, 'wrapper_absence_reason': None if wrapper else 'no wrapper supplied',
         'bindings': bindings, 'required_bindings': sorted(set(CORE) | set(required)),
         'dependencies': d['retained_files'], 'contract_references': d['contract_references'],
         'native': {'path': str(root / 'native.md'), 'sha256': digest(files['native.md']),
                    'surface': d['native_surface'], 'source_path': d['artifact_path']},
         'payload': file_record(root / 'payload.md', payload),
         'files': {name: file_record(root / name, data) for name, data in files.items()},
         'accounting': {'unit': 'bytes', 'payload_bytes': len(payload),
                        'payload_components': [{'name': name, 'bytes': len(data), 'sha256': digest(data)} for name, data in components],
                        'native_definition_bytes': len(files['native.md']) if d['native_surface']['consumption'] == 'agent-definition' else 0,
                        'prepared_input_bytes': len(payload) + (len(files['native.md']) if d['native_surface']['consumption'] == 'agent-definition' else 0),
                        'contract_delivery': contract_delivery,
                        'referenced_contract_bytes': d['accounting']['on_demand_contract_bytes'],
                        'delivery_proven': False}}
    files['manifest.json'] = encoded(m)
    root.parent.mkdir(parents=True, exist_ok=True)
    if root.parent.is_symlink() or root.is_symlink() or root.parent.resolve() != root.parent:
        raise ValueError('dispatch storage must remain inside the assigned work item')
    with (root.parent / '.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if root.exists():
            validate_dispatch(manifest_path)
            if {p.name: p.read_bytes() for p in root.iterdir()} != files:
                raise ValueError('changed payload or binding for existing attempt; use fresh attempt and report IDs')
        else:
            for prior in root.parent.glob('*/manifest.json'):
                if json.loads(prior.read_bytes())['bindings']['report_id'] == bindings['report_id']:
                    raise ValueError('report_id already belongs to another attempt')
            staging = Path(tempfile.mkdtemp(prefix='.prepare-', dir=root.parent))
            try:
                for name, data in files.items():
                    (staging / name).write_bytes(data)
                staging.rename(root)
            finally:
                if staging.exists():
                    shutil.rmtree(staging)
    return {'manifest_path': str(manifest_path), 'manifest_sha256': digest(files['manifest.json']),
            'payload_path': str(root / 'payload.md'), 'payload_sha256': digest(payload),
            'native_path': str(root / 'native.md'), 'native_sha256': digest(files['native.md'])}


def prepare_session(context, *, position, framework, slug, execution_root, packet_id, kdir):
    """Prepare the exact extra_context consumed by the existing worker prompt path."""
    allowed = {'bindings', 'descriptor', 'guidance_file', 'class', 'ceremony'}
    if not isinstance(context, dict) or set(context) - allowed:
        raise ValueError('position context accepts bindings, descriptor, guidance_file, class, ceremony only')
    b = context['bindings']
    if not isinstance(b, dict):
        raise ValueError('bindings must be an object')
    expected = {'work_item': slug.rsplit('--w', 1)[0], 'execution_root': execution_root, 'packet_id': packet_id}
    for key, value in expected.items():
        if b.get(key) != value:
            raise ValueError(f'session {key} conflicts with bindings')
    validate_bindings(b, position, kdir, TASK_BINDINGS)
    existing = kdir / '_work' / b['work_item'] / 'position-dispatch' / b['dispatch_attempt_id'] / 'manifest.json'
    if existing.exists():
        m = validate_dispatch(existing, expected={'position': position, 'framework': framework, **expected})
        if m['bindings'] != b or m['wrapper'] is not None:
            raise ValueError('changed session bindings for existing attempt')
        if context.get('descriptor') is not None and json.loads((existing.parent / 'descriptor.json').read_bytes()) != context['descriptor']:
            raise ValueError('changed descriptor for existing attempt')
        if context.get('guidance_file') and read(Path(context['guidance_file'])) != (existing.parent / 'guidance.md').read_bytes():
            raise ValueError('changed guidance for existing attempt')
        ref = {'manifest_path': str(existing), 'manifest_sha256': digest(existing.read_bytes()),
               'payload_path': m['payload']['path'], 'payload_sha256': m['payload']['sha256'],
               'native_path': m['native']['path'], 'native_sha256': m['native']['sha256']}
    else:
        from position_compile import compile_position
        guidance = read(Path(context['guidance_file'])) if context.get('guidance_file') else run(['bash', str(SCRIPTS / 'render-dispatch-guidance.sh')])
        d = context.get('descriptor') or compile_position(position, framework, kdir, Path(context['guidance_file']) if context.get('guidance_file') else None)
        if d['position'] != position or d['framework'] != framework:
            raise ValueError('session descriptor position/framework mismatch')
        ref = publish(d, b, kdir, guidance, required=TASK_BINDINGS)
    return {'dispatch_guidance': Path(ref['payload_path']).read_text(), 'position_dispatch': ref}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    verbs = parser.add_subparsers(dest='verb', required=True)
    bind = verbs.add_parser('bind')
    for name in ('descriptor', 'bindings', 'kdir', 'guidance-file'):
        bind.add_argument('--' + name, required=True, type=Path)
    bind.add_argument('--require', action='append', default=[])
    bind.add_argument('--wrapper', type=Path)
    bind.add_argument('--prefix-file', type=Path)
    bind.add_argument('--suffix-file', type=Path)
    bind.add_argument('--contract-delivery', choices=('referenced', 'included'), default='referenced')
    check = verbs.add_parser('validate')
    check.add_argument('manifest', type=Path)
    check.add_argument('--sha256')
    session = verbs.add_parser('session')
    for name in ('position', 'framework', 'slug', 'execution-root', 'packet-id'):
        session.add_argument('--' + name, required=True)
    session.add_argument('--kdir', required=True, type=Path)
    args = parser.parse_args()
    if args.verb == 'session':
        result = prepare_session(json.load(sys.stdin), position=args.position, framework=args.framework,
                                 slug=args.slug, execution_root=args.execution_root, packet_id=args.packet_id, kdir=args.kdir.resolve())
    elif args.verb == 'validate':
        result = validate_dispatch(args.manifest, args.sha256)
    else:
        result = publish(json.loads(read(args.descriptor)), json.loads(read(args.bindings)), args.kdir,
                         read(args.guidance_file), required=args.require,
                         wrapper=json.loads(read(args.wrapper)) if args.wrapper else None,
                         prefix=read(args.prefix_file) if args.prefix_file else b'',
                         suffix=read(args.suffix_file) if args.suffix_file else b'', contract_delivery=args.contract_delivery)
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as exc:
        sys.exit(f'position-bind: {exc}')
