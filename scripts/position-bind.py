#!/usr/bin/env python3
"""Publish and validate immutable prepared position dispatches."""
from __future__ import annotations

import argparse
import copy
import os
import fcntl
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import uuid

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


def validate_bindings(bindings, position, kdir, required=(), *, preparation=True, pending_root=False, archived=False):
    """Validate explicit identities against the canonical packet without inventing bindings."""
    if not isinstance(bindings, dict) or set(bindings) != {*FIELDS, 'absence_reasons'}:
        raise ValueError('bindings must contain every declared field and absence_reasons')
    reasons = bindings['absence_reasons']
    if not isinstance(reasons, dict) or set(reasons) - set(FIELDS):
        raise ValueError('invalid absence_reasons')
    if set(required) - set(FIELDS):
        raise ValueError('unknown required binding')
    required = set(CORE) | set(required)
    if pending_root:
        required.discard("execution_root")
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
    physical_item = archived_item(kdir.resolve(), bindings['work_item']) if archived else item
    if not physical_item.is_dir() or physical_item.is_symlink():
        raise ValueError('work item must exist in the selected store')
    execution = absolute(bindings['execution_root'], 'execution_root') if bindings['execution_root'] is not None else None
    if execution is not None and (str(execution) != bindings['execution_root'] or (preparation and not execution.is_dir())):
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
        for field in ('work_item', 'task_id', 'revision_id'):
            if packet.get(field) != bindings[field]:
                raise ValueError(f'canonical packet {field} mismatch')
        unbound_packet = (packet.get('schema_version') == '1' and
                          packet.get('revision_id') is None and
                          packet.get('dispatch_attempt_id') is None and
                          nonempty(packet.get('unbound_reason')))
        if not unbound_packet and packet.get('dispatch_attempt_id') != bindings['dispatch_attempt_id']:
            raise ValueError('canonical packet dispatch_attempt_id mismatch')
        if packet.get('recipient_role') != position:
            raise ValueError('canonical packet position mismatch')
        if preparation and packet.get('delivery_stage') != 'synthesized' and not packet.get('synthesis_waiver'):
            raise ValueError(f"packet {bindings['packet_id']} is a candidate set nobody has synthesized; run "
                             f"`lore packet synthesize {bindings['packet_id']} --by <position> [--drop PATH REASON]... [--add PATH REASON]...` "
                             "and bind again, or record a synthesis_waiver when the packet is built")
        if bindings['packet_pointer'] != pointer(kdir, bindings['packet_id']):
            raise ValueError('canonical packet pointer mismatch')
    elif bindings['packet_pointer'] is not None:
        raise ValueError('packet_pointer requires packet_id')
    return packet


def file_record(path, data):
    return {'path': str(path), 'sha256': digest(data), 'bytes': len(data)}


def archived_item(kdir, slug):
    canonical = kdir / '_work' / '_archive' / slug
    historical = kdir / '_archive' / slug
    if canonical.exists() and historical.exists():
        raise ValueError('conflicting archived item locations')
    return canonical if canonical.exists() or not historical.exists() else historical


def resolve_manifest_path(manifest_path):
    """Resolve active references through canonical archival or the historical layout."""
    path = Path(manifest_path)
    if not path.is_absolute() or path.name != 'manifest.json':
        raise ValueError('invalid dispatch manifest path')
    if path.parent.parent.name != 'position-dispatch' or path.parents[3].name not in ('_work', '_archive'):
        raise ValueError('invalid dispatch manifest location')
    container = path.parents[3]
    kdir = container.parent.parent if container.name == '_archive' and container.parent.name == '_work' else container.parent
    slug = path.parents[2].name
    active = kdir / '_work' / slug
    archived = archived_item(kdir, slug)
    if active.exists() and archived.exists():
        raise ValueError('active and archived item conflict')
    item = active if active.exists() else archived
    resolved = item / 'position-dispatch' / path.parent.name / path.name
    if resolved.is_symlink() or resolved.resolve() != resolved:
        raise ValueError('dispatch reference cannot follow symlinks')
    return resolved


def validate_dispatch(manifest_path, manifest_sha256=None, *, expected=None):
    """Resolve a prepared producer reference; this does not establish delivery or acceptance."""
    path = resolve_manifest_path(manifest_path)
    raw = path.read_bytes()
    if manifest_sha256 is not None and digest(raw) != manifest_sha256:
        raise ValueError('dispatch manifest digest mismatch')
    m = json.loads(raw)
    if m['schema_version'] != 1 or m['state'] != 'prepared':
        raise ValueError('unsupported dispatch manifest')
    root = path.parent.resolve()
    recorded_root = Path(m['work_item_path']) / 'position-dispatch' / m['bindings']['dispatch_attempt_id']
    original_item = Path(m['kdir']) / '_work' / m['bindings']['work_item']
    if Path(m['work_item_path']) != original_item or resolve_manifest_path(recorded_root / 'manifest.json') != path:
        raise ValueError('dispatch manifest location mismatch')
    if {p.name for p in root.iterdir()} != {'manifest.json', *m['files']}:
        raise ValueError('dispatch bundle membership mismatch')
    for name, record in m['files'].items():
        target = root / name
        if target.is_symlink() or target.resolve().parent != root or record != file_record(recorded_root / name, target.read_bytes()):
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
    if m['native'] != {'path': str(recorded_root / 'native.md'), 'sha256': validated['artifact_sha256'],
                        'surface': validated['native_surface'], 'source_path': validated['artifact_path']}:
        raise ValueError('dispatch native reference mismatch')
    payload = (root / 'payload.md').read_bytes()
    if m['payload'] != file_record(recorded_root / 'payload.md', payload):
        raise ValueError('dispatch payload reference mismatch')
    offset = 0
    for component in m['accounting']['payload_components']:
        size = component['bytes']
        if not isinstance(size, int) or size <= 0 or digest(payload[offset:offset + size]) != component['sha256']:
            raise ValueError('dispatch component accounting mismatch')
        offset += size
    native_member = 'native.md'
    if m.get('dispatch_route') not in (None, 'native-subagent'):
        raise ValueError('unsupported dispatch route')
    if m.get('dispatch_route') == 'native-subagent':
        selection = json.loads((root / 'selection.json').read_bytes())
        if m.get('selection') != file_record(recorded_root / 'selection.json', encoded(selection)):
            raise ValueError('native selection reference mismatch')
        registration = selection['registration']
        native_member = 'selection.md' if registration is not None else 'native.md'
        if registration is not None and registration != {
                'filename': selection['tool_input']['subagent_type'] + '.md',
                'sha256': digest((root / native_member).read_bytes()),
                'bytes': len((root / native_member).read_bytes())}:
            raise ValueError('native registration reference mismatch')
        if 'launch.json' in m['files']:
            raise ValueError('native subagent cannot carry session activation')
    elif any(name in m['files'] for name in ('selection.json', 'selection.md')) or 'selection' in m:
        raise ValueError('native selection requires its dispatch route')
    native_bytes = len((root / native_member).read_bytes()) if validated['native_surface']['consumption'] == 'agent-definition' else 0
    if offset != len(payload) or m['accounting']['payload_bytes'] != offset or m['accounting']['native_definition_bytes'] != native_bytes or m['accounting']['prepared_input_bytes'] != offset + native_bytes:
        raise ValueError('dispatch byte accounting mismatch')
    packet = validate_bindings(m['bindings'], m['producer']['position'], Path(m['kdir']), m['required_bindings'], preparation=False, archived=root != recorded_root)
    if packet is not None and encoded(packet) != (root / 'packet.json').read_bytes():
        raise ValueError('canonical packet changed after preparation')
    for key, value in (expected or {}).items():
        actual = m['bindings'].get(key, m['producer'].get(key))
        if actual != value:
            raise ValueError(f'dispatch {key} mismatch')
    return m


