# Settlement TUI Panel

The Settlement panel is a first-class root TUI state beside Work, Follow-Ups, and
Knowledge. It is reached with `t`; `w` and `f` return to Work and Follow-Ups.
The root `t` key is handled before terminal panel routing so a focused PTY does
not consume settlement navigation.

## Panel Role

The panel is an operational console:

- observe `lore settlement status --json`
- request `process --once`, `pause`, and `resume`
- show config and budget controls without editing them
- replace the whole local snapshot whenever status changes

It does not run processors in-process, manage leases, mutate harness choice, or
use spec panel PTYs as job lifetime.

## Rendered Signals

The compact panel shows:

- enabled and paused state
- queue totals for ready, pending, running, complete, failed, blocked, and total
- active lease count and lease rows
- selected harness, harness mode, random mode, concurrency, launch rate, and cap
  remaining
- usage or budget state
- next action or blocked reason
- visible queue rows with work item, claim, task, role, harness, status, and
  per-item blocked reason when present
- a fixed compact `Last settled` section below the queue rows and above active
  leases, sourced from `last_settled` with a tolerant fallback to
  `terminal_items`

The status bar advertises explicit controls:

- `p` process one batch
- `P` pause
- `R` resume
- `v` show config
- `w` work
- `f` follow-ups

Background notices use compact bracketed feedback such as `[settlement] paused`
or `[settlement] not dispatched: disabled`.
Repeated polling errors are rendered in the panel status instead of taking down
the TUI.

## Polling And Reconciliation

Startup and root polling include a settlement status load. Status snapshots are
complete replacements. This is important for multi-instance use: if another TUI
or a processor acquires/releases a lease, the next snapshot replaces stale local
lease rows rather than merging them.

Action commands parse JSON results if present, including `dispatched:false`
reasons from `process --once --json`, apply any nested status snapshot, and then
reload status from the CLI. The reload keeps command output from becoming a
second source of truth.

The queue rows represent the processor's current schedulable working set rather
than an append-only global backlog. The backlog remains durable in work-item
`task-claims.jsonl` files; status snapshots publish the active rebatched queue,
active leases, and the most recent terminal result as `last_settled`. The TUI
does not recompute batches, score relevance, or drain terminal queue entries.

## Retired Mechanisms

The panel intentionally does not integrate with:

- spec panel PTY start, detach, resize, or cleanup paths
- `.lore-session` session files
- Stop-hook or TaskCompleted-hook settlement dispatch

Those paths are terminal/session UX and reporting surfaces. Settlement
processing survives transient TUI views because durable evidence and processor
state own the lifecycle.
