# Session verb reference — disclosed from skills/coordinate/SKILL.md

Mechanics consulted on demand. The judgment doctrine stays in SKILL.md; this file
holds the flag semantics, exit codes, and incident-derived calibrations that back it.

## Knowledge packets

Build context for a recipient at dispatch, or pull it again during a task:

```bash
lore packet build --work-item <slug> --role coordinator --caller coordinator \
  --topic "<assignment topic>" --scale-set architecture,subsystem
```

`--role` names the recipient: `investigator`, `designer`, `worker`, `reviewer`,
or `coordinator`. `--caller` records who requested the assembly. `--task <id>`
addresses a task in the item. Supply `--topic`, `--seeds <paths...>` (space- or
comma-separated), or both; when neither is supplied, the named task must have
a retrieval directive. That directive retains its focal/adjacent topics and
consultation requirements. `--scale-set` is required and declares the buckets
for this pull; there is no default. Existing task directives are read with the
caller’s declared scales.

The JSON status contains `packet_id`, `recipient_role`, `entries_per_scale`,
`scales_requested`, `scales_returned`, `norm_population_count`,
`consultation_requirements`, `trust_snapshot_hash`, `delivery_stage`, `location`,
and `flags`. Counts are distinct entry paths tagged with each requested scale;
a preference or abstract entry returned through the retrieval stack’s bypass
rule does not count as a hit at a different scale. The norm population retains
the full discovery tree enumeration with the labels used by conformance.
Status describes assembly. It does not establish receipt or decide whether the
context answers the assignment.

`--thin-floor <n>` adds `below_floor`, the requested scales whose counts are
below the caller’s threshold. Repeat `--flag <trigger> "<reason>"` to record
`unverified-assumption`, `unfamiliar-boundary`, or `conflicting-explanations`.
The caller declares these reasons; retrieval does not infer them.

A task packet uses schema 2 when a committed revision and a recorded dispatch
attempt exist. A re-pull uses the latest recorded attempt for that task and
current revision. Otherwise `unbound_reason` names the missing task, revision,
or attempt. Assembly writes through `packet-append.sh` and retains the
renderer’s `manifest_load` provenance. It does not publish a revision or create
a dispatch attempt.

Pass `--packet <id>` to managed `lore session start` or raw
`lore session request --type worker` to put one pointer
line after the guidance floor and before the brief. For a harness-native spawn,
`lore dispatch guidance --short --packet <id>` emits the same pointer after the
short floor. Without `--packet`, both surfaces retain their existing output.
The pointer names the store location and `lore packet show <id>`; it carries no
entry bodies. `show` renders entries with their available bylines, norm labels,
flags, and binding. `show --json` returns the stored row. Coordinators receive
the build status by default and can inspect a packet when the decision needs it.
Packets are pulled at dispatch; prefetch and session-start output do not change.


## Managed sessions

Use `lore session start <item> --workspace <source-checkout> --framework <id> --model <model> --context <brief> --packet <packet-id> --key <dispatch-id> --json` for item-backed workers. It starts or recovers a source-scoped host without a human TUI, seeds missing source provenance, and returns a durable session handle. Identical keyed retries join the same start; changed keyed intent refuses; no key means a new worker. Agent initiation and cooperative terminus auto-close are the defaults.

Use the returned handle with `send`, `answer`, `peek`, `wait`, `inspect`, `attach`, or `close`. Managed operations resolve the current host and persist their outcomes. `send` and `answer` await delivery evidence; `close` awaits its correlated teardown and reports worktree disposition. `inspect` remains available after teardown. `wait` owns its persistent observation cursor. A human can attach to the existing tmux terminal without taking over lifecycle ownership.

A `delivery-uncertain` refusal means an input attempt crossed a crash boundary with no provable outcome. Inspect the worker before deciding what to do; the mechanism never replays that input. Cleanup and integration are separate: a retained quarantine ref requires composition judgment even when the execution directory is gone. See [the session manager contract](../../docs/session-manager.md).

The following placement, raw enqueue, and journal-cursor recipes describe `request` and legacy sessions. Managed callers do not select a TUI, seed provenance separately, or capture a cursor before closing.

## Raw request targeting and placement

Placement lives on the work item, and dispatch derives it. A work item declares
its `source_checkout` — the checkout its sessions must start from — seeded by
`lore work source-checkout <slug>`, which takes the value from the dispatching
session's own recorded provenance, resolves it physically, and validates it
against the live instance registry before writing. For a slugged request,
`lore session request` reads that declaration and writes it as
`required_project_dir`: a hard read-side filter, claimable only by an instance
whose project directory equals it — every other live instance leaves the row
pending, with no grace-window decay. The caller passes no placement flag, and
no one resolves a branch to a clone by hand.

Each way the declaration can fail refuses at enqueue with its own repair, and
none is rewritten to an untargeted request: an item with no declaration (seed
it with `lore work source-checkout <slug>`), a declaration resolving to no
existing directory (fix the path), a declaration no live instance serves
(start or re-point an instance in that checkout). The fourth refusal lands at
claim time: `required_target_ref`, the source branch captured at enqueue, is
compared against what the claiming instance actually has checked out and
refuses on contradiction before anything is created on disk. The ref verifies;
it never routes — a ref name does not say which object store holds it, which is
why the placement axis is the directory and the ref is only ever a
contradiction check.
The `requested` journal row carries the complete placement stance under an
explicit `placement_stance` token — `required_dir`, `targeted`,
`preferred_dir`, or `any`; when axes combine, the token names the strongest in
force, in that order. The request file is deleted on every terminal path, so
the journal is the only durable record, and the absence of a field is never the
encoding of a stance. Rows written before the field existed keep their old
claim semantics: refusal gates on the stance token a new row carries, never on
field absence. A pre-feature instance cannot see the field at all and would
claim a declaring row anyway, so pair a declaring dispatch with `--min-vintage`
naming the build that introduced the filter.