def validate_wrapper(wrapper, prefix, suffix, wrapper_source=None):
    if not isinstance(prefix, bytes) or not isinstance(suffix, bytes):
        raise ValueError('prefix and suffix must be bytes')
    for content in (prefix, suffix):
        content.decode('utf-8')
        if b'\x00' in content or b'lore-dispatch-guidance:v1:' in content:
            raise ValueError('wrapper content cannot carry another guidance floor')
    if wrapper is not None:
        wrapper_source = read(Path(wrapper['path'])) if wrapper_source is None else wrapper_source
        if set(wrapper) != {'template_id', 'template_version', 'path', 'sha256'} or not nonempty(wrapper['template_id']) or not re.fullmatch('[0-9a-f]{12}', wrapper['template_version']):
            raise ValueError('invalid wrapper identity')
        if digest(wrapper_source) != wrapper['sha256']:
            raise ValueError('wrapper source digest mismatch')
    elif prefix or suffix:
        raise ValueError('wrapper content requires wrapper identity')
    return wrapper_source


def payload_components(d, bindings, manifest_path, guidance, prefix, suffix, contract_delivery):
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
    return components


def publish(descriptor, bindings, kdir, guidance, *, required=(), wrapper=None, prefix=b'', suffix=b'', contract_delivery='referenced', native_model=None, wrapper_source=None):
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
    wrapper_source = validate_wrapper(wrapper, prefix, suffix, wrapper_source)
    root = kdir.resolve() / '_work' / bindings['work_item'] / 'position-dispatch' / bindings['dispatch_attempt_id']
    manifest_path = root / 'manifest.json'
    components = payload_components(d, bindings, manifest_path, guidance, prefix, suffix, contract_delivery)
    payload = b''.join(data for _, data in components)
    files = {'payload.md': payload, 'descriptor.json': encoded(descriptor), 'bindings.json': encoded(bindings),
             'guidance.md': guidance, 'native.md': read(Path(d['artifact_path']))}
    if native_model is None:
        files['launch.json'] = encoded(render_activation(d, bindings['dispatch_attempt_id']))
    else:
        selection, registration = render_selection(d, bindings['dispatch_attempt_id'], native_model)
        files['selection.json'] = encoded(selection)
        if registration is not None:
            files['selection.md'] = registration
    native_member = 'selection.md' if 'selection.md' in files else 'native.md'
    if packet is not None:
        files['packet.json'] = encoded(packet)
    if wrapper is not None:
        files['wrapper-source.md'] = wrapper_source
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
                        'native_definition_bytes': len(files[native_member]) if d['native_surface']['consumption'] == 'agent-definition' else 0,
                        'prepared_input_bytes': len(payload) + (len(files[native_member]) if d['native_surface']['consumption'] == 'agent-definition' else 0),
                        'contract_delivery': contract_delivery,
                        'referenced_contract_bytes': d['accounting']['on_demand_contract_bytes'],
                        'delivery_proven': False}}
    if native_model is not None:
        m.update(dispatch_route='native-subagent', selection=file_record(root / 'selection.json', files['selection.json']))
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


def invoke_adapter(descriptor, operation_field, *arguments):
    profile = json.loads(read(SCRIPTS.parent / 'adapters/capabilities.json'))['frameworks'][descriptor['framework']]
    if profile.get('position_compilation') != descriptor['native_surface']:
        raise ValueError('compiled native surface changed; recompile before activation')
    adapter_name = 'adapters/agents/' + descriptor['framework'] + '.sh'
    adapter_bytes = read(SCRIPTS.parent / adapter_name)
    retained = next((component for component in descriptor['components'] if component['name'] == adapter_name), None)
    if retained != {'name': adapter_name, 'bytes': len(adapter_bytes), 'sha256': digest(adapter_bytes)}:
        raise ValueError('compiled native renderer changed; recompile before activation')
    operation = profile.get('position_compilation', {}).get(operation_field)
    if not isinstance(operation, str) or not re.fullmatch(r'[a-z_]+', operation):
        raise ValueError('native adapter operation unavailable')
    result = json.loads(run(['bash', str(SCRIPTS.parent / 'adapters/agents' / (descriptor['framework'] + '.sh')),
                             operation, descriptor['artifact_path'], *arguments],
                            env=dict(os.environ, LORE_FRAMEWORK=descriptor['framework'])))
    return result


def render_activation(descriptor, attempt):
    result = invoke_adapter(descriptor, 'activation_operation', attempt)
    if set(result) != {'args', 'env', 'prompt_flag'} or not isinstance(result['args'], list) or not isinstance(result['env'], dict):
        raise ValueError('invalid native activation')
    return result


