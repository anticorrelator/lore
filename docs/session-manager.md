# Managed sessions

`lore session start` owns routine session administration: store-scoped hosting,
worker launch, delivery tracking, reconnecting surviving workers, and physical
session cleanup. The coordinator chooses the task, framework, model, source
workspace, and consequential interventions.

```bash
lore session start my-item --workspace /path/to/source --framework codex \
  --model gpt-6-astra --context /path/to/brief.md --key implementation-1 --json
lore session send <handle> "Include the recovery case" --json
lore session peek <handle> --json
lore session wait <handle> --json
lore session close <handle> --json
lore session inspect <handle> --json
```

`claude-code`, `codex`, and `opencode` share this contract. The existing interactive
harness launch and input adapters remain in use. A visible TUI is optional;
`lore session attach <handle>` attaches a human to the existing tmux terminal.

## Identity and launch

A handle names one worker incarnation and remains valid after its host restarts.
The work item remains a separate identity. `--key` names a logical dispatch:
concurrent or repeated starts with identical intent reuse its handle, while a
changed model, framework, source, packet, or brief content refuses. Without a key, each
start deliberately creates a new worker. Persist the returned handle in the
coordinator ledger; a process-generation instance name is not the session address.

`--packet <id>` carries an already assembled knowledge packet through the worker
guidance writer. Packet selection remains a coordination judgment.

The mechanism canonicalizes the workspace and knowledge store, ensures the
store's host, and seeds a missing work-item source declaration through the existing
metadata writer. An existing different declaration refuses. The worker gets an
isolated session-owned execution worktree; its source checkout remains the
publication destination. Agent initiation and cooperative protocol-terminus
closure are the defaults.

Intent is written before enqueue. A fixed request identity and durable queue,
journal, and launch checkpoints let recovery distinguish an unstarted request
from an already launched worker. Recovery must not launch a second worker merely
because the original caller disappeared.

## Host lifecycle

Each login runs at most one session supervisor (one per runtime namespace, see
below). It runs one headless session host for each knowledge store it serves,
and that host serves every checkout of its store: each session's checkout comes
from its request, and the host's own working directory is the store. The host is
the Go session runtime in a headless mode. It reuses the Bubble Tea scheduler and
PTY instrumentation with rendering and terminal input disabled. No globally
installed service is required, and nothing has to be started by hand.

Any lore command that needs a store's host calls `ensure` for that store. It
records the store in the login's served set, starts the supervisor if none is
running, and waits up to 45 seconds for the store's host to publish readiness.
The supervisor launches the host, relaunches it after a crash with bounded
backoff (six attempts per store), and reconciles unsent starts and uncertain
operations while the host is ready. A host withdraws by itself after its idle
timeout (`LORE_SESSION_HOST_IDLE_TIMEOUT`, 30 seconds by default). The
supervisor launches it again when the store gets work (queued requests keyed to
it, unsent managed starts, or a dead registry row whose sessions it would adopt)
or when a later `ensure` asks for it. The supervisor exits once no store has had
a host or work for 60 seconds (`LORE_SESSION_SUPERVISOR_QUIET_SECONDS`). Its exit
decision and `ensure`'s registration take the same lock, so a request that
arrives as it exits either keeps it running or starts a new one.

A store host's key is a hash of the store's resolved path and the runtime name.
Requests and managed starts carry that key, so only that store's host in that
runtime claims them. Its readiness file and registry row say `scope: "store"`
and name no checkout. An OS lock admits one host per store, and readiness is
published only after recovery completes. The supervisor follows each host
through its lock, its readiness file and its registry row as well as through its
own process handle, so a restarted supervisor picks up hosts it did not start.

The host runs the first of these that exists:

1. `LORE_SESSION_HOST_BINARY`, when set.
2. The installed `~/.local/bin/lore-tui`, which `install.sh` builds and stamps
   with the checkout's commit and commit time.
