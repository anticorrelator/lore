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

The `--short` conditional activates at Step 2 only. From Step 3 onward, short and full paths share every step: collect findings and emit Tier-2 artifacts, strategy gate, synthesis, design ceremony, task review, post-research extraction, post-plan ceremony, and terminal finalization.

## Full Flow (`/spec`)

Team-based divide-and-conquer: the spec-lead composes an investigation plan table (Step 2 full branch), dispatches parallel researcher agents, collects findings, emits Tier-2 artifacts, and then synthesizes — following the shared downstream steps. For complex or uncertain-scope work.

> **Sequencing constraint:** Do not dispatch research agents before completing Step 2. The investigation plan is a completeness checklist and user approval gate, not just a dispatch list.

## Judgment boundary

The verbs prepare evidence and persist decisions; they do not make them. Keep these kernels in lead prose: investigation questions, complexity labels, strict/permissive applicability, synthesis, contradiction decisions, phase/task decomposition, evaluator normalization, whether feedback changes the plan, and every harness-native dispatch or teardown call. If a verb appears able to infer one of these, stop at the boundary and supply the missing judgment explicitly.

---

### Step 1: Parse and resolve (both modes)

1. Parse arguments:
   - Set `TRACK=short` when the first arg after `/spec` is `short`; otherwise set `TRACK=full`. The investigation step (Step 2) follows that declared track.
   - If `--yes` is present, skip all interactive confirmation gates (auto-proceed through investigation plan confirmation, strategy gate, confirm understanding, and task review).
   - If `--model <id>` is present, set `MODEL_OVERRIDE=<id>` and export the per-role overrides for this invocation: `export LORE_MODEL_LEAD=<id> LORE_MODEL_RESEARCHER=<id> LORE_MODEL_ADVISOR=<id>`. Otherwise leave `MODEL_OVERRIDE` empty and let ceremony-scoped role resolution choose each model. An explicit flag without a value is an error, not a request for the configured default.
   - The remaining text is the **input**.

2. Resolve the knowledge path:
   ```bash
   lore resolve
   ```
   Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

3. Run the read-only startup verb. It owns work-reference resolution, plan-state classification, active-framework/model resolution, template-version stamping, and source provenance. It never creates a work item, repairs an index, or chooses a protocol route:

   ```bash
   START_INPUT=${INPUT:-__branch_inference__}
   START_ARGS=("$START_INPUT" --branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)" --json)
   [[ "$TRACK" == "short" ]] && START_ARGS+=(--short)
   [[ -n "$MODEL_OVERRIDE" ]] && START_ARGS+=(--model "$MODEL_OVERRIDE")
   START=$(lore spec start "${START_ARGS[@]}")
   ```

   Required version-1 fields are `schema_version`, `resolved`, `slug`, `archived`, `plan_state`, `intent_anchor`, `strategy_present`, `active_framework`, `effective_lead_model`, `track`, `lead_template_version`, and `provenance`. Missing declarations and unknown flags are errors; there is no default route for malformed input. Exit 2 means ambiguity: ask the user to select from the ordered candidates, then re-run with the exact slug.

4. Choose the route from the returned facts — this is lead judgment, not verb output:

   - **`resolved=false` with user input:** treat the remaining input as a freeform description and continue to Goal Refinement.
   - **`resolved=false` without user input:** ask what the user wants to spec; never turn the branch-inference sentinel into a work item.
   - **`archived=true`:** warn and wait for explicit confirmation.
   - **`plan_state=synthesis-complete`:** load `plan.md`, read any `## Strategy` silently, and continue at Step 5.1.
   - **`plan_state=investigations-only`:** load the persisted findings and any strategy, then continue at Step 5.
   - **`plan_state=follow-up-needed`:** read the open questions and design targeted follow-up investigations.
   - **`plan_state=incomplete`:** present the persisted material for discussion; offer the strategy gate before synthesis when no strategy exists.
   - **`plan_state=none`:** continue to Step 2.

   When `intent_anchor` is non-null, preserve it verbatim — downstream gates (the Step 5.6 verifier, `/implement` anchor prompts) detect drift by string comparison, so a paraphrase breaks the audit chain even when intent is preserved. It is the user-visible capability boundary, not a suggestion the spec may silently narrow. Startup reports the anchor; only the lead judges whether the emerging design still covers it.

### Step 1b: Goal Refinement (new work only)

When the input is a freeform description rather than an existing work item:

1. Restate your understanding in 1-2 sentences.
2. Ask 2-4 clarifying questions using `AskUserQuestion`. Target scope boundaries, constraints, and approach preferences. Do NOT ask questions answerable by reading the codebase.
3. Incorporate answers into a refined goal statement.
4. Create the work item: derive a slug from the description, run the `/work create` flow and pass `--intent-anchor` with an interpreted one-sentence capability statement that names the user-visible outcome. Audit it for looseness — alternatives ("X or Y" admits doing just one), comparatives without targets ("better," "faster" with no acceptance bar), vague verbs ("support," "improve" without naming the bar), and the meta-instruction degenerate case (user said "make a work item for that," no capability named) — before committing. The clarifying questions in step 2 should have closed most looseness; if any remains, ask one targeted question via `AskUserQuestion` before creating. See `/work create` intent-anchor guidance and `[[knowledge:conventions/protocol/work-item-intake-should-store-neutral-intent-ancho]]`.
5. Continue to Step 2.

If the user's description is already specific enough (clear scope, stated constraints, obvious approach), skip to step 4 — don't ask questions for the sake of asking.

---

### Step 2: Investigation — conditional on `--short`

### Step 2a: Short branch (`--short` flag present)