def render_selection(descriptor, attempt, model):
    if not nonempty(model) or any(char.isspace() for char in model):
        raise ValueError('native selection requires an explicit model binding')
    selection = invoke_adapter(descriptor, 'selection_operation', attempt, model)
    if set(selection) != {'tool', 'tool_input', 'prompt_field', 'registration', 'readiness'}:
        raise ValueError('invalid native selection')
    if not nonempty(selection['tool']) or not isinstance(selection['tool_input'], dict) or not nonempty(selection['prompt_field']):
        raise ValueError('invalid native tool input')
    if selection['prompt_field'] in selection['tool_input'] or not isinstance(selection['readiness'], dict):
        raise ValueError('invalid native readiness contract')
    registration = selection['registration']
    content = None
    if registration is not None:
        if set(registration) != {'filename', 'content'} or not nonempty(registration['content']):
            raise ValueError('invalid native registration')
        name = token(selection['tool_input'].get('subagent_type'), 'subagent_type')
        if registration['filename'] != name + '.md':
            raise ValueError('native registration name mismatch')
        content = registration['content'].encode()
        selection['registration'] = {'filename': name + '.md', 'sha256': digest(content), 'bytes': len(content)}
    elif descriptor['native_surface']['consumption'] != 'prompt-text':
        raise ValueError('native agent definition requires registration')
    selection['model_binding'] = model
    return selection, content


def native_selection(manifest_path, manifest_sha256):
    resolved = resolve_dispatch(manifest_path, manifest_sha256)
    m = resolved['manifest']
    if m.get('dispatch_route') != 'native-subagent':
        raise ValueError('dispatch was not prepared for a native subagent')
    root = Path(resolved['resolved_manifest_path']).parent
    if root.parents[1] != Path(m['work_item_path']):
        raise ValueError('native selection requires an active work item')
    validate_bindings(m['bindings'], m['producer']['position'], Path(m['kdir']), m['required_bindings'], preparation=False)
    stored = json.loads(read(root / 'selection.json'))
    selection, registration = render_selection(json.loads(read(root / 'descriptor.json')),
                                               m['bindings']['dispatch_attempt_id'], stored['model_binding'])
    if stored != selection or (registration is not None and read(root / 'selection.md') != registration):
        raise ValueError('native selection changed after publication')
    return resolved, selection, registration


def registration_path(selection, scope):
    if scope is None:
        raise ValueError('native definition requires an explicit registration scope')
    scope = Path(scope)
    if not scope.is_absolute() or scope.resolve() != scope or not scope.is_dir() or scope.name != 'agents' or scope.parent.name != '.claude':
        raise ValueError('registration scope must be an existing physical .claude/agents directory')
    return scope / selection['registration']['filename']


def register_native(manifest_path, manifest_sha256, scope):
    _, selection, content = native_selection(manifest_path, manifest_sha256)
    if content is None:
        raise ValueError('this native selection does not use a registration file')
    target = registration_path(selection, scope)
    handle, staged = tempfile.mkstemp(prefix='.position-', dir=target.parent)
    try:
        with os.fdopen(handle, 'wb') as stream:
            stream.write(content)
        try:
            os.link(staged, target)
        except FileExistsError:
            pass
        if target.is_symlink() or not target.is_file() or target.read_bytes() != content:
            raise ValueError('native registration conflicts with retained bytes')
    finally:
        os.unlink(staged)
    return {'registration': file_record(target, content), 'readiness': selection['readiness']}


def native_input(manifest_path, manifest_sha256, scope=None):
    resolved, selection, content = native_selection(manifest_path, manifest_sha256)
    registration = None
    if content is not None:
        target = registration_path(selection, scope)
        if target.is_symlink() or not target.is_file() or target.read_bytes() != content:
            raise ValueError('native registration is missing or differs from retained bytes')
        registration = file_record(target, content)
    elif scope is not None:
        raise ValueError('text native selection does not accept a registration scope')
    tool_input = dict(selection['tool_input'])
    tool_input[selection['prompt_field']] = read(Path(resolved['payload_path'])).decode()
    return {'manifest_path': str(manifest_path), 'manifest_sha256': manifest_sha256,
            'tool': selection['tool'], 'tool_input': tool_input,
            'registration': registration, 'readiness': selection['readiness']}


def resolve_dispatch(manifest_path, manifest_sha256, *, expected=None):
    """Validate recorded bytes and return their current paths, without changing identity."""
    if not isinstance(manifest_sha256, str) or not re.fullmatch('[0-9a-f]{64}', manifest_sha256):
        raise ValueError('manifest_sha256 is required')
    manifest = validate_dispatch(manifest_path, manifest_sha256, expected=expected)
    root = resolve_manifest_path(manifest_path).parent
    return {'manifest': manifest, 'resolved_manifest_path': str(root / 'manifest.json'),
            'payload_path': str(root / 'payload.md'), 'native_path': str(root / 'native.md')}


def session_required_bindings(position):
    return TASK_BINDINGS if position == 'worker' else ('packet_id', 'packet_pointer')


