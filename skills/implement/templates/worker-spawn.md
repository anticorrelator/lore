# Worker Spawn Template

Per-spawn model selection routes through the adapter's `resolve_model_for_role worker` operation, which on Claude Code returns the model id the lead passes to `TaskCreate`. The adapter validates the binding against the active framework's `model_routing.shape` and rejects mismatches without silent fallback.

```
WORKER_MODEL=$(bash "$ADAPTER" resolve_model_for_role worker)

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
