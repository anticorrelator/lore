## Explorer Task Spawn Template

```
Task:
  subagent_type: "general-purpose"
  model: "<selected-model>"
  team_name: "bootstrap-<SLUG>"
  name: "explorer-N"
  mode: "bypassPermissions"
  prompt: |
    You are explorer-N on the bootstrap-<SLUG> team.

    ## Project Sketch
    <embed the sketch from findings.md>

    ## Prior Knowledge
    <embed $PRIOR_KNOWLEDGE>

    ## Subsystem Structure
    <embed $DOMAIN_TREE>

    ## Mission
    Map this subsystem's **boundaries, contracts, and shapes** at architecture/subsystem scale. Use the project's own vocabulary from the sketch.

    Report on:
    - **Boundaries** — what does this subsystem own? what's outside it?
    - **Contracts at the seams** — signatures of public functions, REST/CLI/IPC surfaces, schemas, message formats, file formats, env-var/config contracts, hook/plugin registries
    - **Shapes** — core data structures, types, schemas that flow through or persist
    - **Lifecycle and ownership** — who creates/mutates/destroys state; ordering constraints; init/teardown paths
    - **Internal layering** — if the subsystem decomposes further, name the layers and what each owns
    - **Integration points** — how this subsystem talks to others (function call, event, queue, file, socket, shared store)
    - **Entry points** — top-of-stack files/symbols that anchor the map (use sparingly; prefer subsystem names over paths)

    Out of scope — do NOT report:
    - Function bodies, algorithm choices, line-level behavior
    - Style/formatting conventions
    - Gotchas, sharp edges, "things that would bite a developer" (these accrue through use, not bootstrap)
    - Test details unless tests *are* the contract

    ## Workflow
    1. TaskList → claim one (TaskUpdate owner=you, status=in_progress)
    2. TaskGet for full context
    3. Explore: README and top-level first; then entry points; then contract definitions (types, schemas, interfaces, registries). Read enough to map the shape — not every line.
    4. SendMessage to "<team-lead-name>":
       summary: "Findings: <subsystem name>"
       content: |
         **Subsystem:** <name>
         **Boundaries:** <what it owns, what's outside>
         **Contracts at the seams:** <bullets>
         **Shapes:** <bullets>
         **Lifecycle and ownership:** <bullets>
         **Internal layering:** <bullets, or "flat">
         **Integration points:** <bullets>
         **Entry points:** <minimal anchor list>
         **Observations:** <claims you're unsure of; contradictions across files; patterns that span beyond this subsystem>

       Do NOT call `lore capture`.
    5. TaskUpdate status=completed
    6. TaskList → claim next if available; done when none remain

    800–2000 chars. Architecture and subsystem scale only. Facts over opinions.
```
