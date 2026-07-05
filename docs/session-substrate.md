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
| `sessions` | array of objects | Live sessions nested under the instance: `[{slug, type, initiator, started}]`. |

Per nested session object: `slug` (string), `type` (string enum
`spec|implement|chat`), `initiator` (string enum `agent|human`), `started`
(string, ISO 8601 UTC).

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

## Request queue

One file per request. A request begins in `requests/pending/<request_id>.json`
and, once an instance claims it, moves to `requests/claimed/<request_id>.json`.

`request_id` = `<timestamp>-<random suffix>`.

| Field | Type | Notes |
|-------|------|-------|
| `request_id` | string | Unique id; also the filename stem. |
| `type` | string | Enum `spec\|implement\|chat`. |
| `slug` | string \| null | Work-item slug the request targets, or null (e.g. a chat with no work item). |
| `target_instance` | string \| null | Instance name the request is addressed to, or null for "any instance". |
| `initiator` | string | Enum `agent\|human`. |
| `requested_by` | string | Who enqueued it (instance name, agent id, or human). |
| `requested_at` | string | ISO 8601 UTC timestamp of enqueue. |
| `attempts` | integer | Claim/spawn attempts so far; starts at `0`. |
| `extra_context` | object \| null | Free-form context object handed to prompt composition, or null. |
| `last_error` | string \| null | Reason of the most recent failed transition; null until one occurs. |
| `last_attempt_at` | string \| null | ISO 8601 UTC of the most recent attempt; null until one occurs. |

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
`target_instance` equals its own name or is null.

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
consume it records.

`lore session send --wait` polls the journal for its request id's `sent` /
`send_refused` and maps the outcome to an exit code (0 sent, 3 refused, 1 error
or timeout). Without `--wait` it enqueues and exits 0 with the request id.

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
| `session_type` | string | `spec\|implement\|chat` — the session's type (the request's `type` maps to this). |
| `initiator` | string | `agent\|human`. |
| `request_id` | string | The request this event concerns; required for queue-lifecycle events. |
| `reason` | string | Failure/reclaim reason; carried by `spawn_failed`, `request_reclaimed`, `request_abandoned`. |
| `links` | object | `{work_item?, artifact?}` — pointers to work-item artifacts rather than duplicated progress. Writer defaults to `{}`. |
| `spend` | object \| null | Reserved. `closed` carries what the TUI knows cheaply at teardown (`duration`); richer spend joins arrive with the model-routing substrate. |

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
| `closed` | TUI | a session ended (reserves `spend`) |
| `step_completed` | protocol terminal verbs | a protocol step finished (e.g. `/implement` phase close) |
| `harness_turn_ended` | stop hooks | a harness turn boundary was reached |
| `spawn_failed` | TUI | spawn failed; request returned to pending (carries `reason`) |
| `request_reclaimed` | TUI (any instance) | a stale/incomplete claim was returned to pending (carries `reason`) |
| `request_abandoned` | TUI | `attempts >= 3`; request dropped, journal row is the dead-letter (carries last `reason`) |
| `request_cancelled` | `session close --request` cancel verb | a pending spawn request was cancelled |
| `close_requested` | `session close` enqueue verb (`<slug>` / `--self`) | a close request was enqueued for the instance running a slug |
| `send_requested` | `session send` enqueue verb | a send request was enqueued for the instance running a slug |
| `sent` | TUI | the readiness gate passed and the message was injected into the composer |
| `send_refused` | TUI | the readiness gate refused injection; `reason` names why (`generating`/`modal`/`no-signature`/`no-contract`/`unsafe-payload`/`error`) |

**Queue-lifecycle events** — `requested`, `claimed`, `spawned`, `spawn_failed`,
`request_reclaimed`, `request_abandoned`, `request_cancelled`, `close_requested`,
`send_requested`, `sent`, `send_refused` — each concern a specific request and
MUST carry a non-empty `request_id`. The writer enforces this. (`sent` and
`send_refused` carry it so `session send --wait` can match its outcome by id.)