1. From conversation context and the work item, identify 3-8 key files to read.
2. Search the knowledge store: `lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 5`. Read relevant entries.
3. Check the knowledge store index for relevant domain files.
4. Read the files yourself — do NOT spawn subagents.
5. Note key findings as you go.
   - **Current-state verification (mandatory before a finding becomes a design constraint):** when a design choice hinges on a current-state claim sourced from a sibling work item's `notes.md` or other uncommitted prose (not committed code or a commons entry), verify the claim against HEAD before adopting it. Notes age faster than code; a stale note silently shapes scope.
   - **Integration-seam trace:** when the work adds a field to a shared substrate (e.g., `_meta.json`) or inserts a script into an existing control-flow gate, trace three seams before drafting: (a) does an existing gate/guard intercept the new state? (b) does the denormalized read model (e.g., `_index.json`) project the field, or is it invisible to consumers? (c) does ordering (archive/move) change where a later step finds the file?
6. Prepare discovery evidence without assigning meaning:

   ```bash
   DISCOVERY=$(lore spec discover "$SLUG" --json)
   ```

   The version-1 result contains `coverage`, `candidates`, and `provenance`. Coverage names every scanned, missing, or unreadable source stratum; candidates retain each source's own rank and score. The verb excludes canonical Lore skill/agent identities structurally, but it never combines rankings or emits `matched`, `binding`, or `applicability` fields.

7. Apply the two discovery judgments yourself:

   - **External skills and agents — strict.** Read plausible external candidates and include only those whose stated domain materially contributes to this implementation. Lore protocol skills remain toolchain, not advisors. Emit `**External skill discovery:**` with the considered set and the matched set; `Matched: none` is valid.
   - **Preferences and conventions — permissive.** Read the surfaced candidates and retain any entry the work might need to honor. Missing a binding preference is worse than carrying an inapplicable candidate into synthesis. Emit `**Preference and convention discovery:**` with coverage counts and the surfaced backlinks; `Surfaced: none` is valid.

   Candidate enumeration is hands work; strict/permissive applicability is head work. Do not ask the verb to collapse that boundary.

8. Present a context summary and offer the strategy gate (Step 4 below). **If `--yes`, skip the strategy prompt.**

### Step 2b: Full branch (default, no `--short` flag)

1. From the feature description, identify 3-7 focused investigation questions. Each should target a specific codebase concern, be answerable by exploring files, and be independent enough to run in parallel.
2. Always include two mandatory fixed investigations (both count toward the 3-7 total): a. External skill and agent applicability (strict)... b. Preferences and conventions applicability (permissive)...

   a. **External skill and agent applicability (strict)** — which installed *external* (non-lore) skills and agent templates should be invoked during **implementation** of this work item. Lore-managed skills (`/spec`, `/implement`, `/work`, `/memory`, `/remember`, `/retro`, `/evolve`, `/renormalize`, `/self-test`, `/followup-discuss`, `/bootstrap`, `/pr-*`, `/codex-*`) are **excluded** — protocol toolchain, not advisors. The researcher filters them out before reporting matches. Key files: `<skills_dir>/*/SKILL.md`, `<agents_dir>/*.md` (resolve via `resolve_harness_install_path skills` / `resolve_harness_install_path agents`); exclusion list comes from the canonical Lore source repo (`source ~/.lore/scripts/lib.sh && printf '%s\n' "$LORE_REPO_DIR"` + `/skills/` and `/agents/`). Do not use `resolve-repo.sh` here — it returns the project's knowledge store, not the Lore source tree. Match criterion is **strict** — include only skills whose stated domain plausibly contributes to *this* work item's implementation.

   b. **Preferences and conventions applicability (permissive)** — which entries from `preferences/`, `conventions/`, and `cross-cutting-conventions/` the work might need to honor. **Inclusion criterion is permissive — the inverse of skill discovery.** The test is "is it *possible* the work might need this" — not "will we definitely apply it." Err on over-inclusion; synthesis culls. Missing an applicable preference is worse than carrying an inapplicable one through review. Key files: `$KDIR/preferences/`, `$KDIR/conventions/`, `$KDIR/cross-cutting-conventions/` (full enumeration; absent = zero) plus BM25 from `lore search "<topic>" --type knowledge --scale-set subsystem,implementation --limit 10` and `--scale-set abstract,architecture --limit 5`.
