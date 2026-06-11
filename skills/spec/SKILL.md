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
   - If `--model <id>` is present, export per-role overrides for the duration of this skill: `export LORE_MODEL_LEAD=<id> LORE_MODEL_RESEARCHER=<id> LORE_MODEL_ADVISOR=<id>` (one shot — no env mutation outside the skill). Otherwise let `resolve_model_for_role` (lib.sh) pick the per-role binding from the active framework's role map. Per-role resolution honors the precedence: env override → per-repo `.lore.config` → user `settings.json` `harnesses.<active>.roles.<role>` → `harnesses.<active>.roles.default`. Multi-provider harnesses (opencode) honor `provider/model` syntax; single-provider harnesses (claude-code, codex) accept bare model ids only — `validate_role_model_binding` rejects mismatches.
   - The remaining text is the **input**.

2. Resolve the work path:
   ```bash
   lore resolve
   ```
   Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

3. Compute template versions for provenance. Resolve agent paths via `resolve_agent_template` (lib.sh) — the canonical lore-repo `agents/<name>.md` is hashed regardless of active harness. The skill path uses the harness skills install path (`~/.claude/skills/` on Claude Code, `~/.codex/skills/` on Codex; resolve via `resolve_harness_install_path skills`):
   ```bash
   source ~/.lore/scripts/lib.sh
   SKILLS_DIR=$(resolve_harness_install_path skills)
   LEAD_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$SKILLS_DIR/spec/SKILL.md")
   RESEARCHER_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$(resolve_agent_template researcher)")
   ADVISOR_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$(resolve_agent_template advisor)")
   ```
   On call failure, fall through with empty string. `scorecard-append.sh` registers into `$KDIR/_scorecards/template-registry.json` on first use. Missing `Template-version:` warns+passes (CC-01 backwards-compat) so legacy emitters don't block.

4. Resolve input via `lore work resolve` (handles exact-slug, fuzzy, branch-matching, and archive fallback):

   ```bash
   if RESULT=$(lore work resolve "$INPUT" --branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"); then
     SLUG=$(printf '%s' "$RESULT" | sed -n '1p')
     ARCHIVED=$(printf '%s' "$RESULT" | sed -n '2p')
     # resolved → continue to the per-state branches below
   else
     case $? in
       1) ;;  # no match → treat input as freeform description (see "If NOT resolved" below)
       2) echo "Multiple work items match '$INPUT' (candidates on stderr above)." >&2
          # disambiguate via AskUserQuestion against the resolver's candidate list, then re-invoke
          exit 1 ;;
     esac
   fi
   ```

   - **If resolved item has `ARCHIVED=true`:** Warn the user and wait for explicit confirmation before continuing.
   - **If resolved** → load the work item:
    - Read `_meta.json.intent_anchor` when present. Treat it as the capability anchor from work-item intake — an interpreted one-sentence statement of the user-visible capability the work must deliver, audited for looseness at intake (alternatives, comparatives without targets, vague verbs) and tightened via user clarification before commit. The spec may refine implementation shape, but it must not silently narrow or remove the capability implied by this statement; any such change is a user-visible scope delta. Preserve the wording verbatim when restating it — downstream gates (Step 5.5 verifier, `/implement` anchor prompts) detect drift by string comparison, so a paraphrase here breaks the audit chain even when intent is preserved.
     - `plan.md` with synthesis complete (Design Decisions + Phases) → skip to Step 5.1. Load any `## Strategy` silently as shaping context.
     - `plan.md` with `## Investigations` and findings but no synthesis → skip to Step 5. Load any `## Strategy` silently; do not re-prompt.
     - Investigations with `## Open Questions` needing follow-up → dispatch targeted follow-ups.
     - `plan.md` incomplete → present for discussion/editing. If no `## Strategy` and synthesis has not run, offer the strategy gate (Step 4) first.
     - No `plan.md` → continue to Step 2.
   - **If NOT resolved** → treat input as freeform description, go to Goal Refinement.
   - **If no input at all** → try branch inference; if no match, ask what they want to spec.

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
   <!-- Sunset: remove these two sub-checks if retro-evolution rows targeting skills/spec/SKILL.md change-type new-failure-mode citing unverified-current-state or missed-integration-seam evidence recur from ≥3 new distinct work items within the next 20 spec cycles. -->