def prepare_session(context, *, position, framework, slug, execution_root, packet_id, kdir):
    """Prepare the exact extra_context consumed by the existing worker prompt path."""
    allowed = {'bindings', 'descriptor', 'guidance_file', 'class', 'ceremony'}
    if not isinstance(context, dict) or set(context) - allowed:
        raise ValueError('position context accepts bindings, descriptor, guidance_file, class, ceremony only')
    b = context['bindings']
    if not isinstance(b, dict):
        raise ValueError('bindings must be an object')
    expected = {'work_item': slug.rsplit('--w', 1)[0], 'execution_root': execution_root or None, 'packet_id': packet_id}
    for key, value in expected.items():
        if b.get(key) != value:
            raise ValueError(f'session {key} conflicts with bindings')
    validate_bindings(b, position, kdir, session_required_bindings(position), pending_root=not execution_root)
    existing = kdir / '_work' / b['work_item'] / 'position-dispatch' / b['dispatch_attempt_id'] / 'manifest.json'
    for prior in existing.parent.parent.glob('*/manifest.json'):
        if prior != existing and json.loads(prior.read_bytes())['bindings']['report_id'] == b['report_id']:
            raise ValueError('report_id already belongs to another attempt')
    if existing.exists():
        m = validate_dispatch(existing, expected={'position': position, 'framework': framework, **expected})
        if m.get('dispatch_route') == 'native-subagent':
            raise ValueError('native subagent dispatch cannot be replayed as a session')
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
        if not re.fullmatch('[0-9a-f]{64}', d.get('descriptor_sha256', '')):
            raise ValueError('descriptor_sha256 is required')
        validate_descriptor(d)
        from position_compile import normalize_guidance
        run(['bash', str(SCRIPTS / 'validate-dispatch-guidance.sh')], data=guidance)
        if normalize_guidance(guidance) != read(Path(d['guidance_path'])):
            raise ValueError('guidance identity differs from selected compilation')
        activation = render_activation(d, b['dispatch_attempt_id'])
        if not execution_root:
            return {'position_preparation': {'position': position, 'framework': framework, 'slug': slug,
                    'packet_id': packet_id, 'bindings': b, 'descriptor': d, 'guidance': guidance.decode(), 'activation': activation}}
        ref = publish(d, b, kdir, guidance, required=session_required_bindings(position))
    return {'dispatch_guidance': Path(ref['payload_path']).read_text(), 'position_dispatch': ref}


def prepare_session_input(descriptor, bindings, kdir, guidance, *, slug=None, wrapper=None, prefix=b'', suffix=b''):
    """Validate inputs whose final execution directory belongs to the session host."""
    pending = {'position': descriptor['position'], 'framework': descriptor['framework'], 'slug': slug,
               'packet_id': bindings['packet_id'], 'bindings': bindings, 'descriptor': descriptor,
               'guidance': guidance.decode()}
    pending['activation'] = render_activation(descriptor, bindings['dispatch_attempt_id'])
    if wrapper is not None or prefix or suffix:
        source = validate_wrapper(wrapper, prefix, suffix)
        pending['composition'] = {'wrapper': wrapper, 'wrapper_source': source.decode(),
                                  'prefix': prefix.decode(), 'suffix': suffix.decode()}
    validate_session_preparation(pending, kdir=kdir)
    context = {'position_preparation': pending}
    bundle = kdir.resolve() / '_work' / bindings['work_item'] / 'position-dispatch' / bindings['dispatch_attempt_id']
    for prior in bundle.parent.glob('*/manifest.json'):
        if prior.parent != bundle and json.loads(read(prior))['bindings']['report_id'] == bindings['report_id']:
            raise ValueError('report_id already belongs to another attempt')
    if bundle.exists():
        session_reference(context, kdir=kdir)
    return context


def validate_session_preparation(pending, *, kdir, framework=None, slug=None, validate_inputs=True, validate_activation=True, preparation=True):
    required = {'position', 'framework', 'slug', 'packet_id', 'bindings', 'descriptor', 'guidance'}
    if not isinstance(pending, dict) or not required <= set(pending) or set(pending) - required - {'composition', 'activation'}:
        raise ValueError('invalid pending position preparation')
    b, d = pending['bindings'], pending['descriptor']
    if (framework is not None and pending['framework'] != framework or
            slug is not None and (slug.rsplit('--w', 1)[0] != b['work_item'] or pending['slug'] not in (None, slug)) or
            pending['packet_id'] != b['packet_id']):
        raise ValueError('pending session identity mismatch')
    if pending['slug'] is not None and pending['slug'].rsplit('--w', 1)[0] != b['work_item']:
        raise ValueError('pending session work item mismatch')
    if b['execution_root'] is not None or 'execution_root' not in b['absence_reasons']:
        raise ValueError('pending root must be explicitly absent')
    if d['framework'] != pending['framework'] or d['position'] != pending['position']:
        raise ValueError('pending producer mismatch')
    if not re.fullmatch('[0-9a-f]{64}', d.get('descriptor_sha256', '')):
        raise ValueError('descriptor_sha256 is required')
    if validate_inputs:
        validate_bindings(b, pending['position'], kdir, session_required_bindings(pending['position']), pending_root=True, preparation=preparation)
        validate_descriptor(d)
        from position_compile import normalize_guidance
        guidance = pending['guidance'].encode()
        run(['bash', str(SCRIPTS / 'validate-dispatch-guidance.sh')], data=guidance)
        if normalize_guidance(guidance) != read(Path(d['guidance_path'])):
            raise ValueError('guidance identity differs from selected compilation')
    options = {}
    if 'composition' in pending:
        if not isinstance(pending.get('activation'), dict):
            raise ValueError('wrapped session requires admitted activation')
        c = pending['composition']
        if not isinstance(c, dict) or set(c) != {'wrapper', 'wrapper_source', 'prefix', 'suffix'}:
            raise ValueError('invalid pending wrapper composition')
        options = {'wrapper': c['wrapper'], 'wrapper_source': c['wrapper_source'].encode(),
                   'prefix': c['prefix'].encode(), 'suffix': c['suffix'].encode()}
        validate_wrapper(**options)
    if validate_inputs and validate_activation:
        activation = render_activation(d, b['dispatch_attempt_id'])
        if 'activation' in pending and pending['activation'] != activation:
            raise ValueError('pending activation differs from selected producer')
    return options