3. A build of the lore checkout's `tui/` sources, cached under
   `_sessions/bin/` and stamped the same way. The verb that starts the host
   prints one line on stderr saying so; `bash install.sh` installs a binary and
   ends the fallback. This build takes whatever is in the checkout, uncommitted
   edits included.

Every 10 seconds the supervisor checks the override or installed binary (never
the checkout build, which would mean running `go build`). When its file
identity differs from the one a host was launched with and has held for 5
seconds, the supervisor writes `restart.json` naming that host's pid and start
time. The host restarts at its next moment with no operation in flight, exiting
75, and the supervisor relaunches it on the new binary without counting a crash.
Surviving tmux sessions are adopted again by the new host. A host that refuses
the store-host arguments (exit 2) is a binary older than the scripts, for
example before `bash install.sh` has run after an update. The supervisor
records that in the store's `supervisor-error.json` and does not retry until the
binary changes. Until then `ensure` fails at once, naming `lore rebuild` and
`bash install.sh`, instead of waiting out its timeout.

The supervisor also restarts itself when `scripts/session-managed.py` or
`scripts/session_runtime.py` changes. It waits until the change has held for 5
seconds and a separate process has loaded the new code and run its self-check.
A failed check leaves it on its current code and records the failure in the
login's `supervisor-error.json`. Hosts keep running across the restart.

A host's environment is the environment of every session it runs. Each host
gets the environment of the lore command that started the supervisor, minus
harness session markers (Claude Code, Claude Agent SDK, Codex and OpenCode
session variables) and lore's per-session variables, so credentials, PATH and
proxy settings carry over while the starting session's identity does not.
Provider and credential settings inside those families, such as
`CLAUDE_CODE_USE_BEDROCK`, `CODEX_HOME` and `OPENCODE_CONFIG`, are kept.
`scripts/session_runtime.py` holds the list. A host gets `LORE_KNOWLEDGE_DIR`
only for the store whose registering command carried that store in
`LORE_KNOWLEDGE_DIR`, and never another store's value. The supervisor's own
commands for a store use that store's environment too. It records the
`TMUX_TMPDIR` it started with. `ensure` warns when a command's `TMUX_TMPDIR`
differs, and `lore session attach` uses the recorded value to reach the tmux
server the hosts use.

`ensure` does not start a supervisor from inside an OS sandbox: a macOS seatbelt
sandbox (detected with `sandbox_check`), or Codex's `CODEX_SANDBOX` and
`CODEX_SANDBOX_NETWORK_DISABLED`. A supervisor started there would keep every
store's host and every session it runs confined to that sandbox until it exits.
The error asks for the command to be run once outside the sandbox. A command
inside a sandbox can still use a supervisor that is already running.

A running host keeps the binary it started with until it restarts. The scripts
always come from the checkout, so after pulling, they can be newer than the
installed binary until `install.sh` runs again. A host that lacks a capability a
request needs is refused at admission rather than handed the request.

Registry rows with `role: "session-host"` and `host_key` belong to this lifecycle.
Managed requests carry the host key so a new generation can resolve ownership.
A normal TUI does not adopt these rows. Recovery checks dead process ownership
without waiting for heartbeat expiry, including abandoned adoption claims. With
tmux, a surviving interactive harness is adopted rather than relaunched. Without
tmux, host death cannot preserve that process; the outcome must expose the loss.
A transcript restart is not live-process recovery.

## Runtime namespaces

`LORE_SESSION_RUNTIME=<name>` (lowercase letters, digits and `-`, at most 32
characters) runs a separate session runtime. Its tmux server is
`lore-tui-<name>` rather than `lore-tui`, its supervisor state lives under
`${LORE_DATA_DIR:-~/.lore}/session-runtimes/<name>/` rather than
`session-runtime/`, its host keys differ from the default runtime's, and its
host state (ready file, locks, host log, delivery and cleanup records) lives
under `_sessions/runtimes/<name>/hosts/` rather than `_sessions/hosts/`. A host
in a namespace therefore never shares a lock, supervisor, host key or tmux
server with the production runtime, and `lore session attach`, the coordinator watcher, and a
visible `lore-tui` started with the same setting all use that namespace's
server. Sessions a namespaced host launches inherit the setting. When the
setting is unset or empty, everything runs exactly as before. An invalid name
is refused rather than falling back to the production server.

