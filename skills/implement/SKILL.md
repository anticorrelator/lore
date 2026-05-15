---
name: implement
description: "Execute a spec's plan with a knowledge-aware agent team — spawns workers, tracks progress, captures architectural findings"
user_invocable: true
argument_description: "[--yes] [work item name]"
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - TaskCreate
  - TaskUpdate
  - TaskList
  - TaskGet
  - Task
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
  - Skill
---

# /implement Skill

Executes a work item's `plan.md` with a team of knowledge-aware agents. Agents produce Tier 2 task evidence during work and optionally surface Tier 3 candidates for commons promotion. The lead verifies, promotes accepted candidates via `lore promote`, and writes a retro-prep bundle for the next-step `/retro` ceremony.

## Approach

**Approach this work from confidence, not caution.** Mistakes are part of working; most are recoverable through normal review. The cost of constant deferral on settled steps exceeds the cost of occasional errors caught later. When the rubric or the protocol gives you a clear path, take it. Defer at genuine forks (multiple plausible directions where the protocol does not pre-decide) or at high-blast-radius operations (destructive, hard-to-reverse, or shared-state-affecting). Defer is a tool for forks, not a default for actions.

## Resolve Paths

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

Agent template files live in the lore repo under `agents/<name>.md` and are surfaced to the active harness via `resolve_agent_template <name>` (or, equivalently, the harness's `resolve_harness_install_path agents` directory, which is symlinked to the lore repo `agents/` by `install.sh`). On Claude Code that resolves to `~/.claude/agents/<name>.md`. Do NOT use `git rev-parse --show-toplevel` for agent paths — the current repo is the target project, not the lore repo.

**MANDATORY:** You MUST read the actual template files for `worker` and `advisor` when spawning agents — resolve each via `resolve_agent_template worker` and `resolve_agent_template advisor` (or read directly from the active harness's agents install path on Claude Code: `~/.claude/agents/worker.md` and `~/.claude/agents/advisor.md`). Do NOT skip this step. Do NOT generate inline agent prompts as a substitute. If the resolver fails or the files are missing, stop and report the error — never fall back to improvised prompts.

## Resolve Template Versions

Compute content-hashes of the agent templates you'll spawn and the skill template itself. These feed the `template_version` provenance field on every downstream emission site (`evidence-append.sh` via worker prompt, `lore promote`, `write-execution-log.sh`, scorecard rows), plus the `{{template_version}}` injection into each agent's resolved prompt:

```bash
source ~/.lore/scripts/lib.sh
SKILLS_DIR=$(resolve_harness_install_path skills)
LEAD_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$SKILLS_DIR/implement/SKILL.md")
WORKER_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$(resolve_agent_template worker)")
ADVISOR_TEMPLATE_VERSION=$(bash ~/.lore/scripts/template-version.sh "$(resolve_agent_template advisor)")
```

Use these variables throughout the rest of the skill. The three are NOT interchangeable — each tags emissions produced by its matching template. If `template-version.sh` fails for any template, log a warning and continue with an empty string; downstream scripts treat the omitted flag as "no template version" (CC-01 legacy warn+pass).

Registration into `$KDIR/_scorecards/template-registry.json` is handled automatically on first use by `scripts/scorecard-append.sh` — no separate registration step.

## Protocol-to-Skill Projection (9 → 7)

Proposal §9.2 describes the flow as nine logical steps. This SKILL.md presents them as seven top-level `### Step N` sections — a compatibility-preserving projection that keeps related concerns (load vs. verify vs. promote) on clean section boundaries. The mapping:

| §9.2 Logical Step | SKILL.md Step |
|---|---|
| 1 Load tasks.json + Tier 2 evidence + prefetched commons | Step 1 |
| 2 Dispatch workers with scope, files, acceptance checks, evidence requirements | Step 2 + Step 3 |
| 3 Workers produce code + tests + Tier 2 + optional Tier 3 | Step 3 |
| 4 Lead verifies work output + Tier 2 evidence | Step 4 |
| 5 Lead separates accepted work from remembered doctrine | Step 4 |
| 6 Lead writes/updates execution evidence | Step 4 |
| 7 Lead runs `lore promote` on accepted Tier 3 | Step 5 |
| 8 Stop hook lazily triggers audit; completion non-blocking | Step 6 (reference only; no explicit call) |
| 9 Prepare `/retro` inputs | Step 7 |

**Lead-inline route variant.** Step 3.0 introduces a pre-dispatch short-circuit. When the plan satisfies the lead-inline conditions (single prescriptive task, no persistent advisor, no required pre-edit orchestration — file count is no longer gated), §9.2 steps 2–6 collapse into direct lead execution: the lead applies edits using its own tools, emits Tier 2 evidence with `LEAD_TEMPLATE_VERSION`, then jumps to Step 5 (promote) → Step 6 (followup gate) → Step 7 (cleanup). No team is created and no workers spawn.

### Step 1: Load work item and validate

1. Parse arguments: extract work item name. The `--model <id>` flag is an undocumented per-invocation override that, when present, exports `LORE_MODEL_LEAD=<id>` for the duration of this skill — it stamps only the lead role for this run and does NOT touch worker/advisor/researcher bindings. Per-role models for spawned agents always come from `resolve_model_for_role <role>` against the active framework's role map; the override is a one-shot escape hatch, not a documented user-facing API. (Per-role overrides via `LORE_MODEL_<ROLE>` env vars are honored independently.) The `--yes` flag is the documented user-facing escape hatch for the Step 1.5b anchor-coverage gate's misaligned-route prompt — when present, the gate skips the `AskUserQuestion` prompt and defaults to the recommended remediation (re-spec, i.e. exit `/implement` with the prescribed-next-command line `Next: run /spec <slug>`; the lead does NOT auto-invoke `/spec`). The flag mirrors `/spec --yes` semantics. **`--yes` NEVER skips the gate evaluation itself** — per `inside-lore-protocol-silent-skip-is`, only the user-facing prompt is suppressed; the lead still evaluates anchor-vs-plan coverage, still emits the `execution-log.md` row, and still respects the legacy-no-anchor branch's logged-skip contract. `--yes` does not affect any other prompt in this skill (e.g., the Step 1.2 archived-item confirmation or the Step 2.3 checksum-mismatch prompt remain interactive).
2. **Resolve the user-provided string to a canonical slug — delegate to `lore work resolve`, then stop.** Do NOT improvise via `ls`, `find`, or directory listing — the resolver is the canonical fuzzy source, and it carries the exact-slug fast path internally (filesystem probe on `_meta.json` before any index read). **Do NOT use `lore work show` here:** it is a human-readable presentation command (pretty-prints `plan.md` and `notes.md` into one rendered blob); its output is not a programmatic data surface, and consuming it here forces you to parse the rendered view of files you are about to read directly in step 3. The single-call resolution:

   ```bash
   if RESULT=$(lore work resolve "$INPUT" --branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"); then
     SLUG=$(printf '%s' "$RESULT" | sed -n '1p')
     ARCHIVED=$(printf '%s' "$RESULT" | sed -n '2p')
     if [[ "$ARCHIVED" == "true" ]]; then
       ITEM_DIR="$WORK_DIR/_archive/$SLUG"
     else
       ITEM_DIR="$WORK_DIR/$SLUG"
     fi
   else
     case $? in
       1) echo "[implement] No work item matches '$INPUT'. Stop — do not fall back to broader filesystem inspection." >&2; exit 1 ;;
       2) echo "[implement] Multiple work items match '$INPUT' (candidates on stderr above). Disambiguate via AskUserQuestion and re-invoke with a unique reference." >&2; exit 1 ;;
     esac
   fi
   ```

   The output of this step is exactly two values — `SLUG` (canonical) and `ARCHIVED` (boolean) — plus the derived `ITEM_DIR`. Nothing else is consumed downstream; `_meta.json` and `plan.md` on disk are the source of truth for everything else.

   - **If resolved item is archived (`ARCHIVED=true`):** Warn the user: "This work item is archived. Proceed anyway?" Wait for explicit confirmation. If the user confirms, continue with `ITEM_DIR=$WORK_DIR/_archive/<slug>`; otherwise stop.
   - **If no candidate matches:** report the failure to the user and stop. Do not fall back to broader filesystem inspection.
3. **Read the on-disk source-of-truth files directly with `Read`** — not via `lore work show`, not via shell piping. The CLI's job ended at step 2; from here the files on disk are authoritative:
   - `$ITEM_DIR/_meta.json` — metadata, including `intent_anchor` (consumed by Step 1.5b).
   - `$ITEM_DIR/plan.md` — phases, design decisions, retrieval directives, task lists (consumed by Step 2 and Step 3.1).
   - `$ITEM_DIR/notes.md` — last entry for session continuity.
   Every downstream step (Step 1.5b's anchor read, Step 2's phase enumeration, Step 3.1's retrieval-directive lookup) reads these files; do not pre-summarize or pre-parse them via rendered CLI output here.
4. **If no `plan.md`:** Tell user "No structured plan found. Run `/spec` first to create phases and tasks."
5. **If `plan.md` has no `## Phases` or no unchecked `- [ ]` items:** Tell user "All plan tasks are already complete."

**Gate:** Anchor-coverage start gate (prose-named "Step 1.5b" — unnumbered by design; preserves Step 1's existing 1.1–1.8 numbering and downstream cross-references). Read the anchor. Read the plan. Decide whether the plan as written will deliver the capability the anchor names.

This is a **lead-attested semantic check, not machine-enforced.** No script adjudicates the alignment verdict; the lead's discretion-bearing read of `_meta.json.intent_anchor` against `plan.md` is the only judge. The sibling structural check (`scripts/verify-plan-intent-anchor.sh`, called by `/spec`) is deliberately distinct — it verifies the anchor block's presence and exact-whitespace match, never its semantic coverage. Do not confuse this gate with a hardened verifier.

**Routing contract (the four things):**
- **Inputs:** `_meta.json.intent_anchor` (verbatim body, with all original whitespace) and `plan.md` (its `## Phases` section, task lists, and verification objectives).
- **Success route:** verdict `aligned` → continue to Step 1.6 (branch cache write).
- **Fallback:** legacy-skip when `_meta.json.intent_anchor` is empty or absent — silent at the user-facing surface, one row logged to `execution-log.md` (mirrors `verify-plan-intent-anchor.sh`'s exit-0-with-stderr-info pattern and Step 6.4's legacy fallback).
- **Lifecycle:** the `misaligned-respec` and `abort` exit branches fire BEFORE Step 1.6 (branch-cache write), Step 2 (TeamCreate), Step 3 (worker dispatch), any code edits, and any `notes.md` writes. The required `execution-log.md` row is the only side effect on those exit branches. Failing earlier wastes less; placing the gate before run-state markers keeps a misaligned-and-aborted run from leaving stale cache or team artifacts.

**Verdict shape (start-time):** binary — `aligned` | `misaligned`. There is no `partial` rung here. The trichotomous `full | partial | none` shape is closure-time only (Step 6.2); at start-time nothing has shipped, so residue routing has no meaning.

**On `aligned`:** write a one-line **Anchor fit statement** (required, non-empty) — the lead's brief explanation of *why* the plan covers the anchor (e.g., "Phases P1–P3 implement the X capability the anchor names via the Y mechanism"). This mirrors Step 6.2's `capability_loop_summary` requirement on `full` — every lead-attested verdict carries a one-line attestation explaining the verdict, so an empty/silent `aligned` cannot degrade to a yes-button reflex. Then emit one `execution-log.md` row per the D6 template below and continue to Step 1.6.

**On `misaligned`:** name the misalignment gap (anchor capability vs plan scope) in a one-line statement, then offer via `AskUserQuestion` exactly three options. **Re-spec is the first/recommended option** (label suffix `(Recommended)`):

- **(a) re-spec (Recommended)** — exit `/implement` with the prescribed-next-command line `Next: run /spec <slug>`. The lead does NOT auto-invoke `/spec`; control returns to the user so they can read the gap themselves and run `/spec` deliberately. Write one `execution-log.md` row with `Anchor-coverage gate: misaligned-respec`, a non-`None` `Misalignment gap:` field, and `Remediation choice: run /spec <slug>`. Write NOTHING to `notes.md`. Then exit.
- **(b) override** — proceed anyway with an explicit scope-delta acknowledgment. **Dual write** to BOTH `execution-log.md` (one row with `Anchor-coverage gate: misaligned-override` and `Override scope delta:` non-`None`) AND `notes.md` (a single-line entry under a fresh timestamp heading: `## YYYY-MM-DDTHH:MM\n**Anchor-coverage override:** <one-line scope delta>`). The dual write mirrors Step 6.2's `partial` pattern — execution-log carries the structured/machine-readable trail retro reads; notes.md carries the human session-timeline entry. Then continue to Step 1.6.
- **(c) abort** — exit `/implement` immediately. Write one `execution-log.md` row with `Anchor-coverage gate: abort`, a non-`None` `Misalignment gap:`, and `Remediation choice: none (user aborted)`. Write NOTHING to `notes.md` (no human-facing timeline entry, since the user explicitly chose to walk away). Then exit.

**`--yes` semantics:** when the lead was invoked with `--yes` (parsed in Step 1.1 above), skip the `AskUserQuestion` prompt and default to (a) re-spec without prompting. The execution-log row, the misalignment-gap field, and the prescribed-next-command exit text are emitted identically to the interactive re-spec path. **`--yes` NEVER skips the gate evaluation itself** — per `inside-lore-protocol-silent-skip-is`, the evaluation always runs; only the user-facing prompt is suppressed.

**Legacy-no-anchor branch:** if `_meta.json.intent_anchor` is empty or absent, skip the user-facing prompt silently and emit one `execution-log.md` row with `Anchor-coverage gate: legacy-skip`. No `AskUserQuestion`, no anchor-fit statement, no misalignment-gap. This is the only authorized silent prompt in the gate; the skip is still logged so the audit loop fires. Mirrors `verify-plan-intent-anchor.sh`'s exit-0-with-stderr-info pattern and Step 6.4's legacy fallback.

**Execution-log emission (every verdict):** for ALL five verdicts (`aligned`, `misaligned-respec`, `misaligned-override`, `abort`, `legacy-skip`), pipe a fixed-body payload through `write-execution-log.sh`. The body uses these labeled lines in **exact order**, with free-text field values rendered as either the literal `None` or a single-line JSON string (so internal anchor newlines survive the append without breaking line anchors):

```
Anchor-coverage gate: <aligned|misaligned-respec|misaligned-override|abort|legacy-skip>
Intent anchor: <JSON string of verbatim anchor body, or None on legacy-skip>
Anchor fit statement: <JSON string one-line on aligned, None on every other verdict>
Misalignment gap: <JSON string one-line on misaligned-* and abort, None on aligned and legacy-skip>
Override scope delta: <JSON string of lead acknowledgment on misaligned-override, None on every other verdict>
Remediation choice: <continue|run /spec <slug>|none (user aborted)|none (legacy skip)>
```

Note the field provenance: `Anchor-coverage gate`, `Anchor fit statement`, `Misalignment gap`, `Override scope delta`, and `Remediation choice` are all **lead-attested** (no script verdicts them). `Intent anchor` is **machine-sourced** (a verbatim copy of `_meta.json.intent_anchor`'s body), rendered through `json.dumps` so newlines are escaped for line-anchor stability. The user-facing `AskUserQuestion` body still displays the anchor verbatim with original whitespace per `work-item-intake-should-store-neutral-intent-ancho` — only the execution-log encoding uses the JSON-string single-line form for parser stability.

Concrete invocation example (the `aligned` verdict):

```bash
ANCHOR_JSON=$(printf '%s' "$INTENT_ANCHOR" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
FIT_JSON=$(printf '%s' "$ANCHOR_FIT_STATEMENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
printf 'Anchor-coverage gate: aligned\nIntent anchor: %s\nAnchor fit statement: %s\nMisalignment gap: None\nOverride scope delta: None\nRemediation choice: continue\n' \
  "$ANCHOR_JSON" "$FIT_JSON" \
  | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
```

The `misaligned-respec`, `misaligned-override`, `abort`, and `legacy-skip` rows follow the same shape — same six labeled lines in the same order — with the per-verdict required values from the table above and `None` for fields the verdict does not carry. The user-facing prompt MUST restate `_meta.json.intent_anchor`'s body **verbatim** (no paraphrase, no neutralization, no distillation) per `work-item-intake-should-store-neutral-intent-ancho` — the JSON-string single-line encoding is for the execution-log row only.

**Output contract:** items 6, 7, 8 below retain their numbering and prose textually unchanged. Cross-references elsewhere in SKILL.md to Step 1.7 (around line 326, line 840) continue to resolve. Step 3.0, Step 6.2, and Step 7 wording is untouched.

6. **Write branch cache** — associate the current branch with this work item for downstream lookup:
   ```bash
   lore work cache-branch --write <slug>
   ```
   If the command fails, log `[implement] Warning: branch cache write failed` and continue — non-fatal.
7. **Load prior Tier 2 evidence** — read `$KDIR/_work/<slug>/task-claims.jsonl` if it exists. This is the canonical log of Tier 2 claims written by prior workers on this work item (via `evidence-append.sh`). Parse each line as JSON and build an in-memory map keyed by `task_id` and by files touched (from the row's `files` field if present, or fall back to the row's claim text). This map feeds Step 3's worker `{{prior_knowledge}}` injection — each worker receives only the Tier 2 rows whose `task_id` matches its assigned task or whose files overlap with the task's `**Files:**` block. If the file is absent or empty, skip silently (first `/implement` run on this item).
8. Present a brief summary and proceed immediately. Resolve the role→model bindings for the roles this skill spawns (`lead`, `worker`, `advisor`) by calling `resolve_model_for_role <role>` for each, then render them as a status line so the operator sees what models the active framework's role map will produce:
   ```bash
   LEAD_MODEL=$(resolve_model_for_role lead)
   WORKER_MODEL=$(resolve_model_for_role worker)
   ADVISOR_MODEL=$(resolve_model_for_role advisor)
   ```
   Output:
   ```
   [implement] <Title>
   Models: lead=$LEAD_MODEL  worker=$WORKER_MODEL  advisor=$ADVISOR_MODEL
   Phases: N with M unchecked tasks
   Prior Tier 2 claims: K rows loaded from task-claims.jsonl (or "none — first run")
   ```
   On a default install all three resolve to the active harness's role-map default; per-repo `.lore.config` or user `settings.json` `harnesses.<active>.roles.<role>` overrides flow through automatically. If `--model <id>` was passed in Step 1.1, `$LEAD_MODEL` reflects that override; worker/advisor lines remain at the configured map values.

### Step 2: Create team and generate tasks

**IMPORTANT: Create the team BEFORE creating tasks.** TaskCreate calls go into whichever task list is active. If you create tasks before TeamCreate, they land in the session's default list — invisible to workers who see the team's list. This produces orphaned stale tasks that persist for the rest of the session.

0. **Resolve the orchestration adapter and query its capability gates.** Every team operation in this skill (spawn, send_message, collect_result, shutdown) routes through the active framework's orchestration adapter at `adapters/agents/<framework>.sh`. The adapter emits `delegate:<tool> ...` directives that the skill body translates into harness-native tool calls — on Claude Code that means `TeamCreate` / `TaskCreate` / `SendMessage` / `TaskList` / `TaskGet`; on opencode/codex the same directives map to plugin-runtime / subagent spawn APIs.
   ```bash
   ADAPTER="$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh"
   ENFORCEMENT=$(bash "$ADAPTER" completion_enforcement)  # native_blocking | lead_validator | self_attestation | unavailable
   TEAM_MESSAGING=$(framework_capability team_messaging)  # full | partial | fallback | none
   ```
   - `ENFORCEMENT` shapes the per-task verification fork in Step 4.1 (per `adapters/agents/README.md` §"Completion Enforcement Degradation Modes"). On `native_blocking` (Claude Code) the harness rejects malformed worker reports synchronously; on `lead_validator` the lead must run the post-hoc validator described in the README; on `self_attestation` and `unavailable` the lead degrades further per the same doc.
   - `TEAM_MESSAGING=none` collapses this skill to lead-inline execution (Step 3.0): no TeamCreate, no worker spawns. The skill is gated to harnesses whose `team_messaging=full` per `adapters/capabilities.json.skills.implement.requires`; the gate fires here.

1. **Create team first:**
   ```
   TeamCreate: team_name="impl-<slug>", description="Implementing <work item title>"
   ```
   On Claude Code this is the realized output of the adapter's team-init contract. On opencode/codex the adapter emits `delegate:plugin_team_init` / `delegate:codex_subagent_init` (see `adapters/agents/README.md` §"Per-Harness Mapping"); the skill body invokes the documented translation when running under those frameworks.

   **`team_name` MUST be exactly `impl-<work-item-slug>`** — the slug suffix has to match the work item directory name in `$KDIR/_work/` byte-for-byte. The TaskCompleted hook (`scripts/task-completed-capture-check.sh`) derives the work-item slug by stripping the `impl-` prefix from `team_name`. The `lore work check` and Tier 2 evidence reads are all affected by the same convention. Use the exact slug.

2. **Read your team lead name** from the active harness's teams install path (resolved via `resolve_harness_install_path teams`; typically `~/.claude/teams/` on Claude Code), at `<teams_dir>/impl-<slug>/config.json`. Frameworks whose `install_paths.teams=unsupported` (codex today) cannot persist team config — the adapter returns a lead-side handle map instead, and the skill reads the lead name from the map.

3. **Load tasks** — run a single command that validates the checksum and outputs all tasks as structured text:
   ```bash
   lore work load-tasks <slug>
   ```
   - **If `tasks.json` exists and checksum matches:** outputs a header line followed by `=== task-N ===` blocks, one per task, each with `subject`, `activeForm`, `blockedBy`, and `description`.
   - **If `tasks.json` exists but checksum mismatches:** exits with an error. Tell the user: "plan.md was edited after tasks.json was generated. Run `/work regen-tasks <slug>` to regenerate, or edit plan.md back." Wait for user decision.
   - **If `tasks.json` does not exist:** exits with an error. Run the fallback instead (item 4 below).

4. **Fallback — `tasks.json` missing:** Run the task generation script:
   ```bash
   lore work tasks <slug>
   ```
   This generates and prints the full `tasks.json` schema. Pipe through `lore work load-tasks <slug>` afterward (it will now find the file), or re-run `lore work load-tasks <slug>` directly.

5. **Create tasks from the output:** Read the `lore work load-tasks` output once. For each `=== task-N ===` block, execute one `TaskCreate` call using the `subject`, `activeForm`, and `description` fields. Track the mapping of `task-N` IDs to actual TaskCreate return IDs, then call `TaskUpdate(addBlockedBy=[...])` for any task with a non-empty `blockedBy` field.

   **Per-task descriptions are lean by design** — each description begins with a `**Phase:** N` line (the authoritative phase-number source per D6) followed only by the task-specific assignment (objective, files, scope). Phase-level context (Design Decisions, Verification, Strategy, Reference files, Knowledge backlinks) lives in `tasks.json → phases[N-1].phase_context` and is fetched lazily by the worker via `lore work phase-context <slug> <phase-number>` after `TaskGet`. The lead does NOT need to embed phase context into `TaskCreate` description fields.

   **Backward-compatibility:** legacy `tasks.json` files (generated before this change) do not carry a `phase_context` field. `lore work phase-context` exits 0 with empty stdout for those files; workers that receive empty output proceed using the inline phase context already present in their description (the old behavior). No regen is required before resuming implementation on a legacy work item.

6. **Build phase map** — after `lore work load-tasks` succeeds, read `tasks.json` directly to build an in-memory phase map indexed by 1-based phase number:
   ```bash
   python3 -c "
   import json, sys
   with open('$WORK_DIR/<slug>/tasks.json') as f:
       data = json.load(f)
   for p in data['phases']:
       print(p['phase_number'], json.dumps(p.get('retrieval_directive')))
   "
   ```
   Store the result as `$PHASE_MAP`: a mapping of `phase_number → {objective, files, retrieval_directive}`. This map is the authoritative source for per-phase retrieval directives consumed by Step 3.1.

   If `tasks.json` is missing (fallback path from Step 2.4), run this step after the fallback generation completes.

### Step 3.0: Lead-inline gate (pre-dispatch short-circuit)

Before spawning anything, evaluate whether the plan qualifies for **lead-inline execution**. Worker dispatch's value is parallelism across independent tasks plus discretion-bearing context for intent+constraints work; both vanish when the plan reduces to a single fully-determined edit. The ~22KB context tax per spawn plus TeamCreate + TaskCreate + completion round-trip is then pure overhead.

The gate fires when **all four** conditions hold:

1. **Single task** — `tasks.json` contains exactly one task across all phases (count unchecked `- [ ]` entries on `plan.md`'s `**Tasks:**` blocks; cross-check against `tasks.json` task array length).
2. **Prescriptive format** — the task's containing phase declares `**Task format:** prescriptive` in `plan.md`. Intent+constraints tasks involve worker discretion shaping the outcome; lead-inline removes that discretion channel and is unsafe for them.
3. **No persistent advisor declaration** — no phase declares an `**Advisors:** ... mode: persistent` line. Per D2, advisor declarations without `mode: persistent` (e.g. `[must-consult]`, `[on-demand]`) become lead-handled inline on the default route and do NOT spawn a separate advisor agent, so they do not by themselves disqualify lead-inline; only `mode: persistent` declarations are persistent team members tied to the team lifecycle and disqualify it.
4. **No required pre-edit consultation or skill invocation** — the selected phase declares no `**Consultations required:**` domains, AND `lore ceremony get implement` returns `[]` (today's flat skill-list ceremony stays on the lead-invocation route — see Step 3.4 — so a non-empty ceremony list means the lead must invoke a skill before editing), AND plan.md's `**Related skills:**` block declares no entries the lead must invoke for the selected phase's scope. `**Consultations required:**` describes work the lead would have to satisfy before applying edits, which has no inline analogue when no team exists; a ceremony skill or related-skill entry signals the same — there is a skill the lead must invoke and log before editing.

   **Lead route with a lead-invoked skill in scope.** When condition 4 fails *only* because plan.md's `**Related skills:**` lists one or more skills (and the other three conditions hold), the lead route remains eligible *provided* the lead first invokes each in-scope skill via the `Skill` tool and records the invocation in `execution-log.md` via `write-execution-log.sh` before applying any edits. The invocation log line uses the format `Lead-invoked skill: <skill-name>\nDomain: <domain>\nSkill template-version: <hash>\n` and stamps `--template-version "$LEAD_TEMPLATE_VERSION"`. If condition 4 fails because of `**Consultations required:**` or a non-empty ceremony list, fall through to Step 3 worker dispatch — those signals indicate orchestration the lead-inline route is not designed to carry.

**No file-count cap.** An earlier version of this gate required ≤3 files. Evidence from the scale-registry-rename cycle (single prescriptive task, 10 verbatim file edits, no discretion) showed the cap was a proxy for "discretion required" that the other conditions already cover better. Single-task + prescriptive + no-persistent-advisor + no-required-pre-edit-orchestration collapses both worker-dispatch values — parallelism across independent tasks, and discretion-bearing context — regardless of file count. A 50-file prescriptive rename is still 50 file edits with no discretion; splitting across workers pays N × ~22KB context tax for no shaping gain. File count is logged below as diagnostic telemetry but does not gate.

**If any condition fails:** skip Step 3.0 entirely and proceed to Step 3 (worker dispatch). Do not log a skip — the worker pipeline is the default.

**If all conditions hold:** apply edits inline.

1. **Log the gate firing** — append one line to `execution-log.md` so retro can attribute the route taken:
   ```bash
   printf 'Lead-inline execution: gate fired\nConditions: single task, prescriptive, no persistent advisor, no required pre-edit orchestration\nFile count (diagnostic): %d\nTask: %s\n' \
     "<file-count>" "<task-subject>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

2. **Invoke in-scope skills before editing (if any).** If plan.md's `**Related skills:**` block lists skills that apply to the selected phase's scope (and the lead route remained eligible per the condition-4 carve-out above), invoke each via the `Skill` tool with `args` matching the phase's objective, then record the invocation in `execution-log.md`:
   ```bash
   SKILL_TV=$(bash ~/.lore/scripts/template-version.sh "$SKILLS_DIR/<skill-name>/SKILL.md")
   printf 'Lead-invoked skill: %s\nDomain: %s\nSkill template-version: %s\n' \
     "<skill-name>" "<domain>" "$SKILL_TV" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```
   Per D3, the skill's output informs the edits the lead applies in step 3. If the `**Related skills:**` block is empty or no entries apply to this phase's scope, skip this sub-step silently.

3. **Apply the edits directly** using the lead's `Read` / `Edit` / `Write` / `Bash` tools, honoring the phase's `**Verification:**` objectives implicitly. The task description still loads via `lore work load-tasks <slug>` — read it the same way a worker would, then execute the prescriptive instructions yourself.

   **Reviewer-facing comment discipline applies to the lead too.** Any
   comment or docstring you write into committed source is read by
   maintainers with no protocol context. Before saving:
   - No `D1`/`D2`/`D3`/`D6` decision IDs, no `P1`/`P2` phase references, no
     `[[knowledge:...]]` / `[[work:...]]` backlinks, no "per D3" / "see the
     spec" / "see the plan" cross-refs.
   - No protocol-speak as load-bearing vocabulary in comments: "harness",
     "invariant" (in the "promise/contract" sense), "structural", "by-design",
     "asymmetric-by-design", "load-bearing", "consumer downstream" — rewrite
     from the maintainer's POV if a comment needs them to parse.
   - No multi-paragraph architectural essays inline. Reasoning longer than
     2-3 lines belongs in `plan.md`, the commit message, or the PR
     description — never in inline source.
   - Audit before commit: `grep -nE 'D[0-9]+|per P[0-9]|class invariant|load-bearing|by-design|consumer downstream' <touched-files>`.

   See preference `never-leave-lore-internal-scaffolding-markers-in-c.md` for the
   full rationale; this rule is the source-code analog of the existing
   "PR descriptions must be reviewer-facing" preference.

4. **Emit Tier 2 evidence** for any falsifiable claims the edits depend on. Use `LEAD_TEMPLATE_VERSION` — the lead is the producer in this route:
   ```bash
   echo '<tier2-row-json>' \
     | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>
   ```

5. **Stash any Tier 3 candidates** the lead notices for Step 5 promotion. Promotion still goes through `lore promote` with `--producer-role implement-lead --template-version "$LEAD_TEMPLATE_VERSION"`.

6. **Mark the task complete** on the plan checkbox:
   ```bash
   lore work check <slug> "<task-subject>"
   ```

7. **Skip Steps 3, 4, and Step 7's TeamDelete** — there is no team to shut down. Proceed directly to **Step 5 (Promote accepted Tier 3 candidates)**, then **Step 6 (Followup creation gate)**, then **Step 7 (Cleanup and report)** with `Tier 2 claims written: <count>` reflecting the lead's emissions.

**Sanctioned pause:** if the lead is unsure whether the prescriptive task is fully determined enough to execute without discretion, fall through to Step 3 worker dispatch. Lead-inline is a short-circuit, not a forced route.

### Step 3: Spawn agents

**You MUST spawn workers immediately after Step 3.6 completes.** Do not pause to confirm scope. Do not echo plan-resolved open questions back to the user (the plan already encodes scope guards in task descriptions). Do not surface "this is large" or "this will take many rounds" as a decision request. Do not request approval to modify a skill because the skill being modified is the running skill (your prompt is loaded; file edits do not affect the current run). The only sanctioned pre-dispatch pauses are: (a) the work item resolved to an `[archived]` item without explicit confirmation (Step 1.2), (b) `tasks.json` checksum mismatch (Step 2.3), (c) the `worker` agent template is missing (i.e., `resolve_agent_template worker` errors per Step 1's MANDATORY clause), or (d) the Step 3.0 Lead-inline gate fired and execution already completed inline (skip Step 3 entirely). Pausing for any other reason is a faster-path bypass — the cost is borne by the user as session-spanning delay; the lead pays nothing. **Why immediate dispatch matters:** one bad spawn is caught in Step 4 review; pre-dispatch confirmation does not buy safety the system already provides.

1. **Pre-fetch knowledge for worker prompts** — build `$PRIOR_KNOWLEDGE` by iterating over each phase in `$PHASE_MAP`. For every phase, apply the three-branch gate in priority order:

   **(a) Directive branch — retrieval_directive is non-null for this phase:**
   Resolve the directive via `resolve-manifest.sh` before spawning any workers:
   ```bash
   PHASE_PK=$(bash ~/.lore/scripts/resolve-manifest.sh "<slug>" "<phase_number>" 2>/dev/null || true)
   ```
   Append non-empty output under a `### Phase N: <phase_name>` heading into `$PRIOR_KNOWLEDGE`. A retrieval directive is authoritative over the other branches for its phase — do not also run prefetch or skip-check for that phase.

   **Sectioned output for v2 directives.** When the phase's directive is `version: 2` (per-topic decomposition — see `/spec` Step 5b), `resolve-manifest.sh` emits a multi-section block under the phase heading: one `### Focal: <topic>` section followed by zero or more `### Adjacent: <topic>` sections. Each section is independently top-K-bounded (focal=8, adjacent=4 default; D3 budget) and dedup'd by file_path with focal precedence. The dispatcher passes this resolved block through to workers verbatim — no per-section re-ranking, no merge into a single ranking. Activity-vocab hits (when the focal topic carries `activity_vocab`) appear *inside* the focal section's served entries (no separate `### Activity:` section); the second BM25 OR query is logged as `query_kind=activity` for telemetry.
   
   **Legacy flat directives** (no `version` field, single `scale_set`, single seed list) continue to resolve to a single-section block at the declared scale via the same `resolve-manifest.sh` call — the dispatcher does not need to branch on directive shape. Notational change only at this step; the script handles the shape.

   **(b) Task-description branch — no directive, but task descriptions contain `## Prior Knowledge`:**
   **Skip prefetch for this phase.** The phase already embeds resolved knowledge from annotation. Appending would duplicate or conflict.

   **(c) Fallback branch — no directive AND no `## Prior Knowledge` in task descriptions:**
   Run complementary prefetch using the phase's file paths and objective:
   ```bash
   PHASE_PK=$(lore prefetch "<phase objective> <file paths from task>" --format prompt --limit 3 --scale-set=<bucket>)
   ```
   Append non-empty output under a `### Phase N: <phase_name>` heading into `$PRIOR_KNOWLEDGE`.

   **Concatenation rule:** accumulate the per-phase outputs (heading + content) into a single `$PRIOR_KNOWLEDGE` string separated by blank lines. Phases that produce no output (branch b skip, or branch a/c with zero results) contribute no heading. The final `$PRIOR_KNOWLEDGE` is injected into the `{{prior_knowledge}}` slot in `agents/worker.md` at spawn time (Step 3.6). Do not inject a partial-phase bundle — resolve all phases before spawning any worker. For v2 directives, the injected block is the multi-section shape (`### Focal:` / `### Adjacent:`) described above; workers consume it as candidates-to-curate per `agents/worker.md`'s `## Knowledge Context` directive, not as authoritative pre-resolved context.

2. **Prepare advisory mixin (opt-in only)** — scan all phases in `plan.md` for `**Advisors:**` lines that carry the `mode: persistent` suffix. Per D1/D2, only `mode: persistent` advisors opt into the advisor-agent route; declarations without that suffix (`[must-consult]`, `[on-demand]`, bare domain) become lead-handled inline on the default route and do NOT trigger mixin concatenation onto worker prompts.

   **Default route (no `mode: persistent` advisor declarations):** set `$ADVISORY_MIXIN=""` and skip the entirety of this sub-step. Do NOT read `scripts/agent-protocols/advisory-consultation.md`. Worker prompts will end at the resolved worker template per the D1 default-route contract.

   **Opt-in route (at least one `mode: persistent` advisor declaration):**

   a. **Collect persistent advisor declarations** — filter to lines matching `**Advisors:**\n- <name> — <domain>. mode: persistent` (other modes on the same `**Advisors:**` block are still lead-handled and are NOT collected here).

   b. **Read the advisory mixin:** Read `scripts/agent-protocols/advisory-consultation.md`. The file's opt-in-only header note (D8) confirms this is the correct consumer.

   c. **Build the `{{advisors}}` replacement block** from the collected declarations. Format as a markdown list with name, domain, and mode clearly separated:
      ```
      - **advisor-name** — domain scope. Mode: persistent
      ```

   d. **Resolve `{{advisors}}`** in the mixin content by replacing the placeholder with the block from (c). Store the resolved mixin as `$ADVISORY_MIXIN`.

3. **Skill reconciliation — build skill-invocation map** — per D3, skill-backed advisors stop being agents on the default route. The lead invokes the skill directly via the `Skill` tool when a worker SendMessages a consultation in the skill's domain. This step repurposes the former late-advisor-declaration logic into a per-domain map the lead consults from Step 4.X.

   a. **Read `**Related skills:**`** from plan.md's `## Context` or `## Investigations` section (if present). This is the discovery researcher's output from `/spec`.

   b. **Build `$SKILL_INVOCATION_MAP`** as a JSON object keyed by domain. For each entry in `**Related skills:**` that is NOT already declared as a `mode: persistent` advisor in any phase (per Step 3.2.a), record:
      ```json
      {"<skill-domain>": {"skill": "<skill-name>", "skill_template_version": "<hash>"}}
      ```
      Compute `skill_template_version` via `bash ~/.lore/scripts/template-version.sh "$SKILLS_DIR/<skill-name>/SKILL.md"` at map-build time. The map is consumed by Step 4.X's lead consultation handler when routing a worker SendMessage by domain. Persistent-advisor skills are NOT added to the map — they route to the agent on the opt-in route per Step 3.5.

   c. **Do NOT modify `plan.md`.** This step no longer declares late `**Advisors:**` entries; per D3 the skill's calibration unit is its SKILL.md template-version, captured directly on lead skill invocation in Step 4.X. The map is in-memory state for this run only.

   d. **If no `**Related skills:**` block exists** or all entries are already `mode: persistent` advisors, set `$SKILL_INVOCATION_MAP={}` and skip silently. The lead consultation handler in Step 4.X handles empty-map domains by falling through to inline evaluation.

4. **Ceremony config injection — lead-invocation route by default** — read ceremony-level skill entries and merge them into the lead-invocation map. Per D2, today's `lore ceremony get implement` returns a flat list of skill names that always collapses to lead-invocation; an agent-mode opt-in for ceremony entries requires a future schema extension (`{skill: "<name>", mode: "agent"}`) and is out of scope here.

   a. **Read configured ceremony skills:**
      ```bash
      lore ceremony get implement
      ```
      Returns a JSON array. **If `[]`, skip to Step 3.5.**

   b. **Merge each entry into `$SKILL_INVOCATION_MAP`** — for each ceremony entry NOT already keyed in the map by domain (Step 3.3.b) and NOT declared as a `mode: persistent` advisor (Step 3.2.a), add it under its declared domain (derive from the entry's `domain` field if the schema carries one, else use the skill's name as the domain):
      ```json
      {"<skill-domain-or-name>": {"skill": "<skill-name>", "skill_template_version": "<hash>", "source": "ceremony"}}
      ```
      The lead will invoke these via the `Skill` tool when a worker SendMessages a consultation in the matching domain (Step 4.X). Do NOT spawn advisor agents for these entries.

   c. **Forward-compat: agent-mode entries.** If a future ceremony schema returns `{skill: "<name>", mode: "agent"}` for an entry, treat it as a persistent-advisor opt-in: add it to the persistent-advisor list collected in Step 3.2.a and rebuild `$ADVISORY_MIXIN`. Today no ceremony entry can request agent-mode, so this branch is dormant.

   d. **Log ceremony-injected skills** — for each entry added to `$SKILL_INVOCATION_MAP` from ceremony config:
      ```bash
      printf 'Ceremony-injected skill: %s\nDomain: %s\nSource: ceremony config\nSkill template-version: %s\n' \
        "<skill-name>" "<domain>" "<skill_template_version>" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
      ```

5. **Spawn advisor agents (opt-in only)** — for each unique advisor name collected from Step 3.2.a (the `mode: persistent` filter; per D1 this is the sole opt-in source today, with the dormant Step 3.4.c agent-mode forward-compat branch as a future addition):

   **Skip this entire sub-step when the persistent-advisor list is empty.** No advisor agents spawn on the default route; per D1 the lead handles consultations inline via Step 4.X. The execution-log will record zero `Advisor spawned:` lines for that run, which the Phase 1 verification checks for.

   a. **Build domain context** — find the `## Investigations` section(s) in `plan.md` whose topic relates to the advisor's domain scope. Extract the relevant investigation entry (findings, verified assertions, key files, implications) and format it as the advisor's domain baseline.

   b. **Spawn the advisor** using the `advisor` agent template (resolve via `resolve_agent_template advisor`; on Claude Code that path is `~/.claude/agents/advisor.md`) with these template injections:
      - `{{team_name}}` → `impl-<slug>`
      - `{{advisor_domain}}` → the advisor's domain scope
      - `{{domain_context}}` → the investigation excerpt from Step 3.5a
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

   Advisors are persistent — they remain active for the entire implementation session and are shut down alongside workers in Step 4.

   c. **Write execution log entries** — after all advisors are spawned, log each lifecycle event. Pass `--template-version "$ADVISOR_TEMPLATE_VERSION"` because the content logged is sourced from the advisor template:
      ```bash
      printf 'Advisor spawned: %s\nDomain: %s\nMode: %s\n' \
        "<advisor-name>" "<domain scope>" "persistent" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
      ```

6. **Surface Tier 2 evidence per worker** — before spawning workers, assemble each worker's per-task Tier 2 extract from the map built in Step 1.7. For each assigned task, collect the matching rows (task_id or file overlap) and render them as a YAML block that will be appended to that worker's `{{prior_knowledge}}`:

   ```yaml
   Prior Tier 2 evidence (from task-claims.jsonl):
     - claim_id: <id>
       claim: <one-line claim text>
       task_id: <task-id>
       captured_at_sha: <sha>
   ```

   If no rows match, omit the block (do NOT emit an empty section).

7. **Spawn worker agents with tier-aware emission instructions** — launch `min(recommended_workers, 4)` workers in a single message. Use the `worker` agent template (resolve via `resolve_agent_template worker`; on Claude Code that path is `~/.claude/agents/worker.md`) as the base prompt, with these template injections:

   Workers declare `--scale-set` at every `lore prefetch` and `lore search` call. The rubric they apply:

   **Scale rubric — declare explicitly at every retrieval surface:**

   - **abstract** — portable principle, behavioral law, or design maxim. The claim survives generic-noun substitution: replace project-specific proper nouns with placeholders and the lesson still holds. Abstract entries make a *law*.
   - **architecture** — project-level structure: decomposition, lifecycle, contracts, data model, invariants, cross-component flows, or major platform choices. Architecture entries make a *map*: "A does B, C does D, and E connects them."
   - **subsystem** — local rule about one named area, feature, module, team, command family, integration, or workflow within a larger system. Concrete terms appear as participants in a local workflow rather than as the whole claim.
   - **implementation** — concrete artifact fact: file, function, script, command, limit, field, test, line-level behavior. If removing the artifact name destroys the claim, classify here.

   **Boundary tests:** abstract vs architecture — substitution test (does the claim survive replacing concrete proper nouns with generic placeholders, or does it become "A does B, C does D"?); architecture vs subsystem — whole-project structure or one bounded area?; subsystem vs implementation — can you state the rule without naming a specific function/file/line?

   **Multi-label encoding (retrieval implication):** entries may carry one label or an *adjacent* pair (`abstract,architecture`, `architecture,subsystem`, `subsystem,implementation`); a `--scale-set` query matches an entry if any requested label is in the entry's set. The full decision tree (four tier tests + substitution test + multi-label rules) lives in the canonical `classifier` agent template (resolved via `resolve_agent_template classifier`; lore repo `agents/classifier.md`).

   **±1 query pattern:** fixing a bug → `subsystem,implementation`; adding to a module → `subsystem,implementation`; modifying a component → `architecture,subsystem`; designing a feature → `abstract,architecture`.

   - `{{team_name}}` → `impl-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 2
   - `{{prior_knowledge}}` → the `$PRIOR_KNOWLEDGE` block from Step 3.1, followed by the per-worker Tier 2 evidence block from Step 3.6 (concatenated with a blank-line separator)
   - `{{template_version}}` → `$WORKER_TEMPLATE_VERSION`

   The worker template itself documents the tier-aware emission contract. In summary, workers are required to:

   - **During task:** write each structured Tier 2 claim by piping a JSON row through `echo '<json>' | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>` before sending the completion report. One call per claim. `evidence-append.sh` is the sole-writer for `$KDIR/_work/<slug>/task-claims.jsonl`.
   - **Post task:** send a completion report to the lead that contains the traditional prose fields (**Task**, **Changes**, **Tests**, **Blockers**, **Surfaced concerns**, **Consultations** — renamed from the legacy `Advisor consultations:` field per D4, with the D6 `handler: lead|skill|agent` discriminator), a new **Tier 2 evidence:** field listing the `claim_id` values written during the task, and an optional **Tier 3 candidates:** YAML block with one entry per reusable observation (producer_role + 13-field Tier 3 shape minus `confidence`).
   - **Naming standard:** the optional Tier 3 section MUST be labeled exactly **Tier 3 candidates:** — not "Tier 3 claims" or "Tier 3 observations". The TaskCompleted hook validates literal-prefix-match.

   **If `$ADVISORY_MIXIN` is non-empty (opt-in route only):** append the resolved mixin content after the fully resolved worker template content, separated by a blank line. The worker prompt becomes: `<resolved worker template>\n\n<resolved advisory-consultation.md>`.

   **On the default route `$ADVISORY_MIXIN` is empty** (Step 3.2 short-circuit). Worker prompts end at the resolved worker template — the worker still has the `**Consultations:**` reporting field and the `## Consultation` request shape from the worker template's §Reporting Guidelines, so it can SendMessage the lead per D6a without the mixin. The lead's Step 4.X handler answers on the next turn boundary.

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

### Step 4: Collect progress

As worker messages arrive (delivered automatically), branch by message kind:

- **Consultation requests** — bodies whose first line is `## Consultation` and that carry a `consultation-id:` line route to §0 (Lead consultation handler) below. These are mid-task questions; reply immediately so the worker resumes on the next turn boundary.
- **Completion reports** — bodies whose top-level structure matches the `## Reporting Guidelines` shape from `agents/worker.md` (Task / Changes / Tests / Observations / Tier 2 evidence / Surfaced concerns / Blockers / etc.) route through §1–§7 below.
- **Blocker messages** — anything else from a worker that requires lead intervention falls through to §6.

Maintain a per-run **`$CONSULTATION_TRANSCRIPT`** structure throughout Step 4: a list of records, one per consultation reply the lead emits, with fields `{consultation_id, worker, domain, handler, skill_template_version?, replied_at}`. §0 appends to it on every reply; §1 reads from it to verify required-consultation acknowledgement when accepting a worker's task.

#### Step 4.0: Lead consultation handler (default route)

A worker SendMessage whose body begins with `## Consultation` and carries `consultation-id:` is a worker question routed to the lead per D6a. On the default route the lead answers inline using its own investigation/plan/code-read tools; per D3, skill-backed domains route through `$SKILL_INVOCATION_MAP` and invoke the named skill via the `Skill` tool before the lead replies. This sub-step is judgment-heavy (matching the worker's specific question to investigation/plan context) and intentionally stays inline rather than scripted — see `[[knowledge:conventions/skills/script-first-skill-design]]`.

**Skip this sub-step entirely on the opt-in route** when the worker's phase declared `mode: persistent` advisors — the worker SendMessages the persistent advisor agent directly on that route (per D6a's request-shape note), not the lead, and the advisor agent's reply path is owned by `agents/advisor.md` §"Responding to Consultations". The lead does not intercept opt-in-route consultations.

1. **Parse the request body** (per `agents/worker.md` §"Sending a `## Consultation` Request"):
   - `consultation-id` — opaque worker-minted token
   - `domain` — one-word or short-phrase domain label
   - `reason` — one-sentence trigger
   - `question` — concrete query (may reference files/symbols/line ranges)
   - `task` — worker's current task id and subject
   - `phase` — worker's current phase number

2. **Route by domain** — look up `$SKILL_INVOCATION_MAP[<domain>]`:

   **(a) Skill-backed domain (map entry exists).** Invoke the named skill via the `Skill` tool with the `args` field set to the worker's `question` (and any file/symbol context the question references). Capture the skill's output and the `skill_template_version` already recorded on the map entry. Set `handler="skill"`.

   **(b) No map entry.** Evaluate the question inline using the lead's `Read` / `Grep` / `Glob` / investigation tools, the `plan.md` content already loaded in Step 1, and the in-flight `notes.md`. Set `handler="lead"`. Do NOT spawn an advisor agent on this path — the absence of a map entry is the default-route signal that the lead answers directly per D1.

3. **Reply via SendMessage** to the requesting worker. The reply body, in order:
   ```
   consultation-id: <verbatim from request>
   handler: <skill|lead>
   lead-acknowledged: true
   <when handler=skill>
   skill_template_version: <12-char hash from $SKILL_INVOCATION_MAP[<domain>].skill_template_version>
   <end conditional>

   <answer body — concrete, anchored, ready for the worker to apply>
   ```

   `lead-acknowledged: true` is the acknowledgement field per D6a; it is what `§1.b` cross-checks for required-consult satisfaction.

4. **Append a transcript record** to `$CONSULTATION_TRANSCRIPT`:
   ```
   {"consultation_id": "<id>", "worker": "<worker-name>", "domain": "<domain>", "handler": "<skill|lead>", "skill_template_version": "<hash-or-null>", "replied_at": "<ISO-8601-now>"}
   ```

5. **Log to `execution-log.md`** via `write-execution-log.sh`. The body for `handler=lead`:
   ```bash
   printf 'Consultation: %s\nWorker: %s\nDomain: %s\nConsultation-handler: lead\nQuestion: %s\nAnswer summary: %s\n' \
     "<consultation-id>" "<worker-name>" "<domain>" "<one-line summary of question>" "<one-line summary of answer>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```
   For `handler=skill`, add the line `Skill template-version: <hash>` between `Consultation-handler: skill` and `Question:`. The `consultation-handler:` line is the canonical signal §1.b cross-checks against the worker's `**Consultations:**` report entries.

6. **Do NOT block other Step 4 sub-steps** on consultation handling — the lead may receive a consultation request from worker-A while waiting for a completion report from worker-B. Reply to the consultation, append to the transcript, log, then return to whichever queue the next message arrives on.

1. **Verify Tier 2 evidence and required consultations before accepting the task** — do NOT re-parse Tier 2 rows from the `SendMessage` body. Instead:

   a. Read the canonical `$KDIR/_work/<slug>/task-claims.jsonl` directly.

   b. Cross-reference against the worker's reported `Tier 2 evidence:` claim_id list. Every reported id MUST exist as a row in the file; any missing id means the worker misreported, and the task is rejected back to the worker for correction.

   c. Rows in the file have already been validated by `evidence-append.sh` against the Tier 2 schema — no additional per-row validation is performed at this step.

   d. **Required-consultation acknowledgement check (D4 lead-side tracking).** Read the worker's phase brief (from `lore work phase-context <slug> <phase-number>` for the phase recorded on the worker's task description) and extract any `**Consultations required:**` domain list. For each required domain:
      - Find the matching `**Consultations:**` entry in the worker's report whose `domain` field equals the required label.
      - Confirm that entry's `consultation_id` appears in `$CONSULTATION_TRANSCRIPT` (Step 4.0) with a matching `domain` and a `lead-acknowledged: true` reply already emitted; for the opt-in route confirm an `advisor-acknowledged: true` reply from the named advisor (transcript provider's spawn surface carries those records — see Step 4.3 for the provider gate).
      - If a required domain has NO matching `**Consultations:**` entry, OR the entry's `consultation_id` does not match any acknowledged reply in the transcript, the task is **rejected** the same way unanswered-must-consult is rejected today (§5.b style: send a `SendMessage` back to the worker naming the unsatisfied required domain and the missing/mismatched id; do NOT accept the task; do NOT proceed to §2).
      - Phases with no `**Consultations required:**` block skip this check entirely. The `**Consultations:**` report field is then optional — emit only what the worker actually sent.

      The mechanism's teeth: per [[knowledge:gotchas/skills-and-protocols/advisory-consultation-protocol-relies-entirely-on-behavioral]], delivery is still behavioral-compliance + turn-boundary; lead-side tracking adds *one* lever the previous pipeline lacked — the lead has the full reply transcript and can reject reports that name a `consultation_id` no acknowledged reply matches. Fabricated consultation entries fail here.

2. **Write execution log entry** — immediately after task acceptance, append to `execution-log.md`. Pass `--template-version "$WORKER_TEMPLATE_VERSION"` because the body logged is the worker's report:
   ```bash
   printf 'Task: %s\nChanges: %s\nSkills: %s\nTier2-claims: %s\nObservations: %s\nInvestigation: %s\nBlockers: %s\nConsultations: %s\nTest result: %s\n' \
     "<task-subject>" "<worker Changes field>" "<worker Skills used field>" \
     "<comma-separated claim_ids from Tier 2 evidence>" \
     "<worker Observations field or Tier 3 candidates summary>" \
     "<worker Investigation field>" "<worker Blockers field>" "<worker Consultations field — verbatim YAML list, or 'none'>" \
     "<passed|failed|skipped>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$WORKER_TEMPLATE_VERSION"
   ```
   If the worker omitted a field, use `None`. `execution-log.md` is created on first write.

3. **Verdict-fabrication guard (handler: agent only)** — before invoking the advisor-impact rollup, verify each consultation in the worker's `**Consultations:**` field **whose `handler` is `agent`** against the transcript's actual advisor spawn events. The guard withholds attribution for unverifiable consultations so the advisor scorecard does not absorb fabricated worker reports as real consultation events.

   **Pre-filter by handler.** From the worker's `**Consultations:**` field, select only entries with `handler: agent` (per D6). Apply the D6 backward-compat normalization here: an entry missing `handler` but carrying `advisor_template_version` is normalized to `handler: agent` before validation; an entry missing `handler` and missing `advisor_template_version` is invalid (the §1 verifier rejected it already). `handler: lead` and `handler: skill` entries bypass this guard entirely — they have no advisor agent to corroborate against, and they attribute to `LEAD_TEMPLATE_VERSION` (lead) or to a future skill-impact rollup (skill) through other channels.

   Skip the entire guard (and §4 below) when (i) the filtered subset is empty (the worker's report contained zero `handler: agent` entries — common on the default route where Step 3.5 spawned no advisors) OR (ii) the original `**Consultations:**` field was empty/`none` — there is nothing to verify.

   The guard consumes the active framework's transcript provider per the canonical consumer pattern (`get_provider()` → catch `UnsupportedFrameworkError` → `provider_status()` gate → operation calls). Run a small Python helper inline:

   ```python
   from adapters.transcripts import get_provider, UnsupportedFrameworkError

   try:
       provider = get_provider()
       status, _reason = provider.provider_status()
   except UnsupportedFrameworkError:
       status = "unavailable"
   # Branch on `status` ∈ {"full", "partial", "unavailable"}; on full|partial-with-spawn-surface
   # call provider.parse_transcript() + provider.read_raw_lines() (two-pass) to extract the set of
   # advisor names actually spawned this session, then intersect with the worker's reported entries.
   ```

   Branch on the result:

   **(a) Provider OK and every claimed advisor is verified in the transcript** — proceed to §4 (`advisor-impact-rollup.sh`) with the `handler: agent` subset (post-filter from this step's preamble) forwarded verbatim. The rollup runs exactly as today.

   **(b) Mismatch** — provider returns `full` (or `partial` with the spawn surface intact), but one or more claimed advisor identifiers in the `handler: agent` subset do NOT appear in the transcript's advisor spawn events. For each unverified entry: log a `fabrication-guard: skipped <advisor_template_version_or_name>` line to `execution-log.md`, then strip THAT entry from the consultations payload. Forward the remaining (verified) entries to §4 — verified consultations still flow through to the rollup. The guard is a per-entry filter, not an all-or-nothing reject.

   **(c) Provider returns `unavailable` or `partial` with the spawn surface degraded** — log `fabrication-guard: provider-<status>; rollup skipped` to `execution-log.md` and skip §4 entirely for this worker's consultations. **Do NOT fall through to today's verbatim-trust behavior.** The guard exists to withhold unsupported attribution; treating absent verification as license to attribute would preserve the exact fabrication path the guard closes. The cost on harnesses without a transcript provider is zero advisor-impact rows for those harnesses; `/retro` interprets zero rows as "no signal" the same way it does for never-invoked judges, and the absence is observable in `execution-log.md`.

   Use `write-execution-log.sh` for both log paths so the entry carries the lead's template-version provenance:

   ```bash
   printf 'fabrication-guard: skipped %s\n' "<unverified-identifier>" \
     | bash ~/.lore/scripts/write-execution-log.sh \
         --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"

   printf 'fabrication-guard: provider-%s; rollup skipped\n' "<unavailable|partial>" \
     | bash ~/.lore/scripts/write-execution-log.sh \
         --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

   The guard is metadata-only: worker task acceptance (verified in §1, logged in §2) is unaffected in all three branches. Fabrication is a metadata fault, not a code fault — the worker's code changes still ship, the Tier 2 evidence still grounds them, only the advisor scorecard attribution is withheld.

   **Identifier semantics.** Worker reports list `advisor_template_version` per consultation. The lead already knows which advisor names it spawned and what `--template-version` flag it passed for each (Step 3.5b). The intersection is "did the lead spawn an advisor whose template-version matches this consultation's `advisor_template_version`?" The transcript provides the corroborating spawn event (TaskCreate with `name: <advisor-name>`) per Step 3.5c's logged `Advisor spawned: <name>` line; consumers that need raw tool inputs follow the two-pass pattern (`parse_transcript()` for ordering and tool_names filter, then `read_raw_lines()[msg.index]` for input extraction). When the lead's spawned-advisor map already records every active advisor, the guard MAY satisfy verification from that map alone without the second pass — the transcript is the corroborator, not the sole source of truth. The lead-side spawn map is only canonical when `provider_status()` is `full`; partial/unavailable returns flow to branch (c) regardless.

4. **Advisor-impact rollup (handler: agent only)** — if the verdict-fabrication guard's branch (a) or branch (b) selected at least one verified `handler: agent` consultation, invoke the scorecard rollup with the filtered payload:
   ```bash
   bash ~/.lore/scripts/advisor-impact-rollup.sh \
     --work-item <slug> \
     --task-id <task-id> \
     --consultations "<verified handler: agent consultations subset, verbatim YAML/JSON>" \
     --template-version "$ADVISOR_TEMPLATE_VERSION"
   ```
   This emits `consultation_rate` and `advice_followed_rate` scorecard rows attributed to `template_id=advisor`. Per D5 the rollup runs only on the opt-in path; `handler: lead` and `handler: skill` entries do NOT emit advisor scorecard rows. Skip the call entirely when (i) the original `**Consultations:**` field was empty or `none`, (ii) the §3 pre-filter found zero `handler: agent` entries (default-route or skill-only consultations — common case), (iii) §3 branch (b) filtered every `handler: agent` entry as fabricated, or (iv) §3 branch (c) fired (provider unavailable/partial — log already written, no rollup invocation).

5. **Set aside Tier 3 candidates for Step 5** — if the worker report contains a `Tier 3 candidates:` YAML block, stash each entry (preserving producer_role and source_artifact_ids) for Step 5 promotion. Do NOT promote here — Step 5 is the sole promotion site.

6. **Handle blockers** — if a worker reports blockers:
   - Read the relevant code/context
   - Send guidance via the adapter's `send_message` operation: `bash "$ADAPTER" send_message <handle> "<body>"`. On Claude Code this expands to `delegate:SendMessage handle=<id>` which the lead invokes as the native `SendMessage` tool. On harnesses where the adapter returns `unsupported`, fall back to lead-only orchestration (the worker cannot receive mid-flight guidance — re-spawn with corrected prompt instead).
   - If unresolvable, note in `notes.md` and move on

7. **Check off completed items in plan.md** (best-effort):
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   If this fails or is missed, Step 7 reconciles from the task system.

Do NOT gate on reviewing diffs — workers proceed autonomously. The user reviews at the end.

When a batch of workers has all reported completion:

1. Call `TaskList` to count remaining tasks with status `pending` and no `blockedBy` dependencies (unblocked tasks).
2. **If unblocked tasks remain:** spawn `min(unblocked_count, max_workers)` fresh workers (same worker template and injections as Step 3.7, incrementing worker names as `worker-N`). Rebuild each worker's per-task Tier 2 extract from the latest `task-claims.jsonl` — prior batches may have added new rows. Continue collecting from the new batch.
   - `max_workers` is the same cap used in Step 3.7: `min(recommended_workers, 4)`.
   - Repeat until no unblocked tasks remain.
3. **If no unblocked tasks remain** (all tasks are complete or all remaining are blocked):
   a. Send `shutdown_request` to all active workers and all advisor agents via the adapter: `bash "$ADAPTER" shutdown <handle> true` per worker/advisor handle. On Claude Code this expands to `delegate:SendMessage handle=<id> type=shutdown_request approve=true`. On opencode/codex the adapter routes to the harness's native subagent-stop / plugin-runtime kill API.
   b. **Write advisor shutdown log entries** — for each advisor that was spawned, log the shutdown:
      ```bash
      printf 'Advisor shutdown: %s\nDomain: %s\n' \
        "<advisor-name>" "<domain scope>" \
        | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
      ```
   c. Run `TeamDelete` (Claude Code only; opencode/codex's runtime owns team teardown).

### Step 5: Promote accepted Tier 3 candidates

Step 5 is the sole Tier 3 promotion site for `/implement`. Do NOT delegate to `/remember`. Do NOT call `lore capture` directly for work-item-scoped observations — `lore promote` is the canonical path because it forces `confidence=unaudited` and enforces Tier 3 schema via `validate-tier3.sh` before writing.

Inputs: the Tier 3 candidate list stashed in Step 4.4, plus any lead-originated cross-task candidates the lead produces by reading the complete `execution-log.md` after the last batch.

**Empty input is a valid input — Step 5 always runs through to the sub-step 4 summary log.** The terminal state when no candidates were stashed is `Tier 3 promotion summary: 0 accepted, 0 rejected` written to `execution-log.md`; that log line is the committed reasoning a later auditor reads. Skipping Step 5 on the rationalization "no candidates → no-op → nothing to do" is the bypass shape named in the commitment protocol — the commitment is to evaluate and emit the summary, not to produce non-zero promotions.

For each accepted Tier 3 candidate, emit one `lore promote` call. Multi-producer synthesis is NEVER merged — one call per distinct producer so that scorecard rows retain the role × template attribution.

1. **Source-artifact verification (reject candidates with missing or stale source_artifact_ids).** Before promotion, read `$KDIR/_work/<slug>/task-claims.jsonl` and confirm that EVERY id listed in the candidate's `source_artifact_ids` array exists as a `claim_id` of some row in that file. Scope is this work item only — cross-work-item references are always rejected. Candidates referencing missing or stale ids are rejected (not promoted). Note each rejection in `execution-log.md`:
   ```bash
   printf 'Rejected Tier 3 candidate: %s\nReason: source_artifact_ids refer to missing claim_ids: %s\n' \
     "<candidate-summary>" "<missing-ids>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

2. **Attribution rule (producer_role → template-version mapping).** Pick the `--template-version` based on the candidate's `producer_role` field so that commons-side scorecard rollups attribute to the correct producing template:
   - `producer_role: worker` → `--template-version "$WORKER_TEMPLATE_VERSION"`
   - `producer_role: advisor` → `--template-version "$ADVISOR_TEMPLATE_VERSION"`
   - `producer_role: implement-lead` → `--template-version "$LEAD_TEMPLATE_VERSION"`

   If `producer_role` is absent from the candidate, default to `implement-lead` and note the defaulting in the execution log.

3. **Invoke `lore promote` per candidate.** One call per accepted candidate; the row JSON is piped on stdin:
   ```bash
   echo '<tier3-row-json>' | lore promote \
     --work-item <slug> \
     --source-artifact-ids "<comma-separated tier2-claim-ids>" \
     --producer-role "<worker|advisor|implement-lead>" \
     --template-version "<TV-per-attribution-rule>"
   ```
   The script forces `confidence=unaudited`, validates via `validate-tier3.sh`, and delegates the actual commons write to `capture.sh`. A non-zero exit means the row was rejected — log the failure and move on to the next candidate.

4. **Log promotion summary to execution-log.md** after the batch completes:
   ```bash
   printf 'Tier 3 promotion summary: %d accepted, %d rejected\nAccepted ids: %s\nRejected reasons: %s\n' \
     "$ACCEPTED" "$REJECTED" "<accepted-claim-id-list>" "<rejection-reasons>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

### Step 6: Closure Acceptance Reconciliation

Step 6 is the capability-anchor reconciliation gate. It compares the run against `_meta.json.intent_anchor`, records a single trichotomous verdict (`full | partial | none`) on the parent's `_meta.json`, and — for `partial` — routes the load-bearing residue into a child work item with its own intent anchor. The closure failure mode this gate catches is named in the [[knowledge:principles/workflow-design/closure-laundering-is-failure-mode-where-local|closure-laundering principle]]: substrate completion (Tier 2 evidence valid, every task checked) accepted as capability completion when a load-bearing step was mocked or deferred.

The system has three distinct closure layers (D2 Precedence). They operate on disjoint signals; none can override another. **All three** must produce a permissive outcome for archive to proceed on an anchored item:

1. **Task-system archive precondition** (existing Step 7 behavior): `REMAINING_COUNT=0`. Hard-blocks archive while any task is `pending`/`in_progress`. Unchanged.
2. **Mechanical Followup Creation Gate** (this step's §6.4 fallback for legacy items + parallel sub-step for anchored items): when `TaskList` shows incompletion or `execution-log.md` Blocker fields carry non-`none` text, it creates a followup artifact in `_followups/`. **Non-blocking** — surfaces mechanical residue for review-loop pickup.
3. **Anchor verdict** (§6.2 below, new): the semantic capability assertion against `intent_anchor`. `full` and `partial` permit archive; `none` hard-blocks it.

**Run order is load-bearing.** Evaluate the task-system archive precondition (§6.1) *before* prompting for or writing the anchor verdict. If `REMAINING_COUNT != 0`, run §6.3 (mechanical gate) and stop — do NOT prompt for a verdict, do NOT write a closure row. The anchor verdict is recorded only against the final task-complete run; otherwise a stale closure row could attach to a state the system no longer matches.

#### Step 6.1: Compute REMAINING_COUNT and read intent_anchor

```bash
REMAINING_COUNT=<count of TaskList tasks with status pending OR in_progress for this work item>
INTENT_ANCHOR=$(python3 -c 'import json,sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print((data.get("intent_anchor") or "").strip())
' "$KDIR/_work/<slug>/_meta.json")
```

**Branch table:**

| `REMAINING_COUNT` | `INTENT_ANCHOR` non-empty | Route |
|---|---|---|
| `> 0` | yes or no | §6.3 mechanical gate only; no verdict |
| `0` | no (empty/absent) | §6.4 legacy fallback; no verdict, no closure row |
| `0` | yes | §6.2 anchor verdict + §6.3 mechanical gate run alongside |

#### Step 6.2: Anchor verdict (anchored + task-complete only)

Display the `intent_anchor` text verbatim to the lead and prompt for exactly one trichotomous verdict, using the [[knowledge:principles/workflow-design/closure-laundering-is-failure-mode-where-local|closure-laundering vocabulary]] verbatim (load-bearing step, mocked, deferred):

- **`full`** — the run delivers the load-bearing capability the anchor names. The lead writes a one-line `capability_loop_summary` naming the user-facing loop now operable. Archive proceeds.
- **`partial`** — at least one load-bearing step the anchor depends on is mocked or deferred. The lead writes a `capability_loop_summary` that *names what shipped* (the delivered subset that justifies archiving the parent), then a one-line residue title and residue intent anchor naming what is mocked or deferred. The protocol creates a child work item, captures the child slug from the successful command result, and only then writes the parent's closure row.
- **`none`** — the run does not deliver the capability. Archive is blocked. Either resume `/implement` with more workers or explicitly reframe via `/spec`. **Skip §6.3 and Step 7 entirely** and exit with a single user-facing line naming the verdict and the next-action choice.

The verdict prompt is the lead's discretion-bearing read of what actually shipped — `notes.md`, `execution-log.md`, the run's worker reports, and any blocker context all inform it. The lead asks the user for the verdict via `AskUserQuestion` only if the lead cannot ground the call in the run's evidence; if the run record is unambiguous (e.g. all tasks checked off, no blockers, the anchor's load-bearing steps all have direct artifact evidence), the lead may decide and report rather than prompting.

**On `full`:** write the closure row to `_meta.json` and proceed to §6.3 + Step 7.

```bash
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
python3 - "$KDIR/_work/<slug>/_meta.json" "<capability_loop_summary>" "$INTENT_ANCHOR" "$TS" << 'PYEOF'
import json, sys
path, summary, anchor, ts = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["closure"] = {
    "verdict": "full",
    "capability_loop_summary": summary,
    "partial_residue_followup": None,
    "verdict_at": ts,
    "intent_anchor_at_close": anchor,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
```

**On `partial`:** create the child work item *before* writing the parent's closure row. The child's intent anchor must obey the [[knowledge:conventions/protocol/work-item-intake-should-store-neutral-intent-ancho|intake neutrality rule]] — describe the residue capability in neutral terms, do not smuggle the parent's framing or solution into the child. Capture the child slug from the command's output; if the create call fails (invalid slug, name collision, etc.), do NOT write the closure row and do NOT archive — exit with the failure message so the lead can re-attempt:

```bash
CHILD_OUTPUT=$(lore work create --json \
  --title "<residue title>" \
  --intent-anchor "<residue intent anchor>" \
  --related-work "<parent-slug>" 2>&1) || {
    echo "[implement] Closure FATAL: child work item creation failed for partial-residue path." >&2
    echo "$CHILD_OUTPUT" >&2
    echo "[implement] Parent closure row NOT written; parent NOT archived. Re-attempt after diagnosing the create failure." >&2
    exit 1
  }
CHILD_SLUG=$(printf '%s' "$CHILD_OUTPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slug"])')

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
python3 - "$KDIR/_work/<slug>/_meta.json" "<capability_loop_summary>" "$CHILD_SLUG" "$INTENT_ANCHOR" "$TS" << 'PYEOF'
import json, sys
path, summary, child_slug, anchor, ts = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["closure"] = {
    "verdict": "partial",
    "capability_loop_summary": summary,
    "partial_residue_followup": child_slug,
    "verdict_at": ts,
    "intent_anchor_at_close": anchor,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

# Append a one-line note to parent notes.md naming the child slug.
printf '\n## %s\n**Closure (partial):** see follow-up `%s`. Delivered subset: %s\n' \
  "$(date -u +"%Y-%m-%dT%H:%M")" "$CHILD_SLUG" "<capability_loop_summary>" \
  >> "$KDIR/_work/<slug>/notes.md"
```

**After archive on `partial`,** the parent is responsible only for the delivered subset named in `capability_loop_summary`; all remaining load-bearing capability residue is owned by the child via its own intent anchor and its own subsequent `/spec` + `/implement` cycle.

**On `none`:** write nothing to `_meta.json`. Skip §6.3 and Step 7. Report:

```
[implement] Closure verdict: none — capability not delivered.
Anchor: <intent_anchor verbatim>
Next: resume `/implement <slug>` with additional scope, or reframe via `/spec <slug>`.
Work item remains active in _work/.
```

#### Step 6.3: Mechanical Followup Creation Gate (runs alongside §6.2 for anchored items, and as the sole closure path on legacy items per §6.4)

[[knowledge:principles/workflow-design/workflow-theater-anti-pattern-in-skill-design-steps-that|Workflow-theater guard:]] this gate's job is to surface *mechanical* residue (incomplete tasks, blocker fields). It does NOT consult `intent_anchor` — that is §6.2's job. Do NOT collapse the two layers; doing so recreates the closure-laundering gap in a new form by either reading the verdict off mechanical signals or laundering blockers as anchor compliance.

**Signal detection** — check two sources:

1. **Incomplete tasks** — call `TaskList`. Flag if any tasks remain with status `pending` or `in_progress`.
2. **Explicit blockers** — read `execution-log.md` for worker report entries where `Blockers:` contains any text other than `none` (case-insensitive).

**If no signals found:** skip to Step 7.

**If signals found:** create a followup:

```bash
bash ~/.lore/scripts/create-followup.sh \
  --title "Deferred work: <work item title>" \
  --source "implement" \
  --attachments '[{"type":"work_item","slug":"<slug>"}]' \
  --suggested-actions '[{"type":"create_work_item"}]' \
  --content "<one-line summary of what didn't finish and why, followed by a checklist of remaining items>"
```

This gate is non-blocking — its firing is not itself proof of archive-clear, and its silence is not itself proof of archive-clear either. Layer 1 (task-system precondition) and layer 3 (anchor verdict) are the gating layers; this layer is observability for the review loop.

#### Step 6.4: Legacy fallback (no intent_anchor)

If `INTENT_ANCHOR` is empty/absent on `_meta.json`, run §6.3 exactly as today and proceed to Step 7. No verdict is required, no closure row is written, no advisory fires in `archive-work.sh`. This preserves the cycle on pre-anchor work items without back-filling — closure-time anchor synthesis would be retroactive intake under conversational pressure, the exact failure mode the intake-side anchor moved capture to intake to avoid.

[[knowledge:architecture/plan-task-models/lore-work-check-is-not-taskcompleted-acceptance|Acceptance-layer note:]] `lore work check` (the task-system layer) and the closure verdict (the capability-loop layer) sit at different altitudes. The task system answers "did this artifact get produced and pass per-task checks"; the closure verdict answers "did the run deliver the capability the anchor names." The closure verdict cannot override the task-system archive precondition (a `full` verdict on a task-incomplete item is not just non-archiving — §6.1's branch table refuses to record it at all), and the task-system precondition cannot substitute for the closure verdict (every task checked is the input to §6.2, not its conclusion).

**Lazy audit note:** per §9.2 Step 8, the Stop hook lazily triggers audit of this session's promotions; `/implement` does not invoke the audit explicitly here. Completion of `/implement` is non-blocking — the audit runs opportunistically after session end.

### Step 7: Cleanup and report

1. **Append a session entry to `notes.md`:**
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** Implementation via /implement
   **Progress:** Completed N/M tasks across K phases
   **Tier 2 claims:** <count> written; **Tier 3 promoted:** <count> accepted, <count> rejected
   **Next:** <remaining tasks if partial, or "Implementation complete">
   ```

2. **Reconcile plan.md from task system** — the task system is the source of truth for completion:
   ```bash
   lore work check <slug> "<task-subject>"
   ```
   Run for every completed task whose checkbox is still unchecked.

3. Run `lore work heal`.

4. **Retro-prep bundle (per §9.2 Step 9, D8).** Write a snapshot of this run's producer facts to `$KDIR/_work/<slug>/retro-bundle.json` so `/retro` has a single, stable input artifact. One write per `/implement` run; overwrite on re-run (snapshot semantics — not append, not merge). `/implement` is the sole writer; `/retro` is a read-only consumer.

   The bundle has exactly these nine required fields:

   | Field | Type | Source |
   |---|---|---|
   | `work_item` | string | `<slug>` |
   | `tasks_completed` | integer | count of tasks in `TaskList` with `status: "completed"` for this work item |
   | `tier2_claim_ids` | array of strings | every `claim_id` in `$KDIR/_work/<slug>/task-claims.jsonl` produced this run |
   | `tier3_promoted_ids` | array of strings | commons entry ids emitted by the `lore promote` calls in Step 5 (accepted only; rejects excluded) |
   | `advisor_consultations_count` | integer | total `Consultations:` entries counted across this run's `execution-log.md` worker-report bodies (legacy `Advisor consultations:` lines from pre-rename worker reports remain counted for backward compatibility) |
   | `blockers` | array of strings | verbatim `Blockers:` text from worker reports where the value was anything other than `none` (case-insensitive) |
   | `template_versions` | object `{lead, worker, advisor}` | `$LEAD_TEMPLATE_VERSION`, `$WORKER_TEMPLATE_VERSION`, `$ADVISOR_TEMPLATE_VERSION` from the "Resolve Template Versions" preamble |
   | `captured_at_sha` | string | `git rev-parse HEAD` at emission time |
   | `run_started_at` | string | ISO-8601 timestamp captured at Step 1 and carried through the run |

   Write the file with:
   ```bash
   python3 -c 'import json, sys; json.dump(<fields>, sys.stdout, indent=2)' \
     > "$KDIR/_work/<slug>/retro-bundle.json"
   ```

   **Scope:** producer-only. This rewrite ships the emitter; it does NOT ship a schema validator. `/retro` treats the bundle as a convenience summary — the canonical artifacts (`task-claims.jsonl`, `observations.jsonl`, `execution-log.md`, `notes.md`) remain the historical truth. If `retro-bundle.json` is missing or malformed, `/retro` falls back to the canonical artifacts rather than failing.

   **Overwrite semantics:** on re-run of `/implement` against the same work item, replace the file unconditionally. No append, no merge, no rotation — each run reflects only that run's producer facts. The canonical log files already carry historical data.

5. **Archive the completed work item.** This step is mandatory when all tasks are done AND, on anchored items, the Step 6 closure verdict permits archive — it is the structural close of the implement cycle, not a discretionary cleanup. Branch on the task-system completion state (not on plan.md), then on the anchored closure precondition:

   - **All tasks completed AND (legacy item OR anchored item with a valid `closure` row):** archive and verify the move:
     ```bash
     # Anchored-item precondition: a valid closure row must exist on _meta.json
     # before archive runs. Per Step 6.2, `none` verdicts skip Step 7 entirely,
     # so reaching this branch on an anchored item implies verdict ∈ {full, partial}.
     # Re-validate here as a defensive gate against a Step 6 implementation drift.
     CLOSURE_VALID=$(python3 -c '
     import json, sys
     with open(sys.argv[1], encoding="utf-8") as f:
         data = json.load(f)
     anchor = (data.get("intent_anchor") or "").strip()
     if not anchor:
         print("legacy")
         sys.exit(0)
     closure = data.get("closure")
     if not isinstance(closure, dict):
         print("missing")
         sys.exit(0)
     verdict = closure.get("verdict")
     summary = (closure.get("capability_loop_summary") or "").strip()
     anchor_at_close = (closure.get("intent_anchor_at_close") or "").strip()
     residue = closure.get("partial_residue_followup")
     if verdict not in ("full", "partial"):
         print("bad_verdict")
         sys.exit(0)
     if not summary:
         print("missing_summary")
         sys.exit(0)
     if not anchor_at_close:
         print("missing_anchor_at_close")
         sys.exit(0)
     if verdict == "partial" and not (isinstance(residue, str) and residue.strip()):
         print("missing_residue_for_partial")
         sys.exit(0)
     print("ok")
     ' "$KDIR/_work/<slug>/_meta.json")

     case "$CLOSURE_VALID" in
       legacy|ok)
         lore work archive "<slug>"
         test -d "$KDIR/_work/_archive/<slug>" \
           || { echo "[implement] FATAL: archive did not move work item to _archive/"; exit 1; }
         test ! -d "$KDIR/_work/<slug>" \
           || { echo "[implement] FATAL: archive left work item in active _work/ path"; exit 1; }
         ;;
       *)
         echo "[implement] FATAL: anchored work item lacks a valid _meta.json.closure block ($CLOSURE_VALID); refusing to archive." >&2
         echo "[implement]        Re-run Step 6 to record the closure verdict before archive." >&2
         exit 1
         ;;
     esac
     ```
     If verification fails, do not proceed to Step 7. Diagnose and re-run archive before rendering the report. Silently skipping archive corrupts the active-vs-archived distinction the work system depends on. **Anchored items missing or malformed `_meta.json.closure` MUST NOT be archived from this step** — that path is exactly the closure-laundering failure mode Step 6 exists to prevent. The advisory in `scripts/archive-work.sh` is a *non-blocking* warning intended for manual / bulk-archive callers; this Step 7 precondition is the *blocking* gate on the `/implement` ceremony path.
   - **Some tasks incomplete or blocked:** do not archive. Leave the work item active so a later `/implement` invocation can resume it.
   - **Anchored item with verdict `none`:** Step 6.2 already exited before reaching Step 7. This branch is unreachable here; do not add a path that silently re-routes around it.

   **Why this is the last step before the report.** The user-facing "Done" report is the natural exit point of `/implement`; once it renders, the operator typically transitions to `/retro` or moves on. Coupling archive to the report (rather than treating it as an earlier optional step) ensures the work item's active/archived state is committed before the cycle visibly closes. Prior versions of this skill placed archive earlier in Step 7 — observed live, the archive call got silently skipped roughly half the time because the report's "consider /retro" line created a perceived clean handoff before archive ran. Placing archive here, with verification, removes that gap.

6. **Report to user.** Before rendering, check that archive ran if it should have. The precondition has two forms — task-completion (existing) and anchored-closure (new):

   ```bash
   if [ "$REMAINING_COUNT" = "0" ] && [ -d "$KDIR/_work/<slug>" ]; then
     # Distinguish "missing closure row" from "archive skipped for unrelated reason"
     # so the operator gets a precise next-action.
     CLOSURE_DIAG=$(python3 -c '
     import json, sys
     try:
         with open(sys.argv[1], encoding="utf-8") as f:
             data = json.load(f)
         anchor = (data.get("intent_anchor") or "").strip()
         closure = data.get("closure")
         if anchor and not isinstance(closure, dict):
             print("anchored_no_closure")
         elif anchor and isinstance(closure, dict) and closure.get("verdict") not in ("full", "partial"):
             print("anchored_invalid_verdict")
         else:
             print("other")
     except Exception:
         print("other")
     ' "$KDIR/_work/<slug>/_meta.json")
     case "$CLOSURE_DIAG" in
       anchored_no_closure|anchored_invalid_verdict)
         echo "[implement] FATAL: tasks complete but anchored work item has no valid closure row. Re-run Step 6 to record the verdict, then archive."
         ;;
       *)
         echo "[implement] FATAL: all tasks completed but work item not archived. Run Step 7.5 archive before this report."
         ;;
     esac
     exit 1
   fi
   ```

   The report MUST NOT render with a completed-but-unarchived work item. If the precondition fires, return to Step 6 (record the verdict if missing) and Step 7.5 (archive). For `none` verdicts, Step 6.2 already produced the user-facing exit message and skipped Step 7 — the report below does not render in that case.

   ```
   [implement] Done.
   Completed: N/M tasks
   Closure: <full|partial|legacy>  <("see follow-up <child-slug>" if partial, omit otherwise)>
   Tier 2 claims written: <count>
   Tier 3 promoted: <count> (rejected: <count>)
   Remaining: <list if any, or "none — work item archived">
   Followup: <"<title>" if created, omit line if not>
   Consider `/retro <slug>` to evaluate knowledge system effectiveness for this work.
   ```

## Handling Partial Completion

If workers hit blockers or the team can't finish all tasks:
1. Capture progress to `notes.md` via the session entry above
2. Reconcile plan.md from the task system (Step 7.2) — completed tasks get checked, incomplete ones stay unchecked
3. Report what completed and what's left
4. The user can re-run `/implement` later to pick up remaining tasks (Step 2 skips checked items)

## Resuming Implementation

When `/implement` is called on a work item with partially-checked `plan.md`:
- Only generate tasks for unchecked `- [ ]` items
- Skip phases where all items are checked
- Step 1.7 re-reads `task-claims.jsonl` so resumed workers still see prior Tier 2 evidence
- Report: "Resuming — N remaining tasks across M phases"