A request with no slug has no declaration to derive from, so it declares
exactly one placement stance explicitly — `--target`, `--prefer-dir`,
`--prefer-cwd`, or `--anywhere` — and the CLI refuses a stanceless one.
`--anywhere` is the deliberate roulette
opt-in, writing no queue field: any live instance may claim, including one whose
harness rejects your model id at launch (haiku probes claimed by a codex-framework
instance died, 2026-07-08). When a dispatch assumes a framework, binary, or vintage,
constrain the claim:

- `--target <instance>` is the only pin (the named instance alone may claim).
- `--min-vintage` is a compatibility floor, not a pin — it refuses a claim only on
  positive evidence of an older build; an instance of unknown vintage passes,
  permissively by design.
- **Targeting pins the instance, not the framework**: the explicit request's
  `--framework` selects the launched harness independently of the host's default.
  Model ids are framework-scoped — every `--model` travels with its framework.
- Instance rows carry the framework an untargeted spawn there will actually resolve,
  alongside the instance's project dir; `session list` renders both as
  `<framework> @ <project_dir>`. An `unknown` in either position is a pre-feature row
  and means *can't tell*, never a default — verify some other way or pin the claim.

Placement stance selects a claimant, not a writable harness cwd.
`required_project_dir` is the one hard directory filter; `--prefer-dir <path>`
stays soft — a matching instance claims
immediately, others defer a 15s grace window, then anyone may take it: claim timing,
never a gate. `--prefer-cwd` is the soft preference for the dispatcher's own
checkout. From an ordinary shell it captures the working directory; from inside
a session it instead resolves the session's captured source checkout — the
checkout its registry row records — because a session runs in a worktree inside
the knowledge store, a path no instance's project directory can ever equal, so
capturing cwd there could only stall the claim and then land anywhere. When it
runs inside a session and no source checkout can be resolved, the flag refuses
rather than writing an unmatchable preference.
An ordinary hosted session captures that checkout into a session-owned
worktree before spawn. A coordinated writer instead carries the all-or-nothing
`--worktree-id`, `--execution-dir`, and `--worktree-identity` tuple allocated by the
coordination manager. Both direct PTY and tmux hosting validate the tuple and run at
the canonical execution directory; neither falls back to the TUI project directory.

## Worktree lifecycle and refusal

The versioned worktree identity carries canonical path, Git common-dir,
per-worktree git-dir, epoch, captured generation (source path/common-dir/git-dir,
HEAD OID, index digest, worktree digest), target ref and OID, and state. Its
ordinary lifecycle is `captured → active → publishable → published | quarantined`.
`teardown-pending` retains ownership while process death is unresolved; only
`published` and `quarantined` are cleanup-eligible.

Spawn, adoption, publish, and cleanup each revalidate identity. Missing legacy
identity, path reuse, git-dir or epoch mismatch, destination drift, and integration
conflict fail closed. The disposition vocabulary is exactly `published`,
`restore_refused`, and `worktree_quarantined`: refusal/quarantine leaves the
destination byte-for-byte unchanged and preserves the candidate under a durable
result ref/patch. Successful `published` projects to the normal exactly-once
`closed` terminal and adds its own `worktree_published` row naming the destination
checkout the merge landed in; refusal and quarantine add their named recovery rows.
None of the three is another close terminal.
Quarantine preserves content, not the physical directory.

A TUI-hosted claude-code session runs under a session-scoped write allowlist
enforced at the tool call by `scripts/guard-session-worktree-writes.sh`. The
session may write inside its own checkout, inside the knowledge store outside the
`_sessions/worktrees` and `_coordination/worktrees/trees` namespaces, and inside
the system temporary directory; every other target is blocked before the write and
appended as a `worktree_write_refused` row, identified by `actor_instance` with
`reason` either `outside-session-allowlist` or `containment-context-missing`. The
spawn path declares the boundary as `LORE_SESSION_WORKTREE` and the store as
`LORE_SESSION_STORE_ROOT`; a process carrying neither is an operator's own terminal
and is never fenced. The fence reads a structured target path, so a write issued
through a shell command, a tool call naming no path, and any harness other than
claude-code stay outside it — verify a cross-checkout edit rather than assuming the
fence caught it. Neither new event joins the default stop set; reach them with an
explicit `--until`.

## Coordinated writer ownership and cleanup

`lore coordinate worktree` is the sole manager for seat-allocated stream trees. Its
manifest embeds the canonical guard identity from `tui/internal/worktree/guard.go` and
adds immutable work item, stream, attempt, temporary branch, allocation base, and
owner identity. The manager alone allocates and advances the outer lifecycle:
`reserved → bound → active|recovered → quiescent → reconciling → cleanup_due → removed` — release is
removal; declaring a tree finished is the act that takes it down, and a failed
removal raises loudly with the record returned to `reconciling` so re-driving the
release is the retry. The manifest binds a session-or-seat 900-second lease;
renewal and lifecycle transitions rewrite the manager row explicitly, and a live
owner protects the tree regardless of age. After quiescence, reconciliation freezes
an immutable source manifest and an integrated manifest before any cleanup runs. A
removal that cannot be proven stays `cleanup_blocked`: no coordinated stream is
done and no dependency is satisfied until removal is proven.

Allocation authority stays with the coordinator or dispatching seat; the manager
allocates only for seats. A mutating subagent may run only inside a worktree
allocated to its dispatching seat; it neither allocates nor receives independent
ownership. When no seat tree is warranted, use an item-backed worker session — the
claiming TUI allocates its tree outside this registry. Read-only agents require no
worktree.

