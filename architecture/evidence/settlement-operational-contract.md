# Settlement Operational Contract

The settlement queue is processor-owned durable state. Producers enqueue work by
writing validated Tier 2 evidence; the TUI observes status snapshots and requests
explicit actions, but it does not own processor lifetime, leases, harness budget,
or job cleanup.

## Trigger

The live trigger is the Tier 2 evidence append path. Successful evidence rows are
the durable write surface that makes settlement work discoverable across shells,
harnesses, and future TUI sessions.

Retired trigger surfaces:

- Spec panel PTY lifetime is not a settlement lifecycle. Closing or detaching a
  terminal panel must not cancel or drain settlement work.
- `.lore-session` files are spec/follow-up session indicators only.
- Stop hooks and TaskCompleted hooks may report or remind, but they do not own
  dispatch.

## Processor Ownership

Processors own lease acquisition, execution, retry accounting, harness selection,
rate limits, and budget accounting. Multiple TUI instances should reconcile by
reloading complete status snapshots from `lore settlement status --json`; local
views must replace status rather than merge old leases or queue rows.

The TUI actions are request-only:

- `lore settlement process --once --json`
- `lore settlement pause --json`
- `lore settlement resume --json`

Each action is followed by a status reload so the durable state remains the
source of truth.

## Status JSON

The TUI consumes the Phase 1 JSON contract defensively. It expects these fields
when available:

- `enabled`, `paused`, `next_action`, `blocked_reason`
- `queue` with `ready`, `pending` or `queued`, `running`, `completed`, `failed`,
  `blocked`, and `total`
- `items` with `id`, `work_item`, `claim_id`, `task_id`, `producer_role`,
  `status`, `harness`, `attempts`, `blocked_reason`, and `next_action`
- `leases` with `id`, `item_id`, `worker_id`, `harness`, `pid`, and `expires_at`
- `harness` or `config` with `mode`, `selected`, `random`, `concurrency`,
  `launch_rate_per_minute`, `cap_remaining`, and `cap_total`
- `usage` with `state`, `cap_remaining`, `cap_total`, `rate_remaining`, and
  `started`

The parser accepts conservative aliases for in-flight Phase 1 naming, but the
panel renders only explicit operational facts and inferred next action labels.

## Harness And Rate Controls

Harness choice is a processor decision. A processor may choose active, specific,
or random mode from eligible harnesses and should launch work with the selected
per-job environment rather than mutating global harness settings.

Enabling settlement, unpausing it, raising caps, or switching to random mode must
be explicit operator action. Settings edits do not auto-start processing; the TUI
surfaces `process once`, `pause`, `resume`, and config visibility as separate,
intentional controls.
