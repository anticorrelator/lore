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

Placement: a claimed session spawns in the claiming TUI's own startup cwd. `--prefer-dir
<path>` (`--prefer-cwd` for your own checkout) is soft — a matching instance claims
immediately, others defer a 15s grace window, then anyone may take it: claim *timing*,
never a gate; pre-feature instances ignore it (pair with `--min-vintage`). The brief's
explicit root/branch direction plus its mismatch instruction stays the correctness backstop.

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
teardown policy rides `--auto-close`.

## Event stream mechanics

- The cursor rides stdout as a final `{"next_cursor": N}` row alongside the event
  rows — read the whole stream, no stderr to fold back in. It is opaque: persist it
  verbatim in the ledger. A mid-row `--since` is refused with
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
Exits: 0 matched, 2 timed out (re-arm from the returned cursor), 3 session-gone,
4 internal error after bounded retries — never read 4 as timeout. `--request-id`
narrows `closed` rows only; a slug-matched `close_failed` still wakes — sloppy wake,
exact read (c2c34e2). The wait default is `closed,close_failed,orphaned`
(teardown-oriented); progress (`step_completed`), completion (`terminus_reached`),
and stall (`modal_blocked`, one journal row per genuine modal entry) wakes are
explicit opt-ins via `--until`. `wait` has no session-type filter — scope every
watcher and raw poll by exact slug or `--request-id`, and on wake check the matched
row's event type and fields before acting.

One closure the verb honestly refuses to absorb: a running watcher dies if a live
tree-writer rewrites `session-wait.sh` or anything in its dependency closure
mid-poll — check the writer's declared file set before arming, and drop to a raw
byte-offset journal poll when it overlaps (n=3 across arcs; the fallback ran clean
through the stream that shipped the terminus contract, 2026-07-12).

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