Integration happens on the stable control checkout: merge the stream's commits,
verify with the suites, record the merge SHA and counts in the ledger. The
coordinator chooses intended composition; merge conflicts are aborted and recorded,
then a worker edits its stream tree and returns a new attempt. Removal pins the
temporary branch's tip to a quarantine ref when it moved off its allocation base,
then proves itself: path absence, absence from `git worktree list --porcelain`, and
recorded branch and ref disposition.

## Send and answer semantics

Send exits are verb-local. Without `--wait`, `0` means enqueued only — the outcome
journals later as `sent` or `send_refused`. With `--wait` (poll budget `--timeout`,
default 15s): `0` sent, `1` error or wait-timeout (a timed-out send may still
deliver), `3` refused by the readiness gate, reason on stderr/JSON.

The readiness gate injects only when the session sits idle at its composer with no
permission modal — deliberately more conservative than what the harness would accept.

Answer exits mirror send: without `--wait`, `0` means enqueued only (journals later
as `answered` or `answer_refused`). With `--wait`: `0` means one navigation+Enter
write landed and a later screen confirmed the expectation gone; `3` is the
fail-closed refusal (`not-modal`, `expect-mismatch`, `option-unavailable`,
`no-contract`, `error`, `unconfirmed`); `1` is error or wait-timeout. Answer keys are
never replayed — read a timeout or `unconfirmed` as an unknown outcome: peek again
before retrying, and let a fresh request's own expectation gate decide whether the
modal is still there.

`lore session answer <slug> --option <N> --expect <literal>`: `N` is the displayed
option number, never a key count; `--expect` is mandatory literal text from the modal
you mean to answer, taken from a screen you actually read (`peek`), not from what the
dispatch led you to expect. The verb acts only when the live screen still classifies
as a numbered modal with the expectation visible and both the selected and requested
options proven; it refuses before any key is written otherwise, journals every
outcome, and exposes no raw-key surface. A modal whose choice geometry the classifier
can't prove is observable but not answerable; that refusal is the honest terminal,
not a bug.

An enabled `standing_decisions.modal_answers.<registration-id>` entry may authorize
one exact `numbered-modal-v1` signature: framework, trimmed title, and the complete
ordered `{number,label}` option list must match byte-for-byte. The modal edge journals
first, then the normal answer verb enqueues with `--registration-id`; requested and
terminal answer rows retain that id. Missing, disabled, malformed, unsupported, or
mismatched entries take the ordinary `modal_blocked` path with no answer request.
This registry does not authorize composer input: recurring composer consent remains
`needs_input` until a separate send-based standing policy exists.

## Close addresses

- `close <slug>` tears down the live session.
- `close --request <id>` cancels a spawn still pending in the queue — the un-dispatch
  for a brief you've thought better of before any instance claims it.
- `close --session <id>` keys on the harness session id (full, or the unambiguous
  leading prefix `session list` renders) and is the only way to reach a slugless
  session from another instance.

Close authority is full-discretion and everything journals — the check on a wrong
close is the audit trail, not a gate. Closing a *human*-initiated session is within
authority but exceptional: prefer a hands-request. `--initiator` records provenance;
teardown policy rides `--auto-close`. A failed close moves guard ownership to
`teardown-pending`; it does not release the session registry row
while the process may still write. Process teardown, guard disposition,
reconciliation, and verified manager cleanup remain separate decisions.

## Event stream mechanics

- The cursor rides stdout as a final `{"next_cursor": N}` row alongside the event
  rows — read the whole stream, no stderr to fold back in. JSON reads also expose
  ordered `records` entries that pair each event with the cursor immediately after
  that row; follow mode uses those exact boundaries rather than the batch cursor.
  Cursors are opaque: persist them verbatim in the ledger. A mid-row `--since` is refused with
  `cursor-not-row-aligned` — cursors are copied verbatim, never computed.
- `--cursor-only` gets a baseline without replaying the journal; `--tail <N>` reads
  the last N rows plus the cursor row — an orientation snapshot, not a resume
  mechanism (resuming always rides `--since` with a stored cursor).
- Interpret, don't re-validate: vocabulary and row shape are the sole writer's job.
  Match lifecycle pairs by per-slug ordering, never adjacency.
- Capture the baseline *before* a teardown you mean to measure: `--cursor-only`,
  then close, then `wait --since` that cursor.

## Wait mechanics

`lore session wait <slug>` keys on exact slug so a worker's close never wakes a
parent (`--work-item <slug>` opts in to the base slug plus derived `--w<n>` workers).
Exits: 0 matched or follow stop reached, 2 timed out (resume from the returned
cursor), 3 session-gone, 4 internal error after bounded retries — never read 4 as
timeout. The omitted timeout is 3600 seconds; explicit `--timeout 0` remains an
immediate check. Without `--follow`, `--until` keeps its one-shot filtering
behavior. With `--follow`, every exact-target row is emitted in journal order and
`--until` is the stop set. Plain output emits each event followed by its exact
`{"next_cursor": N}` checkpoint; `--json` emits one NDJSON matched object per
event with `matched`, `next_cursor`, and `terminal`, then an existing
terminal-shaped object on a non-match exit. Inspect every row's event and fields
before acting. `--request-id` narrows
`closed` rows only; a slug-matched `close_failed` still wakes — sloppy wake, exact
read (c2c34e2). The default stop set is the actionable set: `closed`,
`close_failed`, `orphaned`, `terminus_reached`, `needs_input`, `modal_blocked`,
`restore_refused`, `worktree_quarantined` — narrowing is the explicit act now, not
widening. `step_completed` stays an explicit `--until` opt-in: it is the one
high-frequency name in the vocabulary, and a default that woke per step would wake
constantly and carry no signal. `wait` has no session-type filter — scope every
watcher by exact slug or `--request-id`.

