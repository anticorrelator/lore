# Session verb reference — disclosed from skills/coordinate/SKILL.md

Mechanics consulted on demand. The judgment doctrine stays in SKILL.md; this file
holds the flag semantics, exit codes, and incident-derived calibrations that back it.

## Dispatch targeting and placement

Every request declares exactly one placement stance — `--target`, `--prefer-dir`,
`--prefer-cwd`, or `--anywhere` — and the CLI refuses a stanceless one (0 of 110
pre-contract claims ever stated placement). `--anywhere` is the deliberate roulette
opt-in, writing no queue field: any live instance may claim, including one whose
harness rejects your model id at launch (haiku probes claimed by a codex-framework
instance died, 2026-07-08). When a dispatch assumes a framework, binary, or vintage,
constrain the claim:

- `--target <instance>` is the only pin (the named instance alone may claim).
- `--min-vintage` is a compatibility floor, not a pin — it refuses a claim only on
  positive evidence of an older build; an instance of unknown vintage passes,
  permissively by design.
- **Targeting pins the instance, not the framework**: a targeted request with a
  framework-scoped model id still dies at launch when the target runs a different
  harness (fable → codex 400, 2026-07-13; same class as the haiku incident). Model ids
  are framework-scoped — every `--model` travels with the `--framework` that owns it.
- Instance rows carry the framework an untargeted spawn there will actually resolve,
  alongside the instance's project dir; `session list` renders both as
  `<framework> @ <project_dir>`. An `unknown` in either position is a pre-feature row
  and means *can't tell*, never a default — verify some other way or pin the claim.

Placement stance selects a claimant, not a writable harness cwd. `--prefer-dir
<path>` (`--prefer-cwd` for your own checkout) is soft — a matching instance claims
immediately, others defer a 15s grace window, then anyone may take it: claim timing,
never a gate. An ordinary hosted session captures that checkout into a session-owned
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
`closed` terminal; refusal and quarantine add their named recovery rows, not
another close terminal. Quarantine preserves content, not the physical directory.

## Coordinated writer ownership and cleanup

`lore coordinate worktree` is the sole manager for coordinated stream trees. Its
manifest embeds the canonical guard identity from `tui/internal/worktree/guard.go` and
adds immutable work item, stream, attempt, temporary branch, allocation base, and
owner/lease identity. The manager alone allocates and advances the outer lifecycle:
`reserved → bound → active|recovered → quiescent → reconciling → cleanup_due →
removed`; abnormal cleanup claims advance through `sweep_claimed → swept`, while
`cleanup_blocked` remains retryable and never means success.

Allocation authority stays with the coordinator or dispatching seat. A session owns
the 900-second lease through its durable registry identity; a seat owns it only
through an explicit liveness handle — `--owner-pid` (the long-lived harness process,
never a `$$` subshell pid) or `--owner-tmux` — which allocate requires for
seat-owned trees. The lease is a dead-man's switch: live PID or tmux ownership
protects the tree regardless of lease age, expiry only sets the liveness re-test
cadence, and a reclaimed tree is quarantined with a recovery bundle, never
destroyed silently. A mutating subagent may run only inside a worktree allocated
to its dispatching seat; it neither allocates nor receives independent ownership.
If no seat lease is available, use an item-backed worker session. Read-only agents
require no worktree. Renewals rewrite the manager row through the sole manager
rather than relying on registry mtime.

After quiescence, freeze the immutable source manifest, reconcile from the stable
control checkout, and freeze the integrated manifest before cleanup. The coordinator
chooses intended composition; merge conflicts are aborted and recorded, then a
worker edits the leased source tree and returns a new attempt. Cleanup or crash sweep
first persists tracked, staged, unstaged, and untracked recovery evidence outside the
tree, then removes it. Terminal proof requires path absence, absence from `git
worktree list --porcelain`, and recorded temporary-branch and guard-ref disposition.
Missing proof or failed removal stays `cleanup_blocked`, so the stream cannot satisfy
a dependency edge.

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
`teardown-pending`; it does not release the session registry row or manager lease
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

Arming with `--install` also records what it installed — the settings path and
any scope — in `$KNOWLEDGE_DIR/_coordination/armed-watchers.json`, and `lore
coordinate disarm --settings <path>` removes both the hook entry and the record.
The record is discovery metadata, never authority: the settings file remains the
truth about what is armed; the record lets `lore arc close` find arc-scoped
watchers no live seat remembers. Close selects only records whose arc scope
includes the closing arc: one scoped solely to it is auto-disarmed; one also
naming other arcs or item scopes earns a non-blocking callout naming the disarm
command — a watcher spanning arcs may still be another arc's eye, so that call
stays with the seat. An unscoped record is never selected: the bare board-wide
eye is a seat-lifetime resource attributable to no arc, disarmed by its seat at
wind-down, never by closure. Disarm is idempotent — nothing to remove exits 0 —
and safe to run unconditionally. One residual wake after disarm is expected:
removing the hook stops future windows from opening, but the window already
running ends at its own deadline and delivers its wake.

Per-harness wake support is declared in `adapters/capabilities.json`; branch on
the support flag, never the framework name. Async: claude-code —
interactive/TUI-hosted sessions only; headless `claude -p` runs hooks
synchronously (stream-json input is the headless exception). Sync-only: codex —
the Stop continuation channel exists (exit 2 + stderr) but async hooks are
refused at load, so windows are seat-owned; a short synchronous stop-check with a
turn-friendly `timeoutSec` is the optional middle ground. None: opencode —
seat-owned windows; the server-API wake (`session.promptAsync`) is a recorded
lead, not a shipped path.

## Watch mechanics

