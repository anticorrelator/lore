# Step 7 capture invocation

Invoke at Step 7 after the followup report has been persisted.

```
/remember Holistic review of PR #<N> — capture: mechanism-level patterns (how the system accomplishes things structurally), structural footprint observations (component roles, integration points, what constrains changes), design rationale discovered (why the architecture is this way, what constraints drove decisions), cross-lens convergence patterns (areas where multiple lenses flagged the same concern), convention patterns observed across the codebase. Use confidence: medium for reviewer observations. Skip: findings specific to this PR, style opinions, lens-specific methodology notes. For every `lore capture` call, pass `--producer-role pr-review --protocol-slot Synthesis --work-item <slug>` (when a work item matches the PR).
```