3. Check the knowledge store index for file hints per investigation.
4. Assess complexity for each investigation: **simple** (1-2 files), **moderate** (3-5 files), **complex** (6+ files or cross-cutting).
5. Present the Investigation Plan to the user:
   ```
   ## Investigation Plan

   | # | Area / Topic | Key Files | Complexity |
   |---|-------------|-----------|------------|
   | 1 | External skill and agent applicability — strict, lore toolchain excluded *(mandatory — do not remove)* | `<skills_dir>/*/SKILL.md`, `<agents_dir>/*.md` | simple |
   | 2 | Preferences and conventions applicability — permissive *(mandatory — do not remove)* | `$KDIR/preferences/`, `$KDIR/conventions/`, `$KDIR/cross-cutting-conventions/` | simple |
   | 3 | <topic>     | `file1`, `file2` | simple |
   ...

   Proceed, or adjust?
   ```
6. Wait for user confirmation. If the user requests adjustments, revise and re-present. **If `--yes`, dispatch immediately without confirmation.**
7. Prepare discovery evidence, then make the applicability decisions in lead prose:

   ```bash
   DISCOVERY=$(lore spec discover "$SLUG" --json)
   ```

   Use the returned `coverage` to see what was scanned or missing. Choose strict external-skill/agent matches and permissive preference/convention candidates yourself. Record matched external skills in `$SKILL_INVOCATION_MAP`; invoke them inline when a researcher consults that domain. `/spec` spawns no advisor agents on the default route.

8. Serialize the approved investigation plan to a temporary JSON file and hold its path as `$INVESTIGATIONS_JSON`. The version-1 contract is exact — unknown or missing fields refuse, array order is dispatch order, and every prefetch row declares its scale rather than inheriting a default:

   ```json
   {
     "schema_version": 1,
     "track": "full",
     "investigations": [
       {"id": "external-skills-agents", "kind": "fixed", "question": "External skill and agent applicability ...", "complexity": "simple", "prefetch": [{"query": "<topic>", "scale_set": ["subsystem", "implementation"]}]},
       {"id": "preferences-conventions", "kind": "fixed", "question": "Preferences and conventions applicability ...", "complexity": "simple", "prefetch": [{"query": "<topic>", "scale_set": ["abstract", "architecture"]}]},
       {"id": "<lead-authored-id>", "kind": "lead-authored", "question": "<lead-authored question>", "complexity": "simple|moderate|complex", "prefetch": [{"query": "<topic>", "scale_set": ["implementation"]}]}
     ]
   }
   ```

   Exactly one fixed external-skill/agent question and one fixed preference/convention question are mandatory. The lead owns every question, complexity label, prefetch query, and scale declaration; the verb validates but never invents them.

9. Open the reusable dispatch artifact:

   ```bash
   DISPATCH=$(lore spec open "$SLUG" --investigations "$INVESTIGATIONS_JSON" --json)
   ```

   `open` returns `created | reused | recovered | replaced`, or refuses with the repair target. Its canonical `spec-dispatch.json` carries `input_fingerprint`, `source_fingerprint`, the source manifest, ordered directives, empty lead-side handle slots, and teardown payloads. It never calls a harness tool and never persists live handles.

   Bind `ADAPTER`, `RESEARCHER_MODEL`, and `RESEARCHER_TEMPLATE_VERSION` from the returned source manifest and directives. Do not resolve a second set after publication; that would make the executed payload differ from the artifact being resumed.

10. Execute the returned directives in ordinal order. This is the harness-dispatch judgment kernel: translate each directive into the active harness's native spawn call, decide when to launch it, and store returned handles only in the lead's in-memory handle map. Populate the matching teardown payload with the live handle at shutdown time; do not write handles back into `spec-dispatch.json`.

    `team_messaging != full` removes only shared team state. Codex still executes researcher fanout while `subagents=partial`, then its adapter teardown resolves to lead-mediated `TaskUpdate status=completed`. Collapse to the short branch only when `subagents=none`. On a full team-messaging harness, the lead may create the shared team before executing spawn directives and tear it down after researcher completion.

---

### Step 3: Collect findings and emit Tier-2 artifacts

As researcher messages arrive (or after direct file reading in short branch):

1. Write each finding to the `## Investigations` section of `plan.md` using the investigation entry format from the Plan.md Template below.
2. **Preserve `**Findings:**` verbatim** — copy findings exactly as reported.
3. **Preserve `**Observations:**` verbatim** — copy researcher observations exactly as reported. Do not rephrase, merge, or summarize. These are mechanism-level patterns, design rationale, and structural footprint signals that feed the Step 5.4 capture step.
4. **Emit Tier-2 artifacts** — for each researcher assertion (full branch) or lead-observed task-scoped grounding claim (short branch):
   - Format the claim as a JSON row with the evidence fields (`claim`, `file`, `line_range`, `exact_snippet`, `normalized_snippet_hash`, `falsifier`, `significance`) plus producer/template provenance and `change_context` (`diff_ref`, `changed_files[]`, `summary`). `changed_files[]` must include the row's `file`; `summary` should name why the current investigation/change made the claim relevant. `exact_snippet` and `normalized_snippet_hash` are REQUIRED for every row: `exact_snippet` is the verbatim content at `file:line_range` that grounds the claim, and `normalized_snippet_hash` is the sha256 hex of the v1-normalized snippet. Compute the hash via the canonical helper — do NOT inline the recipe:
     ```bash
     python3 ~/.lore/scripts/snippet_normalize.py --hash <<<"$SNIPPET"
     ```
     The v1 normalization recipe (curly→straight quotes, `\s+`→single space, trim, sha256 lowercase hex) lives only in `scripts/snippet_normalize.py`. See `architecture/artifacts/tier2-evidence-schema.md` for the full schema.
   - Append the row via the sole-writer:
     ```bash
     echo '<json-row>' | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>
     ```
     `evidence-append.sh` is the sole writer of `$KDIR/_work/<slug>/task-claims.jsonl`; it rejects missing snippets and invalid or mismatched normalized hashes. On rejection, fix and retry the row or log the failure to `execution-log.md`. Never write the JSONL directly — direct writes bypass validation and are treated as corrupt.
   - After successful append, write a human-readable mirror entry to `$KDIR/_work/<slug>/evidence.md`. Do not write a mirror entry for a row that failed validation.
   - **Absence semantics:** if no assertions or lead-observed task claims exist, both `task-claims.jsonl` and `evidence.md` may be absent — absence means "no Tier-2 claims captured this session," not "work was fully verified."

5. **Full branch only:** When all investigation tasks are complete:
   - Execute each directive's teardown payload with its in-memory researcher handle. On Claude Code this is a shutdown request; on Codex the live adapter returns the lead-mediated `TaskUpdate task_id=<handle> status=completed` directive. Do not infer teardown from `team_messaging`: the prepared payload and current adapter are the contract.
   - Run `TeamDelete` (Claude Code only; opencode/codex adapters require no explicit teardown — runtime owns lifecycle).

6. Append an investigation summary to `execution-log.md`:
   ```bash
   printf 'Investigations: %d\nTopics: %s\n' \
     "<N>" "<comma-separated investigation topics>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source spec-lead --template-version "$RESEARCHER_TEMPLATE_VERSION"
   ```

7. **Journal the investigation milestone.** The findings, Tier-2 rows, and investigation summary are all durable at this point, so a hosted session emits one `step_completed` row for the parent spec session — individual researcher reports and Tier-2 appends never emit steps:
   ```bash
   if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
     bash ~/.lore/scripts/session-step.sh \
       --step-id spec:investigation --step-label "Investigation complete" \
       || echo "[spec] Warning: investigation step not journaled; the persisted artifacts remain authoritative." >&2
   fi
   ```
   The env gate is the hosted-session test — an unhosted run skips silently. Replay is idempotent, and a failed append warns and moves on; it never rolls back the milestone it was reporting.

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

5. **Consumption-verification checkpoint** — before finalizing synthesis, report the outcome for each prefetched commons entry you actually checked against code during investigation. Held and contradicted both count — a confirmation is signal, not ceremony. Skip entries you never tested; grounded-or-nothing means every report needs the code anchor trio, so an entry you can't anchor is an entry you didn't verify:

   ```bash
   # Entry confirmed by investigation:
   lore verify <knowledge-path> held \
     --source spec-lead \
     --protocol-slot Synthesis \
     --cycle-id "spec-<topic>-$(date +%Y-%m-%d)" \
     --template-version "$LEAD_TEMPLATE_VERSION" \
     --file <absolute-path> --line-range <N-M> --exact-snippet "<verbatim code>"

   # Entry falsified by investigation — additionally lands one pending row in
   # $KDIR/_work/<slug>/consumption-contradictions.jsonl; lore audit consumes it as priority-input:
   lore verify <knowledge-path> contradicted \
     --source spec-lead \
     --protocol-slot Synthesis \
     --cycle-id "spec-<topic>-$(date +%Y-%m-%d)" \
     --template-version "$LEAD_TEMPLATE_VERSION" \
     --file <absolute-path> --line-range <N-M> --exact-snippet "<verbatim code>" \
     --work-item <slug> \
     --rationale "<why the code falsifies the entry>" \
     --claim-text "<the entry assertion being contradicted>" \
     --falsifier "<what evidence would disprove>"
   ```

   Events land in `$KDIR/_trust/trust-events.jsonl` (contract: `architecture/trust-ledger/README.md` in the knowledge store). Run these from the source repo's root, not from inside the knowledge store — `lore` resolves the store and records branch provenance from the current directory. Emission is non-blocking — synthesis continues immediately; re-running an identical invocation is a silent no-op (the writers dedupe).

6. Present the abstract plan (Goal, Design Decisions, Narrative, Architecture Diagram) to the user for review.

**Discovery findings integration:**
- **Related skills block (strict):** If the discovery researcher (full branch) or Step 2 skill scan (short branch) reported matched *external* skills, add a `**Related skills:**` block to the `## Context` or `## Investigations` section. Lore-toolchain skills are not eligible for this block — they're protocol, not advisors:
  ```
  **Related skills:**
  - /external-skill-name — why this skill is relevant to this work item
  ```
- **Related preferences/conventions block (permissive — audit manifest):** If the discovery surfaced any entries from `preferences/`, `conventions/`, or `cross-cutting-conventions/`, add a `**Related preferences/conventions:**` block to the same section. Include every entry the discovery surfaced under the permissive criterion — workers can dismiss inapplicable ones at implement time; missing applicable ones is the worse failure:
  ```
  **Related preferences/conventions:**
  - [[knowledge:preferences/<entry>]] — what to honor at implement time (1 line)
  - [[knowledge:conventions/<entry>]] — what to honor at implement time (1 line)
  ```
  **This block is the audit manifest, not the worker delivery channel.** It exists so a reviewer (and the post-plan ceremony) can see every preference/convention discovery surfaced. Workers do not read top-level plan.md sections — `/implement` consumes per-phase `**Knowledge context:**` backlinks (Step 3.1 directive branch resolves them via `resolve-manifest.sh` into worker `{{prior_knowledge}}`). Distribution into per-phase Knowledge context happens in Step 5b #2 (concordance-assisted annotation) — see that step for the per-phase placement rule. Entries that don't bind to any specific phase still appear here; the manifest also catches them during review even when they have no per-phase home.

  Keep this block at the **full permissive surfaced set** regardless of what binds to a task. The manifest is permissive; the *weave* into task lines is strict (Step 5b "Deliverable contract gate" — only scope-overlapping judgment-class norms become constraint clauses). A backlink staying here while its norm is also woven into a task is correct: the manifest is provenance, the task line is delivery.
- **Advisor declarations:** For each matched skill whose domain overlaps with a phase's scope, consider adding an `**Advisors:**` entry. Set mode based on phase complexity — `must-consult` if the skill defines invariants workers must respect, `on-demand` otherwise.

### Ceremony outcome filing contract

Apply this contract after every terminal evaluator attempt in Steps 5a and 5.5. The evaluator supplies evidence; the lead decides the normalized protocol outcome. Never parse evaluator prose into a disposition.

1. Choose exactly one outcome: `completed | failed | skipped | needs-decision`. Preserve the evaluator's raw verdict byte-for-byte as `--verdict`. `skipped` and `needs-decision` require a reason; `completed` and `failed` forbid one. A registered evaluator that cannot execute is a filed `skipped` attempt, never a silent omission.
2. Build a version-1 evidence manifest with exactly these fields:

   ```json
   {
     "schema_version": 1,
     "evaluator_locator": "<skill or agent locator>",
     "evaluator_template_version": "<12-char hash>",
     "framework": "<active framework>",
     "model": "<effective evaluator model>",
     "final_round": 2,
     "disposition_ledger_sha256": "<sha256 of the round/disposition ledger>",
     "source_plan_sha256": "<sha256 of the plan the evaluator read>"
   }
   ```

   `completed` and `failed` require every evidence field. `skipped` and `needs-decision` keep every field present but may use explicit `null` when evidence is unavailable. Missing fields are errors, never defaults.
3. File the already-made judgment:

   ```bash
   lore spec outcome "$SLUG" \
     --ceremony <spec-design|spec-post-plan> \
     --advisor "$EVALUATOR" --attempt-id "$ATTEMPT_ID" \
     --outcome "$NORMALIZED_OUTCOME" --verdict "$RAW_VERDICT" \
     --evidence-manifest "$EVIDENCE_JSON" [--reason "$REASON"]
   ```

   Exact replay is idempotent; reusing an attempt id for different semantics is a refused collision. `needs-decision` may return `status=partial` when its auxiliary resolution row fails to append; exact retry recovers only that sink.

### Step 5a: Design ceremony evaluation

**Ceremonies always run.** No flag skips this step; no flag is required to run it. Don't ask whether to invoke them — invoke. Judgment applies to acting on the output, not to running the step.

```bash
EVALUATORS=$(lore ceremony get spec-design --work-item <slug>)
```
If non-empty JSON array, for each skill name in the array:
```
/<skill-name> <slug>
```
This evaluates the abstract plan. If WEAK or MISSING areas are identified, revise the abstract plan before proceeding to Step 5b. No evaluators are registered by default — opt-in via `lore ceremony add spec-design <skill>`.

After each evaluator reaches a terminal attempt, make the outcome judgment and file it under `--ceremony spec-design` using the ceremony outcome filing contract. A revision round receives a new attempt id; never overwrite the evidence identity of an earlier round.

When every evaluator holds a terminal disposition and any accepted revisions are persisted — including the no-evaluator case — a hosted session journals the design milestone:

```bash
if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
  bash ~/.lore/scripts/session-step.sh \
    --step-id spec:design --step-label "Design accepted" \
    || echo "[spec] Warning: design step not journaled; the persisted plan remains authoritative." >&2
fi
```

One row marks the accepted design state; evaluator attempts and individual revision rounds do not emit.

### Step 5b: Synthesize — concrete plan

Draft concrete implementation sections on top of the approved abstract plan:

0. **Intent anchor** — if the work item has an `intent_anchor` in `_meta.json`, render a `## Intent Anchor` section in `plan.md` immediately after `## Narrative` and before `## Strategy`/`## Context`. Write the anchor body **verbatim** from `_meta.json.intent_anchor` — no quoting, prefix label, or paraphrase. Before decomposing, name the tempting narrower implementation that would appear successful while violating the anchor; ensure the Goal, task constraints, and Verification cover the load-bearing promise or explicitly label the scope delta.

   Follow the anchor with a `**Scope delta:**` line (default `none — anchor preserved unchanged`; if the spec narrows the capability, name the narrowing here) and a `**Tempting narrower implementation:**` heading the spec author fills in. The anchor body and `**Scope delta:**` line are **verifier-enforced** — the Step 5.6 gate refuses to regenerate tasks if missing or divergent. The `**Tempting narrower implementation:**` body is template-prescribed but not verifier-enforced — its presence forces the author to confront the failure mode, but the content is free-text that no parser can adjudicate. For work items without an `intent_anchor` field, omit the section entirely — the Step 5.6 verifier skips with a one-line stderr info message.

1. **Phases** — concrete implementation phases with tasks, file paths, objectives. Each phase includes `**Knowledge context:**`, `**Tasks:**` (checkbox lines), and optional `**Retrieval directive:**` / `**Advisors:**` / `**Verification:**` / `**Split rationale:**` (required when the phase has more than one task) / `**Scope:**` blocks.

   **Plan-as-unit rule.** A plan is **one** phase by default. Each additional phase is a separate `/implement` worker batch with its own dispatch ceremony — write one phase per plan unless the split earns its keep across the entire run.

   Split a plan into multiple phases **only when all three** conditions hold:

   1. **Cross-phase parallelism** — at least one later phase has tasks with file targets disjoint from all earlier phases, so `/implement` dispatches concurrently. If file overlap forces every later phase sequential, `generate-tasks.py` chains them onto one worker — merging yields the same execution shape with less ceremony.
   2. **Independent deliverable boundary** — each phase produces a coherent artifact a reviewer could accept, capture, or roll back on its own — not a sub-step of the next.
   3. **Architectural checkpoint** — an interface, contract, schema, or substrate finalizes at the boundary that later phases consume as stable input. File-overlap sequencing is not a checkpoint; visual organization is not a checkpoint.

   If any condition fails, merge. The Phase-as-unit rule below still applies *within* the merged phase: most consolidated plans land at one phase, one task.

   **Phase-as-unit rule.** A phase is the default delegation unit. Write **one** `- [ ]` checkbox per phase by default — deliver the phase objective across the listed files while honoring the phase design decisions. Each task spawns a fresh worker that loads its fixed context plus the phase brief; the four conditions below, not a flat per-task overhead, decide whether a split earns that spawn.

   Split a phase into multiple tasks **only when all four** conditions hold:

   1. **Disjoint file ownership** — tasks edit non-overlapping file sets. Tasks sharing a file get chained sequentially by `generate-tasks.py` onto one worker — the split buys nothing.
   2. **Independently reviewable deliverables** — each task produces a coherent artifact a reviewer could accept or reject on its own.
   3. **Real parallel execution** — the split enables concurrent work, not serialized hand-off.
   4. **No residue** — neither side is solely verification, capture, cleanup, single-CLI invocation, or a sub-edit of the other.

   If any condition fails, keep one task. Cross-phase dependencies are file-based. Uniform same-mechanism edits across many files stay one task — one worker doing one read-modify-write pass beats N fresh agents repeating the same edit.

   **Judgment class and the split calculus.** Each task line carries a judgment class (`mechanical | standard | judgment-dense`; see the Deliverable contract gate below) that `/implement` routes to a worker-tier binding — mechanical to a cheaper model, judgment-dense to a stronger one. This gives the four conditions a second thing a split can buy beyond parallelism: separating a judgment-dense core from a mechanical shell over disjoint files, so each routes to its own tier instead of paying the strong-model rate across the whole phase. A judgment-density transition across disjoint files is a legitimate split point. But the four conditions still gate every split: a class mix that fails disjoint-file-ownership or real-parallel-execution stays one task, and a **uniform same-mechanism sweep stays one task regardless of worker tier** — a mechanical sweep never fragments into per-file tasks to shave model spend, because spawn overhead dwarfs the saving. The tipping point remains judgment density, not file count.

   **Context-envelope ceiling.** A task's owned file set plus its phase brief must fit one worker's context envelope with working room to read, reason, and edit. When they do not, the split is **forced** — regardless of judgment class or whether the four conditions hold — because an over-large task passes every structural condition above yet fails *in flight* on worker-context exhaustion, the most expensive discovery point there is. This is a level-1 correctness-of-execution constraint (execution capacity), the sibling of the capability ceiling that keeps judgment-dense work off a model that cannot hold it — **not** a weighable fifth condition and **not** an aesthetic size threshold. It bounds task size from above exactly as **no residue** bounds it from below; between that floor and this ceiling, size stays structure-gated and empirically tuned via the (class, model, size) rework attribution — never trimmed to hit a size target.

   **Split rationale (required for multi-task phases).** Any phase with more than one task carries a `**Split rationale:**` block — one or two sentences naming the judgment-density transition or genuine parallelism that earned the split. The Step 5.6 finalize gate refuses a multi-task phase that lacks it. A single-task phase omits the block.

   **Deliverable contract gate.** Every task line names a durable artifact outcome — what gets built, refactored, authored, migrated, wired, or added. The valid primary verbs are: Implement / Refactor / Author / Migrate / Add support for / Wire... The following primary verbs are **never tasks** — they belong elsewhere: Verify / Check / Inspect / Run / Capture / Append / Cross-link / Note / Document-only.

   A valid task line states the **deliverable**, the **owned file or surface**, and at least one **design or integration constraint** that scopes the worker's choices.

   **Judgment-class marker (required).** Every task line ends with a trailing `[class: mechanical | standard | judgment-dense]` marker, placed after any `[[knowledge:...]]` backlinks so the deliverable verb stays first. It declares the **judgment class** — the worker tier `/implement` routes the task to:
   - **mechanical** — deterministic edits: uniform text substitution, one known transform swept across files, scaffolding. No design judgment; routes to the cheapest worker binding.
   - **standard** — ordinary implementation judgment (the common default): local design choices a competent worker makes without novel reasoning. Routes to plain `worker`.
   - **judgment-dense** — novel design, cross-cutting reasoning, subtle correctness, or security-sensitive surface. Routes to the strongest worker binding.

   The class is **explicit on every line** — the Step 5.6 finalize gate refuses an unannotated task line. An unclassed line is not treated as `standard`: a legacy plan with no markers still regenerates (routing as plain `worker`), but re-finalizing it demands annotation.

   <!-- INVARIANT — canonical /spec weave vocabulary. Keep these terms stable; the
        /implement worker report's `Convention handling:` field and the lead's
        completeness comparison key on them. Drift silently breaks the handoff.
          - "constraint clause" — the imperative norm woven into a task line
          - "woven norm" / "binding norm" — a surfaced norm that became a constraint clause
          - "stable label" — the entry slug/title the backlink resolves to; the
            identifier shared with the worker report and the lead comparison -->
   **Weave binding judgment-class norms into the constraint clause.** When a preference/convention from Step 2 discovery *binds* to a task, render it as an imperative **constraint clause** in the task line itself — the instruction the worker executes — not only as a `**Knowledge context:**` backlink the worker must choose to fetch. The clause **names the norm by its stable label** (the entry slug/title the backlink resolves to) so the worker's `Convention handling:` report and the lead's completeness comparison reference the same identifier. Keep the backlink for provenance even when the norm is woven.

   A norm *binds* only when **both** hold (strict weave):
   - **Scope-overlap** — its `related_files`, file-path globs, ceremony scope, or activity domain intersect this task's owned files, objective, or surface.
   - **Judgment-class** — compliance is a judgment a one-line deterministic check could not make. Mechanical/lint-class norms (file-header rules, scaffolding-marker bans, structural lint) are **never woven** — they route to the hook arm of `route-conventions-by-enforcement-class-delivery-vs`. Judgment-class but no scope-overlap → backlink only (no constraint clause); neither → top-level manifest only.

   Weave only this binding subset — never the full permissive surfaced set, never mechanical norms. The top-level `**Related preferences/conventions:**` audit manifest stays unchanged (Step 5 — full permissive set); strict weaving into task lines is what prevents task-description bloat and dilution.

   Example bound task line:
   ```
   - [ ] Implement the retry wrapper in `src/net/client.py` — surface partial failures rather than swallowing them; honor `error-messages-name-the-failed-operation-and-the-fix` (name the failed operation and the corrective action in every raised error). [[knowledge:conventions/error-messages-name-the-failed-operation-and-the-fix]] [class: standard]
   ```

   Route invalid units:

   - **"Verify X" / "Check Y"** → phase-level `**Verification:**` objective; do not duplicate into each task description.
   - **"Capture Z" / "Append session note"** → lead-side post-phase step (`lore capture` or `notes.md`); not worker work.
   - **Single-line edits, single CLI invocations, sub-edits** → fold into the adjacent implementation task.

   **Task format (intent+constraints).** Default. State what the change accomplishes, what not to do, and what success looks like at the deliverable level. Opt into prescriptive format with `**Task format:** prescriptive` for mechanical work where step-by-step instructions are required.

2. **Concordance-assisted annotation** — after drafting phases, widen each phase's `**Knowledge context:**` block:
   ```bash
   lore prefetch "<phase objective> <key file paths>" --type knowledge --limit 5 --scale-set=<bucket>
   ```
   Declare `--scale-set` explicitly for every prefetch call. Missing declaration is an error.

   **Scale rubric** — declare `--scale-set` explicitly on every prefetch. The four tiers (`abstract`, `architecture`, `subsystem`, `implementation`), boundary tests, multi-label encoding rules, and the ±1 query pattern live in `skills/memory/SKILL.md` Scale-Aware Navigation — read that section before declaring if the right bucket is not obvious. For decision-tree details see the `classifier` agent template (lore repo `agents/classifier.md`).

   Add relevant entries as `[[knowledge:...]]` backlinks with "— why relevant" annotations. Investigation findings are the primary source; concordance is a widener.

   **Distribute surfaced preferences/conventions into per-phase Knowledge context (mandatory).** The top-level `**Related preferences/conventions:**` block from Step 2 discovery is an audit manifest — it does not reach workers. To wire into worker `{{prior_knowledge}}`, distribute each surfaced entry into `**Knowledge context:**` of every phase whose scope plausibly overlaps:

   - **Scope-overlap test:** an entry overlaps when its `related_files`, file-path globs, ceremony scope, or activity domain intersects the phase's `**Files:**`, objective, or owned subsystem. Apply permissively — the Step 2 surfacing gate carries through to distribution. If a reviewer would expect the worker aware of the entry while editing the phase's files, distribute.
   - **Format:** add as `[[knowledge:preferences/<entry>]]` (or `conventions/`, or `cross-cutting-conventions/`) in `**Knowledge context:**`, with a worker-facing "— what to honor at implement time" annotation. Implementation-facing means tell the worker what to *do*, not just what it says.
   - **Distribute to multiple phases when warranted.** Cross-cutting conventions touching every phase's files belong in every phase's Knowledge context — duplication is correct here because each phase is its own `/implement` worker batch needing its own seeds. Do not consolidate across phases.
   - **No-overlap entries stay in the top-level manifest only.** If after permissive review an entry binds to no phase, leave it solely in `**Related preferences/conventions:**` — the manifest preserves the audit trail.
   - **Distribution is permissive; weaving is strict — two separate channels.** This step (per-phase `**Knowledge context:**`) carries every scope-overlapping entry, judgment-class or not, as a backlink — the worker can dismiss inapplicable ones. Weaving into a task's constraint clause (Deliverable contract gate above) is the *strict* subset: only the judgment-class entries that also scope-overlap the task become imperative constraint clauses naming the norm by its stable label. A judgment-class entry that binds to a task gets **both** — the backlink here (provenance + `{{prior_knowledge}}` seed) and the woven clause in the task line (the instruction the worker executes). A mechanical entry gets only the backlink (it is never woven).
   - **Why distribute here:** `/implement` Step 3.1 (directive branch) resolves seeds via `resolve-manifest.sh` from `**Knowledge context:**` backlinks + `**Files:**` paths. Distributing here flows entries through seeds → directive → worker `{{prior_knowledge}}` without new protocol surface in `/implement`.

3. **Retrieval directive derivation** — after concordance widening, populate `**Retrieval directive:**` for each phase. Derivable from phase content alone; no user input.

   **Per-topic decomposition (v2 — default):** the directive is a list of `(topic, scale_set, [activity_vocab])` — **exactly one focal topic** plus **up to five adjacent topics**. Each topic fires its own BM25 OR query at its own scale_set; the worker prompt's `## Prior Knowledge` block ends up sectioned (`### Focal: <topic>` / `### Adjacent: <topic>`).

   - **Focal topic.** The phase's primary subject. Default `scale_set: subsystem,implementation`. Seeds: phase's owned files (from `**Files:**`) plus `[[knowledge:...]]` entries in `**Knowledge context:**` about that subsystem. Prefer **title-vocabulary terms** (the entry's title tokens) over the topic label — title vocabulary resolves to entries the index can rank, while raw `knowledge:...` strings tokenize as a single literal and miss the index.
   - **Adjacent topics (≤5).** Subsystems the phase touches but does not own. Default `scale_set` one tier above focal's bottom — typically `architecture,subsystem`. Seeds: title-vocabulary terms from canonical entries about *that adjacent subsystem* — not the topic label, not the focal seeds. Weak seeds (right scale, wrong entries) are the dominant failure mode — re-derive from adjacent entries' titles and resolved paths.
   - **Activity vocabulary (optional, per topic).** Attach when topic files imply a recurring practice (writing tests, emitting telemetry, capturing). Look up tokens from `$KDIR/_meta/activity-vocab.yaml` by matching its file-path globs against the topic's owned files; **do not invent activity tokens inline**. The activity-vocab file is the single authority. When present, the topic fires one extra BM25 OR query at the same `scale_set` with these tokens (`query_kind=activity`).
   - **Strict v2 invariant.** A v2 directive MUST have exactly one `role: focal` entry. Zero-focal or multi-focal v2 is a hard parse error in `generate-tasks.py` — not silently accepted, not normalized to legacy. If no genuine focal candidate emerges (e.g., purely cross-cutting refactor), emit the legacy flat directive — that path remains valid for rollout compatibility.

   **Seeds derivation (mandatory):** per topic, collect from two sources — (a) `[[knowledge:...]]` backlinks in `**Knowledge context:**` whose subject matches the topic (resolve to entry title and path-vocabulary terms before emitting — raw `knowledge:` strings won't tokenize); (b) `**Files:**` paths the topic owns (verbatim). Deduplicate per topic. Empty seed union → the topic itself is suspect; drop it rather than emit an empty `seeds:` bullet.

   **Defaults:** `hop_budget: 1`. Per-section limits: focal `limit: 8`, adjacent `limit: 4` (tunable). `scale_set:` is **mandatory per topic**; omitting is an error. Pick `abstract`, `architecture`, `subsystem`, or `implementation`; multi-label form (e.g., `architecture,subsystem`) is allowed for adjacent pairs. Omit `filters:` unless type or category filtering adds value.

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

Inspect `phase_cost_summary` as a sanity check — a single task far larger than its peers may signal an under-decomposed deliverable worth a closer read. Cost diagnostics are advisory only; the Plan-as-unit rule, Phase-as-unit rule, and Deliverable contract gate in Step 5b are the binding gates. Do not split tasks merely because they fall above an avg-comparison threshold, and do not merge tasks merely because they fall below one. The avg-comparison heuristic is post-hoc and uniform-thinness blind; trust the intrinsic gates instead.

### Step 5.0a: Verify backlinks

```bash
bash ~/.lore/scripts/verify-plan-backlinks.sh "$WORK_DIR/<slug>/plan.md" "$KNOWLEDGE_DIR" --fix
```

Output: `{verified: N, corrected: [...], unresolved: [...]}`.
- If corrections applied: note them briefly.
- If unresolved backlinks remain: carry forward to Step 5.1 as `[broken backlink]` bullets.
- If all resolved: proceed silently.

The Step 5.6 finalize verb re-runs backlink verification terminally; this early pass exists to surface broken links before the Step 5.1 review, not to replace the terminal check.

### Step 5.0b: Knowledge context block audit

For each phase, run `lore search "<phase objective keywords>" --scale-set subsystem,implementation --limit 3`. If results exist but the phase has no `**Knowledge context:**` block, add the most relevant entry as a backlink with an implementation-facing annotation.

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
- [intent anchor] <anchor body verbatim from `_meta.json.intent_anchor`> — **Scope delta:** <none — anchor preserved unchanged | named narrowing> → Step 5b item 0 intent-anchor preservation (omit this bullet when the work item has no `intent_anchor`)
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

Invoke `/remember` scoped to the spec investigation. **Always invoke it — even when no observation appears to meet the gate.** The gate lives in `/remember`; rejecting candidates is `/remember`'s job, not the lead's. Pre-filtering observations because "nothing qualifies, so `/remember` would be a no-op" is the bypass shape named in the commitment protocol — the lead's commitment is to invoke the gate and surface the result, not to short-circuit it. A run that captures zero entries is a valid terminal so long as `/remember` actually evaluated the observations.

Every `lore capture` call must carry provenance flags; for captures promoted from researcher observations, preserve the original producer's attribution:

- **Lead-original insights:** `--producer-role spec-lead --protocol-slot Synthesis --work-item <slug> --template-version $LEAD_TEMPLATE_VERSION`
- **Researcher-sourced observations:** `--producer-role researcher --capturer-role spec-lead --source-artifact-ids <researcher-report-ids> --protocol-slot Synthesis --work-item <slug> --template-version $RESEARCHER_TEMPLATE_VERSION`
- **Multi-producer synthesis:** one capture call per distinct producer — never merge.

```
/remember Research findings from <work item title> — Read all **Observations:** entries from investigation reports in plan.md and evaluate each: mechanism-level patterns, design rationale, and structural footprint signals all qualify; implementation facts already expressed in Tier-2 assertions do not. Also capture cross-investigation synthesis patterns not surfaced individually.

Apply the provenance flags above on every `lore capture`.
```

---

### Step 5.5: Post-plan ceremony evaluation

**Ceremonies always run before terminal finalization.** No flag skips this step; no flag is required to run it. Judgment applies to acting on output, not to whether the registered obligation executes.

```bash
EVALUATORS=$(lore ceremony get spec-post-plan --work-item <slug>)
```

Invoke every registered evaluator. Present its output to the user. If the lead accepts changes, revise `plan.md`, repeat the affected review gates, and run a fresh evaluator attempt. After each terminal attempt, make the normalized outcome judgment and file it under `--ceremony spec-post-plan` using the ceremony outcome filing contract.

Do not finalize while a post-plan result still requires a plan edit or human decision. `needs-decision` is durable evidence of that open judgment, not permission to route around it.

Run Step 5.6's two lead-owned preflight asserts now, without finalizing: check every instructed invocation against the **live script**, and check that **Tier-2 emission instructions** point to the canonical validator contract. If either assert — or the finalize verb itself — refuses, fix `plan.md` and re-run the affected ceremony before Step 5.6 invokes `lore spec finalize`.

With the post-plan ceremony terminal and both preflight asserts passing, a hosted session journals the plan-ready milestone before entering Step 5.6:

```bash
if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
  bash ~/.lore/scripts/session-step.sh \
    --step-id spec:plan-ready --step-label "Plan ready" \
    || echo "[spec] Warning: plan-ready step not journaled; the persisted plan and preflight result remain authoritative." >&2
fi
```

Finalization emits no step of its own — `lore spec finalize` keeps the later, distinct `terminus_reached` row, and a refused preflight or finalize synthesizes no step history.

---

### Step 5.6: Finalize through the spec verb

**Lead-owned preflight (two prose asserts the verb cannot run):** validate emitted artifacts against their live consumers, never from memory: (1) any script invocation block the plan instructs agents to run must match the live script's current flags (check `--help` or source — script schemas drift faster than plans); (2) Tier-2 emission instructions point at the validator's canonical required-field set rather than enumerating fields inline. Fix `plan.md` first if either fails — a deterministic script can assert JSON structure, but adjudicating prose against live sources is the lead's judgment.

Then close the plan through the finalize verb. Do not hand-run its composed checks or writers; `finalize` owns backlink verification, the intent-anchor hard gate, task regeneration, healing, retrieval-directive assertions, its `spec-verb` atom, and last-write telemetry:

```bash
lore spec finalize <slug>
```

Show the verb's output. The anchor gate enforces structural anchor preservation and scope-delta attestation, not semantic non-drift — semantic alignment between the anchor and the rest of the plan remains a spec-author responsibility, with downstream reviewers (e.g., `/codex-plan-review`) as the semantic backstop. A no-anchor work item reports the gate as `skipped` with the verifier's reason (absence is legible, not silent).

**Refusal handling:**
- **Exit 3 (intent-anchor gate) or an emission-contract assert failure:** surface the named diagnostic (verifier code 2 = section missing, 3 = body diverges, 4 = `**Scope delta:**` missing; contract failures name the failing phase), fix `plan.md`, and re-run `lore spec finalize <slug>` until it passes.
- **Exit 2 (ambiguous reference):** re-run with the exact slug.
- **Exit 1 (validation, precondition, or composed-script failure):** fix the named diagnostic before re-running.

A refused finalize emits no telemetry row and no `spec-verb` atom; re-running after a fix appends a fresh point-event row per run — expected, not duplication.

---

### Step 6: Iterate and suggest retro

If gaps are identified (from evaluator feedback or user review):
- Author a targeted follow-up investigation manifest, run `lore spec open` again, and execute the returned directives.
- Append new findings to the Investigations section.
- Update the synthesis.

Run `lore work heal` after any changes.

After finalization, suggest:
```
Consider `/retro <slug>` to evaluate knowledge system effectiveness for this spec.
```

---

## Plan.md Template

When emitting `plan.md` in Step 5b (including item 0's Intent Anchor render), read `skills/spec/templates/plan.md` for the canonical plan structure. The sidecar holds the full fenced template — Goal, Narrative, Intent Anchor, Strategy, Context, Investigations, Design Decisions, Architecture Diagram, Phases, Open Questions, Related — with the inline HTML-comment guidance preserved alongside each section it governs.