def session_reference(context, *, kdir):
    """Read the final prepared reference independently of the agent's report."""
    if set(context) == {'position_preparation'}:
        pending = context['position_preparation']
        # session-reference reads back a publication the host already made; the synthesis rule was applied when it was prepared.
        options = validate_session_preparation(pending, kdir=kdir, validate_activation=False, preparation=False)
        if not isinstance(pending.get('activation'), dict):
            raise ValueError('reference collection requires admitted activation')
        b = copy.deepcopy(pending['bindings'])
        path = kdir.resolve() / '_work' / b['work_item'] / 'position-dispatch' / b['dispatch_attempt_id'] / 'manifest.json'
        raw = read(path)
        m = validate_dispatch(path, digest(raw))
        b['execution_root'] = m['bindings']['execution_root']
        del b['absence_reasons']['execution_root']
        validate_bindings(b, pending['position'], kdir, session_required_bindings(pending['position']), preparation=False)
        if m['bindings'] != b or m['wrapper'] != options.get('wrapper') or m.get('dispatch_route') == 'native-subagent':
            raise ValueError('published session differs from admitted bindings or wrapper')
        members = {'descriptor.json': encoded(pending['descriptor']), 'guidance.md': pending['guidance'].encode()}
        for key, name in (('wrapper_source', 'wrapper-source.md'), ('prefix', 'wrapper-prefix.md'), ('suffix', 'wrapper-suffix.md')):
            value = options.get(key, b'')
            if value:
                members[name] = value
            elif name in m['files']:
                raise ValueError('published session has unassigned wrapper content')
        if any(read(path.parent / name) != value for name, value in members.items()):
            raise ValueError('published session differs from admitted content')
        components = payload_components(pending['descriptor'], b, path, pending['guidance'].encode(),
                                        options.get('prefix', b''), options.get('suffix', b''), 'referenced')
        if read(path.parent / 'payload.md') != b''.join(data for _, data in components):
            raise ValueError('published session payload differs from admitted composition')
        if read(path.parent / 'launch.json') != encoded(pending['activation']):
            raise ValueError('published session activation differs from admitted producer')
        ref = {'manifest_path': str(path), 'manifest_sha256': digest(raw),
               'payload_path': m['payload']['path'], 'payload_sha256': m['payload']['sha256'],
               'native_path': m['native']['path'], 'native_sha256': m['native']['sha256']}
    elif set(context) == {'dispatch_guidance', 'position_dispatch'}:
        ref = context['position_dispatch']
        m = validate_dispatch(ref['manifest_path'], ref['manifest_sha256'])
        if read(Path(ref['payload_path'])).decode() != context['dispatch_guidance']:
            raise ValueError('queued payload mismatch')
    else:
        raise ValueError('invalid position session context')
    if Path(m['kdir']) != kdir.resolve() or Path(m['work_item_path']) != kdir.resolve() / '_work' / m['bindings']['work_item']:
        raise ValueError('session reference store mismatch')
    validate_bindings(m['bindings'], m['producer']['position'], kdir, session_required_bindings(m['producer']['position']), preparation=False)
    for kind in ('payload', 'native'):
        if ref[kind + '_path'] != m[kind]['path'] or ref[kind + '_sha256'] != m[kind]['sha256']:
            raise ValueError('mixed dispatch reference')
    return {'reference': ref, 'completion_input': {'position_dispatch': ref, 'lore_task_id': m['bindings']['task_id']},
            'bindings': m['bindings'], 'producer': m['producer'], 'publication_state': 'prepared', 'delivery_proven': False}


def launch_session(context, *, framework, slug, execution_root, kdir):
    """Bind to the host's validated directory and return the frozen native launch input."""
    expected = {'framework': framework, 'work_item': slug.rsplit('--w', 1)[0], 'execution_root': execution_root}
    if set(context) == {'position_preparation'}:
        pending = context['position_preparation']
        options = validate_session_preparation(pending, kdir=kdir, framework=framework, slug=slug, validate_inputs=False)
        b = copy.deepcopy(pending['bindings'])
        b['execution_root'] = execution_root
        del b['absence_reasons']['execution_root']
        d = pending['descriptor']
        ref = publish(d, b, kdir, pending['guidance'].encode(), required=session_required_bindings(d['position']), **options)
    elif set(context) == {'dispatch_guidance', 'position_dispatch'}:
        ref = context['position_dispatch']
    else:
        raise ValueError('invalid position session context')
    resolved = resolve_dispatch(ref['manifest_path'], ref['manifest_sha256'], expected=expected)
    m = resolved['manifest']
    if m.get('dispatch_route') == 'native-subagent':
        raise ValueError('native subagent dispatch cannot launch as a session')
    if Path(m['kdir']) != kdir.resolve() or Path(m['work_item_path']) != Path(resolved['resolved_manifest_path']).parents[2]:
        raise ValueError('launch requires the active work item in the selected store')
    validate_bindings(m['bindings'], m['producer']['position'], kdir, session_required_bindings(m['producer']['position']), preparation=False)
    for kind in ('payload', 'native'):
        if ref[kind + '_path'] != m[kind]['path'] or ref[kind + '_sha256'] != m[kind]['sha256']:
            raise ValueError('mixed dispatch reference')
    payload = read(Path(resolved['payload_path'])).decode()
    if 'dispatch_guidance' in context and context['dispatch_guidance'] != payload:
        raise ValueError('queued payload mismatch')
    root = Path(resolved['resolved_manifest_path']).parent
    descriptor = json.loads(read(root / 'descriptor.json'))
    activation = render_activation(descriptor, m['bindings']['dispatch_attempt_id'])
    if 'position_preparation' in context and 'activation' in context['position_preparation'] and context['position_preparation']['activation'] != activation:
        raise ValueError('pending activation differs from selected producer')
    if read(root / 'launch.json') != encoded(activation):
        raise ValueError('native activation changed after publication')
    return {'reference': ref, 'payload': payload, 'activation': activation, 'producer': m['producer']}


# --- /implement dispatch plumbing ------------------------------------------------
# The seat composes a worker or designer attempt from an `impl open` or
# `impl next-batch` envelope. These verbs turn that envelope into the bindings,
# wrapper and session context the binder consumes, and read a landed report or
# reply against the reference the seat holds.

IMPLEMENT_ROUTES = {'native': 'harness-subagent', 'chaperone': 'codex-chaperone',
                    'session': 'worker-session', 'designer': 'designer-consultation'}
CONSULTATION_BODY = ('a ## Consultation body (first line exactly ## Consultation, then '
                     'consultation-id, domain, reason, question, task)')


