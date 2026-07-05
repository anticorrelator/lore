# Review Gates (`review` block + `review_*` events)

Contract for the review-mechanism layer: the substrate that lets a coordinator (or
any agent) mark a work item as needing human comprehension before it is considered
done — a *comprehension* checkpoint, distinct from an *approval* gate. This doc is
the **contract half** — the mechanism spectrum, the `_meta.json` review block, the
verbs, the review-packet contract, and the audit read-path. The journal vocabulary
half lives in [docs/session-substrate.md](session-substrate.md#event-vocabulary);
the four `review_*` events are a third event class there.

The layer follows the session substrate's own **state/history split**: the
`_meta.json` `review` block is the source of truth for *is this item gated right
now*; the `_sessions/events.jsonl` journal answers *what happened and when* (audit).
Every consumer that needs current gate state reads the block (via `_index.json` or
`lore work show`), never the journal.

## Mechanism spectrum

Three mechanisms, ordered by how much they interrupt:

| Mechanism | Blocks archive? | Journal event | Verb | Meaning |
|-----------|-----------------|---------------|------|---------|
| **notify** | no | `review_notified` | none (direct append) | a stateless "you should look at this" — fire-per-occurrence, no gate opened |
| **flag** | yes | `review_flagged` | `lore work flag` | a lightweight async checkpoint: the item is marked "unread"; work on other streams continues |
| **hold** | yes | `review_held` | `lore work hold` | a blocking checkpoint: the item is held pending comprehension; the heaviest mechanism |

**flag** and **hold** both open a gate (write the review block, refuse archive
until released). They differ only in weight/intent — a flag is "read this when you
can", a hold is "this is held". **notify** opens no gate: it is a pure journal
signal with no durable state, so it needs no verb and no release.

## Review block (`_meta.json`)

Review state lives in an optional `review` block on `_meta.json`, following the
`closure` precedent verbatim (an optional nested dict; a whitelisted subset is
projected into `_index.json`; the block's writer is the only sanctioned mutator).

```json
"review": {
  "mechanism": "flag" | "hold",
  "gate_id": "<timestamp>-<random>",
  "gated_at": "2026-07-05T18:03:00Z",
  "reason": "why the item needs comprehension review",
  "packet": "review-packet.md"
}
```

| Field | Required | Notes |
|-------|----------|-------|
| `mechanism` | yes | `flag` or `hold`. `notify` never writes a block (no gate). |
| `gate_id` | yes | `<timestamp>-<random>`, same shape as an event_id. The audit join key — set as the gate-open event's `event_id`, echoed by the release row's `gate_id`. |
| `gated_at` | yes | ISO 8601 UTC of the gate open. |
| `reason` | yes | The gate rationale. Surfaced in markers and `lore work show`. |
| `packet` | no | Filename of the review packet in the work-item directory (omit-when-empty). |

**One active gate per item.** The verbs enforce it: opening a gate on an
already-gated item is refused. Escalation (flag → hold) is `release` + re-gate —
two auditable events, never a silent overwrite.

Only `mechanism`, `gated_at`, and `reason` are projected into `_index.json`
(`plans[].review`) for the renderers. `gate_id` stays in `_meta.json` for release;
`packet` is auto-delivered by the bag-of-files surfaces (`lore work show`, the TUI
detail tab) and needs no projection.

## Verbs

Three verbs, each a thin front that writes the durable block **before** emitting its
journal event (the substrate's durable-before-journal rule), and each shells to
`session-event-append.sh` for the journal write — no verb opens `events.jsonl`
itself.

- **`lore work flag <slug> --reason <r> [--packet <name>]`** — open a flag gate.
  Writes the review block (`mechanism: flag`), rebuilds the index, emits
  `review_flagged` with `event_id = gate_id` and (when a packet is named)
  `links.artifact = <packet>`.
- **`lore work hold <slug> --reason <r> [--packet <name>]`** — identical, with
  `mechanism: hold` and event `review_held`.
- **`lore work release <slug>`** — read the active `gate_id`, clear the review
  block, rebuild the index, emit `review_released` carrying the original `gate_id`.
  Refuses when no gate is active (so a second release exits non-zero).

**Notify has no verb.** The coordinator emits `review_notified` directly through
`session-event-append.sh` (with a non-empty `slug`) — it is stateless by
definition, so there is nothing to write to `_meta.json` and nothing to release.

The gate-open verbs and `release` clone `relate-work.sh`'s mutation pipeline:
`find_item_dir` (active-or-archive), an idempotent Python `_meta.json` mutation,
`update_meta_timestamp`, and an `update-work-index.sh` rebuild.

## Dedupe posture

Keyed to what a duplicate *means* (per the substrate's per-substrate dedupe rule):
the verbs' single-gate / no-active-gate guards make
`review_flagged`/`review_held`/`review_released` naturally once-only per gate — the
verb's state guard enforces it, not the appender (which never dedupes).
`review_notified` is fire-per-occurrence: a stateless notification, so re-emitting
it is a new observation, never a duplicate.

## Review packet

The review packet is a plain markdown reading guide named `review-packet.md` in the
work-item directory (`_work/<slug>/`). It is **not** a second telemetry substrate —
the landed `_packets/` context-packet is machine telemetry whose defining invariant
is that rows never enter a prompt or a human reading path, which is the inverse of a
reading guide's purpose. The packet is human-first by design.

Bag-of-files makes delivery free: `lore work show` auto-delivers any non-underscore
`.md` in the item directory, and the TUI auto-renders it as a detail tab. The
gate-open verb records the filename in the review block's `packet` field and the
event's `links.artifact`; **authoring** the packet is the coordinator's obligation
(see Handoffs).

Four required sections:

- `## Decisions & rationale` — the load-bearing decisions and why they were made.
- `## Diagram` — one diagram that orients the reader before prose.
- `## Reading order` — the sequence to read the change in, so comprehension is
  guided rather than archaeological.
- `## Questions` — split into **Needs the human** (open questions only a human can
  settle) and **Settled** (questions already resolved, recorded so they are not
  re-litigated).

## Audit semantics

Retro reads the review events from `_sessions/events.jsonl`, windowed to the work
period, and re-reads the journal at authoring time (never inheriting counts from an
earlier step). Three signals:

- **Dwell** = `review_released.ts` − gate-open `ts`, joined on `gate_id`
  (`review_released.gate_id` == the gate-open row's `event_id`). How long a gate
  stayed open — a proxy for whether the flag was actually read.
- **Rubber-stamp signal** = near-zero dwell on `review_held` gates — a hold cleared
  almost instantly suggests the comprehension checkpoint was skipped, not honored.
- **Flag-pileup** = count of currently-gated items (from `_index.json`
  `plans[].review`) — a rising backlog means flags are accumulating unread.

These are **tuning signal, not surveillance**: findings route to the retro
journal entry and, where actionable, existing `retro_flag` sidecar rows — **never**
`scorecard-append` rows. Routing dwell metrics through `rows.jsonl` would expose
them to `/evolve` and create a scoring incentive to suppress gates, which is exactly
the failure the off-band rule prevents. The read-path is batch and windowed and
artifact-fed; nothing requires retro to run per-gate.

### Named experiment: the archive-directive change

This layer ships one behavioral change as a **named experiment**: the working
definition of *done* becomes "work-complete **and** comprehension-complete" — a
flagged or held item is not archivable until released, so the active list carries
the comprehension debt rather than human memory.

**Review trigger:** after ~5 releases **or** 4 weeks of first use (whichever comes
first), a retro run evaluates two questions from the journal — did flags actually
get read (the dwell distribution), and did the active list stay signal-rich (the
flag-pileup trend). If flags pile up unread, the experiment is failing and the
archive-blocking directive is the thing to revisit, not the metric.

## Handoffs (mechanism only — policy lives elsewhere)

This layer delivers **mechanism**: the events, the verbs, the block, the packet
contract, and the audit read-path. Three things it deliberately does **not** own:

- **Gate policy** — which mechanism to use per coordination step, escalation
  judgment, step-ledger authoring, packet authoring, and the coordinator-as-explainer
  role — belongs to the `/coordinate` skill. This doc gives that skill callable
  verbs and a packet contract to bind against.
- **"What a hold blocks"** — cross-stream edge semantics belong to the work-item
  dependency-edges item (plan-stage). Until it lands, a hold pauses only its own
  stream; other streams structurally continue (a `blocked_by` edge is a displayed
  signal, not a dispatch gate).
- **Consumption-visibility read-release feed** — a release registering as a
  consumption signal is **dropped from committed scope**: the target endpoint is an
  absorbed stub with no landed surface. If a release should ever register as a
  consumption signal, that routes to the trust-ledger substrate as future work.

## Known gap: review state is not searchable

Review state does not surface in `lore work search`. `search-work.sh` finds
`_meta.json` fields only through its index-grep alternation block (the FTS backend
skips `_meta.json` by design). Adding `review` there was left out of committed scope
— gated items are already visible through the SessionStart digest, `lore work list`,
and the TUI. If review state should become searchable, the index-grep alternation in
`search-work.sh` is the place to extend.
