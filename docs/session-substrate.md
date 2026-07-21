# Session Substrate (`_sessions/`)

Contract for the `_sessions/` coordination substrate: the knowledge-store surface
that lets TUI instances, protocol verbs, and stop hooks coordinate multi-session
spec/implement work without a daemon. This doc is the **contract half** — what the
substrate IS (layout, row schemas, lifecycle, cursor, ownership). The
[Scope note](#scope-note--what-this-does-not-do-yet) at the end is the paired
**non-goals half** — what it deliberately does NOT do yet, and where that work
lands.

Rows here are written by bash and Go and read by bash, Go, and Python. Scalar
types are pinned precisely on purpose (see [Type discipline](#type-discipline)):
a strict Go decoder rejects a numeric field that arrives quoted.

## Layout

The substrate lives at `$KDIR/_sessions/`, a sibling of `_work/` and `_trust/`,
so it inherits repo-scoping for free and stays out of the per-slug work glob. It
has four surfaces, split by **write archetype**:

```
$KDIR/_sessions/
  instances/<name>.json          registry — one file per live TUI instance
                                 (mutable; tmp+atomic-rename writes, mtime heartbeat)
  requests/pending/<id>.json     queue — one file per waiting request
  requests/claimed/<id>.json     queue — a request a specific instance has claimed
                                 (claim = atomic rename pending/ -> claimed/)
  close-requests/<id>.json       queue — one file per close request, consumed
                                 (deleted) by the owning instance (no claim split)
  send-requests/<id>.json        queue — one file per send request, consumed
                                 (deleted) by the owning instance (no claim split)
  peek-requests/<id>.json        queue — one file per peek request, consumed
                                 (deleted) by the owning instance (no claim split)
  peek-responses/<id>.json       response — one file per answered peek, written by
                                 the owning instance, deleted-on-read by the requester
  events.jsonl                   journal — append-only history, one sanctioned writer
```

Two archetypes, no third: **mutable per-owner state** (registry files, request
files, close-request files, send/peek-request files, peek-response files) is
written tmp+atomic-rename so each file has exactly
one writer at any moment — no lock in Go or bash. **History** (`events.jsonl`)
uses the sole-writer append archetype. There is deliberately no single mutable
`registry.json` or `queue.json`; per-owner/per-request files dissolve the
read-modify-write case entirely.

Writers create the directories they own lazily on first write (as
`scorecard-append.sh` seeds `_scorecards/`). Nothing pre-creates the tree.

## Instance registry

One file per live TUI instance at `instances/<name>.json`.

| Field | Type | Notes |
|-------|------|-------|
| `name` | string | Instance identity; path-safe display id matching `^[a-z][a-z0-9-]{2,47}$`. Also the filename stem. |
| `pid` | integer | OS process id of the TUI. |
| `repo` | string | Repo the instance is bound to. |
| `started` | string | ISO 8601 UTC timestamp of instance start. |
| `initiator_default` | string | `"human"` in v1 — the default initiator stamped on sessions this instance starts. |
| `sessions` | array of objects | Live sessions nested under the instance: `[{slug, type, initiator, started}]`, each carrying the recovery fields below and its versioned `worktree` identity. |
| &nbsp;&nbsp;`sessions[].tmux` | string \| absent | tmux session name (`lore-<instance>-<slug>`) hosting the harness, when the session is tmux-hosted. Omit-when-empty; absent for direct-PTY sessions (tmux unavailable / `LORE_TUI_TMUX=off`). Its presence on a dead instance's row is what a restarting TUI's adoption scan keys on to reattach rather than orphan. |
| &nbsp;&nbsp;`sessions[].request_id` | string \| absent | Spawn-request identity, persisted prospectively so recovery can correlate a terminal row to the exact spawn. Omit-when-empty for human or legacy sessions; never reconstructed from slug, time, type, or journal ordering. |
| &nbsp;&nbsp;`sessions[].session_id` | string \| absent | Harness transcript-binding id (claude-code `--session-id`), persisted so an adopting instance can still extract token spend at teardown after the original TUI is gone. Omit-when-empty. |
| &nbsp;&nbsp;`sessions[].harness` | string \| absent | Launch framework the session was spawned under (the spend probe's `--harness`). Omit-when-empty. |
| &nbsp;&nbsp;`sessions[].auto_close` | boolean \| absent | The close-ladder auto-close override carried onto the live session (see [Close-request queue](#close-request-queue)), persisted so it survives adoption. Omit-when-empty: absent defers to `initiator`. |
| &nbsp;&nbsp;`sessions[].worktree` | object \| absent | Complete [session worktree identity](#session-worktree-identity-and-lifecycle), persisted without projection loss across launch, registry rewrites, teardown, and adoption. Absence marks a legacy row and is unsafe to spawn or adopt. |
| `build_sha` | string \| absent | Build vintage — the short git SHA embedded at build time (`-ldflags`). Absent for `go run`/dev builds and for any binary predating this field. Omit-when-empty. |
| `build_time` | string \| absent | Build vintage — the **orderable** quantity: the commit's committer-date (release build) or the binary's mtime (dev build), ISO 8601 UTC. Absent for a binary predating this field. Omit-when-empty. This, not `build_sha`, is what `min_vintage` filtering compares against (a SHA has no read-side ordering). |
| `project_dir` | string \| absent | The instance's project directory, physically resolved (`filepath.Abs` + `EvalSymlinks`) once at startup. Immutable for the process. Omit-when-empty for a binary predating this field. It is the match key a request's `prefer_project_dir` compares against byte-for-byte (both sides resolve physically, so `/tmp`→`/private/tmp` and worktree symlinks match). Not a claim filter — a visibility field only. |
| `framework` | string \| absent | The launch framework the TUI resolves for untargeted spawns (`tui_launch_framework` → `ResolveTUILaunchFramework`), refreshed on every full-row write plus an explicit rewrite when the setting is committed. Omit-when-empty for a binary predating this field or when resolution errors. Not a claim filter — framework selection stays the request's `framework` field; this only surfaces the value a coordinator's routing read needs. |

**Routing-visibility fields** (`project_dir`, `framework`) surface a coordinator's
one-list-read routing tuple (target, framework, model-compat, worktree). Both are
fully **additive**: a row written by a binary predating them carries neither, and
`lore session list` renders each absent field as `unknown` (the vintage-fallback
idiom). Neither is consulted by claim eligibility.

**Build vintage** stamps a live TUI's build identity onto its row at startup so a
live-but-outdated instance — registered, claiming, but executing stale semantics —
becomes a visible column rather than a silent behavioral skew. It is fully
**additive**: a row with neither field reads as *vintage-unknown* and is **never
rejected** by `min_vintage` filtering (see [Request queue](#request-queue)).
`lore session list` renders the vintage column (`build_sha`, falling back to
`build_time`, else `unknown`).

Per nested session object: `slug` (string), `type` (string enum
`spec|implement|chat|worker`), `initiator` (string enum `agent|human`), `started`
(string, ISO 8601 UTC), plus the omit-when-empty recovery-manifest fields `tmux`,
`session_id`, `harness`, `auto_close`, `worktree` (above), and `close_requests`
(an ordered array of distinct, non-empty close-request IDs already consumed
during this session lifecycle). The close-request set and worktree identity
survive a `close_failed` outcome and tmux adoption so a later successful close
can declare the exact attempts it recovers without losing workspace ownership.

**Write archetype.** The instance rewrites its own file via tmp + `os.Rename`
(torn-read-proof) whenever a session starts or ends. **Heartbeat** is an
`os.Chtimes` bump on the file per 5s poll tick — the body does not change, so a
hard kill leaves no cleanup debt. **Liveness** = file mtime within a 30s TTL;
readers glob `instances/*.json`, drop stale-by-mtime files, and deliver
full-snapshot replacement (never a merge). These constants (5s heartbeat, 30s
TTL) carry over from the retired `.lore-session` machinery.

The registry is the single answer to "is instance `<name>` alive right now" — the
queue's reclamation rules (below) reuse this liveness signal rather than growing a
second TTL mechanism.

**Crash/restart recovery (tmux adoption).** When tmux hosting is active, a
TUI-spawned harness runs inside a tmux session (`lore-<instance>-<slug>`) on a
dedicated server, so the harness outlives the TUI process. A **slugless** session
(a chat/work session carrying no work-item slug) hosts the same way under a
generated `lore-<instance>-chat-<short-id>` name recorded on its registry row —
no session class silently loses crash recovery while hosting is active; the two
fallbacks (no instance name, or a tmux creation failure) each announce the
direct-PTY spawn on stderr rather than degrading quietly. A dead instance's
registry row is not deleted (mtime-TTL hides it from live snapshots but nothing
unlinks it), which makes that row its own recovery manifest. At startup a
replacement TUI scans `instances/*.json` **including TTL-stale files**, and a row
is adoptable when it names this repo and its owner is dead (mtime beyond the TTL
**and** PID not alive). The scanner claims a corpse atomically by renaming its file
to a claim suffix — exactly one racing renamer wins, so two fresh TUIs cannot
double-adopt (the same rename-as-claim atomicity the request queue uses). For each
nested session with a live `tmux` session (`tmux has-session`), the adopter
re-attaches through the normal spawn path and journals `recovered`; a session whose
tmux is gone (or that had no `tmux` name) is journaled `orphaned` with
`reason=instance-death`, the dead predecessor in `target_instance`, its persisted
spawn request ID when available, and spend bounded by the existing transcript or
duration-only evidence. Before attaching, the adopter validates the complete
versioned worktree identity and proves that the pane cwd equals its canonical
path. Missing identity, a different Git common-dir or per-worktree git-dir, an
epoch mismatch, or a reused path is refused; recovery never substitutes the
replacement TUI's project directory. The durable registry write transferring
ownership lands before its `recovered` journal row (the substrate's
durable-before-journal ordering). The claimed corpse row is removed only after
surviving ownership has transferred or the session has reached a durable terminal
disposition. Recovery is tmux-gated — with tmux absent or `LORE_TUI_TMUX=off`,
sessions are TUI-lifetime-bound exactly as before and no adoption runs.

## Session worktree identity and lifecycle

Every hosted harness writes in a session-owned Git worktree, never in the source
checkout. The durable `Identity` is versioned and carries exactly:

- the worktree's canonical path, Git common-dir, per-worktree git-dir, and epoch;
- the captured generation: source canonical path, Git common-dir, git-dir, HEAD
  OID, index digest, and worktree digest;
- target ref and target OID; and
- lifecycle state.

The ordinary lifecycle is `captured → active → publishable → published |
quarantined`. `teardown-pending` is the ownership-retaining state used when close
cannot yet prove process death; it may proceed to `publishable` or `quarantined`
but is not cleanup-eligible itself. Identity is checked before spawn, adoption,
publish, and cleanup. Unknown or incomplete legacy identity and any path,
common-dir, git-dir, epoch, or generation mismatch fail closed.

Publishing compares the destination's full live generation with the captured
generation before applying the session result through Git. The typed outcomes
are exactly `published`, `restore_refused`, and `worktree_quarantined`. A refusal
or quarantine leaves every destination file byte-for-byte unchanged and keeps
the session result recoverable through its durable result ref and patch. A
quarantined identity is cleanup-eligible because the content is durable
elsewhere; quarantine does not promise indefinite retention of the physical
worktree directory.

`published` is the successful internal disposition and projects to the normal
exactly-once `closed` session terminal; there is no separate `published` journal
event. `restore_refused` and `worktree_quarantined` add their named worktree rows
because the operator needs the refusal reason and recovery artifact. Those rows
remain linked lifecycle outcomes, not additional close terminals.

This contract stops at safe worktree ownership and disposition. Scheduling
parallel writers, dependency edges, coordinator reconciliation order,
conformance aggregation, and bounded physical cleanup belong to
`parallel-tree-writers-temporary-worktrees`.

## Request queue

One file per request. A request begins in `requests/pending/<request_id>.json`
and, once an instance claims it, moves to `requests/claimed/<request_id>.json`.

`request_id` = `<timestamp>-<random suffix>`.

| Field | Type | Notes |
|-------|------|-------|
| `request_id` | string | Unique id; also the filename stem. |
| `type` | string | Enum `spec\|implement\|chat\|worker`. |
| `slug` | string \| null | Work-item slug the request targets, or null (e.g. a chat with no work item). **Required for `worker`**: a worker's slug is the derived `<work-item-slug>--w<n>` that is its session identity (see [Worker sessions](#worker-sessions)). |
| `target_instance` | string \| null | Instance name the request is addressed to, or null for "any instance". |
| `initiator` | string | Enum `agent\|human`. |
| `requested_by` | string | Who enqueued it (instance name, agent id, or human). |
| `requested_at` | string | ISO 8601 UTC timestamp of enqueue. |
| `attempts` | integer | Claim/spawn attempts so far; starts at `0`. |
| `extra_context` | object \| null | Free-form context object handed to prompt composition, or null. |
| `last_error` | string \| null | Reason of the most recent failed transition; null until one occurs. |
| `last_attempt_at` | string \| null | ISO 8601 UTC of the most recent attempt; null until one occurs. |
| `auto_close` | boolean \| absent | Override for the TUI exit-ladder auto-close gate (see [Close-request queue](#close-request-queue)). Omit-when-empty: absent defers to `initiator` (agent auto-closes, human holds open), `true` forces auto-close, `false` holds open. Carried onto the live session so the ladder can consult it at teardown. |
| `routing_overrides` | object \| absent | Per-dispatch `{<role>: <model>}` map. Omit-when-empty. The claiming instance exports each entry as `LORE_MODEL_<ROLE>` (role uppercased, `-`→`_`) into the spawned session's PTY, riding the resolver's top-of-precedence env layer — so a coordinator's per-dispatch routing wins over settings policy with no resolver change. Roles are validated against `adapters/roles.json` at enqueue time; settings.json stays untouched durable policy (user directive > coordinator override > settings). |
| `min_vintage` | string \| absent | Minimum build vintage (ISO 8601 UTC) the claiming instance's `build_time` must meet — the request never targets an instance built earlier. Omit-when-empty. Filtered read-side, mirroring `target_instance` (the only difference is a temporal `>=` vs a string `==`). The `session request --min-vintage` verb accepts a timestamp or a git commit-ish (resolved to its committer-date at enqueue) and stores the timestamp, so the read side never shells out to git. **Additive**: an instance of unknown vintage, or any unparseable timestamp, passes — a claim is refused only on positive evidence the instance is older. |
| `track` | string \| absent | Spec depth selector (`short`) carried to the session's short-track (`/spec short`). Omit-when-empty: only the non-default `short` is stored (`full` is the default and stays absent), so the field is present only when it changes behavior. Set at enqueue by `session request --track short`, which **refuses the flag on a non-spec request** (`ShortMode` has no effect on implement/chat prompts). Maps to `SessionDescriptor.ShortMode` at spawn. |
| `model` | string \| absent | Per-dispatch lead-model override — the session lead is the top-level agent, so a model chosen here is lead selection. Omit-when-empty. Composed into the spawn as the harness's universal `--model` flag (the same flag `model_routing.tiers` aliases feed). **Opaque**: validated only for non-emptiness at enqueue, never against a model list — the candidate set is coordinator policy, not schema, so a bad id surfaces as an honest harness launch error. Distinct from `routing_overrides`, which routes *sub-agent* roles via `LORE_MODEL_<ROLE>` env. |
| `framework` | string \| absent | Per-request launch framework override. Accepted values are `claude-code`, `opencode`, and `codex`. Omit-when-empty: absent defers to the claiming TUI's `tui_launch_framework` setting. Validated at enqueue against the framework registry and carried to spawn so the harness binary, `LORE_FRAMEWORK`, `SessionProcessStartedMsg.Harness`, and live registry `sessions[].harness` agree. |
| `skip_confirm` | boolean \| absent | Session autonomy override. Omit-when-empty: absent defers to the queue-spawn default (**autonomous** — a claimed request historically runs without confirmation gates), `true` (`--yes`/`--no-confirm`) forces autonomous, `false` (`--confirm`) forces **gated** so every confirmation gate becomes a coordinator send window. Maps to `SessionDescriptor.SkipConfirm` at spawn. |
| `prefer_project_dir` | string \| absent | **Soft** routing preference: a physically-resolved project directory (`session request --prefer-dir <path>` / `--prefer-cwd`, resolved and refused at enqueue when it does not exist). Omit-when-empty. Unlike the hard `target_instance`/`min_vintage` filters, this only *delays* other claimants — the `prefer_` name carries the softness. An instance whose `project_dir` equals it claims immediately; any other instance may claim only after `PreferMatchGrace` (15s, three poll ticks) measured from `requested_at`. **Additive**: absence, an unparseable `requested_at`, or a pre-feature instance (which advertises no `project_dir`) never blocks a claim — the preference only ever adds bounded latency, so a matching instance need not exist. A row reclaimed past its grace is claimable by any instance (the preference had its shot on first dispatch). |
| `worktree_identity` | object \| absent | Complete versioned [session worktree identity](#session-worktree-identity-and-lifecycle), carried unchanged from request to launch. Omit-when-empty only for legacy or TUI-created requests whose claimant allocates the identity before spawn; a hosted process never starts without a complete identity in `captured` state. |

Because `framework` is additive, old TUI decoders ignore it. When a
`--framework` request must not be claimed by a TUI build that predates this
field, enqueue it with `--min-vintage <feature-sha>` so the existing vintage gate
filters stale claimers. Prove framework identity at spawn time through the child
environment, `SessionProcessStartedMsg.Harness`, or the live registry row; codex
`closed` spend rows may remain duration-only and are not the routing proof.

A **claimed** file additionally carries:

| Field | Type | Notes |
|-------|------|-------|
| `claimed_by` | string | Instance name that won the claim rename. |
| `claimed_at` | string | ISO 8601 UTC of the claim. |

**Enqueue** = write a tmp file + rename into `requests/pending/<request_id>.json`
(atomic; readers never see a torn request row).

**Claim** = `os.Rename(pending/X, claimed/X)`. Rename on one filesystem is atomic,
so exactly one racing instance succeeds — this is the sole at-most-once guard, and
it lives entirely at the queue layer. The winner then rewrites the claimed file
(tmp+rename) adding `claimed_by` and `claimed_at`. **A claimed file is not a valid
active claim until both fields are present.**

**Targeting** is filtered read-side: an instance only attempts to claim rows whose
`target_instance` equals its own name or is null. **Vintage** is filtered the same
way, in the same pass: an instance skips a row whose `min_vintage` its own
`build_time` demonstrably fails (both present, parseable, and older). An instance
of unknown vintage never skips on this basis — the filter is additive, so it can
only ever *narrow* the claim set of a vintage-advertising instance, never enlarge
or block a legacy one. **Preference** is honored in the same read-side pass as a
timing window, not a filter: a row carrying `prefer_project_dir` is claimable by a
matching instance at once and by any other instance only once it has aged past
`PreferMatchGrace` from `requested_at`. It never removes a row from the claim set
permanently — an unmatched preference just defers the row 15s — so the atomic
rename stays the sole claim arbiter in both the in-window and past-window regimes.

### Request lifecycle (terminal states)

The queue directories are the source of truth for *liveness* (what is
pending/claimed right now); the journal is the source of truth for *history* (what
happened). Every transition emits its journal event **after** the durable state
for that transition succeeds — for `claimed`, that means after `claimed_by` and
`claimed_at` are written, not merely after the directory rename. A crash before
the journal append loses at most one history row; a crash before claim metadata is
written leaves an incomplete claimed row handled by the recovery rule below.

| Terminal state | Trigger | Effect | Journal event |
|----------------|---------|--------|---------------|
| **spawned** | spawn succeeds | claimer deletes the claimed file | `spawned` |
| **returned to pending** | spawn fails (PTY start error, readiness gate) | increment `attempts`, set `last_error`/`last_attempt_at`, rename claimed → pending | `spawn_failed` (with `reason`) |
| **abandoned** | a claim attempt observes `attempts >= 3` on a pending row | delete the row (journal row is the dead-letter record) | `request_abandoned` (with last `reason`) |
| **reclaimed** | claimed row whose `claimed_by` is stale/absent in the registry AND `claimed_at` older than 60s | rename claimed → pending, `attempts` unchanged (the claimer died; the request didn't fail) | `request_reclaimed` (`reason: "stale_instance"`) |
| **incomplete-claim reclaimed** | claimed row missing `claimed_by` or `claimed_at`, claimed-file mtime older than 60s | rename claimed → pending, preserve `attempts`, set `last_error: "incomplete_claim"` | `request_reclaimed` (`reason: "incomplete_claim"`) |
| **cancelled** | reserved for item 2's `close`/cancel verb | delete pending row | `request_cancelled` |

`request_reclaimed` fires only **after** the durable rename back to `pending/`
succeeds. `last_error` takes the values `"incomplete_claim"` and
`"stale_instance"` for the two reclaim paths; spawn failures set it to the
spawn-failure reason.

## Worker sessions

A **worker** session is an agent-dispatched implementation session: one is
enqueued per dispatched task by an `/implement` lead (through a session-worker
chaperone), runs a lead-composed brief to protocol terminus, and auto-closes.
This half documents the substrate contract for the type; the dispatch protocol
itself (chaperone, brief composition, per-task spend attribution) lives with
`/implement` and is out of scope here.

**Identity — a derived slug.** A worker's `slug` is a derived identifier
`<work-item-slug>--w<n>` (`n` = per-dispatch ordinal), carried in the request's
existing `slug` field and required at enqueue. It is deliberately *distinct* from
the work-item slug: TUI session state (panels, tmux names, the live-session set)
is keyed by bare slug, so a worker sharing the work-item slug would collide with
the lead's own implement session on the same instance. `slugify` collapses any
`--` run, so a real work-item slug can never contain `--` — the double-hyphen
`--w<n>` suffix is therefore an unambiguous worker marker. The work-item
association travels in every worker journal row's `links.work_item` (the sole
writer derives it from the derived slug) and in the brief.

**Spawn and prompt.** A worker request flows through the same claim → spawn path
as every other type (no new booleans). Its brief is composed lead-side and passed
as `--context`; the TUI's worker prompt branch emits that brief *verbatim* as the
initial prompt — no skill invocation. An empty brief yields an empty prompt (the
session idles), never a fall-through to `/spec`.

**Queue gates.** A worker request passes the `implement`→plan-doc gate freely (it
is not an `implement` request; the base work item's plan is guaranteed by the
dispatcher). The per-slug eviction guard keys on the *derived* slug, so a live
base work-item session never blocks its workers and two workers never collide.

**Lifecycle and spend.** Agent-initiated, so it auto-closes at protocol terminus
(the initiator gate) unless a request overrides `auto_close`. Its `closed` event
carries `spend` through the *same* type-agnostic teardown enrichment as any
session — token fields with a `basis` when a transcript binding exists, else
duration-only. Per-task spend attribution rides the execution-log `Spend: task=`
seam (a lead concern), **not** retro's session-spend line: retro sums `closed`
rows by exact work-item slug, and a worker's derived slug does not match that
join, so worker cost is not double-counted as the orchestration's own cost. This
exclusion is intentional — session-spend measures the orchestration's cost, worker
cost is per-task attribution.

**Report landing.** A worker session writes its completion report to
`_work/<work-item-slug>/worker-reports/<derived-slug>.md` as its final step before
terminus (the journal has no report-bearing event, and a report must be durable
*before* `closed` so the chaperone can read it after terminus). The derived slug
doubles as the report's identity: the file is a schema-v1 worker report whose
header carries `Report-schema: 1`, `Report-id: <derived-slug>`, `Work-item:`,
`Task:`, `Producer-role:`, `Dispatch-path: lore-session`, `Harness:`, `Status:`,
and `Template-version:` over the standard worker report sections, `**Artifacts:**`
manifest included (each entry: path, kind, sanctioned writer, durable identity).
The session is the report file's single writer and lands it atomically
(tmp + rename, the substrate's write archetype) exactly once per derived slug —
a re-dispatched attempt is a new `--w<n>` ordinal with its own file, never an
overwrite of prior evidence. Being a full harness session with knowledge-store
access, it appends its own Tier-2 rows via `evidence-append.sh` — no relay
block; every sidecar file keeps its sanctioned sole writer. The journal, screen
renderings, and harness transcripts are lifecycle and debugging channels: they
prove the session ran, not what it delivered. Acceptance reads the landed report
and the canonical artifacts its manifest indexes — persist before checking,
audit before accepting — never a transcript, screen capture, task description,
or message body.

## Close-request queue

One file per close request at `close-requests/<request_id>.json`. A close request
asks the one live instance running a slug to tear that session down. It is a
*separate* surface from the spawn queue on purpose: a spawn request may be claimed
by any matching instance (an at-most-once race resolved by rename), whereas exactly
one instance is ever eligible to act on a close request — the one whose registry
row hosts the slug. There is no claim race, so there is **no pending/claimed
split**: the owning instance consumes the row by **deleting** it after initiating
teardown.

`request_id` = `<timestamp>-<random suffix>` (also the filename stem).

| Field | Type | Notes |
|-------|------|-------|
| `request_id` | string | Unique id; also the filename stem. |
| `slug` | string \| null | Work-item slug whose session is to close, or null. |
| `target_instance` | string | Instance name that runs the slug and must act. |
| `reason` | string | Enum `protocol_terminus\|coordinator\|human` — who/what asked for the close. |
| `requested_by` | string | Who enqueued it (instance name, agent id, or human). |
| `requested_at` | string | ISO 8601 UTC timestamp of enqueue. |
| `session_id` | string \| absent | Harness session id (full or the leading prefix passed to `close --session`) naming the exact session to close. Stamped only by the `--session` form; omit-when-empty. The consumer matches it against each hosted session's id by exact-or-leading-prefix and keys teardown off that session's slug; a row without it (every other form, every legacy row) keys off `slug` unchanged. It is the only handle that disambiguates two slugless sessions, whose `slug` is both null. |

**Enqueue** = write a tmp file + rename into `close-requests/<request_id>.json`
(atomic; readers never see a torn row) — the same primitive as the spawn queue.
The `close` verb resolves `target_instance` two ways: `lore session close <slug>`
looks up the owning live instance in the registry (error if no live instance runs
that slug); `lore session close --self` reads `LORE_SESSION_*` env and
self-addresses. Both are argument-resolution fronts over one physical enqueue
path. Enqueue emits a `close_requested` journal event; the owning instance's later
`closed` emission records completion.

**Consume** = the owning instance deletes the file after it begins teardown.
Because there is only ever one eligible actor, delete-on-consume keeps the
sole-writer-per-file invariant trivially true.

**Close authority: explicit is full-discretion, protocol-terminus is gated.**
Consuming a close-request always deletes the row (the durable ack; `close_requested`
already recorded intent); what the TUI does next branches on the request's `reason`.
An **explicit close** — `reason` `human` (the `session close` CLI default) or
`coordinator` — **always acts**, regardless of initiator or session state: an idle
session runs the exit ladder directly, while a still-**generating** session gets a
two-second natural-quiescence courtesy window before the interrupt-escalation rung
(below), and either way `closed` is journaled with spend. There is no authority gate
on this path — an operator's or coordinator's explicit close is never a silent
no-op. A **protocol-terminus** close
— `reason: protocol_terminus`, enqueued by a protocol's own finalize step
(`spec-finalize` / `impl-close` via `session close --self --reason protocol_terminus`)
— keeps the **initiator/`auto_close` gate**: an agent-initiated session auto-closes
(ladder after natural quiescence, `closed` journaled), while a human-initiated
session (or one carrying `auto_close: false`) is **held open** with a "done" panel
badge so the human can read output, send follow-ups, or run an in-session
closing-act retro (teardown stays available through `Ctrl+\` or a later explicit
close). The `auto_close` field overrides that terminus gate in either direction
(`false` holds an agent session open; `true` opts a human session into terminus
auto-close). The gate reads the session's `initiator` and `auto_close` (already on
the registry/journal) — it adds no new substrate state, and the close-request row
itself is unchanged.

**Reason-discriminated generation waits and interrupt escalation.** A generating
`protocol_terminus` close is cooperative because it was requested from inside the
turn whose completion it records. It waits up to two minutes for natural quiescence
and never writes ESC or enters SIGTERM/KILL while that turn is generating. Natural
quiescence proceeds into the ordinary exit ladder. If the bound expires first, the
consumed request resolves as `close_failed` with `reason: still-generating`; only
its pending-close state is cleared, and the live session, panel, and registry entry
remain intact. A coordinator or operator can then reissue an explicit close as the
sanctioned escalation path.

An explicit human/coordinator close retains teardown authority. It waits two
seconds for the turn to finish naturally, then injects ESC into the session PTY —
which for a tmux-hosted session travels through the attach client into the pane —
and preserves the existing bounded post-interrupt wait followed by the exit ladder
(graceful → SIGTERM → KILL). A human-initiated session held open at protocol
terminus is not being torn down and is never interrupted by that terminus request.

Teardown of a quiescent auto-close session is additionally held while the
session sits at an **interactive prompt** (a harness permission/approval modal,
classified by the same screen matcher the injection readiness gate uses): a
close-request that lands mid-prompt waits for the prompt to clear rather than
tearing the session down on an unanswered question.

**Terminal outcome — every consumed close ends in exactly one row.** Consuming a
close request deletes the row, so the journal is the only remaining record of what
became of the intent. Every consumed close therefore resolves to exactly one of
two terminal events: `closed` when teardown completes, or `close_failed` when it
does not. `close_failed` carries a `reason` from a documented set:
`interactive-prompt` (a held prompt never cleared, so an auto-close session could
not be torn down), `still-generating` (a cooperative protocol-terminus wait expired;
the session remains alive for a later explicit close), `rung-exhausted` (the exit
ladder ran graceful → SIGTERM → KILL without the session ending), or `error` (any
other teardown fault). Because the row is already gone, `close_failed` is the only
signal that a consumed close did not land — it keeps the outcome from becoming a
silent no-op. A watcher keyed on
`closed` alone sleeps through this second terminal, so a close-outcome watcher must
wait on `closed` **or** `close_failed`. Like `closed`, the `close_requested →
close_failed` pair is matched by per-slug ordering, never adjacency — running-session
transitions may fall between the request and its terminal.

Process teardown and worktree disposition are linked but distinct lifecycles. A
`close_failed` row leaves the identity in `teardown-pending` and retains ownership
while the harness may still write. Once process death is proven, the owner records
the worktree's `published`, `restore_refused`, or `worktree_quarantined` outcome
before releasing the registry row. `restore_refused` also retains ownership;
`published` and `worktree_quarantined` are cleanup-eligible dispositions. The
successful `published` disposition projects through `closed`; only refusal and
quarantine add a distinct worktree journal row.

When startup recovery confirms an instance dead, the same atomic corpse owner
retires every pending close request whose exact `target_instance` names that
predecessor. It first appends (or proves an idempotent replay of) a deterministic
`close_failed` row with `reason=target-instance-dead`, then deletes the request.
Those rows are explicit terminal dispositions and are not projected as unmatched
teardown failures. Requests targeting any other instance remain untouched.

A coordinator can retire the legacy case where the target is confirmed dead but
no registry corpse remains with
`lore session close --retire-close-request <request_id>`. This is an assertion,
not a death detector: the verb does not infer or auto-confirm death. It refuses a
target that still has a live registry row, then otherwise mirrors the mechanical
pass exactly — the same deterministic event identity, exact request and target
fields, `reason=target-instance-dead`, and sole-writer append before queue-file
deletion. `--requested-by` (or its normal caller default) records the asserting
actor as `actor_instance`.

The close owner also records every consumed request ID in the live session's
ordered `close_requests` recovery manifest before it acts. A failure that leaves
the session alive retains that set; adoption carries it forward. The eventual
`closed` row encodes the complete set in `links.close_requests`, independently of
the top-level `closed.request_id` (which remains the spawn request for natural
teardown and the latest consumed close request for ladder-driven teardown).

These close-policy changes take effect in live operator sessions only after the
operator rebuilds the TUI; updating the source and contract does not replace an
already-running binary.

There is one bound. A TUI that consumes a close request and then crashes before
emitting either terminal row leaves a `close_requested` with no terminal — no
durable pending-close state exists to replay it, and none is added here. A reader
treats a `close_requested` with no matching terminal as **unknown, bounded by
instance liveness**: once the owning instance leaves the registry, the outcome will
never arrive and the reader stops waiting on it.

The cancel form `lore session close --request <id>` is unrelated to this queue: it
deletes a still-**pending spawn** row in `requests/pending/` and emits
`request_cancelled` (the terminal state the request lifecycle reserves for it).

## Send-request queue

One file per send request at `send-requests/<request_id>.json`. A send request
asks the one live instance running a slug to inject a message into that session's
composer. Same eligibility posture as close-requests — exactly one instance hosts
the slug, so there is **no pending/claimed split** and the owning instance
consumes the row by **deleting** it after running the gate.

| Field | Type | Notes |
|-------|------|-------|
| `request_id` | string | Unique id; also the filename stem. |
| `slug` | string | Work-item slug whose session receives the message. |
| `target_instance` | string | Instance name that runs the slug and must act. |
| `body` | string | The message to inject. |
| `requested_by` | string | Who enqueued it (instance name, agent id, or human). |
| `requested_at` | string | ISO 8601 UTC timestamp of enqueue. |

**Enqueue** = tmp-write + rename, resolving `target_instance` via the registry
walk (`lore session send <slug> <message>`). Enqueue emits `send_requested`.

**The readiness gate is strict.** The owning instance injects only when the
session is quiescent AND its harness `composer_signature` matches the rendered
screen AND the `permission_prompt_signature` does NOT — the screen check is
load-bearing because quiescent/needs_input fire on a single timer edge and cannot,
alone, distinguish a composer-idle session from one paused on a permission modal
(injected text could *answer* the modal). Any other state is a refusal
(`send_refused` with a reason: `generating`, `modal`, `no-signature`,
`no-contract`, `unsafe-payload`, or `error`) and **no bytes reach the PTY**. A
send to a harness with no probed `interaction` contract refuses with `no-contract`
rather than guessing a signature.

**Transport** is always a bracketed paste (`ESC[200~ … ESC[201~`, honoring the
live DECSET 2004 state) followed by the harness's `submit_sequence` — never a raw
write, so the harnesses' divergent CR/LF submit semantics are neutralized, and a
multiline body rides through as **one** composer entry (all three harnesses were
probed to hold a bracketed multiline paste without auto-submitting). The
unsafe-payload refusal is narrow, not a blanket newline ban: a body containing the
bracketed-paste terminator `ESC[201~` is refused in both modes (the encoder would
strip its ESC to a space, silently mangling the coordinator's literal bytes — the
send refuses loudly instead), and a body containing a line break is refused **only
when bracketed-paste mode is off**, where each newline becomes a CR (= submit) and
would fire N partial turns.

**Consume** = delete the request file, then append the outcome (`sent` /
`send_refused`) — the delete lands first so the journal row never precedes the
consume it records. A gate refusal appends its outcome immediately (nothing was
injected). A gate-passing injection deletes the row at once but **defers** its
outcome: the row still lands before any journal row, only later.

**`sent` means observed-submitted, not just injected.** A bracketed paste can land
in the composer without the trailing submit taking (a large paste that collapses
to a "pasted text" chip is the observed failure), which would make an immediate
`sent` a lie. So after a gate-passing injection the instance holds the outcome and
re-observes the composer on later poll ticks. When the observation confirms the
submit took — the session is generating, or the composer returned to its empty
ready signature — it journals `sent`. When the composer is still holding the unsent
payload, it replays the harness `submit_sequence` **once** (a bare submit, no
re-paste, mirroring the manual recovery), then re-observes. If the payload is still
unsubmitted at a bounded deadline, it journals `send_refused` with the post-inject
reason `unsubmitted` — a truthful refusal, since no message was delivered. Every
gate-passing send ends in exactly one terminal (`sent` or `send_refused`).

`lore session send --wait` polls the journal for its request id's `sent` /
`send_refused` and maps the outcome to an exit code (0 sent, 3 refused — including
`unsubmitted`, 1 error or timeout). The exit-code mapping is unchanged by the
deferred outcome; only its timing shifts. Because verification adds one to two poll
ticks (~5–10s) before the outcome row, pass a longer `--timeout` (e.g. `--timeout
30`) for headroom over the default 15s when a swallow-and-retry is possible.
Without `--wait` it enqueues and exits 0 with the request id.

## Answer-request queue

One file per answer request at `answer-requests/<request_id>.json`. The public
surface is `lore session answer <slug> --option <N> --expect <literal>`: `N` is
the displayed positive option number, and the expectation is mandatory text from
the modal the coordinator intends to answer. The request row carries
`{request_id, slug, target_instance, option, expect, requested_by, requested_at}`;
`option` is a JSON number. Enqueue is tmp-write + rename and emits
`answer_requested` through the event writer.

The owning TUI takes one screen snapshot and routes it through the same shared
classifier used by send, peek, close, and modal observation. It refuses before
writing when the screen is not interactive (`not-modal`), the expectation is no
longer visible (`expect-mismatch`), the selected or requested numbered row is not
proven (`option-unavailable`), the harness has no interaction contract
(`no-contract`), or screen/PTY access fails (`error`). Numbered options are kept
in rendered row order, so navigation is the target row index minus the selected
row index, not arithmetic on displayed numbers. The only PTY payload is one
canonical sequence containing the required `Up` (`ESC[A`) or `Down` (`ESC[B`)
keys followed by Enter (`CR`). There is no raw-key surface or automatic choice
policy.

A gate-passing request is deleted immediately and retained only as an in-memory
verification record. A later snapshot that no longer contains the expectation
emits `answered`; a vanished panel or bounded confirmation timeout emits
`answer_refused` with `reason=unconfirmed`. The keys are never replayed. Thus a
successful write syscall alone is not an `answered` outcome, and every request
that reaches a terminal has exactly one of `answered` or `answer_refused`.
`lore session answer --wait` matches that terminal by request id (exit 0 for
answered, 3 for refused, and 1 for usage/error/timeout).

## Peek request / response

`lore session peek <slug>` is the substrate's first **addressed-response**
operation: a request file in, a response file out. The request at
`peek-requests/<request_id>.json` carries `{request_id, slug, target_instance,
raw, requested_by, requested_at}`. The owning instance snapshots the session's
screen on its poll tick and writes `peek-responses/<request_id>.json`
(tmp + atomic rename) carrying `{request_id, slug, captured_at, ready,
blocked_reason, rows[]}` — the plain-text screen rows from the same snapshot the
send gate uses, plus that gate's readiness classification; `--raw` adds the ANSI
render under `ansi`. The requesting CLI polls for the response up to `--timeout`
(default 15s ≈ 3 poll ticks), prints it, and **deletes it** (the requester is the
sole consumer). The owning instance garbage-collects orphaned responses older than
5 minutes on its scan. **Peek emits no journal events** — it is a read, not a
lifecycle transition, so it stays out of the journal's lifecycle vocabulary.

## Event journal

`events.jsonl` — append-only history. Every emitter (the TUI via subprocess,
protocol terminal verbs, stop hooks) appends through the one sanctioned writer,
`scripts/session-event-append.sh`. There is no other writer; see
[Ownership](#ownership-matrix).

### Event row

| Field | Type | Notes |
|-------|------|-------|
| `event_id` | string | Unique id. Writer-generated (`<timestamp>-<random>`) when absent; callers that need idempotency pass a deterministic id and guard on it (see [Dedupe posture](#dedupe-posture)). |
| `ts` | string | ISO 8601 UTC. Writer-stamped when absent. |
| `event` | string | Required. One of the [event vocabulary](#event-vocabulary). |
| `actor_instance` | string \| null | Instance that performed the transition; null when no instance did (e.g. an enqueue not created by a TUI). |
| `target_instance` | string \| null | Instance the underlying request is addressed to; null for "any". |
| `slug` | string | Work-item slug, when the event has one. |
| `session_type` | string | `spec\|implement\|chat\|worker` — the session's type (the request's `type` maps to this). |
| `initiator` | string | `agent\|human`. |
| `request_id` | string | The request this event concerns; required for queue-lifecycle events. |
| `option` | integer | Positive displayed modal option number; required on `answer_requested`, `answered`, and `answer_refused`. |
| `reason` | string | Failure/reclaim reason; also the review-gate rationale carried by `review_flagged`/`review_held`/`review_released`. Also carried by `spawn_failed`, `request_reclaimed`, `request_abandoned`; `modal_blocked` requires exactly `modal`; `answer_refused` uses its closed refusal set; `terminus_reached` requires `spec-finalize` or `impl-close`. |
| `step_id` | string | Stable machine-readable milestone identity. Required on `step_completed`; `/spec` uses `spec:investigation`, `spec:design`, and `spec:plan-ready`, while `/implement` uses `implement:task:<task-id>`. |
| `step_label` | string | Concise human-readable milestone label. Required on `step_completed`. |
| `gate_id` | string | Review-gate audit join key. Omit-when-empty. A gate-open verb (`review_flagged`/`review_held`) sets it as the row's `event_id`; the `review_released` row echoes it here so a reader pairs release→open without replaying state. See [docs/review-gates.md](review-gates.md). |
| `links` | object | `{work_item?, artifact?, close_requests?}` — string-valued pointers and correlations. Review events point `artifact` at the review packet. On `closed` only, `close_requests` is a string containing a compact JSON array of distinct, non-empty consumed close-request IDs in first-consumed order (for example `"[\"term-1\",\"explicit-2\"]"`); the string representation preserves existing `map[string]string` Go readers while safely carrying opaque IDs. Writer defaults to `{}`. For a worker session (derived slug `<work-item-slug>--w<n>`) the writer derives `links.work_item` = the base work-item slug when the caller did not set it, so every worker lifecycle row points back at its work item (see [Worker sessions](#worker-sessions)). |
| `spend` | object \| null | Session token spend, on `closed` and `orphaned`. `duration_seconds` is always present; a `basis` enum (`transcript\|rollout\|store\|duration-only`) marks how the tokens were sourced. When the harness exposes a deterministic transcript binding (claude-code, via a spawn-time `--session-id`), the TUI merges the D1 token vocabulary — `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `reasoning_output_tokens`, `total_tokens`, `cost_usd`, `model`, `harness` (fields the harness does not expose are omitted, never zero-filled). Every gap — codex/opencode-hosted sessions, an absent transcript, a probe timeout, an abrupt quit — degrades to `{duration_seconds, basis:"duration-only"}`. Extraction runs at teardown or recovery via `scripts/session-spend.sh`; the row still flows only through the sole writer. |

Optional fields follow **omit-when-empty** discipline: an absent optional field is
simply not written (its presence is the signal), except `links`, which the writer
always materializes as an object so Go can decode a nested struct.

### Event vocabulary

The closed set. A row whose `event` is outside this set is rejected by the writer.

| Event | Emitter | Meaning |
|-------|---------|---------|
| `requested` | enqueue writer (item 2 verb / TUI human path) | a request was enqueued; `target_instance` copied from the request, `actor_instance` null unless a TUI created it |
| `claimed` | TUI | an instance won the claim rename and wrote claim metadata |
| `spawned` | TUI | the session process started; claimed file deleted |
| `needs_input` | TUI | a running session is waiting on input |
| `quiescent` | TUI | a running session went idle |
| `resumed` | TUI | a session resumed after idle/input |
| `modal_blocked` | TUI | the shared readiness classifier observed a running session enter a harness modal; carries `reason=modal`, emits once per observed entry, and carries no `request_id` |
| `recovered` | TUI | a restarted/replacement instance adopted a still-running tmux-hosted session from a dead instance's registry row; `reason` names the predecessor (`adopted from <dead-instance>`). Session-transition class — no `request_id` |
| `closed` | TUI | a session ended (carries `spend`: token counts where the harness exposes them, else duration-only) |
| `orphaned` | TUI | a dead instance's atomic recovery owner found no surviving tmux session; carries `reason=instance-death`, the dead `target_instance`, persisted spawn `request_id` when available, and evidence-bounded `spend` |
| `step_completed` | hosted `/spec` and `/implement` leads | a durable intra-protocol milestone completed: `/spec` investigation, reviewed design, or plan-ready state; or an `/implement` task accepted, logged, and checked off |
| `terminus_reached` | `spec-finalize` / `impl-close` | the hosted protocol completed its durable terminal writes; carries actor, slug, session type, and terminal verb in `reason`, but no queue `request_id` |
| `harness_turn_ended` | stop hooks | a harness turn boundary was reached |
| `spawn_failed` | TUI | spawn failed; request returned to pending (carries `reason`) |
| `request_reclaimed` | TUI (any instance) | a stale/incomplete claim was returned to pending (carries `reason`) |
| `request_abandoned` | TUI | `attempts >= 3`; request dropped, journal row is the dead-letter (carries last `reason`) |
| `request_cancelled` | `session close --request` cancel verb | a pending spawn request was cancelled |
| `close_requested` | `session close` enqueue verb (`<slug>` / `--self`) | a close request was enqueued for the instance running a slug |
| `close_failed` | TUI | a consumed close request did not complete teardown; `reason` names why (`interactive-prompt`/`still-generating`/`rung-exhausted`/`error`), or `target-instance-dead` records exact dead-target retirement |
| `restore_refused` | TUI | a worktree identity, ownership, or publish precondition could not be proven; carries a reason and links to the expected identity/generation, plus observed values when available. It is a worktree outcome, not a close terminal |
| `worktree_quarantined` | TUI | a session result was preserved under a durable ref/patch after safe publication was refused; carries the result artifact and expected/observed generation links. It is a worktree outcome, not a close terminal |
| `send_requested` | `session send` enqueue verb | a send request was enqueued for the instance running a slug |
| `sent` | TUI | the message was injected AND a later observation confirmed the composer submitted it (verified-outcome; see [Send-request queue](#send-request-queue)) |
| `send_refused` | TUI | injection was refused, or an injected message never submitted; `reason` names why — gate refusals (`generating`/`modal`/`no-signature`/`no-contract`/`unsafe-payload`/`error`) or the post-inject `unsubmitted` |
| `answer_requested` | `session answer` enqueue verb | an expectation-guarded numbered modal choice was enqueued; carries numeric `option` |
| `answered` | TUI | one restricted navigation+Enter write was followed by a later screen where the expectation disappeared |
| `answer_refused` | TUI | the choice failed closed; `reason` is `not-modal`, `expect-mismatch`, `option-unavailable`, `no-contract`, `error`, or `unconfirmed` |
| `review_flagged` | `lore work flag` verb | a lightweight (async) review gate was opened on a work item; `event_id` is the gate_id |
| `review_held` | `lore work hold` verb | a blocking review gate was opened on a work item; `event_id` is the gate_id |
| `review_notified` | coordinator (direct append) | a stateless review notification for a work item; no gate, no verb |
| `review_released` | `lore work release` verb | a review gate was cleared; `gate_id` echoes the gate-open `event_id` (the audit join key) |

**Queue-lifecycle events** — `requested`, `claimed`, `spawned`, `spawn_failed`,
`request_reclaimed`, `request_abandoned`, `request_cancelled`, `close_requested`,
`close_failed`, `send_requested`, `sent`, `send_refused`, `answer_requested`,
`answered`, `answer_refused` — each concern a specific
request and MUST carry a non-empty `request_id`. The writer enforces this. (`sent`
and `send_refused` carry it so `session send --wait` can match its outcome by id;
the three answer events also require a non-empty slug and positive integer
`option`, and let `session answer --wait` match its verified outcome by id;
`close_failed` carries it so a close-outcome watcher can match the failure back to
its `close_requested`.)

**Protocol-transition events** — `step_completed` marks durable progress within a
hosted protocol. `/spec` emits `spec:investigation` after investigation findings,
evidence, and logs persist; `spec:design` after design-ceremony dispositions and
accepted revisions persist; and `spec:plan-ready` after the post-plan ceremony and
preflight succeed. `/implement` emits `implement:task:<task-id>` only after the
lead accepts and logs the task report and its completed checkbox persists. These
are the only step producers: researcher or worker completions, individual evidence
claims, consultations, phase-close echoes, and bare-terminal sessions do not emit.

Every `step_completed` row requires non-empty `actor_instance`, `slug`,
`session_type`, `step_id`, and `step_label`, and MUST NOT carry a top-level
`request_id`. `scripts/session-step.sh` derives its deterministic event id from
the event name, hosted identity, persisted spawn request identity, and stable
`step_id`. Exact replay is idempotent; changing the label for the same hosted step
is conflicting evidence and is refused.

`terminus_reached` remains the separate whole-protocol completion event. It is
emitted after the terminal verb's final refusal/fatal gate and before its
best-effort close enqueue. It requires non-empty `actor_instance`, `slug`, and
`session_type`, carries `reason=spec-finalize|impl-close`, and MUST NOT carry a
top-level `request_id`. Its deterministic event id incorporates the live
registry's persisted spawn request identity, so exact replay is idempotent without
conflating completion with a queue lifecycle.

**Work-item review events** — `review_flagged`, `review_held`, `review_notified`,
`review_released` — form a third event class keyed to a work item rather than a
queue request, so each MUST carry a non-empty `slug` (a distinct writer branch:
`slug` is optional for every other event). The gate mechanism, verbs, packet
contract, and audit semantics are the [review-gates contract](review-gates.md);
this vocabulary is the journal half. Notify is a direct append (the coordinator
owns it, no verb); flag/hold/release are emitted by their `lore work` verbs.

**Emitter ownership** (per the settled design): the TUI owns session transitions
and TUI-driven queue lifecycle; the enqueue writer owns `requested`; the
`session close` verb owns `close_requested` (its enqueue forms) and
`request_cancelled` (its cancel form), while the TUI owns the `closed` /
`close_failed` close outcomes it decides at consume; the `session send` verb owns
`send_requested` (its enqueue), while the TUI owns the `sent` / `send_refused`
outcomes it decides at consume; the `session answer` verb owns `answer_requested`,
while the TUI owns `answered` / `answer_refused`; hosted `/spec` and `/implement` leads own
`step_completed`, while their terminal verbs own `terminus_reached`;
stop hooks own `harness_turn_ended`. Peek has no events — it is a read.

### Prospective emission (emitter obligation)

Events are written **prospectively, at the transition** — the emitter appends the
row when the state change happens, not by mining a transcript afterward. This is an
obligation on every emitter, not a convenience: the journal is designed to outlive
session transcripts, so anything not written at the transition is lost. Do not
design any consumer around retrospective transcript reconstruction.

Close-recovery correlation is prospective and forward-only. A missing
`links.close_requests` declaration means no recovery relationship was declared;
readers never infer one from slug, session type, adjacency, ordering, or the
top-level `request_id`. The complete frozen pre-extension population —
`1889880106a9a922`, `648b75f906159750`, `1a91175bc35f694b`, and
`1d77a8b177268b18` — therefore remains visible by design rather than being
mutated, duplicated, or specially suppressed.

An `orphaned` `spec` or `implement` row also produces exactly one deterministic
retro outcome with `event_type=session-orphaned`, `stratum=instance_death`,
`outcome=due`, and `disposition=unhandled`. Recovery records the obligation only;
later `dispatched|deferred|skipped` handling remains coordinator-owned.

### Writer contract

`session-event-append.sh` is the **sole physical writer** of `events.jsonl`. It:

1. Reads one JSON object (via `--row` or stdin).
2. Validates: object shape; `event` present and in the vocabulary; `request_id`
   non-empty for queue-lifecycle events; `links` (if present) is an object; and
   `links.close_requests`, when present, occurs only on `closed` and is a string
   decoding to a non-empty array of distinct, non-empty strings. The writer never
   derives or defaults that member. Any failure exits non-zero with a diagnostic
   **naming the offending field**, and no row is appended.
3. Treats a caller-supplied `event_id` as a retry identity: exact replay succeeds
   without another append, while different evidence under the same ID is refused.
   Otherwise it generates `event_id` and `ts` when omitted and defaults `links`
   to `{}`.
4. Compacts to one line with `jq -c` and appends with bare `>>` (O_APPEND).

Validation lives at the writer because the writer is the last line of defense: any
path that reaches `events.jsonl` without it corrupts every downstream reader
irreversibly. If a distinct sanctioned operation over this file is needed later, it
is a **sibling script** that shells out to this appender — never a second physical
writer.

### Reader contract

Readers **never re-validate** and never dedupe. A reader that encounters a
malformed or torn row **excludes it with a warning** to stderr (e.g.
`[session] warning: events.jsonl:<N> corrupt — <reason>`) and continues — it does
not abort and does not silently count the row. Validation cost is paid once, at
write time; reader hot paths stay clean.

### Cursor contract

`events --since <cursor>` (item 2) consumes a cursor that is the **byte offset of
the next unread byte**, documented as an **opaque token**: consumers store and echo
it, never compute with it. Offsets are valid only against the current
`events.jsonl` — the journal is append-only with **no compaction, truncation, or
rotation in v1**. Byte offset is the only cursor that is monotonic, O(1)-seekable,
and computable without cross-process coordination on an O_APPEND file; a sequence
number would force the writer to read-modify state, breaking the lock-free
archetype.

Reader tolerance: a malformed or torn trailing row stops the read at the last
newline-terminated valid row, and the reported cursor points there. A malformed
*interior* row is excluded with a stderr warning and the read continues past it. A
cursor that exceeds the file size (impossible without external tampering) resets to
a full re-read with a warning.

`session events` reports that cursor as `next_cursor`. Under `--json` it wraps
`{events: [...], next_cursor: N}`. Plain output is one JSON value per line on
stdout: the event rows, then a final `{"next_cursor": N}` row. The cursor is data,
so it rides stdout with the rows it belongs to — a consumer reads the whole stream
and never has to fold stderr back in to stay caught up; it tells the rows apart by
shape (`has("event")` vs `has("next_cursor")`). Two shortcuts serve the same
stream: `--cursor-only` prints just the current end-of-journal offset (an O(1)
stat, no rows replayed) for capturing a baseline before acting, and `--tail <N>`
emits only the last N rows plus the cursor row.

### Dedupe posture

The appender **does not dedupe** — it appends every validated row unconditionally.
Idempotency is the emitter's responsibility: an emit site that must be at-most-once
constructs a **deterministic `event_id`** and guards on it (checking its own state
or the journal) before calling the writer. Most session transitions are naturally
once-only and need no guard; the writer-generated `event_id` is fine for them.

Review events inherit this posture keyed to what a duplicate *means*: the
flag/hold/release verbs refuse a second gate on an already-gated item and refuse a
release with no active gate, so `review_flagged`/`review_held`/`review_released`
are naturally once-only per gate (the verb's state guard, not the writer, enforces
it). `review_notified` is fire-per-occurrence — a stateless notification with no
gate — so re-emitting it is a new observation, never a duplicate.

## Ownership matrix

Exactly one writer owns each surface. Everything else shells out to that writer or
reads full snapshots.

| Surface | Sole writer | Written by | Landed in |
|---------|-------------|-----------|-----------|
| `instances/<name>.json` | the owning TUI instance (its own file) | tmp + `os.Rename`, `os.Chtimes` heartbeat | Phase 2 (TUI) |
| `requests/pending/<id>.json` | the enqueuer | item 2 `request` verb; TUI human path | item 2 / Phase 2 |
| `requests/claimed/<id>.json` | the claiming TUI instance | `os.Rename` claim + tmp+rename metadata | Phase 2 (TUI) |
| `close-requests/<id>.json` | the enqueuer (`session close` verb); deleted-on-consume by the owning TUI instance | tmp + rename enqueue; owning instance deletes | item 2 (enqueue) / Phase 2 (consume) |
| `answer-requests/<id>.json` | the enqueuer (`session answer` verb); deleted-on-consume by the owning TUI instance | tmp + rename enqueue; owning instance deletes after the shared classifier gate | answer verb |
| `events.jsonl` | `scripts/session-event-append.sh` | every emitter, via subprocess | Phase 1 |
| `[session-request]` cold-start marker | `scripts/load-work.sh` (reader of `requests/pending/`) | SessionStart hook | Phase 1 |

Phase 1 landed the `events.jsonl` writer and the load-work marker; the registry and
request writers, defined by this contract, landed in Phase 2 and item 2.

## Cold-start surface

Nothing reads `_sessions/` at SessionStart by default, so a request enqueued while
no TUI is alive would be invisible. `scripts/load-work.sh` closes that gap: it
globs `requests/pending/`, and for each pending row emits one `[session-request]`
line (type, slug, target instance, age) inside the existing "Active Work" block and
its ~2000-char budget, following the `[stale]` / `[capability-incomplete]` marker
precedent. No new hook is registered. An empty or absent `requests/pending/`
produces no output and no error. The marker makes a waiting request visible to the
next human or coordinator session even when no TUI is alive.

## Type discipline

Rows cross shell → Python → Go. Pin scalar types precisely:

- **Numeric fields** (`pid`, `attempts`) MUST be emitted as JSON numbers, never
  quoted strings — the Go reader uses a strict decoder that rejects `"0"` where it
  expects `0`. Bash writers building rows with `jq` MUST use `--argjson` (not
  `--arg`) for numeric fields.
- **Nullable fields** (`slug`, `target_instance`, `last_error`, `last_attempt_at`,
  `spend`, `claimed_by`/`claimed_at` before claim) are either absent (omit-when-empty)
  or explicit JSON `null` — never the string `"null"`.
- **Enums** (`type`, `session_type`, `initiator`, `event`) are lowercase strings
  from their closed sets; the writer rejects an out-of-set `event`.

---

## Scope note — what this does NOT do yet

The substrate ships ahead of most of its consumers. This half enumerates the
deliberate non-goals so future-implementer energy becomes a scoping signal rather
than scope creep. **If you are reading this and tempted to add one of the
below, don't — it belongs to the item named. Route the need there (or to `/retro`)
rather than growing this contract.**

- **Lifecycle verbs — landed (item 2).** `lore session request` / `list` /
  `events` / `close` (and the `close --request` cancel form) are implemented as
  prepare-and-return scripts behind the `session` dispatcher subgroup. They read
  and write these surfaces per this contract; they do not spawn, wait, or touch
  the TUI. Registry and claimed-queue *writes* remain Phase 2 (TUI).
- **Blocking read verb — landed.** `lore session wait <slug>` is the blocking
  front on the journal: it polls `session events` from a cursor and returns when a
  row matches `<slug>` exactly (never by substring, so a worker's `<slug>--w<n>`
  close never wakes a positional parent wait) and an event in its `--until` set
  (default `closed,close_failed,orphaned`, the close/recovery terminal set). The
  default deliberately remains teardown-oriented. Progress-aware consumers opt
  in with `--until step_completed` and exact-read `step_id`/`step_label` from the
  matched row; completion-aware consumers opt in with `--until terminus_reached`.
  A step wake is not protocol completion, and later close outcomes remain separate
  cleanup/spend evidence. The
  alternate `--work-item <base-slug>` target matches both the exact base and only
  canonical derived `<base-slug>--w<n>` worker slugs, in journal rows and the live
  registry; supplying it together with a positional slug is a usage error. Callers
  watching a reused slug can add `--request-id <id>` to narrow `closed` rows to
  that exact correlation. Other requested outcomes — notably a slug-matched
  `close_failed` carrying a distinct close-request ID — remain a deliberately
  sloppy wake: waking ends sleep only, and the coordinator re-reads the journal
  from the returned cursor to make its exact decision. Exit codes carry the
  outcome: 0 matched, 1 usage/error, 2 timed out, 3 session-gone, and 4 exhausted
  internal reader failure. Both baseline and incremental `session events` calls
  receive three attempts with 1s then 2s backoff; exhaustion is never translated
  into timeout 2. Every non-error exit hands back a resume cursor so a woken
  consumer re-arms with `--since` instead of replaying. A supplied `--since`
  cursor at or before EOF must point immediately after a newline (or be 0); an
  interior offset fails with `cursor-not-row-aligned` and a remediation hint,
  while past-EOF reset and the reference reader's interior-malformed/torn-tail
  tolerance remain unchanged. Instance liveness is only a session-gone hint
  because registry removal can precede the terminal journal append: after liveness disappears,
  `wait` gives the journal a two-second grace and reads once more before returning
  3. The journal row wins if it lands in that window. Session-gone is suppressed
  when the `--until` set names a queue/pre-spawn event, where an unhosted slug is
  the normal starting state. Read-side only — it adds no writer, no event, and no
  TUI surface. See its header for the race-free close-then-wait idiom.
  Modal detection is an explicit opt-in wake edge: `--until modal_blocked` wakes
  on the next shared-classifier entry row (`reason=modal`). The default remains
  the close/recovery terminal set, and consumers re-arm from the returned cursor.
  Because modal clear is silent, coordinate-status recognizes the token but does
  not project a current-state bucket from it.
- **TUI integration — landed (Phase 2).** The per-instance registry, instance
  identity/naming, the pending-queue scan, atomic-rename claim, D4 lifecycle
  handling, badging, and journal emission wiring are implemented in `tui/` per this
  contract.
- **Message injection and readiness gate — landed (item 3).** Delivering a message
  into a running session (the Send-request queue) and gating on harness readiness
  are specified in the body above (`## Send-request queue`, `## Peek request /
  response`) and consumed by the TUI per that contract.
- **Modal choice delivery — landed.** `session answer` uses the same classifier
  as the readiness gate, adds no arbitrary-key authority, and verifies the
  expectation disappeared before reporting success.
- **Skill routing — landed (item 4).** `/coordinate` (`skills/coordinate/SKILL.md`)
  is the coordinator role's protocol home: it consumes these surfaces read-only
  through the session verbs and adds no verbs, no event vocabulary, and no TUI
  surface of its own.
- **Worker session type — landed (substrate half).** The `worker` type, its
  derived-slug identity, `links.work_item` derivation, verbatim-brief prompt
  branch, and queue-gate behavior are specified above (`## Worker sessions`) and
  wired through the enqueue gate, the TUI, and the sole journal writer. The
  *dispatch protocol* that drives it — the session-worker chaperone, lead-side
  brief composition, and per-task spend attribution — is an `/implement` concern,
  not a substrate surface. Route dispatch needs there, not into this substrate.
- **Review mechanism — landed (separate contract).** The four `review_*` events
  are journal vocabulary here, but the gate mechanism they record (flag/hold/notify
  spectrum, the `_meta.json` review block, the flag/hold/release verbs, the review
  packet, and the retro audit read-path) is its own contract in
  [docs/review-gates.md](review-gates.md). Route review-gate needs there, not into
  this substrate.
- **No compaction, truncation, or rotation** of `events.jsonl` in v1. Byte-offset
  cursors depend on it. If the journal outgrows a single file, that is a new design
  decision, not an in-place change.
- **No sticky/durable instance naming.** Identity is per-process; a preferred base
  name persisted in settings was deferred in design review.

Downstream items build against the schemas and event vocabulary **exactly as fixed
here**. Changing a row shape or an event name is re-opening the design decision, not
a silent edit.