`--next-session` requires `--follow`, a positional exact slug, and no caller-supplied
`--request-id`. It starts at a supplied cursor or an invocation-time journal-end
baseline, ignores predecessor rows, and binds the first future request identity
from `requested`, `claimed`, `spawned`, or `spawn_failed`. Claim and spawn are
unordered acquisition edges for that identity: failed or reclaimed attempts keep
waiting, liveness begins only after correlated spawn (or recovery after claim),
and correlated abandonment or cancellation emits and exits 3.

## Arm mechanics

`lore coordinate arm` installs the standing eye once, at seat open — and `lore
arc open` now runs it for you by default (idempotent, `--no-watcher` to opt out),
so the manual verb is the override surface. It refuses a bare invocation: an
arming call must say `--install` or `--render` explicitly, because rendering a
hook without installing it is precisely how a seat once armed nothing and
believed otherwise. It also refuses a
handle-less arm: `--owner-pid` (the long-lived harness process, never a `$$`
subshell pid) or `--owner-tmux` is required, the same liveness-handle discipline
as seat-owned worktree allocation. The handle feeds the watch's stop-biased
liveness check (below); the refusal lands the failure on the dispatcher with a
fixable message instead of on a watcher that cannot prove its seat.

On a harness whose wake capability is async, arm installs a `Stop` hook entry
carrying `asyncRewake: true`, a `rewakeMessage`, and an explicit `timeout`
strictly greater than the watch deadline it configures; the hook spawns the watch
wrapper in the background at every turn boundary. The deadline ordering is
load-bearing: the watch ends every window itself with an exit-2 wake and the hook
timeout stays a backstop, because a hook-timeout SIGTERM kills the wrapper
silently — exit 143 never re-arms, and one such kill would end the chain
invisibly. The wrapper traps SIGTERM and leaves a kill marker so a timeout-kill
stays distinguishable from a clean trigger after the fact. The chain has no
self-propulsion: it advances only through exit-2 delivery into a live harness
turn, and every window is bounded by its hook timeout, so no watcher outlives
its seat.

The installed hook entry is its own record: its command line carries the arc
scope verbatim, so `lore arc close` finds arc-scoped watchers by reading the
settings file's Stop entries directly (`--settings <path>` overrides the default
of the active harness's settings file — the same place `arc open` auto-arms).
Close selects only entries whose arc scope includes the closing arc: one scoped
solely to it is auto-disarmed; one also naming other arcs earns a non-blocking
callout naming the disarm command — a watcher spanning arcs may still be another
arc's eye, so that call stays with the seat. An unscoped entry is never selected:
the bare board-wide eye is a seat-lifetime resource attributable to no arc,
disarmed by its seat at wind-down, never by closure. A hand-installed entry is as
visible to closure as an armed one — an entry is an entry, and it says what it
watches. Disarm is idempotent — nothing to remove exits 0 —
and safe to run unconditionally. One residual wake after disarm is expected:
removing the hook stops future windows from opening, but the window already
running ends at its own deadline and delivers its wake.

Per-harness wake support is declared in `adapters/capabilities.json`; branch on
the support flag, never the framework name.

| Harness | Wake capability | Loop shape |
|---|---|---|
| claude-code | async — the harness re-opens the window at every turn boundary | arm once at seat open; the seat parks idle while the eye runs. Interactive/TUI-hosted sessions only — headless `claude -p` runs hooks synchronously |
| codex | sync-only — a continuation channel without async hooks | seat-owned windows: same watch verb, same wake contract, each window opened by the seat; a short turn-friendly synchronous stop-check is the optional middle ground |
| opencode | none — no hook-return continuation | seat-owned windows, as codex |

Headless `claude -p` runs hooks synchronously (stream-json input is the headless
exception). On codex the Stop continuation channel exists (exit 2 + stderr) but
async hooks are refused at load. On opencode the server-API wake
(`session.promptAsync`) is a recorded lead, not a shipped path.

When the declared capability tier is unavailable where it should work, degrade
down the ladder — seat-owned watch windows → raw byte-offset journal poll
(`lore session events --since <cursor>`) → harness-native persistent monitor — and
ledger the mode in force so a fresh seat inherits a working eye rather than a dead
one. Machine suspension freezes a running window silently while the sessions run
on, so any resume re-joins the board before trusting quiet.

Watcher entries are identity-scoped, and the default install surface is
project-local. `lore arc open` auto-arms into the repo-local
`.claude/settings.local.json`; the user-global file takes an entry only when
`--install` points at it deliberately. A settings file may hold many watcher
entries, each carrying its full identity — canonical store path, owner handle,
arc set — on its own command line: install replaces only an entry with the
caller's exact identity, disarm removes only entries it can attribute, and both
name the identity they touched, so read that line rather than the count — a
count-only reading caused a live misattribution once. An entry with no complete
identity is legacy: reported, left in place, removed only by an explicit
`--legacy-sweep`. A firing whose store is gone, whose arcs are missing or closed,
or whose owner it cannot prove in its own ancestry exits quietly; arc close finds
the exact file its arc open armed through the arc record, from any working
directory.

## Watch mechanics

`lore coordinate watch` is the standing eye. Bare, it is board-scoped: it wakes
on the first actionable row from any session. Scoping is by arc alone — a row
matches when its `slug` or its `links.work_item` equals a member of the arc
(workers run under derived `<item>--w<n>` slugs; the second key is what keeps
them in scope). `--arc <slug>` expands the
arc's declared `members[]` (statuses `active` and `closed`, matching `arc list`)
into the same predicate — membership is declared, never inferred from project
labels. An actionable row carrying neither key bypasses scope and wakes as a
labeled unattributed advisory rather than being dropped.

Cursor and delivery identity include the canonical store, owner handle, and declared scope. The cursor is stored under `_coordination/watch-cursor-<identity>-<scope>.json`; the first run baselines at journal end and an explicit `--since` remains an opaque reader cursor. The installed arm path adds `--durable`. Direct callers may opt in with that flag and an owner handle.