A namespace separates hosts, not knowledge stores: a namespaced host still reads
the request queue, journal and instance registry of the store it runs against.
Its store host claims only requests carrying its own key, but a visible TUI in
the namespace can still pick up unkeyed requests meant for production. Run a development or
test namespace against a scratch store (`LORE_KNOWLEDGE_DIR` pointing at a
throwaway directory, as `tests/test_session_manager_integration.py` does), not
against a store a production host serves.

## Delivery and observation

Managed `send`, `answer`, and `close` persist a request and await its correlated
outcome. `send` retries only explicit pre-injection startup/readiness refusals
within its deadline. A runtime attempt record precedes input injection. If a
crash interrupts outcome verification, `delivery-uncertain` preserves the unknown
outcome and forbids automatic replay. The coordinator can inspect and decide how
to proceed. A timeout likewise does not prove that input was undelivered.

`peek` returns current activity separately from input readiness, with session identity,
freshness, screen evidence, and recognized modal details. See
[Session observation](session-observation.md). `answer` still requires
an observed modal expectation and an explicit choice. `wait` persists its own
observation position; callers need not carry byte offsets for individual managed
sessions. `inspect` reads durable state and receipts after the process is gone.
The existing append-only journal and event vocabulary remain the evidence seam.

## Teardown and result ownership

Managed `close` waits for its own correlated teardown outcome and reports worktree
publication, quarantine, or refusal, including retained result references and
cleanup disposition. Removing an execution directory does not prove integration.
A quarantined result remains available for the coordinator's composition judgment.
A session-owned checkout is removed only when its content on disk matches a
preserved ref. When nothing matches, the checkout is retained. `close` reports
`cleanup: retained` with the reason, and the host logs it and keeps serving. The
startup and idle sweeps treat an abandoned checkout the same way. A retained
checkout stays on disk until someone preserves its content in a ref (for example
`refs/lore/quarantine/<epoch>`) or removes it by hand. Only a removal that
started and did not finish stops the host.
Protocol-terminus close retains the existing cooperative gate; explicit coordinator
close retains its existing authority. Source-generation and worktree ownership
guards apply equally to visible and headless hosts.

## Durable storage and compatibility

Per login, `${LORE_DATA_DIR:-~/.lore}/session-runtime/` (`session-runtimes/<name>/`
in a namespace) holds `supervisor.lock`, `supervisor.json` (pid, runtime,
`TMUX_TMPDIR`, script identity), `served.json` (each served store with the time
it was last asked for and whether its `LORE_KNOWLEDGE_DIR` is set), `served.lock`
and `supervisor.log`. Under each store's `_sessions/`, `hosts/<key>/` holds that
store host's readiness, locks, `host.log`, `child.json` (the launched pid and
binary), `restart.json` and `supervisor-error.json`, and its delivery, allocation
and cleanup records (`runtimes/<name>/hosts/<key>/` in a namespace),
`managed/<handle>.json` holds durable start intent, `start-keys.json` indexes keyed
starts, and `receipts/<handle>/<request-id>.json` retains operation outcomes.
Runtime delivery attempts are persisted before input. Mutable facade indexes are
serialized with advisory locks and atomically replaced; the journal continues
through its sole sanctioned writer.

Raw `lore session request`, instance targeting, and unmanaged session verbs remain
available. Their lower-level placement and cursor contracts are documented in
[session-substrate.md](session-substrate.md). They are compatibility and explicit
control surfaces; ordinary managed dispatch does not require those administrative
steps. Native harness server APIs remain a possible backend change, separate from
this administration contract.