def worker_bindings(dispatch, *, task_id, slug, kdir, report_id, execution_root):
    """Bindings for one task from an open or next-batch envelope."""
    entries = [e for e in dispatch.get('manifest', []) if e.get('op') == 'TaskCreate'] + list(dispatch.get('batch', []))
    task = next((e for e in entries if e.get('local_id') == task_id), None)
    if task is None:
        raise ValueError(f'task {task_id} is not in this dispatch output; it is complete, blocked, excluded or active')
    inputs = task.get('position_binding_inputs') or {
        'work_item': slug, 'task_id': task_id, 'revision_id': task.get('revision_id'),
        'packet_id': task.get('packet_id'), 'dispatch_attempt_id': task.get('dispatch_attempt_id'),
        'assignment': task['description'],
        'packet_pointer': pointer(kdir, task['packet_id']) if task.get('packet_id') else None}
    missing = [k for k in TASK_BINDINGS[:3] + ('dispatch_attempt_id',) if not inputs.get(k)]
    if missing:
        raise ValueError('legacy-unbound task; adopt the item with lore plan revise --reconcile before compiled dispatch: ' + ', '.join(missing))
    b = dict.fromkeys(FIELDS)
    b.update(inputs)
    b.update(report_id=report_id, report_path=str(kdir / '_work' / slug / 'worker-reports' / (report_id + '.md')),
             execution_root=execution_root or None)
    reasons = {k: 'designer consultation fields do not apply to a worker' for k in ('mode', 'consultation_id', 'domain', 'reply_destination')}
    if b['execution_root'] is None:
        reasons['execution_root'] = 'the ordinary session host supplies its physical worktree'
    b['absence_reasons'] = reasons
    return b


def consultation_bindings(request, *, slug, kdir, packet_id, advisor, worker, task_id, revision_id, execution_root):
    """Bindings for a designer consultation attempt from a worker's request body."""
    lines = request.strip().splitlines()
    fields = {m.group(1): m.group(2).strip() for m in (re.match(r'^([a-z-]+):\s*(.*)$', l) for l in lines[1:]) if m}
    missing = [k for k in ('consultation-id', 'domain', 'question') if not fields.get(k)]
    if not lines or lines[0].strip() != '## Consultation' or missing:
        raise ValueError('consultation request refused: not a ## Consultation body with ' + ', '.join(missing or ['the required headers']))
    cid, domain = fields['consultation-id'], fields['domain']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', cid):
        raise ValueError('consultation request refused: consultation-id is not a path-safe token')
    item = kdir / '_work' / slug
    report_id = re.sub(r'[^A-Za-z0-9_.-]', '-', f'{advisor}-{cid}')
    assignment = {'request': request, 'worker': worker, 'task_id': task_id, 'revision_id': revision_id}
    return {'work_item': slug, 'task_id': None, 'revision_id': None, 'packet_id': packet_id, 'packet_pointer': pointer(kdir, packet_id),
            'dispatch_attempt_id': 'consult-' + uuid.uuid4().hex, 'assignment': json.dumps(assignment), 'report_id': report_id,
            'report_path': str(item / 'worker-reports' / (report_id + '.md')), 'execution_root': execution_root or None, 'mode': 'consultation',
            'consultation_id': cid, 'domain': domain, 'reply_destination': str(item / 'consultation-replies' / (cid + '.md')),
            'absence_reasons': {k: 'consultation packet is session-scoped; the worker task and revision are in the assignment' for k in ('task_id', 'revision_id')}}


def implement_wrapper(bindings, route, *, work_title, framework, team_name='', lead_name='', placement_note='', tier2_extract=''):
    """The wrapper identity, identity prefix and dispatching note around a compiled brief.

    The wrapper is versioned by this file, the verb that composes it, so the
    recorded identity names the text that actually wrapped the brief."""
    if route not in IMPLEMENT_ROUTES:
        raise ValueError('route must be one of ' + ', '.join(IMPLEMENT_ROUTES))
    source = Path(__file__).resolve()
    sha = digest(read(source))
    wrapper = {'template_id': 'implement/wrapper', 'template_version': sha[:12], 'path': str(source), 'sha256': sha}
    ids = [('Packet-id', bindings['packet_id']), ('Report-id', bindings['report_id']),
           ('Revision-id', bindings['revision_id']), ('Dispatch-attempt-id', bindings['dispatch_attempt_id'])]
    prefix = ''.join(f'{k}: {v}\n' for k, v in ids if v)
    slug, task = bindings['work_item'], bindings['task_id'] or '(consultation)'
    team = f', on team {team_name} led by {lead_name}' if team_name else ''
    note = [f'## From the dispatching seat\n\nThe seat holding {work_title} handed you task {task} of work item {slug} on the {route} route{team}. '
            'The identity envelope above is the binder\'s record of this attempt. Your assignment is position_dispatch.bindings.assignment, the complete task description. '
            'The Packet-id line names a packet built for this move: lore packet show renders it, and its entries are candidates to check against the code. '
            'It was synthesized before binding; the Left out by synthesis list at its end names what was set aside and why, and when a reason does not hold for what you find in the code, '
            're-pull the entry with lore search. Revision-id and Dispatch-attempt-id name the plan revision and this attempt. '
            f'Work in position_dispatch.bindings.execution_root and allocate no other tree. {placement_note}'.rstrip()]
    if route == 'designer':
        note.append('You are the persistent advisor for the domain in position_dispatch.bindings.domain, answering the worker\'s question carried verbatim in the assignment. '
                    'Read current code in the execution root before answering about current behavior; the baseline in the assignment is older than the file the worker asks about. '
                    'Write the reply to position_dispatch.bindings.reply_destination and return the same text as your result. Its first four lines are the headers the ledger joins on: '
                    'consultation-id (from the assignment), handler: agent, advisor_template_version (position_dispatch.producer.template_version), advisor-acknowledged: true; then '
                    '**Domain:**, **Guidance:**, **Key files:**, **Cautions:**. You stay available: a later question arrives with its own envelope and destination. '
                    'Tier 2 rows you append carry producer_role advisor. You implement no source and complete no task.')
    else:
        sha_source = ('the two environment variables LORE_POSITION_DISPATCH_MANIFEST and LORE_POSITION_DISPATCH_SHA256' if route == 'session'
                      else 'the sha256 you compute over the manifest file the envelope names')
        note.append(f'Write the schema 1 report with these header lines first, plain, one per line: Report-schema: 1, Report-id and Work-item from the envelope, Task: <the task subject>, '
                    f'Producer-role: worker, Dispatch-path: {IMPLEMENT_ROUTES[route]}, Harness: {framework}, Status:, Template-version: position_dispatch.producer.template_version, '
                    f'Position-dispatch-manifest: the envelope\'s manifest_path, Position-dispatch-sha256: {sha_source}, then Packet-id:, Revision-id:, Dispatch-attempt-id:. '
                    f'Tier 2 rows go through evidence-append.sh --work-item {slug} with task_id {task} as each claim forms; the report lists claim IDs. '
                    f'Close criteria run through lore criteria run {slug} {task} <criterion-id> --execution-worktree "$PWD" --packet-id {bindings["packet_id"]}; cite result IDs.')
        if route == 'session':
            note.append('You run as a hosted session, so land the report yourself with '
                        f'printf \'%s\' "$REPORT" | lore coordinate report {slug} --report-id {bindings["report_id"]}. Exit 4 means a file already exists at that path because the id was used before; '
                        'record that under Blockers as written. Exit 1 names what was wrong with the arguments, environment or body; correct the call. '
                        'Once the report has landed and the rows are appended, stop and wait without closing this session or removing anything from its execution root: '
                        'report validation reads every source artifact against that root, and the seat closes the session after integration, so a correction can still reach you here. '
                        f'A required consultation goes in this session\'s output as {CONSULTATION_BODY}; the seat reaches this session with lore session send. '
                        'If no reply arrives, record the domain and how long you waited under Blockers rather than implementing past the requirement.')
        elif route == 'chaperone':
            note.append('The chaperone that launched you relays your final message verbatim and lands it at the bound report path; do not land it yourself. '
                        f'A required consultation is {CONSULTATION_BODY} in your output; wait for the reply before implementing past the requirement.')
        else:
            note.append('Return the finished report as your final message; the seat lands it at the bound report path and checks it against its own copy of this attempt\'s reference. '
                        f'A required consultation travels the same way: return {CONSULTATION_BODY} as your message and stop; the reply sent to your name resumes you.')
    if tier2_extract.strip():
        note.append('Prior Tier 2 evidence for this task, from task-claims.jsonl:\n\n' + tier2_extract.rstrip() + '\n')
    return wrapper, prefix.encode(), ('\n\n'.join(note) + '\n').encode()