6. **External skill and agent discovery (strict — exclude lore protocol toolchain)** — after reading key files, scan for relevant *external* skills and agents:
   - Lore-managed skills (`/spec`, `/implement`, `/work`, `/memory`, `/remember`, `/retro`, `/evolve`, `/renormalize`, `/self-test`, `/followup-discuss`, `/bootstrap`, `/pr-*`, `/codex-*`) are **excluded** — they are protocol toolchain, not advisors. Target external skills (security review, language tooling, harness helpers, domain reviewers).
   - Build the exclusion list from the canonical lore repo:
     ```bash
     source ~/.lore/scripts/lib.sh
     LORE_SOURCE_REPO="$LORE_REPO_DIR"
     LORE_SKILL_NAMES=$(ls "$LORE_SOURCE_REPO/skills/" 2>/dev/null | grep -v '\.md$')
     LORE_AGENT_NAMES=$(ls "$LORE_SOURCE_REPO/agents/"*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//')
     ```
   - Glob `<skills_dir>/*/SKILL.md` (resolve via `resolve_harness_install_path skills`); skip names in `$LORE_SKILL_NAMES`; read remaining frontmatter (`name`, `description`) and first section.
   - Glob `<agents_dir>/*.md` (resolve via `resolve_harness_install_path agents`); apply the same name filter against `$LORE_AGENT_NAMES`; read remaining template name and opening description.
   - Match work item title, description, and key findings against the surviving (external) skill/agent names by keyword overlap. **Skill match criterion is strict:** include only when the skill's stated domain plausibly contributes to *this* work item's implementation — not "could in theory be invoked someday."
   - Deep-read any SKILL.md or agent template with strong overlap.
   - Emit a skill discovery block (mandatory):
     ```
     **External skill discovery:**
     Considered: <comma-separated list of external skill names checked, after lore-toolchain filter>
     Matched: <skill-name — rationale> (or "none")
     ```