Durable observation advances its cursor together with a pending wake payload before output. The payload retains its `wake_id` until the recipient runs `lore coordinate status --wake-id <id>`. That command returns the saved wake alongside the board, then acknowledges after successfully writing its output. Repeated acknowledgment is idempotent; a different owner cannot acknowledge the wake. Receipt does not mean its requested intervention is complete. Undelivered wakes remain available after restart, and redelivery retains the same id. Current observations accompany old evidence so an old park is not presented as a fresh confirmation.

Classification consumes `observation.activity`, never `ready`. A fresh known idle or blocked state can produce `confirmed`; unavailable, unknown, stale, or superseded evidence is `advisory`. A deadline with nothing actionable is `quiet`. A reason on a historical event does not establish that the worker is still parked. Peek reports the screen, framework, input eligibility, lifecycle evidence, worker generation, owning instance, and recognized modal details. Managed peek JSON wraps these under `response`; raw peek JSON returns the snapshot directly.

The watcher reconciles live sessions periodically as well as reading journal events. `--reconcile-interval` defaults to 15 seconds and `--reconcile-budget` to 8 seconds. Bounded concurrent reads rotate through larger session sets; unavailable or deferred observations are explicit. Each wake carries `current_observations` and `current_delta`, so missed journal edges can still bring a worker to attention. These are session observations; `coordinate status` remains the cross-substrate board.

Quiet windows retain the default 600-second cadence and produce real coordinator wakes through the supported harness transport. Pending quiet receipts do not create an immediate re-wake loop or hide newly actionable observations. `--pending-stale <sec>` (default 300, `0` disables) still covers requests no host has claimed. Authority is `hook-row`, `screen-signature`, `runtime`, `observation`, `owner-handle`, or `none`, with signature versions and evidence preserved.