def report_headers(path, limit=16):
    return dict(l.split(': ', 1) for l in read(Path(path)).decode().splitlines()[:limit] if ': ' in l)


def check_report_identity(report_path, reference):
    """Read a landed report against the held reference, never against the report's own claims."""
    ref = reference.get('reference', reference)
    manifest = Path(ref['manifest_path'])
    raw = read(manifest)
    if digest(raw) != ref['manifest_sha256']:
        raise ValueError('held reference does not match the manifest bytes; do not read this report against it')
    producer = json.loads(raw)['producer']['template_version']
    headers = report_headers(report_path)
    want = {'Template-version': producer, 'Position-dispatch-manifest': str(manifest), 'Position-dispatch-sha256': ref['manifest_sha256']}
    bad = [k for k, v in want.items() if headers.get(k) != v]
    if bad:
        raise ValueError('report answers another input; re-dispatch under fresh ids. mismatched: ' + ', '.join(bad))
    return {'status': 'matches', 'report_path': str(report_path), 'manifest_path': str(manifest), 'producer_template_version': producer}


def check_reply(reply_path, *, consultation_id, template_version):
    """A designer reply joins the ledger only through its first four header lines."""
    head = read(Path(reply_path)).decode().splitlines()[:4]
    want = [f'consultation-id: {consultation_id}', 'handler: agent',
            f'advisor_template_version: {template_version}', 'advisor-acknowledged: true']
    bad = [w for h, w in zip(head + [''] * 4, want) if h.strip() != w]
    if bad:
        raise ValueError('designer reply refused; headers missing or wrong: ' + '; '.join(bad))
    return {'status': 'acknowledged', 'reply_path': str(reply_path), 'consultation_id': consultation_id}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    verbs = parser.add_subparsers(dest='verb', required=True)
    bind = verbs.add_parser('bind')
    for name in ('descriptor', 'bindings', 'kdir', 'guidance-file'):
        bind.add_argument('--' + name, required=True, type=Path)
    bind.add_argument('--native-model')
    bind.add_argument('--require', action='append', default=[])
    bind.add_argument('--wrapper', type=Path)
    bind.add_argument('--prefix-file', type=Path)
    bind.add_argument('--suffix-file', type=Path)
    bind.add_argument('--contract-delivery', choices=('referenced', 'included'), default='referenced')
    for verb in ('register-native', 'native-input'):
        native = verbs.add_parser(verb)
        native.add_argument('manifest', type=Path)
        native.add_argument('--sha256', required=True)
        native.add_argument('--scope', type=Path, required=verb == 'register-native')
    check = verbs.add_parser('validate')
    check.add_argument('manifest', type=Path)
    check.add_argument('--sha256')
    resolve = verbs.add_parser('resolve')
    resolve.add_argument('manifest', type=Path)
    resolve.add_argument('--sha256', required=True)
    launch = verbs.add_parser('launch')
    for name in ('framework', 'slug', 'execution-root'):
        launch.add_argument('--' + name, required=True)
    launch.add_argument('--kdir', required=True, type=Path)
    for verb in ('session-reference', 'admit-session'):
        operation = verbs.add_parser(verb)
        operation.add_argument('--kdir', required=True, type=Path)
        if verb == 'admit-session':
            operation.add_argument('--framework', required=True)
            operation.add_argument('--slug', required=True)
    session = verbs.add_parser('session')
    for name in ('position', 'framework', 'slug', 'execution-root', 'packet-id'):
        session.add_argument('--' + name, required=True)
    session.add_argument('--kdir', required=True, type=Path)
    prepare = verbs.add_parser('prepare-session', help='pending session context from the same files bind takes')
    for name in ('descriptor', 'bindings', 'kdir', 'guidance-file'):
        prepare.add_argument('--' + name, required=True, type=Path)
    prepare.add_argument('--slug', required=True)
    prepare.add_argument('--wrapper', type=Path)
    prepare.add_argument('--prefix-file', type=Path)
    prepare.add_argument('--suffix-file', type=Path)
    worker = verbs.add_parser('worker-bindings', help='bindings for one task of an impl open or next-batch envelope')
    worker.add_argument('--dispatch', required=True, type=Path)
    worker.add_argument('--task', required=True)
    worker.add_argument('--work-item', required=True)
    worker.add_argument('--report-id', required=True)
    worker.add_argument('--execution-root', default='')
    worker.add_argument('--kdir', required=True, type=Path)
    worker.add_argument('--out', required=True, type=Path)
    consult = verbs.add_parser('consultation-bindings', help='bindings for a designer consultation from a ## Consultation request')
    consult.add_argument('--request', required=True, type=Path)
    for name in ('work-item', 'packet-id', 'advisor', 'worker', 'task', 'revision'):
        consult.add_argument('--' + name, required=True)
    consult.add_argument('--execution-root', default='')
    consult.add_argument('--kdir', required=True, type=Path)
    consult.add_argument('--out', required=True, type=Path)
    wrapper = verbs.add_parser('wrapper', help='the implement wrapper identity, identity prefix and dispatching note')
    wrapper.add_argument('--bindings', required=True, type=Path)
    wrapper.add_argument('--route', required=True, choices=sorted(IMPLEMENT_ROUTES))
    wrapper.add_argument('--work-title', required=True)
    wrapper.add_argument('--framework', required=True)
    for name in ('team-name', 'lead-name', 'placement-note'):
        wrapper.add_argument('--' + name, default='')
    wrapper.add_argument('--tier2-extract-file', type=Path)
    for name in ('wrapper', 'prefix-file', 'suffix-file'):
        wrapper.add_argument('--' + name, required=True, type=Path)
    identity = verbs.add_parser('check-report-identity', help='read a landed report against the held reference')
    identity.add_argument('--report', required=True, type=Path)
    identity.add_argument('--reference', required=True, type=Path)
    reply = verbs.add_parser('check-reply', help='check the four header lines of a designer reply')
    reply.add_argument('--reply', required=True, type=Path)
    reply.add_argument('--consultation-id', required=True)
    reply.add_argument('--template-version', required=True)
    args = parser.parse_args()
    if args.verb == 'prepare-session':
        result = prepare_session_input(json.loads(read(args.descriptor)), json.loads(read(args.bindings)), args.kdir,
                                       read(args.guidance_file), slug=args.slug,
                                       wrapper=json.loads(read(args.wrapper)) if args.wrapper else None,
                                       prefix=read(args.prefix_file) if args.prefix_file else b'',
                                       suffix=read(args.suffix_file) if args.suffix_file else b'')
    elif args.verb == 'worker-bindings':
        b = worker_bindings(json.loads(read(args.dispatch)), task_id=args.task, slug=args.work_item, kdir=args.kdir.resolve(),
                            report_id=args.report_id, execution_root=args.execution_root)
        args.out.write_text(json.dumps(b, indent=2) + '\n')
        result = {k: b[k] for k in ('task_id', 'revision_id', 'packet_id', 'dispatch_attempt_id', 'report_id', 'execution_root')}
    elif args.verb == 'consultation-bindings':
        b = consultation_bindings(read(args.request).decode(), slug=args.work_item, kdir=args.kdir.resolve(), packet_id=args.packet_id,
                                  advisor=args.advisor, worker=args.worker, task_id=args.task, revision_id=args.revision,
                                  execution_root=args.execution_root)
        args.out.write_text(json.dumps(b, indent=2) + '\n')
        result = {k: b[k] for k in ('dispatch_attempt_id', 'report_id', 'consultation_id', 'domain', 'reply_destination')}
    elif args.verb == 'wrapper':
        extract = read(args.tier2_extract_file).decode() if args.tier2_extract_file else ''
        identity_record, prefix, suffix = implement_wrapper(
            json.loads(read(args.bindings)), args.route, work_title=args.work_title, framework=args.framework,
            team_name=args.team_name, lead_name=args.lead_name, placement_note=args.placement_note, tier2_extract=extract)
        args.wrapper.write_text(json.dumps(identity_record))
        args.prefix_file.write_bytes(prefix)
        args.suffix_file.write_bytes(suffix)
        result = identity_record
    elif args.verb == 'check-report-identity':
        result = check_report_identity(args.report, json.loads(read(args.reference)))
    elif args.verb == 'check-reply':
        result = check_reply(args.reply, consultation_id=args.consultation_id, template_version=args.template_version)
    elif args.verb == 'register-native':
        result = register_native(args.manifest, args.sha256, args.scope)
    elif args.verb == 'native-input':
        result = native_input(args.manifest, args.sha256, args.scope)
    elif args.verb == 'launch':
        result = launch_session(json.load(sys.stdin), framework=args.framework, slug=args.slug,
                                execution_root=args.execution_root, kdir=args.kdir)
    elif args.verb == 'session-reference':
        result = session_reference(json.load(sys.stdin), kdir=args.kdir)
    elif args.verb == 'admit-session':
        result = json.load(sys.stdin)
        if set(result) != {'position_preparation'}:
            raise ValueError('invalid position session context')
        validate_session_preparation(result['position_preparation'], kdir=args.kdir, framework=args.framework, slug=args.slug)
    elif args.verb == 'resolve':
        result = resolve_dispatch(args.manifest, args.sha256)
    elif args.verb == 'session':
        result = prepare_session(json.load(sys.stdin), position=args.position, framework=args.framework,
                                 slug=args.slug, execution_root=args.execution_root, packet_id=args.packet_id, kdir=args.kdir.resolve())
    elif args.verb == 'validate':
        result = validate_dispatch(args.manifest, args.sha256)
    else:
        result = publish(json.loads(read(args.descriptor)), json.loads(read(args.bindings)), args.kdir,
                         read(args.guidance_file), required=args.require,
                         wrapper=json.loads(read(args.wrapper)) if args.wrapper else None,
                         prefix=read(args.prefix_file) if args.prefix_file else b'',
                         suffix=read(args.suffix_file) if args.suffix_file else b'', contract_delivery=args.contract_delivery, native_model=args.native_model)
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as exc:
        sys.exit(f'position-bind: {exc}')