`lore coordinate watch` is the standing eye. Bare, it is board-scoped: it wakes
on the first actionable row from any session. Repeatable `--slug <s>` narrows the
trigger set with a two-key predicate — a row matches when its `slug` or its
`links.work_item` equals a scoped slug (workers run under derived `<item>--w<n>`
slugs; the second key is what keeps them in scope). `--arc <slug>` expands the
arc's declared `members[]` (statuses `active` and `closed`, matching `arc list`)
into the same predicate — membership is declared, never inferred from project
labels. An actionable row carrying neither key bypasses scope and wakes as a
labeled unattributed advisory rather than being dropped.

The board-wide cursor lives at `_coordination/watch-cursor.json`; each distinct
scope persists its own cursor file beside it under a scope-derived name, so
concurrent scoped seats never race one position. Cursors are written atomically
on every exit path; precedence is `--since` > cursor file > journal end, and the
first-ever run baselines at journal end. An explicit `--since` rewrites the
persisted cursor on exit, so a ledgered cursor is seat-handoff material, never
watcher feed — the verb owns its position, and any window resumes from it with no
cursor arguments at all.

Classification: on a park-shaped row the watcher peek-confirms through the owning
instance's shared readiness gate before waking. A strict match against the
versioned per-harness signature set wakes `confirmed`; no strict match wakes
`advisory` carrying the labeled reason no signature fired; an advisory repeating
past its age threshold wakes `aged_advisory`; a window reaching its deadline with nothing
actionable wakes `quiet` with the cursor position. Strictness selects tier, never
existence. `--advisory-age <sec>` sets the escalation threshold; `--peek-timeout
<sec>` bounds the round-trip through the owning instance, and `0` skips the peek
entirely — a skipped peek still wakes, at `advisory` tier with the skip as its
label, because no classification outcome may end in silence. When the matched row itself carries authoritative lifecycle state,
that state is final and the screen is not consulted for that session — authority
`hook-row`, suppression, never blending; otherwise authority `screen-signature`.
`modal_blocked` is the sole exception, and it is a handover rather than a blend:
some harnesses clear their own modals within a second, so the screen classifies
every modal row whatever the emitter said. A modal on the screen confirms; any
other screen demotes to an advisory labelled `modal-not-on-screen`, which ages
normally. A screen that cannot answer leaves the row's claim confirmed on
`hook-row` authority — absence of evidence never demotes. `classification.modal_gate`
reports what the gate found on every modal row, including the ones it left standing.
Every wake body names its authority (`hook-row`, `screen-signature`, `owner-handle` on an owner-gone exit, or `none` on a quiet window) and the signature-set version consulted, so
matcher-contract drift (the codex composer-badge class — see Calibrations below)
is detectable rather than silent; signatures are versioned and refreshable.

The wake payload is six-part: tier, authority, signature version, the matched row
or advisory, the board delta, and the next cursor. The delta comes from `lore
coordinate status --json` (~1s per wake), diffed as per-bucket row-id sets
against `_coordination/watch-board-baseline.json` beside the cursor (same
per-scope naming) and refreshed on each wake; row ids are content-stable, so the
diff is exact across runs. That projection is the wake's dominant cost, and
`--no-board-delta` is the only lever on it: the wake still carries tier,
authority, and the matched row, and you re-run `status` by hand. The delta is
board-wide even under a scoped
watch — scope governs triggers; the delta is information — and its shape reserves
an advisory slot for signals outside the board projection: `--pending-stale
<sec>` (default 300, `0` disables) wakes on a pending request older than the
threshold, age read from the row's `requested_at`, never mtime, which claim
retries rewrite; a journal match outranks an advisory in the same poll.

Direct-call exits: 0 match or advisory, 2 timeout (cursor persisted), 3 owner
gone, 4 reader failure after bounded retries — never read 4 as timeout.
`--wake-shaped` (the arm wrapper's mode) collapses every terminal — match,
advisory, quiet timeout — into exit 2 with the wake body on stderr, because on an
async harness only exit 2 re-arms and a quiet wake is the loop's heartbeat. With
an owner handle (`--owner-pid`/`--owner-tmux`, passed through by arm; add
`--tmux-server <label>` when the seat runs on a non-default tmux server) the watch
runs a stop-biased liveness check each poll: an owner provably dead — pid reaped,
tmux session absent — gets a grace window, one final journal read, then exit 3
and no re-arm. The bias is the worktree lease's inverted: a lease's false "dead"
destroys work, a watcher's false "alive" is a runaway, so unknowable liveness
never extends the chain past the current window. The verb reads the journal and
writes nothing to it.

Run watchers and coordinator control from the stable checkout, never from a mutating
stream tree. This keeps a worker from rewriting the watcher or its dependency closure
mid-poll; declared overlap remains a semantic ownership edge even when Git paths are
physically isolated. For a stream that must perform the rewrite, publish the handoff
first, retain the last cursor, and raw-poll `lore session events --since <cursor>`
with exact slug, event, and field inspection only until the replacement contracts
are green. That raw-poll posture is scoped to the migration window, not standing
guidance.

## Calibrations (session-queues arc, 2026-07-16; n=1 each, ~1h wall clock lost)

1. **Amending plan.md after spec finalization invalidates tasks.json's checksum** —
   run `lore work regen-tasks <slug>` in the same act as the amendment, or the next
   /implement session stalls at its mandatory gate asking permission the seat may
   not be able to grant (codex `send` refused `no-signature`).
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
   different nonce after returning idle.

## Shipped verb history

Moved from the SKILL's "Verbs this role wants" evidence log as each want shipped;
kept for provenance. Live wants stay in SKILL.md.

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
- `close --wait` — DISSOLVED into the wait verb (audit 2026-07-07): `close <slug>`
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