**Emitter ownership** (per the settled design): the TUI owns session transitions
and TUI-driven queue lifecycle; the enqueue writer owns `requested`; the
`session close` verb owns `close_requested` (its enqueue forms) and
`request_cancelled` (its cancel form); the `session send` verb owns
`send_requested` (its enqueue), while the TUI owns the `sent` / `send_refused`
outcomes it decides at consume; protocol terminal verbs own `step_completed`;
stop hooks own `harness_turn_ended`. Peek has no events — it is a read.

### Prospective emission (emitter obligation)

Events are written **prospectively, at the transition** — the emitter appends the
row when the state change happens, not by mining a transcript afterward. This is an
obligation on every emitter, not a convenience: the journal is designed to outlive
session transcripts, so anything not written at the transition is lost. Do not
design any consumer around retrospective transcript reconstruction.

### Writer contract

`session-event-append.sh` is the **sole physical writer** of `events.jsonl`. It:

1. Reads one JSON object (via `--row` or stdin).
2. Validates: object shape; `event` present and in the vocabulary; `request_id`
   non-empty for queue-lifecycle events; `links` (if present) is an object. Any
   failure exits non-zero with a diagnostic **naming the offending field**, and no
   row is appended.
3. Stamps provenance: generates `event_id` and `ts` when the caller omitted them;
   defaults `links` to `{}`.
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
`{events: [...], next_cursor: N}`; plain output is NDJSON rows on stdout followed by
a `next_cursor:` line on stderr, so stdout stays machine-consumable.

### Dedupe posture

The appender **does not dedupe** — it appends every validated row unconditionally.
Idempotency is the emitter's responsibility: an emit site that must be at-most-once
constructs a **deterministic `event_id`** and guards on it (checking its own state
or the journal) before calling the writer. Most session transitions are naturally
once-only and need no guard; the writer-generated `event_id` is fine for them.

## Ownership matrix

Exactly one writer owns each surface. Everything else shells out to that writer or
reads full snapshots.

| Surface | Sole writer | Written by | Landed in |
|---------|-------------|-----------|-----------|
| `instances/<name>.json` | the owning TUI instance (its own file) | tmp + `os.Rename`, `os.Chtimes` heartbeat | Phase 2 (TUI) |
| `requests/pending/<id>.json` | the enqueuer | item 2 `request` verb; TUI human path | item 2 / Phase 2 |
| `requests/claimed/<id>.json` | the claiming TUI instance | `os.Rename` claim + tmp+rename metadata | Phase 2 (TUI) |
| `close-requests/<id>.json` | the enqueuer (`session close` verb); deleted-on-consume by the owning TUI instance | tmp + rename enqueue; owning instance deletes | item 2 (enqueue) / Phase 2 (consume) |
| `events.jsonl` | `scripts/session-event-append.sh` | every emitter, via subprocess | **this phase** |
| `[session-request]` cold-start marker | `scripts/load-work.sh` (reader of `requests/pending/`) | SessionStart hook | **this phase** |

This phase (Phase 1) lands only the `events.jsonl` writer and the load-work marker;
the registry and request writers are defined by this contract and implemented in
Phase 2 and item 2.

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
- **No TUI integration.** The per-instance registry, instance identity/naming, the
  pending-queue scan, atomic-rename claim, D4 lifecycle handling, badging, and
  journal emission wiring are **Phase 2** (`tui/`). This phase defines their
  contract; it does not touch `tui/`.
- **No message injection or readiness gate.** Delivering a message into a running
  session and gating on harness readiness is **item 3**.
- **No skill routing.** Surfacing sessions through skill discovery is **item 4**.
- **No spend joins.** The `spend` object on `closed` is reserved and nullable; the
  TUI fills only cheap teardown duration. Richer spend arrives with the
  model-routing substrate.
- **No compaction, truncation, or rotation** of `events.jsonl` in v1. Byte-offset
  cursors depend on it. If the journal outgrows a single file, that is a new design
  decision, not an in-place change.
- **No sticky/durable instance naming.** Identity is per-process; a preferred base
  name persisted in settings was deferred in design review.

Downstream items build against the schemas and event vocabulary **exactly as fixed
here**. Changing a row shape or an event name is re-opening the design decision, not
a silent edit.
