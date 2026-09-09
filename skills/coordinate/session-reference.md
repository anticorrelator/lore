# Session verb reference — disclosed from skills/coordinate/SKILL.md

Mechanics consulted on demand. The skill holds stance; this file holds what a verb's `--help` does not — how verbs relate, what a refusal means for the seat, and the calibration log behind the skill's rules. Flags and exit codes: each verb's `--help` first.

## Knowledge packets

```bash
lore packet build --work-item <slug> --role <investigator|designer|worker|reviewer|coordinator> \
  --caller coordinator --topic "<assignment topic>" --scale-set architecture,subsystem
```

`--scale-set` is required; there is no default. Supply `--topic`, `--seeds`, or both, or name a `--task` that carries a retrieval directive. The status object describes assembly — `entries_per_scale`, `scales_returned`, `norm_population_count`, `consultation_requirements`, `delivery_stage`, `flags` — not receipt, and not whether the context answers the assignment. `--thin-floor <n>` adds `below_floor`; `--flag <unverified-assumption|unfamiliar-boundary|conflicting-explanations> "<reason>"` records a trigger the caller declares. A task packet binds to a committed revision and a recorded dispatch attempt when both exist; otherwise `unbound_reason` says which is missing.

What `build` returns is a candidate set. Synthesize it before it travels:

```bash
lore packet synthesize <packet-id> --by coordinator --drop <path> "<why>" --add <path> "<why>"
```

The verb appends a superseding row under the same id at `delivery_stage: synthesized`, removes dropped blocks from the content, appends added entries and a `## Left out by synthesis` list the receiver can read, and recomputes the counts. Only delivered paths can be dropped; only store entries not already delivered can be added; one synthesis per pull. `position-bind` refuses a packet whose latest row is not synthesized unless the builder recorded a `synthesis_waiver` — `spec-open` does, for the investigator packets it builds and dispatches in one verb.

Hand on the pointer, not the bodies: `--packet <id>` on `lore session start` or `lore session request --type worker`; `lore dispatch guidance --short --packet <id>` for a harness-native spawn. `lore packet show <id>` renders entries with bylines, norm labels, flags, and binding; `--json` returns the stored row. Packets are pulled at dispatch; prefetch and session-start output are unchanged.

## Managed sessions

```bash
lore session start <item> --workspace <source-checkout> --session-route <canonical-route-json> \
  --context <brief> --packet <packet-id> --key <dispatch-id> --json
```

