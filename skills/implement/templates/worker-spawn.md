# Worker Spawn Template

Two spawn routes. **Default is a same-harness Claude worker.** The codex-routed route activates **only on explicit user or plan direction** (e.g. the user asked to route implementation to Codex, or the plan names Codex workers) — never silently inherited. Before dispatching either route, confirm the resolved worker model against the stated intent; if they disagree, surface it rather than dispatch.

## Per-task judgment class → worker role

Each batch entry from `lore impl open` / `lore impl next-batch` carries a `judgment_class` (`mechanical | standard | judgment-dense`, or `null` on unannotated/legacy tasks). It selects the class-qualified worker role to resolve the model from:

| judgment_class        | worker role            |
|-----------------------|------------------------|
| `mechanical`          | `worker-mechanical`    |
| `standard` / `null`   | `worker`               |
| `judgment-dense`      | `worker-judgment-dense`|

A class role with no binding anywhere resolves identically to plain `worker` (registry `fallback_role`), so routing is byte-identical to the pre-class behavior until a user binds a class role.

**Group the batch by role before spawning:** tasks that resolve the same role can share a model resolution; distinct classes get distinct workers. When same-file serialization merges tasks of different classes onto one worker (the `chain_class` on a `next-batch` collision group), spawn that chain at its `chain_class` — the max class present (judgment-dense > standard > mechanical) — so judgment-dense work never lands on a cheaper binding.

**A user model pin at dispatch beats every class binding.** If the user pinned a model for this run, that model applies to all classes regardless of `judgment_class`; do not resolve per-class bindings. Either way, confirm the effective per-class models against the user's stated intent before spawning — `lore impl start` prints the three class bindings for exactly this check.

## Default route — same-harness worker

Per-spawn model selection routes through the adapter's `resolve_model_for_role <role> implement` operation, where `<role>` is the class-qualified role for the group. The ceremony argument `implement` lets a `ceremony_roles.implement.<role>` binding win over the plain `roles.<role>` binding; with no ceremony binding set, resolution is identical to the role-only form. On Claude Code the adapter returns the model id the lead passes to `TaskCreate`; it validates the binding against the active framework's `model_routing.shape` and rejects mismatches without silent fallback.

```
# WORKER_ROLE is the class-qualified role for this group: worker-mechanical,
# worker, or worker-judgment-dense (see the mapping table above).
WORKER_MODEL=$(bash "$ADAPTER" resolve_model_for_role "$WORKER_ROLE" implement)

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

The class-qualified role is passed to the chaperone as `{{worker_role}}` so it resolves the Codex-side binding for the right class. Resolve it the same way (mapping table above): `worker` for standard/null, `worker-mechanical`, or `worker-judgment-dense`; for a merged same-file chain use the chain's max class.

```
# CHAPERONE_MODEL is empty when claude-code has no validated tiers.

Task:
  subagent_type: "general-purpose"
  model: "$CHAPERONE_MODEL"     # omit this line entirely when CHAPERONE_MODEL is empty
  team_name: "impl-<slug>"
  name: "worker-N"
  mode: "bypassPermissions"
  prompt: |
    <contents of agents/codex-worker.md with {{template}} variables resolved,
     including {{worker_role}} set to the class-qualified role for this task>
```

The chaperone resolves the Codex-side worker binding itself via `LORE_FRAMEWORK=codex resolve_model_for_role {{worker_role}} implement` and reports the effective Codex model back — that resolved model is what to confirm against the user/plan's stated intent. The chaperone marks its result `degraded` when Codex returns no parseable report; on a degraded return, re-dispatch the task as a default-route same-harness worker (codex routing is an optimization, never a dependency).
