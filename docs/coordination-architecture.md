# Coordination Architecture

This is the **roof** over the coordination system's per-layer contract docs. It
gives the assembled picture — the four layers, how they connect, and the
constraints that bind across all of them — then hands off to each layer's own
contract doc for the mechanism. It **duplicates nothing**: every layer detail
lives in exactly one contract doc, linked here. Read this first for the shape;
read the linked contract for the layer you are changing.

The system lets multiple protocol sessions (`/spec`, `/implement`, `/retro`) run
across sessions and days, coordinated by one judgment seat, **without a daemon** —
the layers integrate only through files in the knowledge store (`_sessions/`) and
a daemonless CLI (`lore session`). That property is the design, not an
implementation detail; the [cross-layer constraints](#cross-layer-constraints)
state why, once.

## The system in one diagram

```
                 ┌─────────────────────────────────────────────────┐
                 │  COORDINATOR KERNEL — /coordinate + ledger       │
                 │  judgment: depth · rung · granularity · routing  │
                 │  · gates · unknowns   (coordination.md = seat)   │
                 └───────────────┬──────────────────────▲───────────┘
    interacts ONLY through       │ requests, closes,    │ journal events,
    substrate files & CLI verbs  │ ledgers cursor       │ read via opaque cursor
┌────────────────────────────────▼──────────────────────┴───────────┐
│  SESSION SUBSTRATE  (_sessions/ in the knowledge store)            │
│  instance registry · request queue (atomic claim, extra_context,  │
│  routing_overrides, auto_close, min_vintage) · close/send/peek     │
│  queues · events journal (sole writer, opaque byte cursor,         │
│  spend on `closed`)                    ── the file-based bus ──     │
└──────────┬───────────────────────────────────┬────────────────────┘
           │ claims & spawns                   │ reads & writes
┌──────────▼──────────────────┐   ┌────────────▼───────────────────┐
│  TUI = the INSTRUMENT        │   │  lore session verbs (any agent)│
│  PTY host · screen emulation │   │  request · list · events ·     │
│  readiness gate · send/peek  │   │  close · send · peek           │
│  exit ladder · badges/gates  │   │  (daemonless; prepare + return)│
└──────────┬──────────────────┘   └────────────────────────────────┘
           │ hosts
┌──────────▼───────────────────────────────────────────────────────┐
│  PROTOCOL SESSIONS  /spec · /implement · /retro                   │
│  models: ceremony_roles → class roles → per-dispatch env          │
│  comprehension gates: flag/hold/release · review packets          │
│                                                                    │
│  evidence ─▶ work items ─▶ scorecards ─▶ /retro ─▶ /evolve         │
│         └──────── the audit loop, artifact-fed, bottom-up ─────────┘
└───────────────────────────────────────────────────────────────────┘
```

Two things the diagram encodes that are easy to miss:

- **The vertical arrows are reads and writes, not calls.** The coordinator never
  invokes the TUI; the TUI never invokes the verbs; the verbs never call the
  coordinator. Every layer coordinates through the session substrate — it is a
  message bus made of files, and each layer is a *client* of it. This is why the
  constraints that bind the whole system are file-ownership rules (sole writer,
  atomic rename, opaque cursor, no daemon), not API contracts.
- **The audit loop runs bottom-up and is artifact-fed.** Protocol sessions emit
  evidence → work items → scorecards; `/retro` scores the closed cycle from those
  artifacts; `/evolve` mutates skill templates from that signal. The coordinator
  reads the journal through an opaque cursor to drive the top of the loop. No step
  depends on conversational memory — a memoryless seat can score any closed cycle
  later, which is what makes deferral an instrument rather than a loss.

## The layers

Each layer has exactly one contract doc. This section says what the layer *is* and
what it *binds*, then points at the contract for the mechanism. Where a layer's
forward-looking scope note lags the working tree (it does — see
[How to read this system](#how-to-read-this-system)), trust the tree and the
capability probe over the non-goals list.

### 1. Coordinator kernel — [`../skills/coordinate/SKILL.md`](../skills/coordinate/SKILL.md)

The one participant that sees the whole feature. It drives the arc across sessions
by deciding what happens next and recording why: the five kernel judgments are
**spec depth**, **ceremony rung**, **granularity/routing**, **gate mechanism**, and
**step selection**, plus the **unknowns inventory** at arc open. Its seat is a
`coordination.md` ledger whose location follows the arc's span — a single-item arc
keeps it in that item's directory (`_work/<slug>/`), while a **multi-item arc**
seats it at the project home (`_work/_projects/<project-slug>/coordination.md`,
created by `lore work project describe`). Every dynamic act lands there as decision
+ one-line rationale + evidence pointer, so a fresh coordinator (or the human) can
resume mid-flight from the ledger and item notes alone.

What binds it: **judgment inline, implementation dispatched.** The kernel reviews,
verifies, synthesizes, and adjudicates — and writes *substrate only* (work items,
ledger, notes, commits). It **never writes repo source**; crossing that line
creates an unaudited mega-worker outside every evidence protocol. It interacts with
the layers below only through substrate files and the `lore session` verbs.

### 2. Session substrate — [`session-substrate.md`](session-substrate.md)

The `_sessions/` surface in the knowledge store: the instance **registry** (one
file per live TUI — a crashed instance's row survives past its liveness TTL as the
recovery manifest a restarting TUI adopts from), the request **queue** (pending →
claimed by atomic rename), the **close / send / peek** request queues, and the
append-only **events journal**. It follows a **state/history split**: the queue
directories are the source of truth for *liveness* (what is pending/claimed now);
`events.jsonl` is the source of truth for *history* (what happened). It is
decomposed into per-owner files so that atomic rename replaces both locking and
read-modify-write entirely — there is no single mutable `registry.json` or
`queue.json`, and no lock in Go or bash.

What binds it: **sole writer per file** and **no daemon** (both below). The journal
has one sanctioned physical writer; every emitter shells out to it. The contract
doc is the authority on row schemas, the event vocabulary, the reclamation rules,
and the opaque byte-offset cursor — none of which is restated here.

### 3. The instrument and the verbs — TUI (`tui/`) + `lore session` verbs; capability profile in [`../adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)

Two clients of the substrate, split by role:

- **The TUI is the instrument.** It hosts each harness — inside a **tmux session**
  when tmux is available, so the harness outlives the TUI process and a restarted
  instance can **adopt** a still-running session from the dead instance's registry
  row (journaling `recovered`) — emulates their screens, runs the strict
  **readiness gate** that classifies a session as quiescent / needs-input /
  mid-prompt, injects sends and answers peeks, walks the **exit ladder** at
  teardown, and **emits the journal events** for every session transition. Its
  instrumentation — the gate, the injection, the emission — is load-bearing
  coordination, not a rendering convenience (see *surface is the feature*, below).
- **The verbs are the daemonless CLI.** `lore session request / list / events /
  close / send / peek` are prepare-and-return scripts: they read and write the
  substrate per its contract; they do not spawn, wait, or hold a process. Any
  agent — coordinator, hook, or human — uses them to touch the substrate without
  the TUI being alive.

What binds it: **capability gating with explicit degradation** and **surface is the
feature** (both below). Which verbs and which telemetry a checkout actually has is
probed, never assumed — [`../adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)
is the dated, per-harness evidence for every capability cell (instructions, hooks,
subagents, transcript/spend providers, and the live PTY interaction probes that
back the readiness gate's composer/permission signatures). Claude Code is `full`;
OpenCode and Codex are `partial` with named degradations.

### 4. Protocol sessions — `/spec`, `/implement`, `/retro`; comprehension gates in [`review-gates.md`](review-gates.md)

The actual work the TUI hosts. Three things cut across all of them:

- **Model routing and dispatch controls.** Model routing resolves in precedence
  order: `ceremony_roles` overlay → class-qualified roles → per-dispatch env
  (`LORE_MODEL_<ROLE>`, exported by the claiming instance from a request's
  `routing_overrides`, which routes *sub-agent* roles). A separate `model` field on
  the same request routes the session **lead** (composed as the harness `--model`).
  A coordinator's per-dispatch routing wins over settings policy with no resolver
  change; standing user directives (e.g. the model floor) win over both. The same
  request carries the non-model dispatch controls `track` (spec depth, e.g. `/spec
  short`) and `skip_confirm` (session autonomy), so one enqueue fixes model, depth,
  and gating together.
- **The audit loop**: evidence → work items → scorecards → `/retro` → `/evolve`,
  artifact-fed and seat-independent.
- **Comprehension gates**: a coordinator marks an item **notify** / **flag** /
  **hold** to require human comprehension before *done*. The mechanism — the
  `_meta.json` review block, the flag/hold/release verbs, the review packet, and
  the retro audit read-path — is the [`review-gates.md`](review-gates.md) contract;
  its four `review_*` journal events are a third event class in
  [`session-substrate.md`](session-substrate.md#event-vocabulary). This doc does not
  restate the spectrum.

## Cross-layer constraints

These bind every layer. Each is stated **once, here**; the contract docs enforce
them locally and point back rather than re-arguing them.

| Constraint | What it means | Enforced where | Why |
|---|---|---|---|
| **No daemon** | Coordination is derivable from filesystem state; no long-running process owns it. Enqueue is tmp-write + rename, claim is a rename between dirs, history is an O_APPEND journal read by opaque byte offset. | Substrate layout; the byte-offset cursor (a sequence number would force the writer to read-modify state, breaking the archetype). | The picture survives any process dying. A crash loses at most one journal row; a restarted seat resumes from the ledger + cursor. It is also the anchor a "TUI-as-viewer over a hosting daemon" idea collides with. |
| **Sole writer per file** | Exactly one writer owns each surface: a TUI owns its own registry file; the enqueuer owns a pending request; the claimer owns it after the rename; `events.jsonl` has one sanctioned physical writer that every emitter shells out to. | The per-owner-file decomposition (dissolves read-modify-write); `session-event-append.sh` as the journal's sole validator. | Validation and serialization are paid once, at write time. Readers never re-validate and never dedupe — a torn/interior-malformed row is excluded with a warning, not repaired. |
| **Surface is the feature** | The TUI's interactive instrumentation — readiness gate, injection, exit ladder, journal emission — *is* the coordination capability, not a view over a hidden engine. | The instrument layer: the gate/injection/emission live in the hosting process. | You cannot extract a headless engine and keep the TUI as a viewer without re-introducing a daemon — the instrumentation is load-bearing, so pulling it out reopens the no-daemon anchor. |
| **Capability gating with explicit degradation** | Every capability is probed, not assumed; an absent capability degrades a loop, never aborts it. A needs-input session with no `send` becomes a blocked-on-input ledger row; a harness with no transcript binding degrades spend to `duration-only`. | `lore session --help` (verb availability); `adapters/capabilities.json` + `../adapters/capabilities-evidence.md` (dated per-harness evidence, full/partial/fallback/none). | Harnesses diverge (Claude Code full; OpenCode/Codex partial). The system must run degraded rather than assume-and-break — and consumers must probe live availability rather than trust a contract doc's non-goals list. |
| **Initiator-gated terminus hold-open** | Close authority branches on the close request's `reason`. An **explicit** close (`reason` `human` or `coordinator`) is **full-discretion** — it always acts regardless of initiator or session state (a still-generating turn gets the interrupt-escalation ESC rung first), never a silent no-op. Only a **protocol-terminus** close reads `initiator`/`auto_close`: an agent-initiated session auto-closes, a human-initiated one is **held open** with a *done* badge for reading and follow-ups. A per-request `auto_close` override flips the terminus branch either direction. | The TUI close-request consume path, which branches on `reason` (the [close-authority section](session-substrate.md#close-request-queue)); the exit ladder + interrupt-escalation rung. | Human comprehension is a system invariant **at protocol terminus** — the coordinator removes operator friction, not the understanding operating produced — but an operator's or coordinator's explicit close is authority the system honors, never gates. |
| **Coordinator writes substrate, never source** | The judgment seat's broad agency is bounded to substrate writes (work items, ledger, notes, commits). Repo source is only ever written by dispatched, evidence-protocol-covered workers. | The `/coordinate` kernel's hard edges; every rung dispatches its executor, even rung-0 bugfixes. | Un-audited authorship at the highest-context seat is the one move that escapes every evidence protocol. This is what keeps the kernel a coordinator, not a mega-worker. |

## How to read this system

- **Changing one layer:** read that layer's contract doc (linked above); this roof
  only orients you to where it sits and what binds it.
- **Trust the tree over the non-goals lists.** The contract docs' forward-looking
  sections (scope notes, "until it lands," landing-phase columns) **lag the working
  tree in both directions** — deliverables land as untracked/uncommitted state while
  a doc's scope note still lists them as future non-goals, and vice versa. A
  consumer must **probe capability availability** (which verbs the dispatcher
  exposes, which fields writers populate, what a `closed` event actually carries)
  rather than trusting either a doc's non-goals list or a sibling plan's status.
- **The worked example** of the kernel driving all four layers is a coordination
  ledger: `_work/model-routing-across-roles-harnesses-spend-telemet/coordination.md`
  (the arc that built the coordinator role by hand before the skill existed). The
  live-run friction that this architecture was pressure-tested against is logged in
  `_work/tmux-backed-tui-sessions-crash-recovery-reattach/coordination.md`.
