#!/usr/bin/env python3
"""Publish requests only to runtimes that can interpret their payload."""
import datetime
import json
import os
from pathlib import Path
import sys
import time

POSITION_CAPABILITY = 'position-preparation-v1'

def vintage(value):
    try:
        result = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
        return result if result.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None

def admit(row, instances, ttl=30, clock=None):
    context = row.get('extra_context') or {}
    position = isinstance(context, dict) and any(k in context for k in ('position_preparation', 'position_dispatch'))
    floor = row.get('min_vintage')
    if not position and not floor:
        return row
    now = time.time() if clock is None else clock
    candidates = []
    for path in sorted(Path(instances).glob('*.json')):
        try:
            if now - path.stat().st_mtime > ttl:
                continue
            host = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        name = host.get('name')
        if not name or path.stem != name:
            continue
        if row.get('target_instance') and row['target_instance'] != name:
            continue
        if host.get('host_key', '') != row.get('host_key', ''):
            continue
        required = row.get('required_project_dir')
        if required and (not host.get('project_dir') or os.path.realpath(host['project_dir']) != required):
            continue
        capabilities = host.get('runtime_capabilities', [])
        if position and (not isinstance(capabilities, list) or not all(isinstance(v, str) for v in capabilities)
                         or POSITION_CAPABILITY not in capabilities):
            continue
        if floor and (not vintage(floor) or not vintage(host.get('build_time')) or vintage(host['build_time']) < vintage(floor)):
            continue
        candidates.append(host)
    if not candidates:
        needs = POSITION_CAPABILITY if position else 'known build vintage >= ' + str(floor)
        placement = row.get('target_instance') or row.get('required_project_dir') or 'requested placement'
        raise RuntimeError(f'no live compatible runtime for {placement}: requires {needs}; start a compatible host in that placement and retry; nothing was enqueued')
    prefer = row.get('prefer_project_dir')
    candidates.sort(key=lambda h: (h.get('project_dir') != prefer if prefer else False, h['name']))
    # Legacy readers ignore new fields but already honor this hard identity fence.
    row['target_instance'] = candidates[0]['name']
    if position:
        row['required_runtime_capabilities'] = [POSITION_CAPABILITY]
    return row

if __name__ == '__main__':
    try:
        print(json.dumps(admit(json.load(sys.stdin), sys.argv[1], int(sys.argv[2]))))
    except (RuntimeError, ValueError, OSError) as error:
        sys.exit('session admission: ' + str(error))
