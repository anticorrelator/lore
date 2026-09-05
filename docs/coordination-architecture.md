# Coordination Architecture

This is the **roof** over the coordination system's per-layer contract docs. It
gives the assembled picture — the five layers, how they connect, and the
constraints that bind across all of them — then hands off to each layer's own
contract doc for the mechanism. It **duplicates nothing**: every layer detail
lives in exactly one contract doc, linked here. Read this first for the shape;
read the linked contract for the layer you are changing.

The system lets multiple protocol sessions (`/spec`, `/implement`, `/retro`) run
across sessions and days, coordinated by one judgment seat. Durable ownership,
intent, and outcomes live in the knowledge store (`_sessions/` and
`_coordination/`). An on-demand session host performs routine administration;
the coordinator retains task selection, intervention, and integration judgment.
The [session manager contract](session-manager.md) describes hosting and recovery.

## The system in one diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ COORDINATOR KERNEL — /coordinate + coordination.md               │
│ explicit dependencies · semantic ownership · reconciliation call │
└──────────────┬───────────────────────────────────▲───────────────┘
               │ allocate / reconcile / clean      │ joined status
┌──────────────▼───────────────────────────────────┴───────────────┐
│ COORDINATION SUBSTRATE (_coordination/)                           │
│ leased worktree manifests · immutable source/integrated objects  │
│ cleanup proof · derived readiness (no persisted ready flag)       │
└──────────────┬───────────────────────────────────▲───────────────┘
               │ hard execution identity           │ stream result
┌──────────────▼───────────────────────────────────┴───────────────┐
│ SESSION SUBSTRATE (_sessions/) — request/instance queues + journal│
└──────────┬───────────────────────────────────┬───────────────────┘
           │ claims & spawns                   │ managed verbs
┌──────────▼──────────────────┐   ┌────────────▼───────────────────┐
│ SESSION HOST / TUI          │   │ lore session / coordinate     │
│ PTY/tmux host · guard       │   │ prepare, inspect, reconcile   │
└──────────┬──────────────────┘   └────────────────────────────────┘
           │ hosts at validated execution_dir
┌──────────▼───────────────────────────────────────────────────────┐
│ PROTOCOL SESSIONS — /spec · /implement · /retro                  │
│ evidence ─▶ work items ─▶ scorecards ─▶ /retro ─▶ /evolve        │
└──────────────────────────────────────────────────────────────────┘
```

Two things the diagram encodes that are easy to miss:

- **Durable files join the layers.** The managed CLI can ensure a hosting process,
  but ownership and operation outcomes survive that process in the substrate.
  Sole-writer journal validation, atomic replacement, and serialized ownership
  transitions make recovery inspectable.
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
**step selection**, plus the **unknowns inventory** at arc open. Its seat is the
arc directory: `lore arc open` creates `_work/_arcs/<slug>/`, instantiates the
`coordination.md` ledger there, and records the arc; closure and archival are
recorded through `lore arc close` and `lore arc archive` (a status value — the
directory stays put). Every dynamic act lands in the ledger as decision + one-line
rationale + evidence pointer, so a fresh coordinator (or the human) can resume
mid-flight from the ledger and item notes alone.

What binds it: **consequential decisions remain attributable and checkable.** The
coordinator delegates implementation by default to preserve its context, and may
edit source directly when it has the context, authority, and verification needed.
A small correction carries its rationale and check in the ledger; taking over a
stream retains that stream's integration and review obligations. The skill owns
those distinctions. Coordination state still flows through sanctioned substrate
writes and the `lore session` / `lore coordinate` verbs.

### 2. Coordination worktrees and reconciliation — `lore coordinate`

The `_coordination/` surface isolates every mutating stream in a manager-owned
temporary worktree and preserves its immutable source and integrated manifests.
The manager consumes the versioned identity and lifecycle implemented by
`tui/internal/worktree/guard.go`; it does not introduce a competing checkout
identity. Its outer manifest binds work item, stream, attempt, temporary branch,
allocation base, and a session-or-seat lease to the canonical guard identity.

The coordinator derives readiness from `Depends on`, `Tree`, active attempts,
terminal full+cleaned predecessors, and the concurrency ceiling rendered by
`lore defaults`. It owns integration order and conflict judgment; workers own
source conflict edits. The source and integrated manifests remain valid after the
tree and branch disappear. Normal and crash cleanup share one terminal proof:
path absent, Git worktree registry absent, and branch/guard refs disposed. Recovery
evidence is persisted before removal; incomplete proof remains `cleanup_blocked`.

### 3. Session substrate — [`session-substrate.md`](session-substrate.md)

The `_sessions/` surface in the knowledge store: the instance **registry** (one
file per live host or TUI — a crashed instance's row survives past its liveness TTL as the
recovery manifest a replacement owner adopts from), the request **queue** (pending →
claimed by atomic rename), the **close / send / peek** request queues, and the
append-only **events journal**. It follows a **state/history split**: the queue
directories are the source of truth for *liveness* (what is pending/claimed now);
`events.jsonl` is the source of truth for *history* (what happened). It is
decomposed into per-owner files. Queue claims use atomic rename; managed host
ownership and facade indexes additionally use advisory locks. There is no single
mutable `registry.json` or `queue.json`.

What binds it: **sole writer per file** and **durable ownership** (both below). The journal
has one sanctioned physical writer; every emitter shells out to it. The contract
doc is the authority on row schemas, the event vocabulary, the reclamation rules,
and the opaque byte-offset cursor — none of which is restated here.

### 4. The instrument and the verbs — TUI (`tui/`) + `lore session` verbs; capability profile in [`../adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)

