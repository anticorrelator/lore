"""Project the exact runtime generation shared by close writers and host observations."""
import datetime
import json
from pathlib import Path
import sys
import time


def generation(row):
    identity = row.get('session_id') or row.get('request_id') or row.get('tmux') or ''
    if row.get('started'):
        started = datetime.datetime.fromisoformat(row['started'].replace('Z', '+00:00'))
        return f"{identity}/{row.get('request_id') or ''}/{int(started.timestamp())}"
    return identity


def resolve(directory, instance, slug, session_id='', ttl=30):
    matches = []
    for path in Path(directory).glob('*.json'):
        try:
            if time.time() - path.stat().st_mtime > float(ttl):
                continue
            owner = json.loads(path.read_text())
            if owner.get('name') != instance:
                continue
            for row in owner.get('sessions', []):
                if (session_id and (row.get('session_id') or '').startswith(session_id)) or (not session_id and (row.get('slug') or '') == slug):
                    matches.append(dict(row, generation=generation(row)))
        except (OSError, ValueError, TypeError):
            continue
    if len(matches) != 1:
        raise ValueError('close target changed or is ambiguous; resolve the live session again')
    return matches[0]


if __name__ == '__main__':
    try:
        print(json.dumps(resolve(*sys.argv[1:])))
    except ValueError as error:
        sys.exit(str(error))
