---
name: spec
description: "Create a technical specification — `/spec short` for single-pass plans, `/spec` for full team-based investigation"
user_invocable: true
argument_description: "[short] [--yes] [--model <id>] [name or description] — existing work item name, or a freeform description to start from. `--model` overrides every per-role binding (lead/researcher/advisor) for this invocation only; otherwise per-role models come from `resolve_model_for_role`."
---

# /spec Skill

Produces a `plan.md` inside a work item's `_work/<slug>/` directory.

## Short Flow (`/spec short`)

Single-agent path: the spec-lead reads key files directly (Step 2 `--short` branch) and drafts the plan without dispatching a researcher team. For well-understood, small-scope work where parallel investigation is unnecessary overhead.

The `--short` conditional activates at Step 2 only. From Step 3 onward, short and full paths share every step: collect findings and emit Tier-2 artifacts, strategy gate, synthesis, design ceremony, task review, post-research extraction, finalization, post-plan ceremony.

## Full Flow (`/spec`)

Team-based divide-and-conquer: the spec-lead composes an investigation plan table (Step 2 full branch), dispatches parallel researcher agents, collects findings, emits Tier-2 artifacts, and then synthesizes — following the shared downstream steps. For complex or uncertain-scope work.

> **Sequencing constraint:** Do not dispatch research agents before completing Step 2. The investigation plan is a completeness checklist and user approval gate, not just a dispatch list.

---

### Step 1: Parse and resolve (both modes)

1. Parse arguments:
   - If first arg after `/spec` is `short`, the investigation step (Step 2) uses the **short** branch.
   - If `--yes` is present, skip all interactive confirmation gates (auto-proceed through investigation plan confirmation, strategy gate, confirm understanding, and task review).
   - If `--model <id>` is present, export per-role overrides for the duration of this skill: `export LORE_MODEL_LEAD=<id> LORE_MODEL_RESEARCHER=<id> LORE_MODEL_ADVISOR=<id>` (one shot — no env mutation outside the skill). Otherwise let `resolve_model_for_role` (lib.sh) pick the per-role binding from the active framework's role map. Per-role resolution honors the precedence: env override → per-repo `.lore.config` → user `framework.json` roles → `roles.default`. Multi-provider harnesses (opencode) honor `provider/model` syntax; single-provider harnesses (claude-code, codex) accept bare model ids only — `validate_role_model_binding` rejects mismatches.
   - The remaining text is the **input**.

2. Resolve the work path:
   ```bash
   lore resolve
   ```
   Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

3. Compute template versions for provenance. Resolve agent template paths via `resolve_agent_template` (lib.sh helper) so the canonical lore-repo `agents/<name>.md` is hashed regardless of which harness is active. The skill template path uses the active harness's skills install path — on Claude Code that's `~/.claude/skills/`, on Codex it's `~/.codex/skills/` (per `resolve_harness_install_path skills`):
   ```bash
   source ~/.lore/scripts/lib.sh
   SKILLS_DIR=$(resolve_harness_install_path skills)
   LEAD_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$SKILLS_DIR/spec/SKILL.md")
   RESEARCHER_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$(resolve_agent_template researcher)")
   ADVISOR_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$(resolve_agent_template advisor)")
   ```
   If any call fails, fall through with an empty string. Registration into `$KDIR/_scorecards/template-registry.json` is handled by `scorecard-append.sh` on first use. Reports without a `Template-version:` field warn+pass rather than fail — the CC-01 backwards-compat gate enables incremental template migration without blocking legacy emitters.

4. Try to resolve input as an existing work item (fuzzy match or branch inference, same algorithm as `/work`, including archive fallback):
   - **If resolved item is tagged `[archived]`:** Warn the user and wait for explicit confirmation before continuing.
   - **If resolved** → load the work item:
     - If `plan.md` exists with synthesis already complete (Design Decisions + Phases present), skip to Step 5.1 (Confirm understanding). If a `## Strategy` section exists, load it silently as shaping context.
     - If `plan.md` exists with `## Investigations` and completed findings but no synthesis yet, skip to synthesis (Step 5). If a `## Strategy` section exists, load it silently and use it as shaping context — do not re-prompt.
     - If it has investigations but `## Open Questions` needing follow-up, dispatch targeted follow-ups.
     - If `plan.md` exists but is incomplete, present for discussion/editing. If no `## Strategy` section exists and synthesis has not yet run, offer the strategy gate (Step 4) before synthesizing.
     - If no `plan.md`, continue to Step 2.
   - **If NOT resolved** → treat input as freeform description, go to Goal Refinement.
   - **If no input at all** → try branch inference; if no match, ask what they want to spec.

### Step 1b: Goal Refinement (new work only)

When the input is a freeform description rather than an existing work item:

1. Restate your understanding in 1-2 sentences.
2. Ask 2-4 clarifying questions using `AskUserQuestion`. Target scope boundaries, constraints, and approach preferences. Do NOT ask questions answerable by reading the codebase.
3. Incorporate answers into a refined goal statement.
4. Create the work item: derive a slug from the description, run the `/work create` flow.
5. Continue to Step 2.

If the user's description is already specific enough (clear scope, stated constraints, obvious approach), skip to step 4 — don't ask questions for the sake of asking.

---

### Step 2: Investigation — conditional on `--short`

### Step 2a: Short branch (`--short` flag present)