The runtime hosts each interactive harness in a PTY, with tmux preserving the
worker across host failure when available. It classifies readiness, injects and
verifies input, walks the exit ladder, and journals session transitions. The same
instrumentation runs in a visible TUI or an on-demand headless session host.

The managed `lore session start / send / answer / peek / wait / close` facade
ensures the host, resolves stable handles, persists intent and receipts, and waits
for correlated outcomes. `inspect` retains access after teardown; `attach` offers
a human terminal without transferring lifecycle ownership. Raw `request`, instance
listing, and journal verbs retain their lower-level substrate contracts.

What binds it: **capability gating with explicit degradation** and **interactive instrumentation** (both below). Which verbs and which telemetry a checkout actually has is
probed, never assumed — [`../adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)
is the dated, per-harness evidence for every capability cell (instructions, hooks,
subagents, transcript/spend providers, and the live PTY interaction probes that
back the readiness gate's composer/permission signatures). Claude Code is `full`;
OpenCode and Codex are `partial` with named degradations.

### 5. Protocol sessions — `/spec`, `/implement`, `/retro`

The actual work the session runtime hosts. Three things cut across all of them:

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
- **Comprehension gates**: a coordinator marks a stream **notify** / **flag** /
  **hold** in its ledger to route human comprehension. Hold is legal only at
  arc-open or a genuine intent fork; mid-arc material flags and proceeds, landing
  in the arc's terminal decision digest. The spectrum lives in the coordinate
  skill's ledger vocabulary; a separate journal-event mechanism for review gating
  shipped, was never used, and was deleted (2026-08-10).

## Cross-layer constraints

These bind every layer. Each is stated **once, here**; the contract docs enforce
them locally and point back rather than re-arguing them.

| Constraint | What it means | Enforced where | Why |
|---|---|---|---|
| **Durable ownership** | Hosting processes may be started on demand; intent, ownership, and outcomes remain recoverable from filesystem state. | Managed host locks, readiness barrier, launch and delivery checkpoints; registry and journal. | A process crash must not require coordinator bookkeeping or silently duplicate a worker or input. |
| **Sole writer per file** | Exactly one writer owns each surface: a TUI owns its own registry file; the enqueuer owns a pending request; the claimer owns it after the rename; `events.jsonl` has one sanctioned physical writer that every emitter shells out to. | The per-owner-file decomposition (dissolves read-modify-write); `session-event-append.sh` as the journal's sole validator. | Validation and serialization are paid once, at write time. Readers never re-validate and never dedupe — a torn/interior-malformed row is excluded with a warning, not repaired. |
| **Isolated trees with semantic ownership** | Every mutating stream runs in its own worktree — session-owned (host-allocated) for worker sessions, seat-allocated through the manager for harness-native subagents. Allocation never delegates; a subagent is valid only in its dispatching seat's tree. Known overlap consolidates or gains an explicit edge. | `lore coordinate worktree`; hard session placement; ledger `Depends on` / `Tree`; canonical guard identity in `tui/internal/worktree/guard.go`. | Physical isolation prevents checkout collisions, while explicit ownership prevents semantically incompatible edits from becoming surprise merges. |
| **Audited integration gates completion** | A writer is not `done` until its commits are merged on the control checkout, verified by the suites, and the merge SHA and results are in the ledger row. Seat-tree removal pins the branch tip to a quarantine ref when it moved off its base and proves path, Git-registry, and branch/ref disposition. | The seat's integration discipline (coordinate skill § Verifying and closing); manager removal proof; quarantine refs. | A process terminal or successful merge cannot launder leaked worktrees into closure, and removing a tree can never strand the commits it carried. |
| **Interactive instrumentation** | Readiness gates, verified input, the exit ladder, and journal emission belong to the hosting runtime; a visible terminal is optional. | Shared Go session runtime, visible TUI and headless host modes. | Cross-harness behavior retains the existing interactive tools while removing the prerequisite of a manually placed TUI. |
| **Capability gating with explicit degradation** | Every capability is probed, not assumed; an absent capability degrades a loop, never aborts it. A needs-input session with no `send` becomes a blocked-on-input ledger row; a harness with no transcript binding degrades spend to `duration-only`. | `lore session --help` (verb availability); `adapters/capabilities.json` + `../adapters/capabilities-evidence.md` (dated per-harness evidence, full/partial/fallback/none). | Harnesses diverge (Claude Code full; OpenCode/Codex partial). The system must run degraded rather than assume-and-break — and consumers must probe live availability rather than trust a contract doc's non-goals list. |
| **Initiator-gated, cooperative terminus close** | Close authority branches on the close request's `reason` before any interrupt write. An **explicit** close (`reason` `human` or `coordinator`) is **full-discretion**: a generating turn gets two seconds to finish naturally, then ESC and the existing force-teardown ladder. Only a **protocol-terminus** close reads `initiator`/`auto_close`: an auto-closing agent session waits up to two minutes for natural quiescence and never interrupts or force-kills while generating; expiry emits one correlated `close_failed/still-generating` with the session alive for an explicit re-close. A human-initiated session is **held open** with a *done* badge, and a per-request `auto_close` override flips that terminus branch either direction. | The TUI close-request consume path, which branches on `reason` (the [close-authority section](session-substrate.md#close-request-queue)); the shared screen classifier, cooperative waits, and explicit interrupt ladder. Live behavior changes only after the operator rebuilds the TUI. | Human comprehension is a system invariant **at protocol terminus**, and teardown must not destroy the tail whose completion it records. Truthful refusal preserves that work while explicit operator/coordinator authority remains the sanctioned runaway-session escape hatch. |
| **Coordinator authorship remains checkable** | Implementation is delegated by default; direct source edits remain within the coordinator's authority, with recorded reasons and verification proportionate to the change. | The `/coordinate` kernel's hard edges distinguish small corrections from stream takeovers; sanctioned writers still own substrate state. | Successors and peers can assess the work regardless of which participant wrote it. |

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
  ledger: `_work/_arcs/model-routing-tranche-1/coordination.md`
  (the arc that built the coordinator role by hand before the skill existed). The
  live-run friction that this architecture was pressure-tested against is logged in
  `_work/_arcs/tmux-backed-tui-sessions-arc-grew-multi-item-seate/coordination.md`.
