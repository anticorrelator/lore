# Advisor Spawn Template (opt-in route)

Use this when `**Advisors:**` declares one or more entries with `mode: persistent`. Persistent advisors remain active for the entire implementation session and are shut down alongside workers in Step 4.

For each persistent advisor:

1. **Build domain context** — find the `## Investigations` section(s) in `plan.md` whose topic relates to the advisor's domain scope. Extract the relevant investigation entry (findings, verified assertions, key files, implications) and format it as the advisor's domain baseline.

2. **Spawn the advisor** using the `advisor` agent template (resolve via `resolve_agent_template advisor`; on Claude Code that path is `~/.claude/agents/advisor.md`) with these template injections:
   - `{{team_name}}` → `impl-<slug>`
   - `{{advisor_domain}}` → the advisor's domain scope
   - `{{domain_context}}` → the investigation excerpt from sub-step 1
   - `{{template_version}}` → `$ADVISOR_TEMPLATE_VERSION`

   Per-spawn model selection for advisors routes through `bash "$ADAPTER" resolve_model_for_role advisor`. The Claude Code path produces a `delegate:TaskCreate` directive with the resolved model id; opencode honors `provider/model` syntax for advisor bindings independently of worker bindings.

   ```
   ADVISOR_MODEL=$(bash "$ADAPTER" resolve_model_for_role advisor)

   Task:
     subagent_type: "general-purpose"
     model: "$ADVISOR_MODEL"
     team_name: "impl-<slug>"
     name: "<advisor-name>"
     mode: "bypassPermissions"
     prompt: |
       <contents of the advisor agent template with {{template}} variables resolved>
   ```

3. **Write execution log entry** — log each spawn. Pass `--template-version "$ADVISOR_TEMPLATE_VERSION"` because the content logged is sourced from the advisor template:

   ```bash
   printf 'Advisor spawned: %s\nDomain: %s\nMode: %s\n' \
     "<advisor-name>" "<domain scope>" "persistent" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
   ```