Direct-call exits: 0 match or advisory, 2 timeout (cursor persisted), 3 owner
gone, 4 reader failure after bounded retries — never read 4 as timeout.
`--wake-shaped` (the arm wrapper's mode) collapses every terminal — match,
advisory, quiet timeout — into exit 2 with the wake body on stderr, because on an
async harness only exit 2 re-arms and a quiet wake is the loop's heartbeat. With
an owner handle (`--owner-pid`/`--owner-tmux`, passed through by arm; add
`--tmux-server <label>` when the seat runs on a non-default tmux server) the watch
runs a stop-biased liveness check each poll: an owner provably dead — pid reaped,
tmux session absent — gets a grace window, one final journal read, then exit 3
and no re-arm. The bias is deliberate: a watcher's false "alive" is a runaway,
so unknowable liveness never extends the chain past the current window — while
work itself is never at stake, because trees survive their watchers. The verb reads the journal and
writes nothing to it.

Run watchers and coordinator control from the stable checkout, never from a mutating
stream tree. This keeps a worker from rewriting the watcher or its dependency closure
mid-poll; declared overlap remains a semantic ownership edge even when Git paths are
physically isolated. For a stream that must perform the rewrite, publish the handoff
first, retain the last cursor, and raw-poll `lore session events --since <cursor>`
with exact slug, event, and field inspection only until the replacement contracts
are green. That raw-poll posture is scoped to the migration window, not standing
guidance.

## The evidence spine — verbs the seat reads and writes

`lore work show <slug> --json` returns `reader_contract_version: 2` with an `evidence` object: `revision` (head row), `result_summary` (per task and criterion: latest state, stale flag and reason), `review_summary` (attempts, sealed or open, cited results), `packet_summary` (per attempt: packet id, revision, delivery stage), and `sources` (coverage envelopes for tasks, reports, claims, the legacy close bundle — `read | absent | unreadable | unsupported`). The retrospective's `cycle_work` reader consumes exactly this projection; the TUI's evidence pages read it too.

`lore plan revise <slug>` publishes a revision after an authored plan edit or a checkbox; `--decision-for <revision-id>` appends a decision record (anchor coverage; dispatch: proceed, wait, or reuse a named review) without creating a new revision. `lore criteria run <slug> <task-id> <criterion-id> --execution-worktree <root> --packet-id <id>` (or `--revision <rid> --unbound-reason <text>` outside a dispatch) executes a declared criterion and appends the result; a recovery by result id republishes without re-running. `lore plan review prepare <slug> --attempt <id> --revision <rid> --purpose <criterion-adequacy|integration>` freezes the reviewed input; `lore plan review seal` publishes output, dispositions, and the evaluator manifest in one rename. `lore packet build --work-item <slug> --role <position> --scale-set <buckets> --caller <role> [--task <id>] [--thin-floor <n>] [--flag <reason>]…` returns the status object; `lore packet show <id>` renders the packet. All flags and refusals are in each verb's `--help`.

## Calibrations

The evidence log behind the skill's rules. A rule lives in SKILL.md clean — no
date, no incident; the row here holds what produced it, so a later seat can
check the rule against its origin. Each row names its status: **in skill**
(prose carries it), **mechanized** (a verb enforces it; the prose retired or
reduced to a habit), or **retired** (stopped doing work). Rows leave the log by
the lifecycle stated in § The role of the skill.

### Session-queues arc, 2026-07-16 (n=1 each, ~1h wall clock lost)

1. **Amending plan.md after spec finalization invalidates tasks.json's checksum** —
   run `lore work regen-tasks <slug>` in the same act as the amendment, or the next
   /implement session stalls at its mandatory gate asking permission the seat may
   not be able to grant (codex `send` refused `no-signature`). *In skill.*
2. **A refused steer is not health evidence — peek is the direct read.** Current Codex
   may insert optional badges before its footer separator (`high fast · <cwd>`), so
   readiness keys on the bottom-region separator+cwd suffix and nearby composer row,
   not a closed status-token list. A `generating` refusal remains truthful even while
   that composer chrome is visible: wait for `peek` to report `ready=true`, then
   correlate the nonce with one `send_requested` → `sent` journal pair before treating
   it as delivered. A `no-signature` refusal on an apparently idle future Codex build
   is a matcher-contract drift signal; preserve the screen and refresh the capability
   fixture instead of retrying the body. Rechecked on codex-cli 0.144.3 (2026-07-21):
   the fast-badge footer classified ready at idle, refused `generating` during a
   running tool call without placing the nonce in the transcript, and accepted a
   different nonce after returning idle. *In skill.* Addendum 2026-09-03: the
   `generating` refusal this row describes no longer occurs on codex — see row 14.

### Rows folded out of SKILL.md prose, 2026-09-01

3. **2026-07-28, 2026-08-11 (twice) — harness-native spawns omitting a model inherited
   the seat's tier and billed it.** Rule: state the model on every spawn.
   *Mechanized* — `validate-dispatch-guidance.sh` injects the resolver default when an
   `Agent` launch omits one; the skill keeps only the habit of stating the call.
4. **2026-08-11 — owner calibration: protocol text never quotes the human; rules are
   written in the skill's own voice.** *In skill* (§ The role).
5. **2026-08-13 — a rung-2 worker ran `lore impl start` against a spec-less item and
   parked at `needs_input` recommending /spec.** Rule: rung-1/2 briefs name the
   ceremony negatively as well as positively. *In skill* (§ Dispatching).
6. **2026-08-13 — watcher entries became identity-scoped with a project-local install
   default.** Contract documented above under Arm mechanics. *Mechanized.*
7. **2026-08-17 — a weekend of ten-minute quiet wakes against a two-input human gate,
   every one a no-op.** Rule: park the eye when the board is wholly human-gated.
   *In skill* (§ Monitoring).
8. **2026-08-20 — two ceremony dispatches rode a prior arc's `--framework claude-code`
   onto all-opus bindings unjustified.** Rule: a framework override needs a live,
   ledgered reason per dispatch. *In skill* (§ Dispatching, routing floor).
9. **2026-08-20 — archived-item distribution 2026-06→08 averaged ~2.7 tasks with ~40%
   single-task plans after the merge-default rules landed.** Rule: underfill is priced
   like over-ceremony. *In skill* (§ Open the arc).
10. **2026-08-26 — delegated spec agents made well-justified but needless architecture
    decisions; partial views inflate a part's importance.** Rules: the seat holds
    conceptual integrity; rung-3 specs carry a coordinator strawman. *In skill*
    (§ The role, § Open the arc).
11. **2026-09-01 — the cost-model paragraph assumed a short provider cache window; the
    current claude-code seat runs on a one-hour window.** Rule rewritten to read the
    window from the harness in force. The subagent-observability paragraph likewise
    asserted a fixed capability set the harness has since outgrown; rewritten as a
    capability probe. *In skill* (§ Monitoring, § Dispatching).

12. **2026-09-01 — owner calibration: the seat may take a stream over and write source
    when a standing directive routes the class to the lead or a dispatched agent is
    reading the picture narrower than the seat can see.** Precedent the same arc
    already set: the 2026-08-29 simplicity fix wave was implemented at the seat under
    the UI-lead directive, ledgered as a step, reviewed independently. Rule: hard edge 2
    now carries the exception, bounded by ledger row + item commit + control verify +
    independent review. *In skill* (§ The role, hard edge 2).

13. **2026-09-03 — owner calibration: small corrections the seat is confident in —
    tweaking a mostly-right spec before implement, correcting another agent's faulty
    assumption — are the seat's to make directly, not to route through a dispatch.**
    Rule: hard edge 2 gains a seat-scale correction tier below stream takeover,
    bounded by a ledger row and `regen-tasks` after plan amendments. *In skill*
    (§ The role, hard edge 2). n=1, stated at the open of the trace-evaluators arc.

14. **2026-09-03 — a claude-code lead with a running background subagent refused
    every steer as `generating` for ~90 min while its composer was idle.** The gate
    keyed on the output-quiescence timer, and the agents panel below the composer band
    repaints its elapsed-time counter every second, so the timer never fired; the
    harness itself accepted the same bytes at once. Same lesson as row 2 (Codex footer
    badges): anchor on the composer band, never on "anything animating on screen".
    *Mechanized* — the gate now reads the harness's probed `mid_generation_semantics`
    and, on a queued-autosubmit harness, admits on screen state alone. Same day, the
    codex row was re-probed on 0.148.0 with a held turn and lore's real transport
    (bracketed paste + CR): codex steers too — the message is held as "to be
    submitted after next tool call" and lands inside the turn; Tab is its separate
    queue-for-next-turn. The July `buffered-draft` reading was a probe artifact (raw
    nonce + CR in one burst, which codex treats as a paste). All three harnesses now
    admit mid-generation; `generating` only fires on a stale row. Open want:
    `needs_input` / `session wait` still key on the same timer.
    *In skill* (§ Dispatching, steerable mid-stream).

15. **2026-09-03 — owner calibration, second statement of the same intent as rows 12–13:
    the seat should feel free to act directly when its judgment says the action is
    justified — amending a spec, landing a small fix when several streams converge on
    the same mistake.** Rows 12–13 had added the permissions but left the stance as an
    exception ("executor of last resort", "by default never repo source"), and § Ceremony
    rung still read "never-write-source holds at every rung". Rule: hard edge 2 rewritten
    as a judgment with a test (act when you can write the rationale row now; two
    mechanism-shaped signals — the fix needs the whole-feature view, or the round-trip
    costs more than the edit; delegate when the work needs a working set the seat
    should not load or evidence machinery it cannot produce inline); the rung sentence
    retired. n=2. *In skill* (§ The role, hard edge 2; § Ceremony rung).

16. **2026-09-03 — owner calibration: the skill is the seat's own document, and
    guidance that has outlived the seat's understanding changes; the system must not
    exert the kind of control that keeps an agent from exercising creativity or
    flexibility in a novel situation.** Read against the text: 64 "never"s in 8,200
    words, closure duties with no size clause, a third of the file restating watch
    and arm mechanics this reference already holds, and a theory-page clause that
    contradicted hard edge 2. Pass: the opening now says a situation the file does
    not name is the ordinary case and the arc wins over a default; closure is sized
    to the arc, with silent skipping (not skipping) the defect; mechanism-"never"s
    became plain statements or moved here; the theory-page clause defers to edge 2;
    the monitoring section keeps stance and points here for mechanics. 8,200 → 6,900 words; 64 → 20 "never"s.
    *In skill* (throughout). n=1; the friction read is textual — retro evidence on
    whether seats actually park or over-ceremony under the old text is still owed.

### Coordination panel review, 2026-09-04

17. **2026-09-04 — the owner reviewed the coordination panel and found the stream rows
    unreadable cold and the graph wrapping into illegibility at half-screen widths.**
    Diagnosis: register, not density. The TUI projects the ledger's Step cell to the
    owner verbatim, first and largest, while the skill wrote it for the seat — 150-char
    dispatch notes with `[[work:…]]` links and protocol vocabulary — and the one register
    the owner reads well, the decision digest's four plain sentences, existed only at arc
    close. Rule: the Step cell is a plain headline in the digest register (roughly sixty
    characters, no slug, no session identifiers, no protocol vocabulary); the shorthand
    and the backlink move to the rationale cell; each step closure appends its settled
    decisions to a running `digest.md` the panel renders live, and the terminal digest
    is that file re-read and re-ordered rather than composed fresh. *In skill*
    (§ The ledger; § Verifying and closing; § Close the arc; the template's Step Ledger).
    n=1. Evidence: [[work:coordination-panel-owner-plain-headlines-marquee-r]], design.md.

### Trace-evaluator arc, 2026-09-04

18. **2026-09-04 — the owner opened the first PR of a seven-PR stack and found it about
    a fifth comment lines, and asked whether the preferences had been applied.** They
    had been *transmitted*: every brief carried "Comments minimal and reader-facing;
    no lore/plan vocabulary in source." What did not travel was the preference's test
    — default no comment, delete-by-default for correctness narration — so three
    implement and fix streams each wrote tidy, short justifications and the conformance
    aggregate recorded them as honored on the worker's own reading ("the descriptor's
    docstring is two lines for eight fields"); the second item's aggregate did not
    render at all and nothing asked why. The closure-time read the 2026-07-06 owner
    directive named ("seat reads norm adherence at every stream close") had left the
    skill on 2026-07-21 when the aggregate's mechanism moved into `/implement`'s
    close; the mechanism moved, the seat's reading of it did not come along. Two
    rules: a preference travels as the test it is checked by, never as its title or
    the seat's paraphrase; and the closure sequence has the seat read a few instances
    of the exercised preferences against the diff, with an unrendered aggregate as a
    prompt rather than a pass. Both written as what the seat is positioned to see, not
    as a gate. Cost of the gap here: one rebase-plus-hygiene worker stream over seven
    branches (~330 comment lines, ~1,400 test lines to triage) after the arc had
    closed. *In skill* (§ Dispatching, the five-element paragraph; § Verifying and
    closing, the closure sequence). n=1. Evidence: arc `trace-project-evaluators`
    ledger, post-close rows; item 1's `closure-conformance.md` rows 59–93.

### Coordinator agency dry run, 2026-09-04

19. **A cold read found the current skill granting direct authorship while the
    architecture guide still prohibited it, and requesting installation read-back
    already implemented by the arm verb.** Reconciled both with the current
    contracts. The skill's decision criterion now asks for evidence and authority,
    rather than the ability to write a rationale; explained uncertainty and a
    reasoned no-change decision are explicit outcomes. Genuine intent forks pause
    dependent work at any point, while reversible design calls within agreed
    authority continue with a flag. Routine reads need no ledger row. The revision
    guidance describes circumstances and reasons without attributing motives to
    agents, and permits challenging a rule's premise. *In skill* (§ The role,
    § The loop, § Monitoring, § What escalates). Evidence: arc
    `coordinator-agency-dry-run`; work item
    `coordinate-skill-prose-reduction-classify-mechaniz`; the independent peer read
    recorded in `implement-spec-reshape-agent-s-interaction-commons` supplied
    convergent reasoning, not a verdict binding this read. n=1 dry run; effects on
    sustained coordination have not been measured.


### Commons-reshape arc, 2026-09-04/05 (n=1 arc, thirteen steps)

1. **Tiers are what the work needs; rungs are the ceremony.** The arc that dissolved
   spec and implement into tiered dispatch needed a vocabulary for *what kind of work
   this is* separate from *how much ceremony it gets*: fix / decision / change / arc,
   set by decisions and working sets, never by diff size, and cheap to move between
   because a fix can reveal a fork mid-stream. A peer read from a differently-trained
   model named the failure this prevents — agents defend an initial classification to
   avoid procedural expansion when moving costs something. *In skill.*
2. **A packet at every dispatch; investigation and design are commissioned, not
   scheduled.** The retrospective record (2026-08-15) showed the store holding the
   answer to the one decision that went wrong while no surface put it in front of the
   agent making it — the lead path had no packet; only implement workers did, once, at
   finalize. `lore packet build` (arc step 4) builds one for any role at dispatch and
   returns facts, not a verdict; the seat declares a floor if it wants one. The three
   non-thin triggers (unverified assumption, unfamiliar boundary, conflicting
   explanations) came from the same peer read: a packet can be rich, current, and
   pointed at the wrong framing, and no retrieval count distinguishes that from
   readiness. *In skill.*
3. **Seat captures carry role and work item.** Bylines shipped (arc step 2) and the
   seat's own captures showed no byline because `lore capture` at the seat had been
   given no role; every seat capture now passes `--producer-role coordinator
   --work-item <slug>`. *In skill.*
4. **Compare a wake's event time to the session's spawn time before acting on it.** A
   `needs_input` wake for a just-finalized spec session arrived; by the time the seat
   peeked, a fresh implement session had spawned on the same slug and sat in its
   pre-submit startup state (launch command typed, unsent — `no-signature`). The seat
   read the startup as a park and closed it, losing 46 s and one re-request. Ledgered
   with a false first explanation, corrected against the journal. *Not yet in skill* —
   the durable fix is the watcher carrying spawn time, or readiness recognizing the
   startup state; see the arc's friction log.
5. **Session-owned teardown never lands a commit.** Across eleven streams: when the
   seat had moved main, the guard quarantined (correct, empty of anything new); when it
   had not, the guard *published* the result as uncommitted working-tree changes on the
   control checkout, and the next fast-forward refused to overwrite them. The landing
   path is always the worker's branch commit — verify the published copies identical,
   discard, fast-forward or cherry-pick. *Not yet in skill*; belongs in § Verifying and
   closing once the guard's behavior is settled rather than described.

## Shipped verb history

Moved from the SKILL's "Verbs this role wants" evidence log as each want shipped;
kept for provenance. Live wants stay in SKILL.md.

- Arm installation read-back — verified in the working tree 2026-09-04:
  `coordinate-arm.sh` requires `--install` or `--render` and checks the exact
  installed command through `installed_entry_present`; a missing entry fails.
  If Python is unavailable, the command reports that read-back was not performed.
  This retires the skill's installation-verification want. A delivered wake still
  verifies a different boundary: the harness actually ran the installed hook and
  returned its result. See [[work:coordinate-arm-renders-without-installing-reads-as]].

- `--track` / `--model` / `--yes` on `lore session request` — SHIPPED 2026-07-06: the
  three kernel dispatch judgments (depth, lead model, autonomy) became request fields.
- `close_refused` + tiered close authority — RESOLVED by gate *removal*, not event
  addition: full-discretion close shipped; no refusal branch survived, so the token
  was never minted. The worked example of a verb-want dissolving.
- `step_completed` — SHIPPED 2026-07-16: hosted `/spec` journals investigation,
  accepted-design, and plan-ready milestones; hosted `/implement` journals each task
  after acceptance, report logging, and checkbox persistence. Wake opt-in via
  `--until step_completed`; whole-protocol completion stays `terminus_reached`.
- `events --tail` / `--cursor-only` — SHIPPED 2026-07-07: a baseline cursor is an
  O(1) stat, no journal replay.
- `lore session wait` — SHIPPED 2026-07-07 after three hand-rolled watcher builds
  burned by three distinct footguns in one arc (sleep-blocked subagent; stderr-carried
  `next_cursor` dropped by `2>/dev/null` hygiene; BSD `grep -qv` exiting 0 on empty
  input). Gotchas captured: `lore-session-events-emits-next-cursor-on-stderr-wh`,
  `bsd-grep-macos-exits-0-grep-qv`. The stderr-cursor footgun is gone — the cursor
  rides stdout as a final JSON row → [[work:session-wait-verb-plus-events-cursor-to-stdout]].
- Raw `close --wait` — DISSOLVED into the wait verb (audit 2026-07-07): `close <slug>`
  then `wait <slug> --until closed` is the teardown-measurement idiom.
- wait-verb watcher blind spots — SHIPPED 2026-07-11 (c2c34e2 →
  [[work:session-wait-watcher-blind-spots]]): request-id/`close_failed` identity
  blindness, worker derived-slug mismatch, crash-read-as-timeout (now exit 4), and
  mid-row cursors all closed after 2 live misses + 1 near-miss in one arc. Mid-work
  modal stalls journal as `modal_blocked` (ebc500b →
  [[work:journal-modal-blocked-session-detection]]) — live-proven same day
  (3 entries, latch-clean, zero heartbeat spam).
- persistent follow, next-session acquisition, and the one-hour default — SHIPPED
  2026-07-21: follow emits every target row with a per-row resume checkpoint;
  next-session binds the future request across the no-owner gap and tolerates
  claim/spawn reordering. Rewriting the wait closure remains a calibrated n=4
  watcher hazard, so raw journal polling is a stream-scoped migration handoff only
  → [[work:session-watch-persistent-follow-sane-timeout-next]].
- actionable default stop set + `lore coordinate watch` + allocate lifecycle hint —
  SHIPPED 2026-07-24 → [[work:coordinator-seat-orientation-fixes-automatic-sleep]]:
  the safe stop set became wait's default (the prose warning it replaced is gone);
  watch retired per-session watcher fleets and covers the silent-park gap
  (a targeted request whose instance died pre-claim sat pending 61 minutes with
  zero journal rows — the incident that earned `--pending-stale`); allocate now
  names the next lifecycle verb for seat-owned trees.
- close retry-on-unblock + `terminus_reached` — SHIPPED 2026-07-12 (park-open arc →
  [[work:completed-sessions-park-open-close-retry-on-unbloc]]), both legs. Origin: a
  spec session completed its protocol but both terminus auto-closes died against a
  modal; the finished session parked open ~18 min. Shipped shape: `terminus_reached`
  emitted by the terminal verbs before close enqueue, plus a bounded 30/60/120s
  transient-modal close retry on the TUI heartbeat. Dogfood proof: `terminus_reached`
  journaled 33s before its teardown bounced `close_failed`; seat idiom closed it in
  86s vs the original 18 min. The interim seat idiom (close it yourself on
  `close_failed` + terminus narration at a resting composer) stays live until running
  TUI instances rebuild with the retry ladder.
