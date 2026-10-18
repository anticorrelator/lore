"""Session runtime namespace: which tmux server and host state directory a host uses."""
import os
from pathlib import Path
import re

ENV = 'LORE_SESSION_RUNTIME'
PRODUCTION_TMUX_SERVER = 'lore-tui'
_NAME = re.compile(r'[a-z0-9-]{1,32}')


def runtime_name(environ=None):
    value = (os.environ if environ is None else environ).get(ENV, '')
    if not value:
        return ''
    if not _NAME.fullmatch(value):
        raise ValueError(f'{ENV}={value!r} is not a valid runtime name (want [a-z0-9-]{{1,32}})')
    return value


def tmux_server(environ=None):
    name = runtime_name(environ)
    return PRODUCTION_TMUX_SERVER + '-' + name if name else PRODUCTION_TMUX_SERVER


def hosts_dir(kdir, environ=None):
    name = runtime_name(environ)
    sessions = Path(kdir) / '_sessions'
    return sessions / 'runtimes' / name / 'hosts' if name else sessions / 'hosts'

