"""Session runtime namespace, per-login state and the environment session hosts run with."""
import hashlib
import os
from pathlib import Path
import re
import sys

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


def store_host_key(kdir, environ=None):
    """The host key of a store's session host, over the store's resolved path.

    The request queue and instance registry are shared by every runtime, and
    claims match on this key, so a named runtime's key differs from the default
    runtime's: a development host serving a store never claims its rows.
    """
    name = runtime_name(environ)
    material = str(Path(kdir).resolve()) + ('\0runtime\0' + name if name else '')
    return hashlib.sha256(material.encode()).hexdigest()[:24]


def login_dir(environ=None):
    """Per-login supervisor state, outside every knowledge store."""
    env = os.environ if environ is None else environ
    name = runtime_name(env)
    data = Path(env.get('LORE_DATA_DIR') or Path(env.get('HOME') or Path.home()) / '.lore')
    return data / 'session-runtimes' / name if name else data / 'session-runtime'


# A session host's environment becomes the environment of every session it
# runs, in every checkout of its store. The supervisor builds each host's
# environment from the environment of the lore call that started it, minus the
# names below, so credentials, PATH and proxy settings carry over while the
# starting session's own identity does not.
#
# A family is removed by prefix unless KEEP_NAMES or KEEP_PREFIXES restores the
# name. tests/fixtures/session_harness_env_names.json holds the names seen in
# real Claude Code, Codex and OpenCode sessions and pins what happens to each.
SCRUB_PREFIXES = (
    # Claude Code: entrypoint, the child-session marker (it turns off transcript
    # saving in every Claude session the host starts), messaging socket and
    # token, session and host-session ids, account identity.
    'CLAUDE_CODE_',
    # Claude Agent SDK host markers (desktop app and other SDK embedders).
    'CLAUDE_AGENT_SDK_',
    # Codex: session and thread ids, CI marker, sandbox markers, version.
    'CODEX_',
    # OpenCode: session id and terminal marker.
    'OPENCODE_',
    # Lore's identity and routing for one session.
    'LORE_SESSION_',
    'LORE_POSITION_',
    'LORE_MODEL_',
)
SCRUB_NAMES = frozenset({
    # Claude Code sets these for the commands its tools run.
    'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT', 'GIT_EDITOR', 'COREPACK_ENABLE_AUTO_PIN',
    'NoDefaultCurrentDirectoryInExePath',
    # Claude Code and OpenCode both set AI_AGENT; OpenCode also sets these two.
    'AI_AGENT', 'AGENT', 'OPENCODE',
    # Codex sets these for the commands its tools run.
    'NO_COLOR', 'PAGER', 'GIT_PAGER', 'GH_PAGER',
    # The starting app's trace context, which would attach every session's
    # telemetry to that app's trace.
    'BAGGAGE', 'TRACEPARENT', 'TRACESTATE',
    # Internal flags the Claude desktop app sets for its own embedded sessions.
    'USE_STAGING_OAUTH', 'USE_LOCAL_OAUTH',
    # Lore's per-session variables outside the families above.
    'LORE_FRAMEWORK', 'LORE_WORKTREE_ID', 'LORE_EXECUTION_DIR',
    # Set per store by child_environment, never carried from one store to another.
    'LORE_KNOWLEDGE_DIR',
    # The starting shell's own position.
    'TMUX', 'TMUX_PANE', 'PWD', 'OLDPWD', 'SHLVL',
})
KEEP_NAMES = frozenset({
    # Claude Code provider selection, credentials, network and limits.
    'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
    'CLAUDE_CODE_SKIP_BEDROCK_AUTH', 'CLAUDE_CODE_SKIP_VERTEX_AUTH', 'CLAUDE_CODE_SKIP_FOUNDRY_AUTH',
    'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS',
    'CLAUDE_CODE_CLIENT_CERT', 'CLAUDE_CODE_CLIENT_KEY', 'CLAUDE_CODE_CLIENT_KEY_PASSPHRASE',
    'CLAUDE_CODE_PROXY_RESOLVES_HOSTS', 'CLAUDE_CODE_MAX_OUTPUT_TOKENS', 'CLAUDE_CODE_MAX_RETRIES',
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS',
    'CLAUDE_CODE_ENABLE_TELEMETRY', 'CLAUDE_CODE_OTEL_HEADERS_HELPER_DEBOUNCE_MS',
    'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE', 'CLAUDE_CODE_SHELL', 'CLAUDE_CODE_SHELL_PREFIX',
    'CLAUDE_CODE_TMPDIR', 'CLAUDE_CODE_GIT_BASH_PATH',
    # Codex configuration home, credentials and CA bundle.
    'CODEX_HOME', 'CODEX_SQLITE_HOME', 'CODEX_CA_CERTIFICATE', 'CODEX_API_KEY',
    # OpenCode credentials and switches; OPENCODE_CONFIG* is kept by prefix.
    'OPENCODE_API_KEY', 'OPENCODE_DISABLE_AUTOUPDATE', 'OPENCODE_DISABLE_PROJECT_CONFIG',
    'OPENCODE_DISABLE_MODELS_FETCH', 'OPENCODE_MODELS_URL', 'OPENCODE_MODELS_PATH',
    # Lore settings that apply to every host of the login rather than one session.
    'LORE_SESSION_HOST_BINARY', 'LORE_SESSION_HOST_IDLE_TIMEOUT', 'LORE_SESSION_RUNTIME',
})
KEEP_PREFIXES = ('OPENCODE_CONFIG',)


def scrubbed(name):
    if name in KEEP_NAMES or name.startswith(KEEP_PREFIXES):
        return False
    return name in SCRUB_NAMES or name.startswith(SCRUB_PREFIXES)


def child_environment(base, kdir, pin_knowledge_dir):
    """The environment for a store's host and for the supervisor's own work on that store."""
    env = {name: value for name, value in base.items() if not scrubbed(name)}
    if pin_knowledge_dir:
        env['LORE_KNOWLEDGE_DIR'] = str(kdir)
    return env


def sandbox_reason(environ=None):
    """Why this process runs inside an OS sandbox, or '' when it does not.

    A macOS seatbelt sandbox follows process ancestry rather than environment,
    so a supervisor started here would confine every store's host and every
    session it runs to this sandbox until it exits.
    """
    env = os.environ if environ is None else environ
    for name in ('CODEX_SANDBOX', 'CODEX_SANDBOX_NETWORK_DISABLED'):
        if env.get(name):
            return f'{name} is set'
    if sys.platform == 'darwin':
        import ctypes
        try:
            check = ctypes.CDLL('/usr/lib/libSystem.B.dylib').sandbox_check
        except (OSError, AttributeError):
            return ''
        check.restype = ctypes.c_int
        check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        if check(os.getpid(), None, 0) == 1:
            return 'this process runs inside a macOS sandbox'
    return ''