1. From conversation context and the work item, identify 3-8 key files to read.
2. Search the knowledge store: `lore search "<topic>" --type knowledge --json --limit 5`. Read relevant entries.
3. Check the knowledge store index for relevant domain files.
4. Read the files yourself — do NOT spawn subagents.
5. Note key findings as you go.
6. **Skill and agent discovery** — after reading key files, scan for relevant skills and agents:
   - Glob `<skills_dir>/*/SKILL.md` — read the YAML frontmatter (`name`, `description`) and first section of each. Resolve `<skills_dir>` via `resolve_harness_install_path skills` (typically `~/.claude/skills` on Claude Code; differs on Codex).
   - Glob `<agents_dir>/*.md` — read each agent template name and opening description. Resolve `<agents_dir>` via `resolve_harness_install_path agents` (typically `~/.claude/agents` on Claude Code).
   - Match the work item title, description, and key findings against skill/agent names using keyword overlap.
   - Deep-read any SKILL.md or agent template that shows strong overlap with the work item domain.
   - Emit a skill discovery block (mandatory):
     ```
     **Skill discovery:**
     Considered: <comma-separated list of all skills checked>
     Matched: <skill-name — rationale> (or "none")
     ```
7. Present a context summary and offer the strategy gate (Step 4 below). **If `--yes`, skip the strategy prompt.**

### Step 2b: Full branch (default, no `--short` flag)