7. **Preferences and conventions discovery (permissive — include if possibly relevant)** — after skill discovery, surface every preference or convention that *might* apply, even tangentially:
   - **Inclusion criterion is the inverse of skill discovery.** The test is "is it *possible* the work might need this" — not "will we definitely apply it." Any topic, file pattern, ceremony, surface, or activity overlap (even loose) qualifies. Err on the side of over-inclusion; synthesis culls. Missing an applicable preference is worse than carrying an inapplicable one through review.
   - Enumerate canonical directories so nothing is missed by ranking:
     ```bash
     KDIR=$(lore resolve)
     for dir in "$KDIR/preferences" "$KDIR/conventions" "$KDIR/cross-cutting-conventions"; do
       [[ -d "$dir" ]] && ls "$dir"
     done
     ```
     Missing directories count as zero; one absent category does not fail the scan.
   - Run BM25 queries at both altitudes to catch entries the directory walk misses by topic affinity:
     ```bash
     lore search "<work item topic>" --type knowledge --scale-set subsystem,implementation --limit 10
     lore search "<work item topic>" --type knowledge --scale-set abstract,architecture --limit 5
     ```
     Retain results whose path is under `preferences/`, `conventions/`, or `cross-cutting-conventions/`.
   - Read each candidate's title and lead paragraph; deep-read any with surface-level overlap.
   - Emit a discovery block (mandatory):
     ```
     **Preference and convention discovery:**
     Scanned: <count> entries across preferences/, conventions/, cross-cutting-conventions/ + <count> BM25 hits
     Surfaced:
       - [[knowledge:preferences/<entry>]] — why it might apply (1 line)
       - [[knowledge:conventions/<entry>]] — why it might apply (1 line)
     ```
     If nothing surfaced after permissive review, write `Surfaced: none`.

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
7. **Create team via orchestration adapter.** The adapter at `adapters/agents/<framework>.sh` exposes `spawn` / `wait` / `send_message` / `collect_result` / `shutdown` as the dispatch contract; it emits `delegate:<tool> ...` directives the skill body translates into native tool calls (Claude Code: `TeamCreate` / `TaskCreate` / `SendMessage` / `TaskList` / `TaskGet`; opencode/codex: plugin-runtime / subagent-spawn APIs). Before creating the team, query capability gates:
   ```bash
   ADAPTER="$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh"
   ENFORCEMENT=$(bash "$ADAPTER" completion_enforcement)  # native_blocking | lead_validator | self_attestation | unavailable
   TEAM_MESSAGING=$(framework_capability team_messaging)  # full | partial | fallback | none
   ```
   - `ENFORCEMENT` shapes the retry/abandon decision in Step 3 (per `adapters/agents/README.md` §"Completion Enforcement Degradation Modes").
   - `TEAM_MESSAGING != full` collapses only the shared-team layer: skip `TeamCreate`, `SendMessage`, and on-disk team config; use a lead-side handle map. Do **not** collapse to `--short` while `subagents` remains available — continue with lead-orchestrated fanout and serial collection.
   - `subagents=none` is the `--short` collapse point: if the adapter cannot spawn isolated researcher contexts, fall back to Step 2a.

   On Claude Code (default), team creation is the native `TeamCreate` tool:
   ```
   TeamCreate: team_name="spec-<slug>", description="Investigating <work item title>"
   ```
   When `TEAM_MESSAGING != full` (opencode/codex today), skip team creation and initialize an in-memory handle map keyed by investigation number.
8. Read your team lead name from the active harness's teams install path (resolved via `resolve_harness_install_path teams`; typically `~/.claude/teams/` on Claude Code), at `<teams_dir>/spec-<slug>/config.json`. Frameworks where `install_paths.teams=unsupported` (e.g. codex today) cannot persist team config — use the lead-side handle map instead of on-disk config.
9. Create investigation tasks — for each question, route through the adapter's `spawn` operation:
   ```bash
   RESEARCHER_MODEL=$(bash "$ADAPTER" resolve_model_for_role researcher)
   bash "$ADAPTER" spawn researcher "<task_prompt>" "$RESEARCHER_MODEL"
   # → delegate:TaskCreate role=researcher model=<id>  (claude-code)
   ```
   On Claude Code the lead invokes `TaskCreate` with the directive's role/model; one `TaskCreate` per question with full question, context, file hints, and expected report format.
   - Mandatory **External skill and agent applicability** investigation — instructions: (a) evaluate implementation-phase applicability (not investigation phase); (b) read actual SKILL.md files; (c) **exclude lore-managed skills and agents** (exclusion list from `source ~/.lore/scripts/lib.sh; printf '%s\n' "$LORE_REPO_DIR"`, matched by parent-directory name); (d) strict match criterion — skill domain must plausibly contribute to *this* work item, not "could in theory be invoked"; (e) report `**Matched skills:**` / `**Matched agents:**` blocks after `**Implications:**`. `**Matched skills:** none` after filtering is a valid terminal.
   - Mandatory **Preferences and conventions applicability** investigation — instructions: (a) enumerate `$KDIR/preferences/`, `$KDIR/conventions/`, `$KDIR/cross-cutting-conventions/` directly (absent = zero, not error), plus BM25 at `subsystem,implementation` and `abstract,architecture` retaining hits under those paths; (b) **permissive** inclusion — include if it is *possible* the work might need to honor the entry; (c) read title and lead paragraph, deep-read on surface overlap; (d) report `**Surfaced preferences/conventions:**` block after `**Implications:**` listing each entry as `[[knowledge:<path>]] — 1-line "why it might apply"`. Err on over-inclusion; synthesis culls. No surfaced entries → report `**Surfaced preferences/conventions:** none`.
