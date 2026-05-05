# Framework Compatibility Matrix

This file is the operator-facing matrix of which Lore skills run **full**,
**partial**, **fallback**, or **unavailable** on each supported harness
(Claude Code, OpenCode, Codex). Every cell is grounded in the capability
profile in [`adapters/capabilities.json`](../adapters/capabilities.json)
and the dated vendor evidence in
[`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md).
Cells that name a degradation point at the contract that owns it
(`adapters/hooks/README.md`, `adapters/agents/README.md`).

> **Status:** First cut (T23, May 2026). The skill-capability
> manifest that drives a generated matrix lands in T21 and a
> companion regen script lands in T66; until then, the cells below
> are hand-derived from the four capability dependencies that
> matter most: `subagents`, `team_messaging`, `task_completed_hook`,
> and `model_routing.shape`. The "Why" column for every degraded
> cell names the missing capability and the fallback (or, for
> `unavailable`, the reason no fallback works).

## Support Levels

The four support levels mirror the schema's `support_levels` block:

- **full** — the skill works without behavioral compromise; every required capability has `support=full`.
- **partial** — the skill runs, but at least one required capability is `partial`, so a documented behavior shifts (e.g. lead-orchestrated fanout instead of in-flight messaging).
- **fallback** — the skill runs through a wrapper or post-hoc validator instead of a native blocking surface; protocol compliance is best-effort.
- **unavailable** — the skill cannot run on this harness; users get a degraded-status notice and must use a different harness for that workflow.

## Per-Skill Capability Dependencies

The matrix below classifies skills by their hardest required
capability. Skills that use `TeamCreate` / `SendMessage` / `Task`
spawn primitives depend on the team-orchestration capabilities;
skills that drive a single-agent flow only depend on `instructions`
and `skills` discovery (full on every harness).

| Skill                | Subagents required | Team messaging required | TaskCompleted blocking required | Multi-provider model routing required |
|----------------------|--------------------|-------------------------|---------------------------------|----------------------------------------|
| `/spec`              | yes                | yes                     | no (lead validates returned reports) | no (per-role bindings collapse on single) |
| `/implement`         | yes                | yes                     | yes (worker reports gated by hook) | no                                       |
| `/bootstrap`         | yes                | yes                     | no                                 | no                                       |
| `/renormalize`       | yes                | yes                     | no                                 | no                                       |
| `/retro`             | yes                | yes                     | no                                 | no                                       |
| `/work`              | no (single-agent)  | no                      | no                                 | no                                       |
| `/memory`            | no                 | no                      | no                                 | no                                       |
| `/remember`          | no                 | no                      | no                                 | no                                       |
| `/self-test`         | no                 | no                      | no                                 | no                                       |
| `/evolve`            | no                 | no                      | no                                 | no                                       |
| `/followup-discuss`  | no                 | no                      | no                                 | no                                       |
| `/pr-review`         | yes (lens fanout)  | no (lead-only aggregation) | no                              | no                                       |
| `/pr-self-review`    | yes                | no                      | no                                 | no                                       |
| `/pr-create`         | no                 | no                      | no                                 | no                                       |
| `/pr-revise`         | no                 | no                      | no                                 | no                                       |
| `/pr-pair-review`    | no                 | no                      | no                                 | no                                       |
| Single-lens reviews (`/pr-{correctness,security,blast-radius,test-quality,interface-clarity,regressions,thematic,user-impact}`) | no | no | no | no |
| `/codex-plan-review` | no (delegates to codex CLI) | no                | no                                 | no                                       |
| `/codex-pr-review`   | no (delegates to codex CLI) | no                | no                                 | no                                       |
| `/codex-design-review` | no (delegates)            | no                | no                                 | no                                       |

## Compatibility Matrix

The classification below applies the dependency table above against
each harness's capability profile. Single-agent skills that depend
only on `instructions` and `skills` (the "no" rows above) are
**full** on every harness; they are summarized in the "Single-agent
skills" row at the bottom rather than enumerated.

| Skill                | Claude Code | OpenCode  | Codex     |
|----------------------|-------------|-----------|-----------|
| `/spec`              | full        | partial   | partial   |
| `/implement`         | full        | partial   | partial   |
| `/bootstrap`         | full        | partial   | partial   |
| `/renormalize`       | full        | partial   | partial   |
| `/retro`             | full        | partial   | partial   |
| `/work`              | full        | full      | full      |
| `/pr-review`         | full        | full      | full      |
| `/pr-self-review`    | full        | full      | full      |
| `/codex-plan-review` | full        | full      | full      |
| `/codex-pr-review`   | full        | full      | full      |
| Single-agent skills  | full        | full      | full      |

### Why each non-`full` cell degrades

Each cell that is not `full` is degraded for a specific reason
documented below. Adapters MUST surface a one-line stderr notice
matching the "Degraded notice" column when the skill runs in that
mode.

| Skill           | Harness   | Mode      | Why (capability gap)                                                                                                       | Fallback                                                                                                              | Degraded notice                                                                |
|-----------------|-----------|-----------|---------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| `/spec`         | OpenCode  | partial   | `team_messaging=none` — no native SendMessage equivalent.                                                                 | Lead-orchestrated fanout: workers run in parallel without inter-agent messaging; lead aggregates returned reports.    | `[lore] degraded: /spec via lead-orchestration (team_messaging=none)`           |
| `/spec`         | Codex     | partial   | `team_messaging=none` — same as OpenCode.                                                                                  | Same as OpenCode.                                                                                                     | `[lore] degraded: /spec via lead-orchestration (team_messaging=none)`           |
| `/implement`    | OpenCode  | partial   | `team_messaging=none` AND `task_completed_hook=fallback` — no in-flight messaging, no native worker-completion blocking. | Lead-orchestrated fanout + lead-side validator (rejects worker reports missing required structure).                   | `[lore] degraded: /implement via lead-validator (task_completed_hook=fallback)` |
| `/implement`    | Codex     | partial   | Same as OpenCode.                                                                                                          | Same as OpenCode.                                                                                                     | Same as OpenCode.                                                              |
| `/bootstrap`    | OpenCode  | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /bootstrap via lead-orchestration (team_messaging=none)`      |
| `/bootstrap`    | Codex     | partial   | Same.                                                                                                                      | Same.                                                                                                                 | Same.                                                                          |
| `/renormalize`  | OpenCode  | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /renormalize via lead-orchestration (team_messaging=none)`    |
| `/renormalize`  | Codex     | partial   | Same.                                                                                                                      | Same.                                                                                                                 | Same.                                                                          |
| `/retro`        | OpenCode  | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /retro via lead-orchestration (team_messaging=none)`          |
| `/retro`        | Codex     | partial   | Same.                                                                                                                      | Same.                                                                                                                 | Same.                                                                          |

The `/pr-review` family is `full` on every harness because its lens
fanout uses lead-only aggregation today — no skill in that family
relies on `team_messaging` or `task_completed_hook`. If a future
revision adds inter-lens messaging, this matrix re-classifies them.

### Why no skill is `unavailable` today

Every Lore skill has a working fallback path on every supported
harness. The candidates for `unavailable` would be:

- A skill that hard-required `task_completed_hook=full` with no
  fallback (would force `unavailable` on OpenCode/Codex). Today's
  `/implement` keeps protocol compliance via the lead-side
  validator — see [`adapters/agents/README.md`](../adapters/agents/README.md)
  "Completion Enforcement Degradation Modes" (T32).
- A skill that hard-required `plugin_runtime=full` (would force
  `unavailable` on Claude Code and Codex). No such skill exists; the
  OpenCode plugin (`adapters/opencode/lore-hooks.ts`, T26) is an
  adapter, not a skill.
- A skill that hard-required `mcp=full` for non-optional behavior
  (no such skill today).

If T21's skill-capability manifest reveals a hard requirement that
breaks one of the supported harnesses, that skill flips to
`unavailable` here and the `/<skill>` SKILL.md gains a
"Harness compatibility" section listing supported harnesses.

## Where to file follow-ups

- **Vendor capability changes** (new hooks, dropped hooks, subagent
  semantics shift) → update
  [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)
  with a fresh `Retrieved:` date, then flip the matching
  [`adapters/capabilities.json`](../adapters/capabilities.json) cell,
  then re-grade this matrix. The flow is intentional: the matrix
  must never be the canonical source for capability state — it is a
  view over capabilities.json, not a peer.
- **New skills added under `skills/`** — re-run the dependency table
  scan (today the four capabilities surveyed are `subagents`,
  `team_messaging`, `task_completed_hook`, `model_routing.shape`)
  and add a row. T21's manifest will make this mechanical.
- **A skill whose degradation note doesn't match this table** —
  the adapter is the bug. Fix the stderr notice, not the doc.

## Related documents

- [`adapters/capabilities.json`](../adapters/capabilities.json) — capability profile per harness (closed-set, evidence-gated).
- [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md) — dated vendor evidence backing every non-`none` cell.
- [`adapters/hooks/README.md`](../adapters/hooks/README.md) — hook adapter contract (lifecycle events, dispatch shape).
- [`adapters/agents/README.md`](../adapters/agents/README.md) — orchestration adapter contract (spawn, wait, completion enforcement).
- [`docs/codex-migration.md`](codex-migration.md) — operator note on the April 2026 Codex hooks update.