1. From the feature description, identify 3-7 focused investigation questions. Each should target a specific codebase concern, be answerable by exploring files, and be independent enough to run in parallel.
2. **Always include** one mandatory fixed investigation: **Skill and agent applicability** — which installed skills and agent templates should be invoked during **implementation** of this work item. Key files: `<skills_dir>/*/SKILL.md`, `<agents_dir>/*.md` (resolve via `resolve_harness_install_path skills` / `resolve_harness_install_path agents`). This counts toward the 3-7 total.
3. Check the knowledge store index for file hints per investigation.
4. Assess complexity for each investigation: **simple** (1-2 files), **moderate** (3-5 files), **complex** (6+ files or cross-cutting).
5. Present the Investigation Plan to the user:
   ```
   ## Investigation Plan

   | # | Area / Topic | Key Files | Complexity |
   |---|-------------|-----------|------------|
   | 1 | Skill and agent applicability *(mandatory — do not remove)* | `<skills_dir>/*/SKILL.md`, `<agents_dir>/*.md` | simple |
   | 2 | <topic>     | `file1`, `file2` | simple |
   ...

   Proceed, or adjust?
   ```
6. Wait for user confirmation. If the user requests adjustments, revise and re-present. **If `--yes`, dispatch immediately without confirmation.**
7. **Create team via orchestration adapter.** Resolve the active framework's orchestration adapter at `adapters/agents/<framework>.sh` and treat its `spawn` / `wait` / `send_message` / `collect_result` / `shutdown` subcommands as the dispatch contract for every team operation in this skill. The adapter emits `delegate:<tool> ...` directives that the skill body translates into the harness's native tool calls — on Claude Code that means `TeamCreate` / `TaskCreate` / `SendMessage` / `TaskList` / `TaskGet`; on opencode/codex the same directives map to plugin runtime / subagent spawn APIs. Before creating the team, query the adapter's capability gates:
   ```bash
   ADAPTER="$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh"
   ENFORCEMENT=$(bash "$ADAPTER" completion_enforcement)  # native_blocking | lead_validator | self_attestation | unavailable
   TEAM_MESSAGING=$(framework_capability team_messaging)  # full | partial | fallback | none
   ```
   - `ENFORCEMENT` shapes the retry/abandon decision in Step 3 (per `adapters/agents/README.md` §"Completion Enforcement Degradation Modes").
   - `TEAM_MESSAGING=none` collapses the skill to lead-only orchestration: skip team creation, do not spawn researchers, fall back to the `--short` branch path. The skill requires `team_messaging=full` per `adapters/capabilities.json.skills.spec.requires`; the gate fires here.

   For Claude Code (the default path), team creation is the native `TeamCreate` tool:
   ```
   TeamCreate: team_name="spec-<slug>", description="Investigating <work item title>"
   ```
   The opencode/codex adapters emit `delegate:plugin_team_init` / `delegate:codex_subagent_init` respectively (see `adapters/agents/README.md` §"Per-Harness Mapping"); the skill body calls the documented translation when running under those frameworks.
8. Read your team lead name from the active harness's teams install path (resolved via `resolve_harness_install_path teams`; typically `~/.claude/teams/` on Claude Code), at `<teams_dir>/spec-<slug>/config.json`. Frameworks where `install_paths.teams=unsupported` (e.g. codex today) cannot persist team config — the skill reads `team_messaging=fallback` and proceeds with a lead-side handle map instead of the on-disk config.
9. Create investigation tasks — for each question, route through the adapter's `spawn` operation:
   ```bash
   RESEARCHER_MODEL=$(bash "$ADAPTER" resolve_model_for_role researcher)
   bash "$ADAPTER" spawn researcher "<task_prompt>" "$RESEARCHER_MODEL"
   # → delegate:TaskCreate role=researcher model=<id>  (claude-code)
   ```
   On Claude Code, the lead model invokes `TaskCreate` with the directive's role/model; the spawn directive carries one `TaskCreate` per question with full question, context, file hints, and expected report format.
   - For the mandatory "Skill and agent applicability" investigation: include instructions to evaluate implementation-phase applicability (not the investigation phase), read actual SKILL.md files, and report `**Matched skills:**` / `**Matched agents:**` blocks after `**Implications:**`.
10. Pre-fetch knowledge for each investigation:
    ```bash
    PRIOR_KNOWLEDGE=$(lore prefetch "<investigation topic>" --format prompt --limit 5 --scale-set=<bucket>)
    ```
11. **Skill-applicability scan and advisor provisioning:**
    a. Scan the skill list in your system prompt. Emit a skill discovery block (mandatory):
       ```
       **Skill discovery:**
       Considered: <comma-separated list of all skills checked>
       Matched: <skill-name — rationale> (or "none")
       ```
    b. If applicable skills are found:
       - For each skill, read its SKILL.md file.
       - Spawn an advisor using `agents/advisor.md` with template injections: `{{team_name}}` → `spec-<slug>`, `{{advisor_domain}}` → skill name + scope, `{{domain_context}}` → SKILL.md content.
       - Build `$ADVISORY_MIXIN` from `scripts/agent-protocols/advisory-consultation.md` with `{{advisors}}` resolved. All skill-backed advisors use `on-demand` mode.
    c. If no applicable skills: set `$ADVISORY_MIXIN` to empty.
12. Spawn researcher agents — `min(investigation_count, 4)` in a single message via the orchestration adapter's `spawn` operation. Use the `researcher` agent template (resolve via `resolve_agent_template researcher`; on Claude Code that path is `~/.claude/agents/researcher.md`) with template injections: `{{team_name}}` → `spec-<slug>`, `{{team_lead}}` → lead name, `{{prior_knowledge}}` → `$PRIOR_KNOWLEDGE`, `{{template_version}}` → `$RESEARCHER_TEMPLATE_VERSION`. If `$ADVISORY_MIXIN` is non-empty, append it after the resolved researcher template content with a blank line separator. Per-spawn model selection routes through `resolve_model_for_role researcher` (or the explicit override set in Step 1.1 from `--model`); the adapter validates the role→model binding against the active framework's `model_routing.shape` and rejects mismatches without silent fallback.

---

### Step 3: Collect findings and emit Tier-2 artifacts

As researcher messages arrive (or after direct file reading in short branch):

1. Write each finding to the `## Investigations` section of `plan.md` using the investigation entry format from the Plan.md Template below.
2. **Preserve `**Findings:**` verbatim** — copy findings exactly as reported.
3. **Preserve `**Observations:**` verbatim** — copy researcher observations exactly as reported. Do not rephrase, merge, or summarize. These are mechanism-level patterns, design rationale, and structural footprint signals that feed the Step 5.4 capture step.
4. **Emit Tier-2 artifacts** — for each researcher assertion (full branch) or lead-observed task-scoped grounding claim (short branch):
   - Format the claim as a JSON row with the 7-field schema (`claim`, `file`, `line_range`, `exact_snippet`, `normalized_snippet_hash`, `falsifier`, `significance`) plus producer/template provenance. See `architecture/artifacts/tier2-evidence-schema.md` for the full schema.
   - Append the row via the sole-writer:
     ```bash
     echo '<json-row>' | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>
     ```
     `evidence-append.sh` validates the row via `validate-tier2.sh` before appending to `$KDIR/_work/<slug>/task-claims.jsonl`. Direct writes to `task-claims.jsonl` bypass validation and are treated as corrupt.
   - **On validation failure:** `evidence-append.sh` exits non-zero. Either fix the row and retry, or log the failure to `execution-log.md` and proceed. Schema-valid absence is acceptable; silent corrupt writes are not.
   - After successful append, write a human-readable mirror entry to `$KDIR/_work/<slug>/evidence.md`. Do not write a mirror entry for a row that failed validation.
   - **Absence semantics:** if no assertions or lead-observed task claims exist, both `task-claims.jsonl` and `evidence.md` may be absent — absence means "no Tier-2 claims captured this session," not "work was fully verified."

5. **Full branch only:** When all investigation tasks are complete:
   - Send shutdown requests via the orchestration adapter's `shutdown` operation: `bash "$ADAPTER" shutdown <handle> true` for each researcher and advisor handle. On Claude Code this expands to `delegate:SendMessage handle=<id> type=shutdown_request approve=true` which the lead invokes as the native `SendMessage` tool. On harnesses where `team_messaging=none`, the adapter returns `unsupported` and the skill body relies on harness-native session cleanup (Codex subagent-stop, OpenCode plugin-runtime kill).
   - Run `TeamDelete` to clean up the team (Claude Code only; opencode/codex's adapter does not require an explicit teardown — the runtime owns lifecycle).

6. Append an investigation summary to `execution-log.md`:
   ```bash
   printf 'Investigations: %d\nTopics: %s\n' \
     "<N>" "<comma-separated investigation topics>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source spec-lead --template-version "$RESEARCHER_TEMPLATE_VERSION"
   ```

---

### Step 4: Strategy gate

Before synthesizing, offer the user a chance to shape the plan.

1. Check `plan.md` for a `## Strategy` section. If found, read it silently and proceed with it as shaping context — do not re-prompt.
2. If no `## Strategy` exists, present a context summary (either compressed investigation summary for full branch, or key-findings summary for short branch) and prompt:
   ```
   Any strategy to apply to the plan? (Enter to skip)
   ```
3. If the user skips, proceed to Step 5 unchanged.
4. If the user supplies strategy, append to `plan.md` immediately:
   ```markdown
   ## Strategy
   <user's strategy verbatim>
   ```
   Then proceed with the strategy as additional shaping context.

**Always present the prompt — do not skip because scope seems clear. Exception: if `--yes` was passed, skip this step entirely.**

### Step 4.9: Read surfaced_concerns (if present)

Before synthesizing, check for worker-surfaced concerns:

```bash
KDIR=$(lore resolve)
SC_FILE="$KDIR/_work/<slug>/surfaced_concerns.jsonl"
[ -f "$SC_FILE" ] && cat "$SC_FILE"
```

If present and non-empty, read each pending entry (no `status` field = unresolved):
- Scope boundary / unresolved question → add to `## Open Questions`
- Dubious design assumption → add to `## Design Decisions` open question or refine the relevant decision
- Architectural observation → treat as additional research finding for Step 5

This step is **read-only** — do not modify `surfaced_concerns.jsonl`.

---

### Step 5: Synthesize — abstract plan

Produce the conceptual frame first before committing to phase breakdown.

1. **Goal** — what we're building/changing and why (1 paragraph).
2. **Design Decisions** — use the `### DN: Title` format from the template. Each decision requires `**Decision:**`, `**Rationale:**`, `**Alternatives considered:**`, and `**Applies to:**` fields. Number decisions sequentially (D1, D2, ...).
3. **Draft Narrative** — synthesize goal and chosen approach into a `## Narrative` section (1-2 paragraphs). Place it after `## Goal`. Write for a reader who wants the story without reading all sections. Draw from Goal and Design Decisions. Omit file paths and task lists.
4. **Architecture Diagram (conditional)** — after drafting Narrative, include a `## Architecture Diagram` section when the work touches 2+ distinct modules.

   Read diagram conventions:
   ```bash
   cat ~/.lore/claude-md/review-protocol/followup-template.md
   ```

   Diagram types: call chain (invocation paths), state machine (state transitions), data flow (data transforms). Write a plain-text ASCII diagram inside a fenced code block using box-drawing characters. Do NOT use Mermaid or other diagram DSLs — the TUI renderer cannot interpret them.

5. **Consumer-contradiction emission checkpoint** — before finalizing synthesis, check each prefetched commons entry for contradictions against code observed during investigation:

   ```bash
   if [ -x ~/.lore/scripts/consumption-contradiction-append.sh ]; then
     # For each prefetched entry where investigation directly falsifies a specific claim:
     bash ~/.lore/scripts/consumption-contradiction-append.sh \
       --work-item <slug> \
       --entry-id <entry-path> \
       --claim "<exact-claim-text>" \
       --falsifying-evidence "<file:line + snippet>" \
       --producer-role spec-lead \
       --protocol-slot Synthesis \
       --template-version "$LEAD_TEMPLATE_VERSION" \
       --captured-at-branch <branch> \
       --captured-at-sha <sha> \
       --captured-at-merge-base-sha <merge-base>
     # Rows emit to $KDIR/_work/<slug>/consumption-contradictions.jsonl
     # lore audit picks these up as priority-input (not probabilistic sampling)
   else
     # consumption-contradiction-append.sh not yet installed (consumer-contradiction-channel follow-on pending)
     bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source spec-lead \
       --template-version "$LEAD_TEMPLATE_VERSION" <<< \
       "consumer-contradiction emission skipped — consumption-contradiction-append.sh not found"
   fi
   ```

   Emission is non-blocking — synthesis continues immediately after emitting.

6. Present the abstract plan (Goal, Design Decisions, Narrative, Architecture Diagram) to the user for review.

**Discovery findings integration:**
- **Related skills block:** If the discovery researcher (full branch) or Step 2 skill scan (short branch) reported matched skills, add a `**Related skills:**` block to the `## Context` or `## Investigations` section:
  ```
  **Related skills:**
  - /skill-name — why this skill is relevant to this work item
  ```
- **Advisor declarations:** For each matched skill whose domain overlaps with a phase's scope, consider adding an `**Advisors:**` entry. Set mode based on phase complexity — `must-consult` if the skill defines invariants workers must respect, `on-demand` otherwise.

### Step 5a: Design ceremony evaluation

**Ceremonies always run.** No flag skips this step; no flag is required to run it. Don't ask whether to invoke them — invoke. Judgment applies to acting on the output, not to running the step.

```bash
EVALUATORS=$(lore ceremony get spec-design)
```
If non-empty JSON array, for each skill name in the array:
```
/<skill-name> <slug>
```
This evaluates the abstract plan. If WEAK or MISSING areas are identified, revise the abstract plan before proceeding to Step 5b. No evaluators are registered by default — opt-in via `lore ceremony add spec-design <skill>`.

### Step 5b: Synthesize — concrete plan

Draft concrete implementation sections on top of the approved abstract plan:

1. **Phases** — concrete implementation phases with tasks, file paths, objectives. For each phase, include `**Knowledge context:**`, `**Tasks:**` (checkbox lines), optional `**Retrieval directive:**`, optional `**Advisors:**`, optional `**Verification:**`, and optional `**Scope:**` blocks.

   **Plan-as-unit rule.** A plan is **one** phase by default. Each additional phase is a separate `/implement` worker batch with its own dispatch ceremony — write one phase per plan unless the split earns its keep across the entire run.

   Split a plan into multiple phases **only when all three** conditions hold:

   1. **Cross-phase parallelism** — at least one later phase has tasks with file targets disjoint from all earlier phases, so `/implement` can dispatch the phases concurrently. If every later phase is forced-sequential behind earlier phases by file overlap, `generate-tasks.py` chains them onto one worker anyway and merging into one phase produces the same execution shape with less ceremony.
   2. **Independent deliverable boundary** — each phase produces a coherent artifact a reviewer could accept, capture, or roll back on its own — not a sub-step of the next phase's work.
   3. **Architectural checkpoint** — an interface, contract, schema, or substrate finalizes at the phase boundary that later phases consume as a stable input. Pure file-overlap-induced sequencing is not a checkpoint; visual organization is not a checkpoint.

   If any condition fails, merge into one phase. The Phase-as-unit rule below still applies *within* the merged phase: most consolidated plans land at one phase, one task.

   **Phase-as-unit rule.** A phase is the default delegation unit. Write **one** `- [ ]` checkbox per phase by default — deliver the phase objective across the listed files while honoring the phase design decisions. Each task spawns a fresh worker that loads ~22KB of fixed context plus the phase brief; a phase split has to earn that overhead.

   Split a phase into multiple tasks **only when all four** conditions hold:

   1. **Disjoint file ownership** — the tasks edit non-overlapping file sets. Tasks sharing a file are chained sequentially by `generate-tasks.py` and run on one worker anyway, so the split buys nothing.
   2. **Independently reviewable deliverables** — each task produces a coherent artifact a reviewer could accept or reject on its own.
   3. **Real parallel execution** — the split enables concurrent work, not serialized hand-off.
   4. **No residue** — neither side is solely verification, capture, cleanup, single-CLI invocation, or a sub-edit of the other.

   If any condition fails, keep one task. Cross-phase dependencies are file-based. Uniform same-mechanism edits across many files stay one task: a single worker doing one read-modify-write pass is cheaper than N fresh agents repeating identical edits.

   **Deliverable contract gate.** Every task line names a durable artifact outcome — what gets built, refactored, authored, migrated, wired, or added. The valid primary verbs are:

   `Implement / Refactor / Author / Migrate / Add support for / Wire`

   A valid task line states: the **deliverable**, the **owned file or surface**, and at least one **design or integration constraint** that scopes the worker's choices.

   The following primary verbs are **never tasks** — they belong elsewhere:

   `Verify / Check / Inspect / Run / Capture / Append / Cross-link / Note / Document-only`

   Route invalid units:

   - **"Verify X" / "Check Y"** → phase-level `**Verification:**` objective the worker is implicitly held to. Do not duplicate the same verification block into each task description.
   - **"Capture Z" / "Append session note"** → lead-side post-phase step. The lead runs `lore capture` or appends to `notes.md` after the phase completes; this is not worker work.
   - **Single-line edits, single CLI invocations, sub-edits of a larger piece** → fold into the adjacent implementation task.

   **Task format (intent+constraints).** Default. State what the change accomplishes, what not to do, and what success looks like at the deliverable level. Opt into prescriptive format with `**Task format:** prescriptive` for mechanical work where step-by-step instructions are required.

2. **Concordance-assisted annotation** — after drafting phases, widen each phase's `**Knowledge context:**` block:
   ```bash
   lore prefetch "<phase objective> <key file paths>" --type knowledge --limit 5 --scale-set=<bucket>
   ```
   Declare `--scale-set` explicitly for every prefetch call. Missing declaration is an error.

   **Scale rubric — declare explicitly at every retrieval surface.** Four tiers in canonical top-to-bottom order: `abstract > architecture > subsystem > implementation`.

   - **abstract** — portable principle, behavioral law, or design maxim. The claim survives translation to a different project: it still teaches the same lesson when concrete project nouns are replaced with generic placeholders. Abstract entries make a *law*.
   - **architecture** — project-level structure: decomposition, lifecycle, contracts, data model, invariants, cross-component flows, promoted abstractions, or major platform choices. Architecture entries make a *map*: "A does B, C does D, and E connects them."
   - **subsystem** — local rule about one named area, feature, module, team, command family, integration, or workflow within a larger system. Concrete terms may appear as participants in a local workflow rather than as the whole claim.
   - **implementation** — concrete artifact fact: file, function, script, command, limit, field, test, bug, line-level behavior. If removing the artifact name destroys the claim, classify here.

   **Multi-label encoding:** an entry's scale may be a single id or a comma-delimited pair of adjacent ids (allowed pairs: `abstract,architecture`, `architecture,subsystem`, `subsystem,implementation`); for the full decision tree (four linguistic tests + substitution test) see the `classifier` agent template (lore repo `agents/classifier.md`).

   **Boundary tests:** abstract vs architecture — does the claim survive generic-noun substitution (abstract) or does it become "A does B, C does D, E connects them" (architecture)? architecture vs subsystem — whole project structure (architecture) or one named bounded area (subsystem)? subsystem vs implementation — can you state the rule without naming a specific function/file/line (subsystem) or does the claim depend on the artifact (implementation)?

   **±1 query pattern:** fixing a bug → `subsystem,implementation`; adding to a module → `subsystem,implementation`; modifying a component → `architecture,subsystem`; designing a feature → `abstract,architecture`.

   Add relevant entries as `[[knowledge:...]]` backlinks with "— why relevant" annotations. Investigation findings are the primary source; concordance is a widener.

3. **Retrieval directive derivation** — after concordance widening, populate a `**Retrieval directive:**` block for each phase. The directive must be derivable from content already in the phase; no additional user input is required.

   **Per-topic decomposition (v2 — default):** every directive is a list of `(topic, scale_set, [activity_vocab])` entries — **exactly one focal topic** plus **up to five adjacent topics**. Each topic fires its own BM25 OR query at its own declared scale_set; the worker prompt's `## Prior Knowledge` block ends up sectioned (`### Focal: <topic>` / `### Adjacent: <topic>`) per D3.

   - **Focal topic.** The phase's primary subject. Default `scale_set` is `subsystem,implementation`. Seeds: the phase's owned files (from `**Files:**`) plus `[[knowledge:...]]` entries in `**Knowledge context:**` directly about that subsystem. When seeding from canonical entries, prefer **title-vocabulary terms** (the entry's title tokens) over the topic label alone — title-vocabulary seeds resolve to entries the index can actually rank, while raw `knowledge:...` strings tokenize as a single literal and miss the index.
   - **Adjacent topics (≤5).** Subsystems or themes the phase touches but does not own. Default `scale_set` is one tier higher than the focal's bottom — typically `architecture,subsystem`. Seeds: title-vocabulary terms drawn from canonical entries about *that adjacent subsystem*, not the topic label and not the focal seeds. Weak seeds (right scale, wrong entries) are the dominant failure mode here — re-derive the seeds from the adjacent entries' titles and resolved paths.
   - **Activity vocabulary (optional, per topic).** Attach when files in the topic imply a recurring practice (writing tests, emitting telemetry, capturing). Look up the token list from `$KDIR/_meta/activity-vocab.yaml` by matching its file-path globs against the topic's owned file set; **do not invent activity tokens inline**. The activity-vocab file is the single authority for the practice → tokens mapping. When present, the topic fires one extra BM25 OR query at the same `scale_set` with these tokens (logged as `query_kind=activity`).
   - **Strict v2 invariant.** A v2 directive MUST have exactly one entry with `role: focal`. Zero-focal or multi-focal v2 directives are a hard parse error in `generate-tasks.py` — they are NOT silently accepted, and they are NOT normalized to the legacy flat form. If after seed derivation no genuine focal candidate emerges (e.g., a purely cross-cutting refactor across many subsystems), emit the legacy flat directive instead — that path remains valid for rollout compatibility.

   **Seeds derivation (mandatory):** for each topic, collect seeds from two sources — (a) `[[knowledge:...]]` backlinks in the phase's `**Knowledge context:**` block whose subject matches the topic become seeds (resolve to entry title and path-vocabulary terms before emitting — raw `knowledge:` strings won't tokenize); (b) file paths in the phase's `**Files:**` block that the topic owns become seeds verbatim. Deduplicate per topic. If a topic's seed union is empty, the topic itself is suspect — drop it rather than emit an empty `seeds:` bullet.

   **Defaults:** `hop_budget: 1`. Per-section limits: focal `limit: 8`, adjacent `limit: 4` (tunable). `scale_set:` is **mandatory per topic** — declaration is required at every topic; omitting it is an error. Pick the appropriate bucket (`abstract`, `architecture`, `subsystem`, `implementation`); multi-label form (e.g., `architecture,subsystem`) is allowed for adjacent pairs. Omit `filters:` unless the topic has a narrow domain where type or category filtering adds value.

   **Format (v2 — default):**
   ```yaml
   retrieval_directive:
     version: 2
     topics:
       - role: focal
         topic: "<short label>"
         seeds:
           - "[[knowledge:path#heading]]"
           - "path/to/owned/file.py"
         scale_set: [subsystem, implementation]
         activity_vocab: [pytest, fixture, assertion, mock]   # optional; from _meta/activity-vocab.yaml
         limit: 8
       - role: adjacent
         topic: "<adjacent subsystem label>"
         seeds:
           - "<title-vocabulary terms from a canonical entry about the adjacent subsystem>"
         scale_set: [architecture, subsystem]
         limit: 4
       # ...up to 5 adjacent total
     hop_budget: 1
   ```

   **Format (legacy flat — rollout compatibility):**
   ```markdown
   **Retrieval directive:**
   - seeds: [[knowledge:path#heading]], path/to/file.py, ...
   - hop_budget: 1
   - scale_set: <bucket>
   ```
   The legacy form continues to resolve to a single focal topic at the declared `scale_set` so existing plans don't break.

   **Omission rule:** if a phase has neither `**Knowledge context:**` backlinks nor `**Files:**` entries, omit the `**Retrieval directive:**` block and add a comment: `<!-- no directive: no backlinks or files to derive seeds from -->`.

   **Position:** place `**Retrieval directive:**` immediately after `**Knowledge delivery:**` (or after `**Files:**` / `**Objective:**` when `**Knowledge delivery:**` is absent) and before `**Knowledge context:**`.

4. **Open Questions** — anything investigations couldn't resolve.

5. Present the synthesized plan to the user for review.

---

### Step 5.0: Review context cost estimates (advisory)

```bash
lore work regen-tasks <slug>
```

Inspect `phase_cost_summary` as a sanity check — a single task far larger than its peers may signal an under-decomposed deliverable worth a closer read. Cost diagnostics are **advisory only**; the *Plan-as-unit rule*, *Phase-as-unit rule*, and *Deliverable contract gate* in Step 5b are the binding gates. Do not split tasks merely because they fall above an avg-comparison threshold, and do not merge tasks merely because they fall below one. The avg-comparison heuristic is post-hoc and uniform-thinness blind; trust the intrinsic gates instead.

### Step 5.0a: Verify backlinks

```bash
bash ~/.lore/scripts/verify-plan-backlinks.sh "$WORK_DIR/<slug>/plan.md" "$KNOWLEDGE_DIR" --fix
```

Output: `{verified: N, corrected: [...], unresolved: [...]}`.
- If corrections applied: note them briefly.
- If unresolved backlinks remain: carry forward to Step 5.1 as `[broken backlink]` bullets.
- If all resolved: proceed silently.

### Step 5.0b: Knowledge context block audit

For each phase, run `lore search "<phase objective keywords>" --limit 3`. If results exist but the phase has no `**Knowledge context:**` block, add the most relevant entry as a backlink with an implementation-facing annotation.

---

### Step 5.1: Confirm understanding

Before finalizing, present 5-10 bullet points covering key assumptions, behavioral claims (mark `[verified]` or `[unverified]`), design decisions with rejected alternatives, scope boundaries, and any unresolved backlinks.

**Format:**
```
Before finalizing this plan, here is my understanding of the key assumptions:

- [verified] <claim> → Investigation: <topic>, Assertion #N
- [unverified] <claim> → Investigation: <topic>, Assertion #N
- <decision statement> (over <rejected alternative>) → Design Decision: D1: <title>
- <scope boundary> → Goal / user input
- [broken backlink] [[knowledge:path]] could not be resolved → Step 5.0a backlink check
...

Does this match your understanding? Any corrections?
```

**Gate:** Do not proceed to Step 5.3 until the user explicitly confirms or provides corrections. **If `--yes`, skip (auto-proceed).**

### Step 5.2: Handle corrections (if needed)

1. Identify affected plan sections via `→` trace links.
2. Revise affected sections in `plan.md`.
3. Re-check affected phases for tasks that depended on the corrected assumption.
4. Re-present only the corrected bullets:
   ```
   Updated understanding after your corrections:
   - [corrected] <revised claim> → <source>
   ...
   Anything else to adjust?
   ```
5. If the user confirms, proceed to Step 5.3.

---

### Step 5.3: Task review

Before finalizing, present the plan phases as structured summaries. This is a separate gate from Step 5.1 — that validates understanding; this validates the work plan.

1. For each phase, produce:
   ```
   Phase N: <Name>
     Objective: <what this phase accomplishes>
     Mechanism: <HOW — specific technical approach, 1-3 sentences>
     Scope:     <files and components touched>
     Tasks:     <N tasks>
   ```
2. Present all phase summaries. Before them, add:
   ```
   Workers: N (max concurrent from task DAG topology)
   ```
   Read `recommended_workers` from `tasks.json`. End with: `Review the phases above. Approve to proceed, or request changes.`
3. **Wait for explicit approval.** **If `--yes`, skip (auto-approve).**
4. If user requests changes: revise affected phases in `plan.md`, re-present only changed summaries. Repeat until approved.
5. If user needs new investigation: suggest re-running `/spec <slug>`.

---

### Step 5.4: Post-research extraction

Invoke `/remember` scoped to the spec investigation. **Always invoke it — even when no observation appears to meet the gate.** The gate lives in `/remember`; rejecting candidates is `/remember`'s job, not the lead's. Pre-filtering observations on the rationalization "nothing qualifies, so `/remember` would be a no-op" is the bypass shape named in the commitment protocol — the lead's commitment is to invoke the gate and surface the result, not to short-circuit it. A run that captures zero entries is a valid terminal so long as `/remember` actually evaluated the observations.

Every `lore capture` call must carry provenance flags; for captures promoted from specific researcher observations, preserve the original producer's attribution:

- **Lead-original insights:** `--producer-role spec-lead --protocol-slot Synthesis --work-item <slug> --template-version $LEAD_TEMPLATE_VERSION`
- **Researcher-sourced observations:** `--producer-role researcher --capturer-role spec-lead --source-artifact-ids <researcher-report-ids> --protocol-slot Synthesis --work-item <slug> --template-version $RESEARCHER_TEMPLATE_VERSION`
- **Multi-producer synthesis:** split into one capture call per distinct producer — never merge.

```
/remember Research findings from <work item title> — Read all **Observations:** entries from investigation reports in plan.md and evaluate each — mechanism-level patterns, design rationale, and structural footprint signals all qualify; implementation facts already expressed in assertions routed to Tier-2 do not. Also capture: cross-investigation synthesis patterns not surfaced individually.

Provenance on every `lore capture`:
  - Lead-original insight: `--producer-role spec-lead --protocol-slot Synthesis --work-item <slug> --template-version $LEAD_TEMPLATE_VERSION`.
  - Promoted researcher observation: `--producer-role researcher --capturer-role spec-lead --source-artifact-ids <researcher-report-id[,id2,...]> --protocol-slot Synthesis --work-item <slug> --template-version $RESEARCHER_TEMPLATE_VERSION`.
  - Multi-producer synthesis: split per distinct producer; one capture call per producer.
```

---

### Step 5.5: Generate tasks.json and finalize

```bash
lore work regen-tasks <slug>
```

Run `lore work heal`.

---

### Step 5.6: Post-plan ceremony evaluation

**Ceremonies always run.** No flag skips this step; no flag is required to run it. Don't ask whether to invoke them — invoke. Judgment applies to acting on the output, not to running the step.

```bash
EVALUATORS=$(lore ceremony get spec-post-plan)
```
If non-empty JSON array, for each skill name in the array:
```
/<skill-name> <slug>
```
Present the evaluator's output to the user. If WEAK or MISSING areas are identified, ask the user whether to address them before proceeding. If the user wants to address gaps, proceed to Step 6.

---

### Step 6: Iterate and suggest retro

If gaps are identified (from evaluator feedback or user review):
- Create a new investigation team (same pattern) for targeted follow-ups.
- Append new findings to the Investigations section.
- Update the synthesis.

Run `lore work heal` after any changes.

After finalization, suggest:
```
Consider `/retro <slug>` to evaluate knowledge system effectiveness for this spec.
```

---

## Plan.md Template

```markdown Plan.md Template
# <Work Item Title>

## Goal
<!-- One paragraph: what we're building/changing and why -->

## Narrative
<!-- 1-2 paragraphs synthesizing the goal and key design choices into a readable story.
     Written for a reader who wants the "what, why, and how it fits together" without reading all sections.
     Draw from Goal (the what/why) and Design Decisions (trade-offs chosen).
     Omit file paths and task lists — those belong in Phases. -->

## Strategy
<!-- Optional. Written verbatim from user input at the strategy gate (Step 4).
     Omit this section entirely if the user skips the strategy prompt — absence is the default.
     On continuation runs, this section is read silently and used to shape synthesis.

     Format: free-form text block written as a worker-facing directive.
     Write the user's input as-is — do not summarize, annotate, or interpret.
     If the user provides a list, preserve it as a list. If prose, preserve as prose.

     This content is injected into worker task descriptions alongside design decisions.
     Write it so a worker reading it for the first time understands what to do. -->

## Context
<!-- SHORT BRANCH ONLY: 3-6 bullets summarizing key files, constraints, and patterns found -->
<!-- FULL BRANCH: delete this section and use ## Investigations instead -->

## Investigations
<!-- FULL BRANCH ONLY: findings from team-based exploration -->
<!-- SHORT BRANCH: delete this section and use ## Context instead -->

### <Topic 1>
**Question:** <what was investigated>
**Findings:**
- Finding 1
- Finding 2
**Key files:** `path/to/file.ts`, `path/to/other.ts`
**Implications:** How this affects the design
**Observations:**
- <mechanism-level pattern, design rationale, or structural footprint signal, preserved verbatim from researcher report>

<!-- Note: researcher assertions (7-field YAML shape) are emitted to task-claims.jsonl (Tier 2)
     via evidence-append.sh — they do not appear in plan.md. See architecture/artifacts/tier2-evidence-schema.md. -->

## Design Decisions

### D1: <Decision Title>
**Decision:** What was decided — a concrete, actionable statement
**Rationale:** Why this choice over others — the reasoning, constraints, or evidence that led here
**Alternatives considered:** What other approaches were evaluated and why they were rejected
**Applies to:** Phase N (<name>), Phase M (<name>) — which phases/tasks this decision affects

## Architecture Diagram
<!-- Optional — include when the work involves multi-component systems, novel data flows, or module boundaries
     that are not self-evident from the phase list. Omit for single-file or straightforward additive changes.
     Format: plain-text ASCII art inside a fenced code block. Use box-drawing characters (─ │ ┌ ┐ └ ┘ ├ ┤),
     arrows (──►, ──┐, ◄──). Do NOT use Mermaid or other diagram DSLs.
     Label components with actual file/module names. -->

## Phases
<!-- One phase per plan by default. Add a second phase only when all three Plan-as-unit conditions
     hold (Step 5b): cross-phase parallelism, independent deliverable boundary, architectural
     checkpoint. File-overlap-forced sequencing is not a checkpoint — merge into one phase. -->

### Phase 1: <Name>
**Objective:** What this phase accomplishes
**Files:** relevant file paths
**Scope:**
<!-- Optional — list files/components workers must NOT modify and any output contracts. -->
- Do not modify: `path/to/file`
- Output contract: <what the phase must produce without changing>
**Task format:** prescriptive  <!-- optional — omit for default intent+constraints format -->
**Knowledge delivery:** full  <!-- optional — omit for default annotation-only delivery -->
**Retrieval directive:**
<!-- Optional — omit when phase has no Knowledge context backlinks and no Files entries.
     Seeds are derived from (a) [[knowledge:...]] backlinks in Knowledge context, and
     (b) file paths in Files. Deduplication applied. hop_budget defaults to 1.
     scale_set: REQUIRED — declare the appropriate bucket (abstract | architecture | subsystem | implementation); multi-label form (e.g., architecture,subsystem) is allowed for adjacent pairs. Omitting is an error.
     Consumed by /implement Step 3.1 branch (a) via resolve-manifest.sh → {{prior_knowledge}}. -->
- seeds: [[knowledge:file#heading]], path/to/file.py
- hop_budget: 1
<!-- scale_set: REQUIRED — declare one bucket: abstract | architecture | subsystem | implementation (multi-label form architecture,subsystem etc. allowed for adjacent pairs) -->
<!-- - filters: type=knowledge, exclude_category=... (optional; omit when not filtering) -->
**Knowledge context:**
<!-- Each entry MUST include a "— why relevant" annotation after the backlink.
     Annotations are implementation-facing: tell the worker what to DO with the entry.
     GOOD: "— understand the call graph before modifying resolve_backlinks()"
     BAD:  "— provides context for this phase" -->
- [[knowledge:file#heading]] — why this is relevant to this phase
**Advisors:**
<!-- Optional — declare domain-expert advisors. /implement spawns these as persistent team members. -->
- advisor-name — domain scope. [must-consult|on-demand]
**Verification:**
<!-- 0–3 observable-behavior criteria. Lives at phase level only — never duplicated into per-task descriptions.
     The phase worker(s) are implicitly held to these objectives; "Verify X" is never its own task.
     Each bullet names a behavior of the changed system a worker can check without reading the diff.
     Anti-patterns — never use:
       "X no longer exists" — recoverable from ls/diff, not a behavior
       grep-for-absence-as-audit — acceptable only when prose is the contract being verified
       task restatement — "refactored Y" is the task, not a verification criterion
     Good example: "`lore prefetch` with no `--scale-set` exits non-zero with a usable error" -->
- <observable behavior — e.g., "`lore search foo` returns ranked results from the updated index">
**Tasks:**
<!-- One - [ ] checkbox per phase by default. Multiple only when the four conditions in Step 5b hold:
     disjoint file ownership, independently reviewable deliverables, real parallel execution, no residue.
     Valid primary verbs: Implement / Refactor / Author / Migrate / Add support for / Wire.
     Banned as primary verb: Verify / Check / Inspect / Run / Capture / Append / Cross-link / Note / Document-only.
     See Step 5b "Deliverable contract gate" for routing of invalid units. -->
- [ ] <Verb> <deliverable> in <owned file/surface> — <design or integration constraint>

## Open Questions
- Unresolved decisions or items needing follow-up

## Related
<!-- Cross-cutting references that apply to the whole plan, not a specific phase. -->
- [[knowledge:file#heading]] — cross-references to knowledge store
```

---

## Resuming a spec across sessions

When `/spec` is called on a work item that already has a plan:
- Read existing investigations/context — they are your memory (no need to re-explore).
- If a `## Strategy` section exists, read it silently and use it as shaping context — do not re-prompt.
- Check if synthesis (Design/Phases) is complete; if not, synthesize from existing findings.
- Check Open Questions — dispatch follow-up investigations for unresolved items.
- **Always run the approval gates before finalizing:** whether synthesis was just completed or carried over from a prior session, proceed through Step 5.1 (Confirm understanding) and Step 5.3 (Task review). Do not skip because the plan "already exists." Exception: if `--yes` was passed, these gates are auto-approved.
