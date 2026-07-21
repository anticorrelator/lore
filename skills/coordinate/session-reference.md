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
the 900-second lease through its durable registry identity. A mutating subagent may
run only inside a worktree allocated to its dispatching seat; it neither allocates
nor receives independent ownership. If no seat lease is available, use an item-backed
worker session. Read-only agents require no worktree. Live PID or tmux ownership
protects the tree regardless of lease age; renewals rewrite the manager row through
the sole manager rather than relying on registry mtime.

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
read (c2c34e2). The default stop set remains
`closed,close_failed,orphaned`; progress (`step_completed`), completion
(`terminus_reached`), worktree refusal/quarantine (`restore_refused`,
`worktree_quarantined`), and stall (`modal_blocked`, one journal row per genuine
modal entry) are explicit `--until` choices. `wait` has no session-type filter —
scope every watcher by exact slug or `--request-id`.

`--next-session` requires `--follow`, a positional exact slug, and no caller-supplied
`--request-id`. It starts at a supplied cursor or an invocation-time journal-end
baseline, ignores predecessor rows, and binds the first future request identity
from `requested`, `claimed`, `spawned`, or `spawn_failed`. Claim and spawn are
unordered acquisition edges for that identity: failed or reclaimed attempts keep
waiting, liveness begins only after correlated spawn (or recovery after claim),
and correlated abandonment or cancellation emits and exits 3.

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
