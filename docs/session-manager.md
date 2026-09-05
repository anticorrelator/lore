# Managed sessions

`lore session start` owns routine session administration: source-scoped hosting,
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

The mechanism canonicalizes the workspace and knowledge store, ensures their
host, and seeds a missing work-item source declaration through the existing
metadata writer. An existing different declaration refuses. The worker gets an
isolated session-owned execution worktree; its source checkout remains the
publication destination. Agent initiation and cooperative protocol-terminus
closure are the defaults.

Intent is written before enqueue. A fixed request identity and durable queue,
journal, and launch checkpoints let recovery distinguish an unstarted request
from an already launched worker. Recovery must not launch a second worker merely
because the original caller disappeared.

## Host lifecycle

The Python facade starts an on-demand supervisor and a headless mode of the Go
session runtime. It reuses the Bubble Tea scheduler and PTY instrumentation with
rendering and terminal input disabled. A stable host key binds the physical source
workspace and store; each runtime generation has a fresh instance name. An OS lock
admits one runtime owner. Readiness is published only after recovery completes.
The supervisor retries runtime failure with bounded backoff; a drained host exits
after its idle timeout. No globally installed service is required.

Registry rows with `role: "session-host"` and `host_key` belong to this lifecycle.
Managed requests carry the host key so a new generation can resolve ownership.
A normal TUI does not adopt these rows. Recovery is source-scoped and checks dead
process ownership without waiting for heartbeat expiry, including abandoned
adoption claims. With tmux, a surviving interactive harness is adopted rather
than relaunched. Without tmux, host death cannot preserve that process; the
outcome must expose the loss. A transcript restart is not live-process recovery.

## Delivery and observation

Managed `send`, `answer`, and `close` persist a request and await its correlated
outcome. `send` retries only explicit pre-injection startup/readiness refusals
within its deadline. A runtime attempt record precedes input injection. If a
crash interrupts outcome verification, `delivery-uncertain` preserves the unknown
outcome and forbids automatic replay. The coordinator can inspect and decide how
to proceed. A timeout likewise does not prove that input was undelivered.

`peek` returns the current screen and readiness evidence. `answer` still requires
an observed modal expectation and an explicit choice. `wait` persists its own
observation position; callers need not carry byte offsets for individual managed
sessions. `inspect` reads durable state and receipts after the process is gone.
The existing append-only journal and event vocabulary remain the evidence seam.

## Teardown and result ownership

Managed `close` waits for its own correlated teardown outcome and reports worktree
publication, quarantine, or refusal, including retained result references and
cleanup disposition. Removing an execution directory does not prove integration.
A quarantined result remains available for the coordinator's composition judgment.
Protocol-terminus close retains the existing cooperative gate; explicit coordinator
close retains its existing authority. Source-generation and worktree ownership
guards apply equally to visible and headless hosts.

## Durable storage and compatibility

Under `_sessions/`, `hosts/<key>/` holds runtime readiness and supervisor state,
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