Starts or recovers a source-scoped host without a human TUI, seeds a missing source declaration on the item (and refuses a conflicting one rather than changing the item's destination), allocates the execution checkout, and returns a durable handle for `send`, `answer`, `peek`, `wait`, `inspect`, `attach`, `close`. Managed verbs resolve ownership after a host restart. The dispatch key: identical keyed retries join the same start; a changed brief or model under the same key refuses; no key means a new worker. Agent initiation and terminus auto-close are the defaults; a human may `attach` without taking lifecycle ownership.

`send` and `answer` await delivery evidence; `close` awaits its correlated teardown and reports worktree disposition; `inspect` works after teardown. A `delivery-uncertain` refusal means an input crossed a crash boundary with no provable outcome — inspect the worker; the mechanism never replays that input. Cleanup and integration are separate: a retained quarantine ref needs composition judgment even when the execution directory is gone. Contract: [docs/session-manager.md](../../docs/session-manager.md).

Two habits the verbs do not carry for you. The guidance floor rides every managed brief; for harness-native spawns render it with `lore dispatch guidance` and prepend its complete stdout before every launch and retry — some harnesses repair a floorless launch silently, others refuse it. Parallelism runs through sessions and subagents, not stacked Skill calls.

## Request targeting and placement

Placement lives on the work item and dispatch derives it. An item declares its `source_checkout` (`lore work source-checkout <slug>` seeds it from the dispatching session's provenance and validates it against the live instance registry). A slugged `lore session request` writes it as `required_project_dir`: a hard filter, claimable only by an instance whose project directory equals it. Every way the declaration can fail refuses at enqueue with its own repair — no declaration (seed it), a path that does not exist (fix it), a checkout no live instance serves (start one there) — and a fourth refuses at claim: `required_target_ref`, the branch captured at enqueue, contradicts what the claimant has checked out. The ref verifies; the directory routes.

A slugless request declares exactly one stance — `--target <instance>` (the only pin), `--prefer-dir <path>` or `--prefer-cwd` (soft: a match claims at once, others wait a 15s grace, then anyone), or `--anywhere` (deliberate: any instance, including one whose harness rejects your model). `--min-vintage` is a floor, not a pin — it refuses only on positive evidence of an older build. Targeting pins the instance, not the framework: `--framework` selects the harness independently, and every `--model` travels with its framework. Inside a session `--prefer-cwd` resolves the session's recorded source checkout, never its worktree path. The `requested` row carries `placement_stance` (`required_dir` | `targeted` | `preferred_dir` | `any`); the request file is deleted on every terminal path, so the journal is the record.

Seat-owned trees (below) cannot host worker sessions — do not pass their identity tuple to `request`. Hosted workers receive a session-owned worktree from the claiming host.

## Worktree lifecycle and refusal

The worktree identity carries canonical path, Git common-dir, per-worktree git-dir, epoch, captured generation (HEAD OID, index digest, worktree digest), target ref and OID, and state. Lifecycle: `captured → active → publishable → published | quarantined`; `teardown-pending` retains ownership while process death is unresolved, and only `published` and `quarantined` are cleanup-eligible. Spawn, adoption, publish, and cleanup each revalidate identity and fail closed on mismatch.

Dispositions are exactly `published`, `restore_refused`, and `worktree_quarantined`. Publish fast-forwards the destination branch to the worktree's committed tip when the allocation base equals the destination's HEAD, the tip descends from it, and both trees are clean; a failed check quarantines with `base-diverged`, `worktree-dirty`, or `destination-dirty`. Refusal or quarantine leaves the destination byte-for-byte unchanged and preserves the candidate under a durable result ref/patch. Quarantine preserves content, not the physical directory. `published` projects to the exactly-once `closed` terminal and adds a `worktree_published` row naming the destination that advanced; none of the three is another close terminal.

A TUI-hosted claude-code session runs under a session-scoped write allowlist enforced at the tool call (`scripts/guard-session-worktree-writes.sh`): its own checkout, the store outside the worktree namespaces, and the system temp dir. A blocked write is journaled as `worktree_write_refused` with reason `outside-session-allowlist` or `containment-context-missing`. The fence reads a structured target path, so shell-issued writes, path-less tool calls, and other harnesses are outside it — verify a cross-checkout edit rather than assume the fence caught it. Neither event joins the default stop set.

## Coordinated writer ownership and cleanup

`lore coordinate worktree` is the sole manager for seat-allocated stream trees. Its manifest embeds the canonical guard identity from `tui/internal/worktree/guard.go` plus work item, stream, attempt, temporary branch, allocation base, and owner. Outer lifecycle: `reserved → bound → active|recovered → quiescent → reconciling → cleanup_due → removed` — release is removal, and a failed removal returns to `reconciling` so re-driving the release is the retry. A session-or-seat 900-second lease protects the tree; a live owner protects it regardless of age. After quiescence, reconciliation freezes an immutable source manifest and an integrated manifest before cleanup. A removal that cannot be proven stays `cleanup_blocked`, and no coordinated stream is done until removal is proven.

Allocation authority stays with the dispatching seat; a mutating subagent runs only inside a tree allocated to its seat and never allocates. When no seat tree is warranted, an item-backed worker session gets its tree from the claiming host, outside this registry. Read-only agents need none.

Integration happens on the stable control checkout: merge the stream's commits, verify with the suites, record the merge SHA and counts in the ledger row. On conflict, abort and record the paths; the seat decides the intended composition when existing contracts settle it, the worker makes source edits in its own stream tree and returns a new attempt, and an intent-anchor or directive change escalates. Removal pins the temporary branch's tip to a quarantine ref when it moved off its base, then proves itself: path absence, Git-registry absence (`git worktree list --porcelain`), and recorded branch/ref disposition. Run watchers and seat control from the stable checkout, never from a mutating stream tree.

## Send, answer, close

`send`: without `--wait`, exit 0 means enqueued; the outcome journals as `sent` or `send_refused`. With `--wait`: 0 sent, 1 error or timeout (a timed-out send may still land), 3 refused with the reason. Every current harness admits a send mid-generation; a modal or a composer already holding text refuses on all of them.

`answer <slug> --option <N> --expect <literal>`: `N` is the displayed option number; `--expect` is literal text from a screen you actually read. The verb acts only when the live screen still classifies as a numbered modal with the expectation visible and both options proven; otherwise it refuses (`not-modal`, `expect-mismatch`, `option-unavailable`, `no-contract`, `unconfirmed`) before any key is written. Keys are never replayed — read a timeout or `unconfirmed` as unknown, peek, and let a fresh request's own expectation decide. A `standing_decisions.modal_answers.<id>` entry may pre-authorize one exact `numbered-modal-v1` signature; anything not matching byte-for-byte takes the ordinary `modal_blocked` path. Composer consent is not covered — that stays `needs_input`.

`close <slug>` tears down a live session; `close --request <id>` cancels a pending spawn; `close --session <id>` reaches a slugless session by harness id. Close is full-discretion and everything journals. A failed close moves the guard to `teardown-pending` and keeps the registry row while the process may still write.

## Events and wait

`lore session events --since <cursor>` emits event rows and a final `{"next_cursor": N}` row on stdout; JSON reads pair each event with the cursor after it. Cursors are opaque — persist them verbatim in the ledger; a mid-row `--since` is refused. `--cursor-only` baselines without replay; `--tail <N>` orients but does not resume. Interpret rows, don't re-validate them; match lifecycle pairs by per-slug ordering. To measure a teardown, take the baseline before closing.

`lore session wait <slug>` keys on the exact slug (`--work-item` adds derived `--w<n>` workers). Exits: 0 matched, 2 timed out (resume from the returned cursor), 3 session gone, 4 reader failure — never read 4 as timeout. Default timeout 3600s. The default stop set is the actionable set — `closed`, `close_failed`, `orphaned`, `terminus_reached`, `needs_input`, `modal_blocked`, `restore_refused`, `worktree_quarantined`; `step_completed` is an explicit opt-in because it fires per step. `--follow` emits every target row with a per-row checkpoint. A slug-matched `close_failed` wakes even with `--request-id`: sloppy wake, exact read. `--next-session` (with `--follow`) binds the first future request for the slug across the no-owner gap and tolerates claim/spawn reordering.

## Arm

`lore coordinate arm` installs the standing eye; `lore arc open` runs it by default (`--no-watcher` opts out), so the manual verb is the override. It refuses a bare call — say `--install` or `--render` — and a handle-less one — `--owner-pid` (the long-lived harness process, not a subshell) or `--owner-tmux`. Install reads the installed entry back and reports when it cannot.

On an async-capable harness the entry is a `Stop` hook with `asyncRewake: true` and a timeout strictly greater than the watch deadline: the watch ends every window itself with an exit-2 wake, and the hook timeout is only a backstop, because a timeout kill is silent and never re-arms. The chain advances only through exit-2 delivery into a live turn, so no watcher outlives its seat. Installation and delivery are separate facts: if the first expected wake does not arrive, read the window log and the harness's hook delivery.

| Harness | Wake capability | Loop shape |
|---|---|---|
| claude-code | async — the harness re-opens the window at every turn boundary | arm once; the seat parks while the eye runs. Interactive/TUI-hosted only — headless `claude -p` runs hooks synchronously |
| codex | sync-only continuation channel | seat-owned windows: same watch verb, each window opened by the seat |
| opencode | none | seat-owned windows, as codex |

Capability is declared in `adapters/capabilities.json`; branch on the flag, never the framework name. When the declared tier is unavailable, degrade down the ladder — seat-owned watch windows → raw journal poll (`lore session events --since`) → harness-native monitor — and ledger the mode in force. Machine suspension freezes a window while sessions run on: re-join the board on any resume.

Entries are identity-scoped — canonical store, owner handle, arc set, on the command line — and install project-local (`.claude/settings.local.json`) unless `--install` names another file. Install replaces only an entry with the caller's exact identity; disarm removes only entries it can attribute, and both name what they touched — read that line, not the count. A legacy entry with no identity is reported, left in place, and removed only by `--legacy-sweep`. `lore arc close` auto-disarms an entry scoped solely to the closing arc, calls out one that also names other arcs, and never touches an unscoped board-wide eye — that is a seat-lifetime resource, disarmed at wind-down. Disarm is idempotent; one residual wake after disarm is expected. A firing whose store is gone, whose arcs are closed, or whose owner it cannot prove exits quietly.

## Watch

`lore coordinate watch` is the standing eye. Bare, it is board-scoped; `--arc <slug>` scopes to the arc's declared members (a row matches when its `slug` or `links.work_item` is a member; workers run under derived `<item>--w<n>` slugs). An actionable row carrying neither key wakes as a labeled unattributed advisory rather than being dropped. The cursor lives under `_coordination/watch-cursor-<identity>-<scope>.json`; the installed path adds `--durable`.

A durable wake advances the cursor together with a pending payload that keeps its `wake_id` until `lore coordinate status --wake-id <id>` returns it with the board and acknowledges it. Redelivery keeps the same id and is not a new event; receipt is not completion of what the wake asks. Current observations travel with old evidence so a stale park is not presented as fresh, and a wake carries historical events separately from current observations, their delta, and unclaimed spawn requests. Compare a wake's event time to the session's spawn time: a just-spawned session in pre-submit startup reads like a park and is not one. `--full-evidence --receipt-only` expands compact evidence when a decision needs it.

Tiers: `confirmed` (a fresh known idle or blocked state — actionable on sight), `advisory` (unavailable, unknown, stale, or superseded evidence — it names why no strict signature matched), `quiet` (a deadline with nothing actionable — the heartbeat). Authority names what the verdict rests on: `hook-row`, `screen-signature`, `runtime`, `observation`, `owner-handle`, or `none`. Classification consumes `observation.activity`, never `ready`. A surprising classification settles at the authority the wake names; a wrong screen verdict on an idle session is signature drift — preserve the screen and refresh the fixture rather than retry the read.

The watcher reconciles live sessions on a 15s interval (8s budget) as well as reading the journal, so a missed journal edge still brings a worker to attention; each wake carries `current_observations` and `current_delta`. Quiet windows run a 600s cadence; `--pending-stale <sec>` (default 300) covers requests no host has claimed. Direct-call exits: 0 match or advisory, 2 timeout, 3 owner gone, 4 reader failure. `--wake-shaped` (the arm wrapper's mode) collapses every terminal into exit 2 with the wake on stderr, because only exit 2 re-arms. With an owner handle the watch runs a stop-biased liveness check each poll: an owner provably dead gets a grace window, one final read, exit 3, no re-arm — a watcher's false "alive" is a runaway, and trees survive their watchers. The verb reads the journal and writes nothing to it.

## Peek

`lore session peek <handle> --summary --json` returns the current observation without terminal bulk; `--lines N` (with `--max-bytes`) pages retained history, `--before <cursor>` pages earlier within the same snapshot. `peek.ready` says a message can be accepted, including mid-turn; `peek.observation` carries activity, identity, capture time, authority, and matcher evidence (managed JSON nests these under `response`). `unknown` is an observation limit — read the screen or the saved artifact. An idle composer is not task completion. An omitted count is a coverage limit, not evidence the omitted sessions are settled.

## The evidence spine

`lore work show <slug> --json` returns `reader_contract_version: 2` with an `evidence` object: `revision` (head), `result_summary` (per task and criterion: latest state, stale flag and reason), `review_summary` (attempts, sealed or open, cited results), `packet_summary` (per attempt), and `sources` (coverage: `read | absent | unreadable | unsupported`). The retrospective's `cycle_work` reader and the TUI's evidence pages consume exactly this projection.

`lore plan revise <slug>` publishes a revision after a plan edit or checkbox; `--decision-for <revision-id>` appends a decision record (anchor coverage; dispatch: proceed, wait, or reuse a named review) without a new revision. `lore criteria run <slug> <task-id> <criterion-id> --execution-worktree <root> --packet-id <id>` executes a declared criterion and appends the result; a recovery by result id republishes without re-running. `lore plan review prepare <slug> --attempt <id> --revision <rid> --purpose <criterion-adequacy|integration>` freezes the reviewed input; `lore plan review seal` publishes output, dispositions, and the evaluator manifest in one rename.

## Arc close

`lore arc close` records the closure and reads the settings file's Stop entries to find arc-scoped watchers (§ Arm). The cost tally comes from the journal's `closed` events — sessions running at close and human-initiated streams escape recall. If a retro over the arc's window reported fixed health as degraded or not-computable, say so at close rather than let its scorecards read as more than trend. Walkthroughs and gate packets for the owner come from the ledger and artifacts re-read, not conversational memory.

## Calibrations

The evidence behind the skill's rules: date, incident, rule, status. A rule lives in SKILL.md clean; the row here is what produced it. Status: **in skill** (prose carries it), **mechanized** (a verb enforces it), **retired**. Rows leave when the rule generalizes into stance, a verb mechanizes it, or a season passes without need.

**2026-07-16, session-queues arc.** Amending plan.md after finalization invalidated tasks.json's checksum and stalled the next implement session → run `lore work regen-tasks` in the same act. *In skill.* — A refused steer is not health evidence; Codex footer badges made readiness key on the composer band, not a closed token list. Re-probed 0.144.3 (07-21) and 0.148.0 (09-03): codex steers mid-turn; the July `buffered-draft` reading was a probe artifact. *Mechanized* (gate reads the harness's probed `mid_generation_semantics`).

**2026-07-28, 2026-08-11.** Harness-native spawns omitting a model inherited the seat's tier and billed it → state the model on every spawn. *Mechanized* (`validate-dispatch-guidance.sh` fills the default).

**2026-08-11.** Owner: protocol text never quotes the human; rules are written in the skill's own voice. *In skill.*

**2026-08-13.** A rung-2 worker ran `lore impl start` on a spec-less item and parked recommending /spec → rung-1/2 briefs name the ceremony negatively too. *In skill.* — Watcher entries became identity-scoped with a project-local install default. *Mechanized.*

**2026-08-17.** A weekend of ten-minute quiet wakes against a two-input human gate → park the eye when the board is wholly human-gated. *In skill.*

**2026-08-20.** Two ceremony dispatches rode a prior arc's `--framework claude-code` unjustified → a framework override needs a live, ledgered reason per dispatch. *In skill.* — Archived items 06→08 averaged ~2.7 tasks, ~40% single-task, after merge-default rules → underfill is mis-sizing like over-ceremony. *In skill.*

**2026-08-26.** Delegated spec agents made well-justified but needless architecture decisions; partial views inflate a part → the seat holds conceptual integrity; rung-3 specs carry a coordinator strawman. *In skill.*

**2026-09-01.** The cost-model paragraph assumed a short cache window; the seat runs on a one-hour window → read the window from the harness. The subagent-observability paragraph asserted a fixed capability set → written as a probe. *In skill.* — Owner: the seat may take a stream over when a standing directive routes the class to the lead or a stream reads the picture narrower than the seat can see (precedent: the 08-29 simplicity fix wave). *In skill* (hard edge 2).

**2026-09-03.** Owner: small confident corrections — a mostly-right spec, another agent's faulty assumption — are the seat's to make directly → seat-scale correction tier. Second statement two days later: the seat should feel free to act when its judgment says so → hard edge 2 rewritten as a judgment with a test; the "never-write-source" rung sentence retired. *In skill.* — A claude-code lead with a background subagent refused every steer as `generating` for ~90 min while idle: the gate keyed on output quiescence and the agents panel repaints per second → anchor on the composer band. *Mechanized*; `needs_input` / `session wait` still key on the same timer. — Owner: the skill is the seat's own document; guidance that outlives understanding changes; the system must not keep an agent from creativity in a novel situation. 64 "never"s in 8,200 words; a third restating watch mechanics → pruned to 6,900. *In skill.*

**2026-09-04.** The owner found the coordination panel's stream rows unreadable cold: the TUI projects the Step cell verbatim and the skill wrote it for the seat → Step cell is a plain headline in the digest register; shorthand and backlink move to the rationale cell; each closure appends to a running `digest.md`. *In skill.* Evidence: [[work:coordination-panel-owner-plain-headlines-marquee-r]]. — Trace-evaluator arc: the first PR of a seven-PR stack was a fifth comment lines though every brief said "comments minimal"; the preference's *test* had not travelled and the conformance aggregate recorded it honored on the worker's own reading → a preference travels as the test it is checked by; the seat reads a few instances back at closure. *In skill.* Cost: one rebase-plus-hygiene stream over seven branches. — Coordinator agency dry run: a cold read found the skill granting direct authorship while the architecture guide prohibited it → reconciled; explained uncertainty and a reasoned no-change are explicit outcomes; routine reads need no row. *In skill.* Evidence: arc `coordinator-agency-dry-run`.

**2026-09-04/05, commons-reshape arc.** Tiers (what the work needs) separated from rungs (the ceremony). *In skill.* — A packet at every dispatch; investigation and design commissioned on three triggers, not scheduled (the store had held the answer to the one decision that went wrong, with no surface in front of the agent). *In skill.* — Seat captures pass `--producer-role coordinator --work-item`. *In skill.* — A `needs_input` wake for a just-finalized spec arrived as a fresh implement session sat in pre-submit startup; the seat read it as a park and closed it → compare event time to spawn time. *In reference* (§ Watch). — Before fast-forward publication, teardown never landed a commit; the guard published uncommitted changes onto the control checkout → publish = fast-forward when base == HEAD and both trees clean, else quarantine. *Mechanized.* — A one-file fix made by checking out a branch in the control checkout gave two workers a transient teardown target → the control checkout stays on `main`; seat edits use an allocated worktree. *In skill.* — Owner (09-05): the seat should hold small changes, and a whole arc when small enough, without dispatching. Twelve arc ledgers: r0=2, r1=48, r2=22, r3=17; rung 0 unreachable in an arc, rung 1 spelled "micro-dispatch"; a seat edit left its reason, a dispatch never "why not the seat"; one catch became "a second head verifies every time" → rung 0 reaches the seat; every route leaves the same row; a catch is a reason to look again, not a duty; arc takeover. *In skill.* Settling test — of the text — in [[work:ceremony-ladder-route-symmetry]]. — Owner (09-05): the skill had grown past what an honest reader needs — 2,500 words (07-06) → 8,441; the 09-03 prune regrew in two days — and tests pinning skill sentences made it hard to change → rewritten to ~4,000 words as stance, hard edges, vocabulary, with participation in the commons as a fourth purpose; mechanics moved here; phrase-pin tests on skill prose retired (the two INVARIANT vocabulary tests stay). *In skill.* Comparison: `rewrite-comparison.md` in the same item. — Owner (09-06): `/remember` is part of closing any arc, at every size; `lore capture` alone leaves the thread half unwritten. *In skill* (§ Close the arc).

**2026-09-08.** Sixteen weekend worker sessions ran on the seat's own model (fable) while every role was bound to opus: `session start` required `--model`, offered no resolver, and the codex worker default lived in skill prose that three compactions had removed → session requests resolve framework and model from the role route (`codex/<model>` selects the target); a half-override is refused; the TUI refuses an unresolved launch instead of falling through to the harness default; `lore defaults` renders the effective route per role. *Mechanized.* — Roles `judge` and `summarizer` retired (no live caller since July). Evidence: [[work:model-routing-cost-audit-seat-typed-fable-dispatch]], [[work:session-spawns-resolve-framework-model-role-route]].

## Shipped verb history

Wants that shipped, kept for provenance:

- `--track` / `--model` / `--yes` on `session request` (07-06); `step_completed` journaling with `--until` opt-in (07-16); `events --tail` / `--cursor-only` (07-07); `close --wait` dissolved into `wait --until closed` (07-07).
- `lore session wait` (07-07) after three hand-rolled watchers each hit a distinct footgun; blind spots closed 07-11 ([[work:session-wait-watcher-blind-spots]]); `modal_blocked` journaling ([[work:journal-modal-blocked-session-detection]]); persistent follow, `--next-session`, one-hour default (07-21, [[work:session-watch-persistent-follow-sane-timeout-next]]).
- Actionable default stop set, `lore coordinate watch`, allocate lifecycle hint (07-24, [[work:coordinator-seat-orientation-fixes-automatic-sleep]]) — a pending request whose instance died pre-claim sat 61 minutes with zero rows; that incident earned `--pending-stale`.
- `terminus_reached` + close retry-on-unblock (07-12, [[work:completed-sessions-park-open-close-retry-on-unbloc]]): a finished spec session parked open ~18 min against a modal; the retry ladder closed the same shape in 86s.
- `close_refused` — resolved by gate removal, not event addition: full-discretion close shipped and no refusal branch survived. The worked example of a want dissolving.
- Arm installation read-back (09-04, [[work:coordinate-arm-renders-without-installing-reads-as]]): `--install` or `--render` required; the installed command is read back.
