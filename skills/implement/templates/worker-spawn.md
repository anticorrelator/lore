# Worker Spawn Template

Two spawn routes. **Default is a same-harness Claude worker.** The codex-routed route activates **only on explicit user or plan direction** (e.g. the user asked to route implementation to Codex, or the plan names Codex workers) — never silently inherited. Before dispatching the codex route, confirm the resolved worker model against the stated intent; if they disagree, surface it rather than dispatch.

## Default route — same-harness worker

Per-spawn model selection routes through the adapter's `resolve_model_for_role worker implement` operation. The ceremony argument `implement` lets a `ceremony_roles.implement.worker` binding win over the plain `roles.worker` binding; with no ceremony binding set, resolution is identical to the role-only form. On Claude Code the adapter returns the model id the lead passes to `TaskCreate`; it validates the binding against the active framework's `model_routing.shape` and rejects mismatches without silent fallback.

```
WORKER_MODEL=$(bash "$ADAPTER" resolve_model_for_role worker implement)

Task:
  subagent_type: "general-purpose"
  model: "$WORKER_MODEL"
  team_name: "impl-<slug>"
  name: "worker-N"
  mode: "bypassPermissions"
  prompt: |
    <contents of the worker agent template with {{template}} variables resolved>
    <if advisors: contents of advisory-consultation.md with {{advisors}} resolved>
```

## Codex-routed route — chaperone worker (user/plan-directed only)

The Task tool spawns Claude-native subagents only, so a Codex implementation worker is a chaperone: a cheap Claude subagent (`agents/codex-worker.md`) whose body drives `codex exec` and relays the result. Spend spreads because the chaperone sits blocked on the Codex call at cheap-tier cost while Codex burns the implementation tokens.

Pick the chaperone's Claude model from the lowest validated claude-code tier. `model_routing.tiers` is ordered **cheapest-first (ascending capability)**, so the first entry is the cheapest validated alias.

```
source ~/.lore/scripts/lib.sh
CHAPERONE_MODEL=$(framework_model_routing_tiers claude-code | head -n1)
```

**Empty-tiers handling:** an empty `tiers` array means claude-code has no validated alias ladder — do not guess an alias (a wrong alias fails only at spawn time). Omit the `model:` field so the chaperone inherits the session default model. The chaperone still routes the implementation to Codex; only its own (cheap) tier selection is lost.

```
# CHAPERONE_MODEL is empty when claude-code has no validated tiers.

Task:
  subagent_type: "general-purpose"
  model: "$CHAPERONE_MODEL"     # omit this line entirely when CHAPERONE_MODEL is empty
  team_name: "impl-<slug>"
  name: "worker-N"
  mode: "bypassPermissions"
  prompt: |
    <contents of agents/codex-worker.md with {{template}} variables resolved>
```

The chaperone resolves the Codex-side worker binding itself via `LORE_FRAMEWORK=codex resolve_model_for_role worker implement` and reports the effective Codex model back — that resolved model is what to confirm against the user/plan's stated intent. The chaperone marks its result `degraded` when Codex returns no parseable report; on a degraded return, re-dispatch the task as a default-route same-harness worker (codex routing is an optimization, never a dependency).