10. Pre-fetch knowledge for each investigation:
    ```bash
    PRIOR_KNOWLEDGE=$(lore prefetch "<investigation topic>" --format prompt --limit 5 --scale-set=<bucket>)
    ```
11. **External skill-applicability scan (strict — exclude lore protocol toolchain):** identifies skills relevant to this work item but does NOT spawn advisor agents on the default route. Per D1/D3, default-route consultations are handled inline by the spec-lead (and `/implement`'s lead at implementation time); skill-backed domains are invoked directly via the `Skill` tool when a researcher SendMessages a question. Applicable external skills are recorded in (a) an in-memory `$SKILL_INVOCATION_MAP` consulted inline if a researcher routes a question to that domain, and (b) the `**Related skills:**` block in `plan.md` (added in Step 5 Discovery findings integration).
    a. Scan the skill list in your system prompt. **Filter out lore-managed skills** (`/spec`, `/implement`, `/work`, `/memory`, `/remember`, `/retro`, `/evolve`, `/renormalize`, `/self-test`, `/followup-discuss`, `/bootstrap`, `/pr-*`, `/codex-*`) before matching — protocol toolchain, not advisors. Apply a strict match criterion: include only when the skill's domain plausibly contributes to *this* work item's implementation. Emit a skill discovery block (mandatory):
       ```
       **External skill discovery:**
       Considered: <comma-separated list of external skills checked, after lore-toolchain filter>
       Matched: <skill-name — rationale> (or "none")
       ```
    b. For each matched skill, read its SKILL.md and record an entry in `$SKILL_INVOCATION_MAP` keyed by domain (skill name + scope). The lead consults this map inline when a researcher's SendMessage routes to that domain — invokes the skill via the `Skill` tool and replies with its output.
    c. **`$ADVISORY_MIXIN` is empty on the default route.** Researcher prompts do not receive `scripts/agent-protocols/advisory-consultation.md`; the mixin is consumed only by `/implement` when a phase declares `**Advisors:** ... mode: persistent`. `/spec` neither authors nor consumes `mode: persistent` declarations. The legacy advisor-spawn / mixin-build path (`agents/advisor.md` per matched skill + `{{advisors}}` resolution) is gated behind a `SPEC_PERSISTENT_ADVISORS_OPT_IN` flag that no `/spec` surface flips today — preserved as reference for a future opt-in surface, unreachable on the default route.
12. Spawn researcher agents — `min(investigation_count, 4)` in a single message via the adapter's `spawn` operation. Use the `researcher` agent template (`resolve_agent_template researcher`; Claude Code path `~/.claude/agents/researcher.md`) with injections: `{{team_name}}` → `spec-<slug>`, `{{team_lead}}` → lead name, `{{prior_knowledge}}` → `$PRIOR_KNOWLEDGE`, `{{template_version}}` → `$RESEARCHER_TEMPLATE_VERSION`. On the default route `$ADVISORY_MIXIN` is empty (per Step 2b.11.c) and mixin concatenation is a no-op. Concatenation is conditional: append `$ADVISORY_MIXIN` after the resolved template with a blank-line separator **only if non-empty** (opt-in path; default `/spec` never populates). Per-spawn model selection routes through `resolve_model_for_role researcher` (or the `--model` override from Step 1.1); the adapter validates the role→model binding against `model_routing.shape` and rejects mismatches without silent fallback.

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
     `evidence-append.sh` validates the row via `validate-tier2.sh` before appending to `$KDIR/_work/<slug>/task-claims.jsonl`. The validator enforces that `exact_snippet` is a non-empty string, `normalized_snippet_hash` matches `^[0-9a-f]{64}$`, and the hash equals `sha256(v1_normalize(exact_snippet))` — rows that fail any check are rejected. Direct writes to `task-claims.jsonl` bypass validation and are treated as corrupt.
   - **On validation failure:** `evidence-append.sh` exits non-zero. Either fix the row and retry, or log the failure to `execution-log.md` and proceed. Schema-valid absence is acceptable; silent corrupt writes are not.
   - After successful append, write a human-readable mirror entry to `$KDIR/_work/<slug>/evidence.md`. Do not write a mirror entry for a row that failed validation.
   - **Absence semantics:** if no assertions or lead-observed task claims exist, both `task-claims.jsonl` and `evidence.md` may be absent — absence means "no Tier-2 claims captured this session," not "work was fully verified."

5. **Full branch only:** When all investigation tasks are complete:
   - Send shutdown via the adapter: `bash "$ADAPTER" shutdown <handle> true` for each researcher handle, **plus each advisor handle if any were created on the opt-in path.** Default-route Step 2b.11 spawns no advisor agents (`$SPEC_PERSISTENT_ADVISORS_OPT_IN=false`), so skip the advisor-shutdown block silently; researcher shutdown always runs. On Claude Code each shutdown expands to `delegate:SendMessage handle=<id> type=shutdown_request approve=true` invoked as the native `SendMessage` tool. When `team_messaging=none` the adapter returns `unsupported` and the skill relies on harness-native session cleanup (Codex subagent-stop, OpenCode plugin-runtime kill).
   - Run `TeamDelete` (Claude Code only; opencode/codex adapters require no explicit teardown — runtime owns lifecycle).

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
     # Rows → $KDIR/_work/<slug>/consumption-contradictions.jsonl; lore audit consumes as priority-input.
   else
     # consumption-contradiction-append.sh not yet installed (follow-on pending)
     bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source spec-lead \
       --template-version "$LEAD_TEMPLATE_VERSION" <<< \
       "consumer-contradiction emission skipped — consumption-contradiction-append.sh not found"
   fi
   ```

   Emission is non-blocking — synthesis continues immediately.

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

0. **Intent anchor** — if the work item has an `intent_anchor` in `_meta.json`, render a `## Intent Anchor` section in `plan.md` immediately after `## Narrative` and before `## Strategy`/`## Context`. Write the anchor body **verbatim** from `_meta.json.intent_anchor` — no quoting, no prefix label, no paraphrase. ... Before decomposing, name the tempting narrower implementation that would appear successful while violating the anchor; ensure Exit Criteria and Verification cover the load-bearing promise or explicitly label the scope delta.

   Follow the anchor with a `**Scope delta:**` line (default `none — anchor preserved unchanged`; if the spec narrows the capability, name the narrowing here) and a `**Tempting narrower implementation:**` heading the spec author fills in. The anchor body and `**Scope delta:**` line are **verifier-enforced** — the Step 5.5 gate refuses to regenerate tasks if missing or divergent. The `**Tempting narrower implementation:**` body is template-prescribed but not verifier-enforced — its presence forces the author to confront the failure mode, but the content is free-text that no parser can adjudicate. For work items without an `intent_anchor` field, omit the section entirely — the Step 5.5 verifier skips with a one-line stderr info message.

1. **Phases** — concrete implementation phases with tasks, file paths, objectives. Each phase includes `**Knowledge context:**`, `**Tasks:**` (checkbox lines), and optional `**Retrieval directive:**` / `**Advisors:**` / `**Verification:**` / `**Scope:**` blocks.

   **Plan-as-unit rule.** A plan is **one** phase by default. Each additional phase is a separate `/implement` worker batch with its own dispatch ceremony — write one phase per plan unless the split earns its keep across the entire run.

   Split a plan into multiple phases **only when all three** conditions hold:

   1. **Cross-phase parallelism** — at least one later phase has tasks with file targets disjoint from all earlier phases, so `/implement` dispatches concurrently. If file overlap forces every later phase sequential, `generate-tasks.py` chains them onto one worker — merging yields the same execution shape with less ceremony.
   2. **Independent deliverable boundary** — each phase produces a coherent artifact a reviewer could accept, capture, or roll back on its own — not a sub-step of the next.
   3. **Architectural checkpoint** — an interface, contract, schema, or substrate finalizes at the boundary that later phases consume as stable input. File-overlap sequencing is not a checkpoint; visual organization is not a checkpoint.

   If any condition fails, merge. The Phase-as-unit rule below still applies *within* the merged phase: most consolidated plans land at one phase, one task.

   **Phase-as-unit rule.** A phase is the default delegation unit. Write **one** `- [ ]` checkbox per phase by default — deliver the phase objective across the listed files while honoring the phase design decisions. Each task spawns a fresh worker that loads ~22KB of fixed context plus the phase brief; a phase split has to earn that overhead.

   Split a phase into multiple tasks **only when all four** conditions hold:

   1. **Disjoint file ownership** — tasks edit non-overlapping file sets. Tasks sharing a file get chained sequentially by `generate-tasks.py` onto one worker — the split buys nothing.
   2. **Independently reviewable deliverables** — each task produces a coherent artifact a reviewer could accept or reject on its own.
   3. **Real parallel execution** — the split enables concurrent work, not serialized hand-off.
   4. **No residue** — neither side is solely verification, capture, cleanup, single-CLI invocation, or a sub-edit of the other.

   If any condition fails, keep one task. Cross-phase dependencies are file-based. Uniform same-mechanism edits across many files stay one task — one worker doing one read-modify-write pass beats N fresh agents repeating the same edit.

   **Deliverable contract gate.** Every task line names a durable artifact outcome — what gets built, refactored, authored, migrated, wired, or added. The valid primary verbs are: Implement / Refactor / Author / Migrate / Add support for / Wire... The following primary verbs are **never tasks** — they belong elsewhere: Verify / Check / Inspect / Run / Capture / Append / Cross-link / Note / Document-only.

   A valid task line states the **deliverable**, the **owned file or surface**, and at least one **design or integration constraint** that scopes the worker's choices.

   <!-- INVARIANT — canonical /spec weave vocabulary. Keep these terms stable; the
        /implement worker report's `Convention handling:` field and the lead's
        completeness comparison key on them. Drift silently breaks the handoff.
          - "constraint clause" — the imperative norm woven into a task line
          - "woven norm" / "binding norm" — a surfaced norm that became a constraint clause
          - "stable label" — the entry slug/title the backlink resolves to; the
            identifier shared with the worker report and the lead comparison -->
   **Weave binding judgment-class norms into the constraint clause.** When a preference/convention from Step 5 Discovery *binds* to a task, render it as an imperative **constraint clause** in the task line itself — the instruction the worker executes — not only as a `**Knowledge context:**` backlink the worker must choose to fetch. The clause **names the norm by its stable label** (the entry slug/title the backlink resolves to) so the worker's `Convention handling:` report and the lead's completeness comparison reference the same identifier. Keep the backlink for provenance even when the norm is woven.

   A norm *binds* only when **both** hold (strict weave):
   - **Scope-overlap** — its `related_files`, file-path globs, ceremony scope, or activity domain intersect this task's owned files, objective, or surface.
   - **Judgment-class** — compliance is a judgment a one-line deterministic check could not make. Mechanical/lint-class norms (file-header rules, scaffolding-marker bans, structural lint) are **never woven** — they route to the hook arm of `route-conventions-by-enforcement-class-delivery-vs`. Judgment-class but no scope-overlap → backlink only (no constraint clause); neither → top-level manifest only.

   Weave only this binding subset — never the full permissive surfaced set, never mechanical norms. The top-level `**Related preferences/conventions:**` audit manifest stays unchanged (Step 5 — full permissive set); strict weaving into task lines is what prevents task-description bloat and dilution.

   Example bound task line:
   ```
   - [ ] Implement the retry wrapper in `src/net/client.py` — surface partial failures rather than swallowing them; honor `error-messages-name-the-failed-operation-and-the-fix` (name the failed operation and the corrective action in every raised error). [[knowledge:conventions/error-messages-name-the-failed-operation-and-the-fix]]
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

   **Distribute surfaced preferences/conventions into per-phase Knowledge context (mandatory).** The top-level `**Related preferences/conventions:**` block from Step 5 Discovery is an audit manifest — it does not reach workers. To wire into worker `{{prior_knowledge}}`, distribute each surfaced entry into `**Knowledge context:**` of every phase whose scope plausibly overlaps:

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
- [intent anchor] <anchor body verbatim from `_meta.json.intent_anchor`> — **Scope delta:** <none — anchor preserved unchanged | named narrowing> → Step 5b.0 intent-anchor preservation (omit this bullet when the work item has no `intent_anchor`)
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

### Step 5.5: Generate tasks.json and finalize

Before regenerating `tasks.json`, run the intent-anchor verifier:

```bash
bash scripts/verify-plan-intent-anchor.sh <slug>
```

This gate enforces structural anchor preservation and scope-delta attestation, not semantic non-drift — semantic alignment between the anchor and the rest of the plan remains a spec-author responsibility... A free-text "preserve near Goal" instruction is rhetoric without an actionable required check — exactly the failure mode this gate exists to close.

Semantic alignment also falls to downstream reviewers (e.g., `/codex-plan-review`). The verifier exits 0 when `## Intent Anchor` body matches `_meta.json.intent_anchor` and `**Scope delta:**` is present; exits 0 with a one-line stderr info when the work item has no `intent_anchor` field (absence is legible, not silent); exits non-zero (2 = section missing, 3 = body diverges, 4 = `**Scope delta:**` missing) otherwise. On any non-zero exit, **do not proceed** to `lore work regen-tasks` — surface the error, address the gap in `plan.md`, and re-run until it passes.

```bash
lore work regen-tasks <slug>
```

Run `lore work heal`.

**Emission contract round-trip (mandatory):** after regen-tasks, validate emitted artifacts against their live consumers, never from memory: (1) every `retrieval_directive` in tasks.json carries non-empty `seeds` AND non-empty `scale_set` (jq assert; a bare/empty directive → fix the plan block or apply the omission rule, then regen); (2) any script invocation block the plan instructs agents to run must match the live script's current flags (check `--help` or source — script schemas drift faster than plans); (3) Tier-2 emission instructions point at the validator's canonical required-field set rather than enumerating fields inline.
<!-- Sunset: remove if evidence-gap retro-evolution rows targeting skills/spec/SKILL.md citing consumer-contract drift recur from ≥3 new distinct work items within the next 20 spec cycles. -->

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

When emitting `plan.md` in Step 5b (and the corresponding Step 5b.0 Intent Anchor render), read `skills/spec/templates/plan.md` for the canonical plan structure. The sidecar holds the full fenced template — Goal, Narrative, Intent Anchor, Strategy, Context, Investigations, Design Decisions, Architecture Diagram, Phases, Open Questions, Related — with the inline HTML-comment guidance preserved alongside each section it governs.

---

## Resuming a spec across sessions

When `/spec` is called on a work item that already has a plan:
- Read existing investigations/context — they are your memory (no need to re-explore).
- If a `## Strategy` section exists, read it silently and use it as shaping context — do not re-prompt.
- Check if synthesis (Design/Phases) is complete; if not, synthesize from existing findings.
- Check Open Questions — dispatch follow-up investigations for unresolved items.
- **Always run the approval gates before finalizing:** whether synthesis was just completed or carried over from a prior session, proceed through Step 5.1 (Confirm understanding) and Step 5.3 (Task review). Do not skip because the plan "already exists." Exception: if `--yes` was passed, these gates are auto-approved.
