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

Executes a work item's `plan.md` with a team of knowledge-aware agents. Agents produce Tier 2 task evidence during work and optionally surface Tier 3 candidates for commons promotion. The lead verifies, promotes accepted candidates, and closes the run against the capability anchor.

Mechanical bookkeeping routes through the eight `lore impl` verbs — `start`, `gate-anchor`, `open`, `next-batch`, `check-report`, `consult-log`, `promote-batch`, `close`. Each verb stamps provenance at the write site and appends its own `execution-log.md` attribution row (`--source impl-verb`), so verb-mediated bookkeeping is distinctly attributable from hand-run writes. The verbs file judgments; they never make them. Every verdict, route choice, acceptance, and selection in this skill is the lead's, made in prose before the verb is invoked — a verb that receives a verdict it did not expect rejects it rather than inferring one.

## Approach

**Approach this work from confidence, not caution.** Mistakes are part of working; most are recoverable through normal review. The cost of constant deferral on settled steps exceeds the cost of occasional errors caught later. When the rubric or the protocol gives you a clear path, take it. Defer at genuine forks (multiple plausible directions where the protocol does not pre-decide) or at high-blast-radius operations (destructive, hard-to-reverse, or shared-state-affecting). Defer is a tool for forks, not a default for actions.

## Judgment Kernels

<!-- INVARIANT — canonical kernel vocabulary, validated by the verb scripts.
     A future edit that renames any token here silently silences a downstream
     gate; change the verb contract first, then this file in the same commit.
       anchor verdict (impl-gate-anchor.sh): aligned | misaligned-respec | misaligned-override | abort | legacy-skip
       gate route (impl-gate-anchor.sh):     continue | respec | abort
       consultation handler (impl-consult-log.sh, impl-check-report.sh): lead | skill | agent
       closure verdict (impl-close.sh):      full | partial | none -->

Eight decisions stay in lead prose. The verbs validate the vocabulary these kernels emit, so a drifted token is rejected at filing time:

| Kernel | Where | Canonical vocabulary | Filing verb |
|---|---|---|---|
| Anchor verdict | Step 1.5b | `aligned` \| `misaligned-respec` \| `misaligned-override` \| `abort` \| `legacy-skip` | `gate-anchor` |
| Lead-inline decision | Step 3.0 | four condition fields, read by the lead | — (route choice) |
| Spawn decision | Steps 3, 4 dispatch join | who runs what, serialize vs merge | — (harness calls) |
| Consultation answers | Step 4.0 | `handler: lead` \| `skill` \| `agent` | `consult-log` |
| Accept/reject | Step 4 §1 | acceptance after mechanical pass | `check-report` (mechanics only) |
| Divergence-rationale assessment | Step 4 §2 | convincing / unconvincing | — (followup) |
| Tier-3 selection | Step 5 | accepted candidate set | `promote-batch` |
| Closure verdict | Steps 6–7 | `full` \| `partial` \| `none` | `close` |

## Resolve Paths

```bash
lore resolve
lore defaults
```
Set `KNOWLEDGE_DIR` to the first result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`. The second renders the standing defaults in force (settings-derived role/model maps, coordination concurrency, ceremony registrations, sampling rates, preference directives cited by title); treat its output as binding for this run. Resolve the worker ceiling there and lower it to available runtime capacity; never replace it with a per-run constant. Missing or malformed concurrency fails closed to one writer seat.

Agent templates live in the lore repo under `agents/<name>.md` and surface via `resolve_agent_template <name>` (Claude Code: `~/.claude/agents/<name>.md`). Do NOT use `git rev-parse --show-toplevel` for agent paths — the current repo is the target project, not the lore repo.

**MANDATORY:** You MUST read the actual template files for `worker` and `advisor` when spawning agents — resolve each via `resolve_agent_template worker` and `resolve_agent_template advisor`. Do NOT skip this step. Do NOT generate inline agent prompts as a substitute. If the resolver fails or the files are missing, stop and report the error — never fall back to improvised prompts.

Template versions and role→model bindings come from the `lore impl start` struct (Step 1). Keep `$LEAD_TEMPLATE_VERSION`, `$WORKER_TEMPLATE_VERSION`, and `$ADVISOR_TEMPLATE_VERSION` distinct — each tags emissions produced by its matching template; an unresolved version is empty and downstream writers warn-degrade to unstamped.

### Step 1: Start the run

1. **Parse arguments:** extract the work item reference. The `--model <id>` flag is an undocumented per-invocation override that, when present, exports `LORE_MODEL_LEAD=<id>` for the duration of this skill — it stamps only the lead role for this run and does NOT touch worker/advisor/researcher bindings. (Per-role overrides via `LORE_MODEL_<ROLE>` env vars are honored independently.) The `--yes` flag is the documented user-facing escape hatch for the Step 1.5b anchor-coverage gate's misaligned-route prompt — when present, the gate skips the `AskUserQuestion` prompt and defaults to the recommended remediation (re-spec). **`--yes` NEVER skips the gate evaluation itself** — per `inside-lore-protocol-silent-skip-is`, only the user-facing prompt is suppressed; the lead still evaluates anchor-vs-plan coverage, still files the gate row, and still respects the legacy-no-anchor branch's logged-skip contract. `--yes` does not affect any other prompt in this skill (the Step 1.2 archived-item confirmation and the Step 2 checksum-mismatch prompt remain interactive). Record `RUN_STARTED_AT` (ISO-8601 now) — Step 7's close consumes it.

2. **Run the start verb — the sole Step 1 envelope.** Do NOT improvise resolution via `ls`, `find`, `lore work show`, or directory listing, and do NOT hand-run the resolver, plan validation, branch cache, claims parsing, or model/template-version resolution it absorbs:

   ```bash
   lore impl start "$INPUT" --json
   ```

   `start` resolves the work item, validates a structured plan with unchecked work, and returns the title and `intent_anchor` verbatim plus prior claims, models, template versions, and branch-cache status. It computes facts only; it never adjudicates the anchor.

   Exit codes: `0` start struct printed (single JSON object with `--json`); `1` no match, missing `plan.md` ("No structured plan found. Run `/spec` first…"), or no unchecked tasks ("All plan tasks are already complete.") — report the verb's message and stop, do NOT fall back to broader filesystem inspection; `2` ambiguous reference — disambiguate via `AskUserQuestion` from the candidate list and re-invoke.

   Bind from the struct: `SLUG`, `ITEM_DIR` (`$WORK_DIR/<slug>`, or `$WORK_DIR/_archive/<slug>` when `archived: true`), `INTENT_ANCHOR`, the three models, the three template versions, and the prior-claims maps (these feed Step 3's per-worker Tier 2 extracts via `open`). Keep `worker_class_models` as the raw scalar bindings displayed for compatibility, and bind `worker_class_routes` as the structured dispatch map. Each judgment-class route carries exactly `binding`, `source_framework`, `target_framework`, `native_binding`, and `qualified`.

   - **If `archived: true`:** warn the user: "This work item is archived. Proceed anyway?" Wait for explicit confirmation. (Note: `gate-anchor` and the other writing verbs refuse archived items.)

3. **Read the on-disk source-of-truth files directly with `Read`** — `$ITEM_DIR/plan.md` (phases, design decisions, retrieval directives, task lists) and `$ITEM_DIR/notes.md` (last entry for session continuity). The verb validated structure; the lead's judgments — the anchor gate below, dispatch shaping, consultation answers — read content.

4. **Present a brief summary and proceed immediately.** The verb's text output already renders the operator-facing lines (`Models: lead=… worker=… advisor=…`, `Phases: N with M unchecked tasks`, `Prior Tier 2 claims: …`, the verbatim intent anchor) — surface them. If `--model <id>` was passed, the lead model reflects that override.

<!-- INVARIANT — canonical anchor-gate vocabulary. scripts/impl-gate-anchor.sh
     validates these exact tokens and rejects any other:
       verdict: aligned | misaligned-respec | misaligned-override | abort | legacy-skip
       route:   continue | respec | abort
     Do not rename a verdict here without changing the verb's contract first;
     a drifted token is refused at filing time and the gate's audit row never lands. -->

**Gate:** Anchor-coverage start gate (prose-named "Step 1.5b"). **Evaluate the gate now — this step is mandatory and must not be skipped.** Read the anchor (verbatim in the start struct). Read the plan. Decide whether the plan as written will deliver the capability the anchor names.

This is a **lead-attested semantic check, not machine-enforced.** No script adjudicates the alignment verdict; the lead's discretion-bearing read of `intent_anchor` against `plan.md` is the only judge. `gate-anchor` files the verdict the lead hands it — it never infers one. The sibling structural check (`scripts/verify-plan-intent-anchor.sh`, called by `/spec`) is deliberately distinct — it verifies the anchor block's presence and exact-whitespace match, never its semantic coverage. Do not confuse this gate with a hardened verifier.

**Verdict shape (start-time):** binary — `aligned` | `misaligned`. There is no `partial` rung here. The trichotomous `full | partial | none` shape is closure-time only (Step 6); at start-time nothing has shipped, so residue routing has no meaning.

**On `aligned`:** write a one-line **Anchor fit statement** (required, non-empty) — the lead's brief explanation of *why* the plan covers the anchor. Mirrors Step 6's `capability_loop_summary` requirement on `full` — every lead-attested verdict carries a one-line attestation so an empty/silent `aligned` cannot degrade to a yes-button reflex.

**On `misaligned`:** name the misalignment gap in a one-line statement, then emit a per-misalignment verdict — `route-respec`, `route-override`, or `escalate`. The lead is the primary decider; `AskUserQuestion` fires only on `escalate`.

**Verdict criteria (per misaligned-route decision):**

- **`route-respec` (default)** — the gap is *capability-level* (plan does not address what the anchor names). Default for unambiguous capability gaps; the verdict `--yes` forces. Files as `misaligned-respec`.
- **`route-override` (lead-attested scope-delta)** — the gap is *scope-level* and the lead can articulate a concrete one-line scope-delta acknowledgment naming in-scope vs deferred. Files as `misaligned-override`; the scope-delta is the verdict rationale.
- **`escalate`** — the lead cannot confidently pick between the three. Common reasons: gap straddles capability-and-scope, two equally-plausible scope-delta framings, high cost-of-wrong (upstream dependencies). Route through `AskUserQuestion` with three options — **(a) re-spec (Recommended)**, **(b) override** with an explicit scope-delta acknowledgment, **(c) abort**. The user-facing prompt MUST restate the anchor body **verbatim** (no paraphrase) per `work-item-intake-should-store-neutral-intent-ancho`. Record the human's resolution as the verdict. **Abort is available only on the escalate path** — the lead does not auto-abort.

**`--yes` semantics:** skip the `AskUserQuestion` prompt regardless of verdict and default to re-spec without prompting. The gate row, misalignment-gap field, and prescribed-next-command exit text are emitted identically to the interactive re-spec path.

**Legacy-no-anchor branch:** if the start struct's `intent_anchor` is empty/absent, the verdict is `legacy-skip` — no user-facing prompt, no anchor-fit statement, no misalignment gap. This is the only authorized silent prompt in the gate; the skip is still filed so the audit loop fires. (`gate-anchor` enforces the pairing both ways: `legacy-skip` is refused when an anchor exists, and every other verdict is refused when none does.)

**File EVERY verdict through the gate verb — the only legal channel for the gate row.** Do NOT hand-compose the execution-log row and do NOT inline an encoding of the anchor body; the verb reads the anchor from `_meta.json` itself, JSON-string encodes the free-text fields so multi-line values survive as single log lines, and owns the six-field row shape (`Anchor-coverage gate` / `Intent anchor` / `Anchor fit statement` / `Misalignment gap` / `Override scope delta` / `Remediation choice` — gate, fit, gap, scope-delta, and remediation are lead-attested; the anchor line is machine-sourced):

```bash
lore impl gate-anchor "$SLUG" --verdict <verdict> \
  [--fit "<anchor fit statement>"] [--gap "<misalignment gap>"] \
  [--scope-delta "<in-scope vs deferred>"] \
  --template-version "$LEAD_TEMPLATE_VERSION"
```

Per-verdict field contract (R = required, − = must be omitted; the verb rejects every other combination, in both directions — a row can never carry a field its verdict does not define):

| verdict | `--fit` | `--gap` | `--scope-delta` | remediation filed | route returned |
|---|---|---|---|---|---|
| `aligned` | R | − | − | `continue` | `continue` |
| `misaligned-respec` | − | R | − | `run /spec <slug>` | `respec` |
| `misaligned-override` | − | R | R | `continue` | `continue` |
| `abort` | − | R | − | `none (user aborted)` | `abort` |
| `legacy-skip` | − | − | − | `none (legacy skip)` | `continue` |

On `misaligned-override` the verb dual-writes: the gate row AND a timestamped `**Anchor-coverage override:**` entry in `notes.md`. Exit codes: `0` filed, `Route:` on stdout; `1` validation error / no match; `2` ambiguous reference.

**Route handling:**
- **`continue`** (aligned, misaligned-override, legacy-skip) → proceed to Step 2.
- **`respec`** → exit `/implement` with the prescribed-next-command line `Next: run /spec <slug>`. The lead does NOT auto-invoke `/spec`; control returns to the user. Write NOTHING further to `notes.md`.
- **`abort`** → exit `/implement` immediately. Write NOTHING further to `notes.md`.

**Lifecycle:** the `respec` and `abort` routes fire BEFORE Step 2 (TeamCreate), Step 3 (worker dispatch), any code edits, and any lead `notes.md` writes. The gate row (plus `start`'s branch-cache write) is the only side effect on those exits — failing here keeps misaligned-and-aborted runs from leaving stale team artifacts.

### Step 2: Open the dispatch

**Prepare the dispatch envelope with the open verb, then execute its manifest in order.** Run:

```bash
lore impl open "$SLUG" --all --json --template-version "$LEAD_TEMPLATE_VERSION"
```

Selection is the caller's declaration — exactly one mode is required, no default: `--all` (every task), `--phase <n>` (repeatable), or `--task <id>` (repeatable; e.g. `task-3`). Use subset selection when resuming or staging phases.

Contract (`scripts/impl-open.sh`) — a prepare-and-return emitter; it never invokes harness tools, never spawns anything, never decides routes. Its only write is one execution-log attribution row. It returns:

- **Checksum validation** — delegates to `load-tasks`; a `tasks.json`/`plan.md` checksum mismatch is a hard exit-1 directing to `lore work regen-tasks <slug>`. Tell the user: "plan.md was edited after tasks.json was generated. Run `/work regen-tasks <slug>` to regenerate, or edit plan.md back." Wait for the user's decision — this prompt stays interactive. If `tasks.json` does not exist, generate it with `lore work tasks "$SLUG"`, then re-run `open`. The checksum gate is owned by `open` alone — `next-batch` deliberately does not re-enforce it mid-run.
- **`capabilities.team_messaging`** — `full | partial | fallback | none`. One input to Step 3.0's operation-level probe, never a proxy for the whole subagent surface: it gates mid-flight messaging (consultations, steering, TeamCreate coordination), while the spawn surface, direct result collection, completion enforcement, and report materialization are probed separately. A sub-`full` level changes how messaging-dependent coordination runs (Step 3.0 decides the route); it does not by itself collapse the run to lead-inline.
- **`manifest`** — TeamCreate first, then one TaskCreate per eligible task in `tasks.json` order, then TaskUpdate wiring ops whose `add_blocked_by` edges are complete (tasks.json edges within the selection plus collision-serialization edges). Edges pointing outside the selection surface per-task as `external_blocked_by` for the lead to wire against already-created tasks. An empty manifest is success with an explanatory `status`, not an error.
- **`collisions`** — same-file intersections among concurrent selected tasks, already folded into the manifest as serialization edges so the wiring is collision-safe. **Cross-selection collisions are NOT detected:** when dispatching a `--phase`/`--task` subset, the lead accounts for files held by unselected or still-in-flight tasks before spawning.
- **`phase_map`** and **`prior_knowledge`** — per-phase knowledge resolved through the 3-branch gate: a `retrieval_directive` resolves via `resolve-manifest.sh` (authoritative; v2 directives return `### Focal:`/`### Adjacent:` sectioned blocks, legacy flat directives a single section — the dispatcher does not branch on shape); task descriptions embedding `## Prior Knowledge` skip prefetch (the phase already carries resolved knowledge; appending would duplicate or conflict); otherwise the fallback `lore prefetch` runs ONLY when the caller declared `--fallback-scale-set <buckets>` (comma-separated from `abstract|architecture|subsystem|implementation`). Without a declaration the phase returns `status: needs-prefetch` with the suggested query — **scale is the caller's declaration, never a default.** On `needs-prefetch`, declare the bucket per the scale rubric (see `skills/memory/SKILL.md` § Scale-Aware Navigation) and re-run `open` with `--fallback-scale-set` — re-declare with intent, not habit. When the fallback branch ran, log one `Knowledge-delivery-path: lead-fallback-prefetch` line via `write-execution-log.sh` so the delivery gap is visible to /retro.
- **`tier2_extracts`** — per-task prior Tier 2 rows from `task-claims.jsonl`, matched by `task_id` or file-target overlap. These feed each worker's `{{prior_knowledge}}` injection in Step 3.
- **`skill_invocation_map`** — plan `**Related skills:**` entries merged with `lore ceremony get implement` entries, each with its `skill_template_version`. Hold this as in-memory routing state for Step 4.0; the lead invokes these skills directly.
- **`advisors`** — `mode: persistent` declarations only. Advisor declarations without `mode: persistent` (e.g. `[must-consult]`, `[on-demand]`) are lead-handled inline on the default route and do NOT spawn advisor agents.
- **`lead_inline_conditions`** — the four gate conditions as SEPARATE fields (`single_task`, `prescriptive`, `no_persistent_advisor`, `no_required_consultation`) plus a `detail` block. Never an aggregate eligibility boolean — the lead reads conditions and decides (Step 3.0).

Exit codes: `0` manifest emitted (possibly empty with explanatory status); `1` validation error / no match / missing tasks.json / checksum mismatch; `2` ambiguous reference.

**Evaluate Step 3.0 before executing the manifest.** A selected lead-inline route consumes the manifest's task entries as its serial task list but executes none of its TeamCreate/TaskCreate/TaskUpdate operations. Only the worker-dispatch route executes harness operations.

**On the worker-dispatch route, the lead executes every harness tool call itself, in manifest order — TeamCreate first.** A CLI verb cannot invoke harness tools; the TeamCreate-first ordering is the orphan-task guard: TaskCreate calls go into whichever task list is active, so tasks created before TeamCreate land in the session's default list — invisible to workers who see the team's list, persisting as orphaned stale tasks for the rest of the session. Walk the manifest top-to-bottom:

1. **TeamCreate** with the manifest's `team_name` and `description="Implementing <work item title>"`. **`team_name` MUST be exactly `impl-<work-item-slug>`** — the slug suffix has to match the work item directory name in `$KDIR/_work/` byte-for-byte. The TaskCompleted hook (`scripts/task-completed-capture-check.sh`) derives the work-item slug by stripping the `impl-` prefix; `lore work check` and Tier 2 evidence reads use the same convention. On opencode/codex the adapter emits `delegate:plugin_team_init` / `delegate:codex_subagent_init`; invoke the documented translation.
2. **TaskCreate** per manifest entry with its `subject`, `activeForm`, `description`, tracking each `local_id` → created-task ID. Per-task descriptions are lean by design — each begins with a `**Phase:** N` line (the authoritative phase-number source) followed only by the task-specific assignment; phase-level context lives in `tasks.json → phases[N-1].phase_context`, fetched lazily by the worker via `lore work phase-context <slug> <phase-number>` after `TaskGet`. The lead does NOT embed phase context into descriptions. (Legacy `tasks.json` without `phase_context` exits 0 with empty stdout there; workers fall back to inline phase context — no regen required.)
3. **TaskUpdate(addBlockedBy=[…])** per wiring op, mapping `local_id`s through the ID map; wire any `external_blocked_by` edges against the matching already-created tasks.

**Read your team lead name** from the active harness's teams install path (resolved via `resolve_harness_install_path teams`; typically `~/.claude/teams/`) at `<teams_dir>/impl-<slug>/config.json`. Frameworks whose `install_paths.teams=unsupported` (codex today) cannot persist team config — the adapter returns a lead-side handle map instead; read the lead name from the map.

### Step 3.0: Lead-inline gate (pre-dispatch short-circuit)

**Probe the operations the selection actually needs, then decide the route yourself.** The probe is operation-level and lives in the adapter capability layer — `framework_capability` cells plus the active agent adapter's own queries (`ADAPTER="$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh"`) — never a branch on the framework's name; capability overrides participate automatically. Worker dispatch needs four things, each probed on its own:

1. **Spawn surface** — `subagents` supports the adapter's `spawn`/`wait`/`shutdown` operations.
2. **Direct result collection** — `collect_result` returns the full report body to the lead.
3. **Completion enforcement** — the adapter's `completion_enforcement` query returns `native_blocking` or `lead_validator`. `self_attestation` or `unavailable` disqualifies dispatch: a worker's own word is never acceptance evidence.
4. **Report materialization** — the lead can land each collected report at its canonical `worker-reports/` path (Step 4 §1) before checking it.

Probe `team_messaging` only when the selection actually requires mid-flight messaging — declared `**Consultations required:**` domains, `mode: persistent` advisors, or steering the lead intends. `team_messaging=none` removes consultations and shared team state, not the spawn surface: a selection of self-contained tasks stays eligible for worker dispatch on such a harness, with TeamCreate/SendMessage coordination replaced by the adapter's spawn → wait → collect_result → shutdown loop and report checking by the lead-validator path when no native hook fires. The probe routes mechanism only — model selection stays on the separate role-resolution path (`worker_class_routes`, backed by `resolve_route_for_role` and `adapters/roles.json`) under the standing routing directives.

Two lead-inline routes exist:

- **Capability collapse:** when the probe disqualifies worker dispatch — no spawn surface, no direct result collection, enforcement at `self_attestation`/`unavailable`, no way to land the report file, or a messaging-requiring selection on a harness whose messaging probe fails (with no session route selected for those tasks) — execute every selected task serially in manifest dependency order. This route changes bookkeeping and coordination only — the lead still performs every discretion-bearing task judgment and declared consultation/skill obligation. When no route at all — worker dispatch, session-routed worker, or lead-inline — can land and validate the canonical report artifact, refuse the run explicitly rather than auditing a transcript or accepting a self-attested result.
- **Efficiency collapse:** on a harness where worker dispatch is available, read the four conditions as separate fields — never an aggregate boolean — because the route is a judgment, not an arithmetic AND: the `detail` block tells you *why* a condition is false, and the carve-out below turns on that distinction. Worker dispatch's value is parallelism across independent tasks plus discretion-bearing context for intent+constraints work; both vanish when the plan reduces to a single fully-determined edit. The ~22KB context tax per spawn plus TeamCreate + TaskCreate + completion round-trip is then pure overhead.

On either route, selecting lead-inline is provisional. The collapse fires only after the durable read-back below proves one landed report file and one report key per selected task; task shape is never a substitute for report presence.

The efficiency route is eligible when **all four** conditions hold:

1. **`single_task`** — `tasks.json` contains exactly one task across all phases.
2. **`prescriptive`** — the task's containing phase declares `**Task format:** prescriptive`. Intent+constraints tasks involve worker discretion; lead-inline removes that channel and is unsafe for them.
3. **`no_persistent_advisor`** — no phase declares a `mode: persistent` advisor. Non-persistent advisor declarations are lead-handled inline and do not disqualify.
4. **`no_required_consultation`** — no phase declares `**Consultations required:**` domains, the ceremony list is empty, AND plan.md's `**Related skills:**` block declares no entries. Each signals orchestration that has no inline analogue when no team exists.

   **Lead route with a lead-invoked skill in scope.** On the efficiency route, when condition 4 is false *only* because `detail.related_skills` is non-empty (and the other three hold), the lead route remains eligible *provided* the lead first invokes each in-scope skill via the `Skill` tool and records the invocation in `execution-log.md` before applying any edits (log line format: `Lead-invoked skill: <skill-name>\nDomain: <domain>\nSkill template-version: <hash>` via `write-execution-log.sh --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"`; the skill's `skill_template_version` is already in `open`'s map). If condition 4 is false because of `**Consultations required:**` or a non-empty ceremony list, fall through to Step 3 worker dispatch. On the capability route, the lead invokes every related skill and satisfies every declared consultation itself before editing the affected task.

**No file-count cap.** An earlier version of this gate required ≤3 files. Evidence from the scale-registry-rename cycle (single prescriptive task, 10 verbatim file edits, no discretion) showed the cap was a proxy for "discretion required" that the other conditions already cover better. A 50-file prescriptive rename is still 50 file edits with no discretion; splitting across workers pays N × ~22KB context tax for no shaping gain. `detail.file_count_diagnostic` remains telemetry and does not gate.

**On a worker-dispatch-capable harness, if any condition fails (outside the carve-out):** skip Step 3.0 entirely and proceed to Step 3 (worker dispatch). Do not log a skip — the worker pipeline is the default.

**If either route is selected:** execute and persist each task inline.

1. **Log route selection** — one entry to `execution-log.md`; do not claim that the collapse fired yet:
   ```bash
   printf 'Lead-inline execution: route selected\nRoute: %s\nTask count: %d\n' \
     "<capability-collapse|efficiency-collapse>" "<selected TaskCreate manifest entry count>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug "$SLUG" --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```
2. **Invoke in-scope skills before editing (if any),** per the condition-4 carve-out, logging each as above.
3. **For each selected task in manifest dependency order, apply its edits directly** using the lead's `Read` / `Edit` / `Write` / `Bash` tools and honor its phase's `**Verification:**` objectives. Read each task description the same way a worker would. **Reviewer-facing comment discipline applies to the lead too** — apply the drop/keep rules, drift test, and worked examples from `agents/worker.md` step 5 to any comments you write into committed source.
4. **Emit that task's Tier 2 evidence** for any falsifiable claims the edits depend on, with `$LEAD_TEMPLATE_VERSION` — the lead is the producer:
   ```bash
   echo '<tier2-row-json>' | bash ~/.lore/scripts/evidence-append.sh --work-item "$SLUG"
   ```
   Every row MUST carry `exact_snippet` and `normalized_snippet_hash`. Compute via the canonical helper — do NOT inline the recipe (`python3 ~/.lore/scripts/snippet_normalize.py --hash <<<"$SNIPPET"`); the v1 normalization recipe lives only in `scripts/snippet_normalize.py`, and `evidence-append.sh` delegates to `validate-tier2.sh`, which rejects rows that omit either field or carry a hash that does not match.
5. **Persist that task's full report, then its execution-log reduction.** Assign the task's report id at route selection — filesystem-safe and attempt-specific (`<task-id>-r<attempt>`; a retried task gets a fresh id, never an overwrite) — and write the complete schema-v1 report to `$ITEM_DIR/worker-reports/<report-id>.md` (create the directory on first write): the identity header (`Report-schema: 1`, `Report-id:`, `Work-item:`, `Task:`, `Producer-role: implement-lead`, `Dispatch-path: lead-inline`, `Harness:`, `Status:`, `Template-version:`) followed by the same labeled sections a worker report carries (`agents/worker.md` step 9), **Artifacts:** manifest included. That file is the durable evidence of record; the execution-log entry below is its per-task reduction, never its substitute. Give every reduction a run-and-task key, and use the same narrative fields as Step 4 §3 so /retro receives per-task material on every route:
   ```bash
   REPORT_KEY="$RUN_STARTED_AT/<task-id>"
   printf 'Report-key: %s\nTask: %s\nChanges: %s\nSkills: %s\nTier2-claims: %s\nObservations: %s\nConvention: %s\nInvestigation: %s\nBlockers: %s\nConsultations: %s\nTest result: %s\n' \
     "$REPORT_KEY" "<task-subject>" "<lead Changes>" "<lead Skills used>" \
     "<comma-separated claim_ids>" "<lead Observations or Tier 3 summary>" \
     "<lead Convention handling>" "<lead Investigation>" "<lead Blockers>" \
     "<lead Consultations>" "<passed|failed|skipped>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug "$SLUG" --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```
   If a field has no content, write `None`. Never batch several tasks into one entry.
6. **Read back the durable report and key before accepting the task:**
   ```bash
   test -s "$ITEM_DIR/worker-reports/<report-id>.md"
   test "$(rg -Fxc "Report-key: $REPORT_KEY" "$ITEM_DIR/execution-log.md")" -eq 1
   ```
   A failed write or read-back halts the route before the task is checked off. Do not count a screen-rendered report or an in-memory draft.
7. **Stash any Tier 3 candidates** for Step 5 (promotion still goes through `promote-batch` with `producer_role: implement-lead`), then mark that task complete: `lore work check "$SLUG" "<task-subject>"`. Once that checkbox write succeeds, a hosted session journals the task milestone:
   ```bash
   if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
     bash ~/.lore/scripts/session-step.sh \
       --step-id "implement:task:<task-id>" --step-label "Accepted task <task-id>" \
       || echo "[implement] Warning: step for task <task-id> not journaled; the logged report and checked task remain authoritative." >&2
   fi
   ```
   The env gate is the hosted-session test — an unhosted run skips silently. Replay is idempotent, and a failed append warns without unwinding the acceptance.
8. **Commit the collapse only after all selected tasks pass read-back.** Let N be the number of selected TaskCreate manifest entries, then verify and log the durable count:
   ```bash
   REPORT_COUNT=$(rg -Fc "Report-key: $RUN_STARTED_AT/" "$ITEM_DIR/execution-log.md")
   test "$REPORT_COUNT" -eq "<selected TaskCreate manifest entry count>"
   printf 'Lead-inline execution: gate fired\nDurable per-task reports: %d/%d\n' \
     "$REPORT_COUNT" "<selected TaskCreate manifest entry count>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug "$SLUG" --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```
   The per-task exact-key read-backs in §6 make those N prefix matches distinct task reports. If the count is not N, halt before Step 5; the collapse did not fire.
9. **Skip Steps 3, 4, and the batch-loop shutdown** — no team exists to shut down. Proceed directly to **Step 5** → **Step 6** → **Step 7**.

**Sanctioned pause (efficiency route only):** if the lead is unsure whether the prescriptive task is fully determined enough to execute without discretion, fall through to Step 3. The capability route remains mandatory — its harness has no worker-dispatch surface to fall through to — so uncertainty there is the lead's to resolve by judgment, never by weakening report persistence.

### Step 3: Spawn agents

**You MUST spawn workers immediately once the manifest is executed and worker prompts are assembled.** Do not pause to confirm scope. Do not echo plan-resolved open questions back to the user (the plan already encodes scope guards in task descriptions). Do not surface "this is large" as a decision request. Do not request approval to modify a skill because the skill being modified is the running skill (your prompt is loaded; file edits do not affect the current run). The only sanctioned pre-dispatch pauses: (a) item resolved to archived without confirmation (Step 1.2), (b) `tasks.json` checksum mismatch (Step 2), (c) the `worker` agent template is missing (Resolve Paths' MANDATORY clause), or (d) Step 3.0 fired and execution completed inline. Pausing for any other reason is a faster-path bypass — the cost is borne by the user as session-spanning delay; the lead pays nothing. **Why immediate dispatch matters:** one bad spawn is caught in Step 4 review; pre-dispatch confirmation does not buy safety the system already provides.

**Render guidance at each exact prompt seam.** Immediately before assembling an advisor, worker, chaperone, or worker-session prompt, run `lore dispatch guidance`; if it fails, do not launch that prompt. Prepend the complete output verbatim before all template and task content. Render separately for every launch and retry. A chaperone's inner worker prompt is a distinct launch and receives its own fresh rendering; the outer rendering is not inherited. The spawn templates below carry the route-specific assembly details, while model, placement, task, and report decisions remain on their existing paths.

1. **Assemble `$PRIOR_KNOWLEDGE` from `open`'s `prior_knowledge`** — the verb already ran the 3-branch gate per phase. Concatenate each resolved phase's content under its `### Phase N: <phase_name>` heading, blank-line separated; phases with no output contribute no heading. Resolve every `needs-prefetch` phase (declare scale, re-run `open` with `--fallback-scale-set`) before spawning any worker. For v2 directives, workers consume the multi-section `### Focal:`/`### Adjacent:` shape as candidates-to-curate per `agents/worker.md`'s `## Knowledge Context` directive, not as authoritative pre-resolved context.

2. **Prepare advisory mixin (opt-in only)** — from `open`'s `advisors` field (already filtered to `mode: persistent`).

   **Default route (empty list):** set `$ADVISORY_MIXIN=""` and skip the rest of this sub-step. Do NOT read `scripts/agent-protocols/advisory-consultation.md`.

   **Opt-in route (at least one persistent advisor):** read the advisory mixin at `scripts/agent-protocols/advisory-consultation.md` (its opt-in-only header note confirms this is the correct consumer), build the `{{advisors}}` replacement block as a markdown list (`- **advisor-name** — domain scope. Mode: persistent`), resolve the placeholder, store as `$ADVISORY_MIXIN`.

3. **Hold `open`'s `skill_invocation_map` as `$SKILL_INVOCATION_MAP`** — in-memory routing state for Step 4.0's per-domain skill invocation. Do NOT modify `plan.md`; per D3 the skill's calibration unit is its SKILL.md template-version, already captured in the map. An empty map means Step 4.0 falls through to inline lead evaluation for every domain.

4. **Spawn advisor agents (opt-in only)** — one per unique persistent advisor. **Skip this entire sub-step when the persistent-advisor list is empty** — no advisor agents spawn on the default route; the lead handles consultations inline via Step 4.0 and the execution log records zero `Advisor spawned:` lines. For the spawn block and log entry shape, read `skills/implement/templates/advisor-spawn.md`. Advisors are persistent — active for the entire session and shut down alongside workers in the batch-loop shutdown.

5. **Surface Tier 2 evidence per worker** — render each task's rows from `open`'s `tier2_extracts` as a YAML block appended to that worker's `{{prior_knowledge}}`:

   ```yaml
   Prior Tier 2 evidence (from task-claims.jsonl):
     - claim_id: <id>
       claim: <one-line claim text>
       task_id: <task-id>
       captured_at_sha: <sha>
   ```

   If no rows match, omit the block (do NOT emit an empty section).

6. **Allocate mutating placements, then spawn with tier-aware emission instructions.** Launch up to the effective settings-derived ceiling, further bounded by ready work and runtime capacity. Read-only tasks need no worktree. Before every mutating launch, the lead allocates through `lore coordinate worktree allocate` and carries its immutable stream/attempt identity into the dispatch. Allocation never delegates. A session uses `owner-kind=session`; a harness-native worker is admitted only when its dispatching seat owns the lease and the adapter can place it inside that exact `execution_dir`. Otherwise route the task to an item-backed worker session. An unleased mutating subagent is prohibited. Use the `worker` agent template (resolve via `resolve_agent_template worker`) as base, with these injections:

   - `{{team_name}}` → `impl-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 2
   - `{{prior_knowledge}}` → `$PRIOR_KNOWLEDGE`, followed by that worker's Tier 2 extract block (blank-line separator)
   - `{{template_version}}` → `$WORKER_TEMPLATE_VERSION`
   - For a mutating task, include `worktree_id`, `execution_dir`, stream id, attempt id, lease owner, and the rule that child workers may not allocate. The adapter must set the worker cwd to that exact execution directory; a mismatch refuses before source edits.
   - Include each assigned task's `packet_id` (carried on its TaskCreate manifest entry and in `open`'s `packets` field) as a literal `Packet-id: <packet_id>` line in that worker's Task prompt — the post-session packet assessor matches this line to confirm handoff. Omit the line for tasks without a `packet_id`.
   - Assign each task's report id before dispatch — filesystem-safe and attempt-specific (`<task-id>-r<attempt>`; a re-dispatch gets a fresh id, never a reuse) — and include it as a literal `Report-id: <report-id>` line alongside the task assignment in that worker's Task prompt. The worker echoes the id in its report header; the id fixes where Step 4 §1 lands the collected report.
   - Prepend the per-launch `lore dispatch guidance` output before the resolved worker or chaperone template. For a session route, also prepend a separately rendered block to the durable session brief before writing it; `session request --type worker` validates that exact brief at enqueue.

   Assign only tasks from `open`'s `initial_unblocked` set that the joined coordination board still reports ready. Known file/surface overlap consolidates or receives an explicit dependency edge before allocation; worktree isolation never waives semantic ownership. For subset selections, also account for files held by unselected tasks. After claiming (`TaskUpdate(owner=…)`), a worker-side `TaskGet` ownership re-check is the backstop for claim races.

   Workers declare `--scale-set` at every `lore prefetch` and `lore search` call. **Scale rubric — declare explicitly at every retrieval surface:** for the four scale definitions (abstract / architecture / subsystem / implementation), boundary tests, multi-label encoding, and the ±1 query pattern, see `skills/memory/SKILL.md` § Scale-Aware Navigation. The full decision tree lives in the canonical `classifier` agent template (resolved via `resolve_agent_template classifier`).

   The resolved worker template owns the Tier 2 append and completion-report procedure. Preserve the exact report labels **Tier 2 evidence:** and optional **Tier 3 candidates:**; the latter is literal-prefix-matched by the TaskCompleted hook.

   **If `$ADVISORY_MIXIN` is non-empty (opt-in route only):** append the resolved mixin content after the fully resolved worker template content, separated by a blank line. **On the default route `$ADVISORY_MIXIN` is empty** — worker prompts end at the resolved worker template; workers still have the `**Consultations:**` reporting field and `## Consultation` request shape from the worker template's §Reporting Guidelines, so they can SendMessage the lead without the mixin. The lead's Step 4.0 handler answers on the next turn boundary.

   For the spawn block, read `skills/implement/templates/worker-spawn.md`. It maps each task's judgment class to `worker-mechanical | worker | worker-judgment-dense` and consumes the matching `worker_class_routes` entry. An explicit per-run model or route pin wins. Otherwise a qualified route selects its `target_framework`: same-framework targets spawn natively, while a foreign Codex target uses the existing chaperone with its resolved `native_binding`; unsupported foreign pairs have already been refused by `impl start`. An unqualified binding stays on the native route unless the user or plan explicitly selects the legacy Codex or session route. A standing Codex route uses the first validated source-framework tier for the relay under the settled 2026-07-21 haiku exception; an empty tier ladder omits the relay model and surfaces degraded inheritance. Re-dispatch any `degraded` chaperone result through the same-harness route.

### Step 4: Collect progress

As worker results arrive — delivered automatically on messaging harnesses, collected via the adapter's `wait` + `collect_result` loop where messaging is unavailable — branch by kind:

- **Consultation requests** — bodies whose first line is `## Consultation` and that carry `consultation-id:` route to Step 4.0 below. Mid-task questions; reply immediately so the worker resumes on the next turn boundary.
- **Completion reports** — bodies matching the `## Reporting Guidelines` shape from `agents/worker.md` route through §1–§6.
- **Blocker messages** — anything else from a worker requiring intervention falls through to §5.

The durable consultation record is `$ITEM_DIR/consultation-transcript.jsonl` — one acknowledged-reply record per line, written ONLY by `lore impl consult-log` (the verb is its sole sanctioned writer). It replaces the old in-memory per-run transcript: §1's required-consultation check intersects against this file, so a consultation that was answered but never filed is indistinguishable from one that never happened. File every reply.

#### Step 4.0: Lead consultation handler (default route)

A worker SendMessage whose body begins with `## Consultation` and carries `consultation-id:` is a worker question routed to the lead. On the default route the lead answers inline using its own investigation/plan/code-read tools; skill-backed domains route through `$SKILL_INVOCATION_MAP` and invoke the named skill via the `Skill` tool before the lead replies. Answering is judgment-heavy (matching the worker's specific question to investigation/plan context) and intentionally stays inline rather than scripted — see `[[knowledge:conventions/skills/script-first-skill-design]]`; only the filing is a verb.

**Skip this sub-step entirely on the opt-in route** when the worker's phase declared `mode: persistent` advisors — the worker SendMessages the advisor agent directly on that route, not the lead. The advisor agent's reply path is owned by `agents/advisor.md` §"Responding to Consultations" (its reply carries `handler: agent`, `advisor_template_version`, and `advisor-acknowledged: true`). When an advisor-handled consultation surfaces (the advisor's reply, or the worker's report naming it), file it via `consult-log` with `--handler agent` so the durable transcript stays complete — the Step 4 §1 fabrication guard separately verifies `handler: agent` entries against actually-spawned advisors.

1. **Parse the request body** (per `agents/worker.md` §"Sending a `## Consultation` Request"): `consultation-id` (opaque worker-minted token), `domain`, `reason`, `question`, `task`, `phase`.

2. **Route by domain** — look up `$SKILL_INVOCATION_MAP[<domain>]`:

   **(a) Skill-backed domain.** Invoke the named skill via the `Skill` tool with `args` set to the worker's `question` (and any file/symbol context). Capture output and the map's `skill_template_version`. Set `handler="skill"`.

   **(b) No map entry.** Evaluate inline using the lead's `Read` / `Grep` / `Glob` tools, the `plan.md` already loaded in Step 1, and the in-flight `notes.md`. Set `handler="lead"`. Do NOT spawn an advisor agent — absence of a map entry is the default-route signal that the lead answers directly.

3. **Reply via SendMessage** to the requesting worker, in order:
   ```
   consultation-id: <verbatim from request>
   handler: <skill|lead>
   lead-acknowledged: true
   <when handler=skill>
   skill_template_version: <12-char hash from $SKILL_INVOCATION_MAP[<domain>].skill_template_version>
   <end conditional>

   <answer body — concrete, anchored, ready for the worker to apply>
   ```
   `lead-acknowledged: true` is the acknowledgement field §1's required-consultation check cross-checks for satisfaction.

4. **File the consultation through the verb — the only legal channel for the transcript record.** Immediately after replying, append both the transcript record (to `consultation-transcript.jsonl`) and the execution-log entry in one call; do NOT hand-append to either file:

   ```bash
   lore impl consult-log "$SLUG" \
     --consultation-id <id> --worker <worker-name> --domain <domain> \
     --handler <lead|skill|agent> \
     --question "<one-line summary>" --answer "<one-line summary>" \
     [--skill-template-version <hash>] [--advisor-template-version <hash>] \
     --template-version "$LEAD_TEMPLATE_VERSION"
   ```

   Contract (`scripts/impl-consult-log.sh`): judgment in, filing out — the answer is the lead's already-made judgment and the verb never produces or amends it; a missing answer or missing consultation metadata is a non-zero usage error before any write. Question and answer are JSON-string encoded so multi-line values survive as single log lines. Per-handler field contract (R = required, − = must be omitted; other combinations are rejected):

   | handler | `--skill-template-version` | `--advisor-template-version` |
   |---|---|---|
   | `lead` | − | − |
   | `skill` | R | − |
   | `agent` | − | R |

   Exit codes: `0` filed (transcript/log identifiers on stdout); `1` validation error / no match; `2` ambiguous reference.

5. **Do NOT block other Step 4 sub-steps** on consultation handling — the lead may receive a consultation from worker-A while waiting for a completion report from worker-B. Reply, file, then return to whichever queue the next message arrives on.

#### Step 4 §1–§6: Completion reports

1. **Persist the report, then run the mechanical check — every report, no exceptions.** Land the worker's completion report body verbatim at its preassigned canonical path, `$ITEM_DIR/worker-reports/<report-id>.md` (the id assigned at dispatch; create `worker-reports/` on first landing), before any checking. The message body, task description, and adapter result envelope are transport; the landed file is the evidence of record, immutable once the task is accepted — a re-dispatched attempt lands under its fresh id, never over prior evidence. A session-routed worker lands its own report at `$ITEM_DIR/worker-reports/<derived-slug>.md` before `terminus_reached`; validate that file rather than re-copying the chaperone's relay. Then gather the harness facts the verb cannot read itself and invoke the check against the landed file:

   ```bash
   lore impl check-report "$SLUG" --task <task-id> --report <file> --phase <n> \
     [--transcript "$ITEM_DIR/consultation-transcript.jsonl"] \
     [--woven-norm <label>]... \
     [--provider-status <full|partial|unavailable>] [--spawned-advisors <csv>] \
     --template-version "$LEAD_TEMPLATE_VERSION" --json
   ```

   Contract (`scripts/impl-check-report.sh`) — the verb never accepts or rejects the report; it runs the mechanical checks and files the findings:

   - **Tier 2 cross-reference (BLOCKING).** Every `claim_id` in the report's `**Tier 2 evidence:**` section must exist as a row in the canonical `task-claims.jsonl` — the substrate is checked, never the report's own assertion (rows there were already validated by `evidence-append.sh`; no re-validation). Missing ids are named in the findings.
   - **Required-consultation acknowledgement check (BLOCKING).** The phase brief's `**Consultations required:**` domains (from `lore work phase-context`) must each have a matching `**Consultations:**` entry in the report whose `consultation_id` appears in the `--transcript` file with a matching domain — i.e. a `lead-acknowledged: true` (or advisor-acknowledged) reply was actually filed. `--transcript` is required when the phase brief declares required domains; pass `consultation-transcript.jsonl`. Phases with no required block skip this check; the report field is then optional. Lead-side tracking adds *one* lever the previous pipeline lacked — a report naming a `consultation_id` no acknowledged record matches fails here; fabricated entries cannot satisfy a required consult.
   - **Convention-handling completeness (non-blocking).** Source the labels from the task's `woven_norms` array in `tasks.json` — one `--woven-norm <label>` per entry, in stored order. The field is omit-when-empty, so an absent field means either nothing was woven or the plan predates structured extraction: re-derive from the task description's `honor <stable-label>` clauses that carry a same-line knowledge backlink (the generator's own conjunction) — this recovers legacy labels and correctly yields nothing when nothing was woven. The verb compares the report's dispositions against that list — missing / duplicated / unrecognized labels and `none in scope`-despite-woven-norms conflicts are surfaced as findings, never as failures. This needs only the woven-norm list — do NOT read the diff. Divergence rationales are filed verbatim into the execution-log entry — the durable record the closure conformance aggregate reads at close — so a worker's honest `diverged: <label> — <why>` is exactly the signal worth preserving, never a blemish to smooth over; assessing rationales is §2's judgment, not the verb's.
   - **Fabrication guard (non-blocking, metadata-only).** `handler: agent` consultations are pre-filtered from the report's `**Consultations:**` field (entries with `handler: lead` or `handler: skill` bypass the guard — they have no advisor agent to corroborate against; an entry missing `handler` but carrying `advisor_template_version` is normalized to `handler: agent` for backward compat) and intersected with `--spawned-advisors` under the declared `--provider-status`. Three outcomes: **(a)** provider OK and every claimed advisor is verified — the full `handler: agent` subset flows to the rollup; **(b)** Mismatch — each unverified entry is stripped from the rollup payload and logged as `fabrication-guard: skipped <identifier>` (a per-entry filter, not all-or-nothing); **(c)** provider `unavailable`, or `partial` with the spawn surface degraded — the rollup is withheld entirely and `fabrication-guard: provider-<status>; rollup skipped` is logged. The guard exists to withhold unsupported attribution: absent verification is never license to attribute, so branch (c) does NOT fall through to verbatim-trust of the report. Zero rows on a providerless harness reads as "no signal" to /retro, same as never-invoked judges. The guard is metadata-only — the worker's code changes still ship, the Tier 2 evidence still grounds them; only the advisor scorecard attribution is withheld.
   - **Advisor-impact rollup.** The verified `handler: agent` subset is forwarded to `advisor-impact-rollup.sh` (the scorecard sole writer), emitting `consultation_rate` and `advice_followed_rate` rows. `handler: lead` and `handler: skill` entries never emit advisor scorecard rows. Rollup status (`appended` / `skipped` + reason / `failed`) is in the output.
   - **One execution-log entry** (source: impl-verb) filing the findings, including the canonical `fabrication-guard:` log lines.

   Every check reports a status — skips are loud, never swallowed. Exit codes: `0` checks ran, `mechanical_pass: true`; `1` validation error / no match; `2` ambiguous reference; `3` checks ran, `mechanical_pass: false`.

   **Harness facts are flag-passed because a CLI verb cannot read harness tool surfaces.** `--provider-status` is required only when the report carries `handler: agent` consultations; `full` additionally requires `--spawned-advisors` (pass an empty value when none were spawned). Compute the status via the canonical transcript-provider consumer pattern — `get_provider()` → catch `UnsupportedFrameworkError` → `provider_status()`:

   ```python
   from adapters.transcripts import get_provider, UnsupportedFrameworkError
   try:
       provider = get_provider()
       status, _reason = provider.provider_status()
   except UnsupportedFrameworkError:
       status = "unavailable"
   ```

   The spawned-advisor list comes from the lead's own spawn map (Step 3.4); when `provider_status()` is `full`, the transcript's spawn events (TaskCreate with `name: <advisor-name>`, extracted via the documented two-pass `parse_transcript()` + `read_raw_lines()` pattern) corroborate it — the lead-side map is canonical only on `full`; `partial`/`unavailable` statuses flow to branch (c) regardless.

   **On exit 3, the task is rejected — reject it.** SendMessage the report back to the worker naming the verb's `fail_reasons` (missing claim_ids, unsatisfied required domains); do NOT accept; do NOT proceed to §2. The rejected attempt's landed file stays as evidence; the retry reports under a fresh report id. **On exit 0, acceptance remains the lead's decision** — mechanical checks alone never accept. Audit the durable artifacts the report indexes — its **Artifacts:** manifest entries, the cross-checked Tier 2 rows, the changed files and test outputs — and weigh the report's substance (tests, blockers, scope), then accept or send back with guidance. Acceptance reads the landed report and the canonical artifacts behind it; a transcript, screen rendering, message body, or task description is never the evidence of record.

2. **Assess divergence rationales — the lead's judgment, never the verb's.** For each `diverged: <label> — <why>` finding the check surfaced, assess whether the rationale is convincing. A worker may legitimately diverge — silencing principled divergence is worse than the violation. "Woven but inapplicable to the actual change" is a valid divergence rationale (and a signal the upstream relevance-gate wove too loosely). You are assessing the *rationale*, not re-deriving compliance from the diff. This assessment is observability, not a gate: it NEVER blocks task acceptance and NEVER edits the worker's output.

   **Open a non-blocking followup for unconvincing divergences or completeness findings** (missing/duplicated/unrecognized norms from the check) — the observability trail only; task acceptance already happened in §1 and is unaffected:
   ```bash
   bash ~/.lore/scripts/create-followup.sh \
     --title "Convention handling: <work item title> — <task subject>" \
     --source "implement" \
     --attachments '[{"type":"work_item","slug":"<slug>"}]' \
     --suggested-actions '[{"type":"create_work_item"}]' \
     --content "<which norm label(s); whether unconvincing-divergence or missing/duplicated/unrecognized; the worker's rationale verbatim>"
   ```
   `honored`/`none in scope` reports with a clean completeness comparison pass without a followup — this is the common path. Never auto-fix the worker's output; the followup is the review-loop's input, not an edit.

3. **Write the worker-report execution log entry** — immediately after task acceptance. Pass `--template-version "$WORKER_TEMPLATE_VERSION"` because the body logged is the worker's report:
   ```bash
   {
     printf 'Task: %s\nChanges: %s\nSkills: %s\nTier2-claims: %s\nObservations: %s\nConvention: %s\nInvestigation: %s\nBlockers: %s\nConsultations: %s\nTest result: %s\n' \
       "<task-subject>" "<worker Changes field>" "<worker Skills used field>" \
       "<comma-separated claim_ids from Tier 2 evidence>" \
       "<worker Observations field or Tier 3 candidates summary>" \
       "<worker Convention handling field + your §2 assessment outcome: clean | followup-opened: <reason>>" \
       "<worker Investigation field>" "<worker Blockers field>" "<worker Consultations field — verbatim YAML list, or 'none'>" \
       "<passed|failed|skipped>"
     # Codex- and session-routed tasks only — one Spend: line copied from the
     # report's **Spend:** section (see the Spend-line note below). Drop this
     # line entirely for claude-native workers, which relay no **Spend:** section.
     printf 'Spend: task=%s %s\n' "<task-id>" "<the report's **Spend:** tokens, verbatim>"
   } | bash ~/.lore/scripts/write-execution-log.sh --slug "$SLUG" --source implement-lead --template-version "$WORKER_TEMPLATE_VERSION"
   ```
   If the worker omitted a field, use `None`.

   **The `Spend:` line — chaperone-routed tasks only.** When an accepted worker report carries a `**Spend:**` section — the `agents/codex-worker.md` and `agents/session-worker.md` chaperones each relay one; claude-native Task-tool workers do not — copy its `key=value` tokens verbatim into one `Spend: task=<task-id> <copied tokens>` line: `harness=<h> model=<m> effort=<e|none> input_tokens=<n> … duration_seconds=<n> basis=<b>`, the closed spend vocabulary flattened to `key=value`, fields omitted exactly as the report omitted them. It is a verbatim copy — the lead adds only `task=<task-id>` (the id it is logging), never rewrites, re-splits the effort suffix (already split adapter-side), or backfills a token the report did not carry. The copy mechanic is identical across both chaperones; the source differs — codex builds it from its terminal `token_count` event, the session chaperone from the worker session's `closed` event (basis `transcript`/`rollout`/`store`, or `duration-only` when degraded). A report with **no** `**Spend:**` section writes **no** `Spend:` line; `impl-close` reads that absence as `spend: null`. A degraded chaperone run relays a duration-only `**Spend:**` (`duration_seconds=<n> basis=duration-only`) — copy it the same way. The line records the *effective* model the chaperone resolved, which may differ from the class binding `impl-close` re-resolves; both stay legible. Session-routed tasks land their spend here, on the per-task line — the worker session's own `closed` row runs under a derived slug and is intentionally outside retro's session-spend line (see the `skills/retro/SKILL.md` session-spend note).

   **Log discipline:** one execution-log entry per task, written only after that task's worker completion report arrives — never log `pending worker report` placeholders. When a worker reports several tasks in one message, write one entry per task (batched entries lose per-task sequence and starve /retro of evidence).

4. **Set aside Tier 3 candidates for Step 5** — if the worker report contains a `Tier 3 candidates:` YAML block, stash each entry (preserving producer_role and source_artifact_ids) for Step 5. Do NOT promote here — Step 5 is the sole promotion site.

5. **Handle blockers** — if a worker reports blockers: read the relevant code/context; send guidance via the adapter's `send_message` (on Claude Code the native `SendMessage` tool; on harnesses where the adapter returns `unsupported`, fall back to lead-only orchestration — re-spawn with a corrected prompt instead). If unresolvable, note in `notes.md` and move on.

6. **Reconcile mutating work, then check off completed items.** A read-only task may proceed directly to the checkbox after acceptance. For a mutating task, worker completion means quiescent, not done: freeze the immutable source manifest, run pre-merge conformance, and let the coordinator attempt integration from the clean stable checkout. A conflict is recorded and aborted; the coordinator decides intended composition when existing contracts settle it, then re-dispatches worker source edits and freezes a new attempt. After a clean audited merge, freeze the integrated manifest, advance the manager to `cleanup_due`, and clean the tree. Only a full verdict plus proof of path absence, Git-registry absence, and temporary branch/guard-ref disposition permits:
   ```bash
   lore work check "$SLUG" "<task-subject>"
   ```
   Once that checkbox write succeeds, a hosted session journals the task milestone (the same env-gated invocation as the lead-inline route):
   ```bash
   if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
     bash ~/.lore/scripts/session-step.sh \
       --step-id "implement:task:<task-id>" --step-label "Accepted task <task-id>" \
       || echo "[implement] Warning: step for task <task-id> not journaled; the logged report and checked task remain authoritative." >&2
   fi
   ```
   `next-batch` reads completion from these checkboxes; Step 7's close reconciles any misses via `--check-task`. `cleanup_blocked`, missing proof, or an unresolved conflict keeps the checkbox open.

A task's `step_completed` row belongs to the parent implement session and asserts the full acceptance sequence — report accepted, logged, checkbox persisted. Nothing upstream of that emits: worker completion messages, Tier-2 claim appends, consultation replies, batch transitions, and phase-close echoes all stay journal-silent. Whole-protocol completion remains `impl-close`'s separate `terminus_reached` row.

#### Eager dispatch join

After every task acceptance, rejection, dispatch, terminus, reconciliation, cleanup, failure, or steering transition, re-join the board and ask what is dispatchable. Do not wait for unrelated active workers:

```bash
lore impl next-batch "$SLUG" [--active <task-id>]... --json --template-version "$LEAD_TEMPLATE_VERSION"
```

Contract (`scripts/impl-next-batch.sh`) — a prepare-and-return emitter; the lead spawns workers. Completion comes from plan.md checkboxes, active task ids come from the lead, and explicit dependency edges come from tasks.json; no `ready` flag is persisted. The plan checksum is deliberately not re-enforced after `open`, because checkbox writes change plan.md. For coordinated work, intersect the result with `lore coordinate status`: only `act_now` streams with no active attempt and terminal full+cleaned predecessors may launch. Exit codes: `0` result emitted, `1` error, `2` ambiguous reference.

- **Ready work:** dispatch immediately up to the effective settings-derived ceiling, with each worker's refreshed Tier 2 extract and, for mutating work, a fresh manager allocation. Known overlap consolidates or receives an explicit edge before dispatch.
- **`status: all-blocked`:** every pending task is blocked or in flight — return to collecting reports (§ above) or resolve blockers (§5).
- **`status: all-complete`:** no pending tasks remain and every coordinated writer is reconciled and cleanup-verified. Shut down the team:
  a. Send `shutdown_request` to all active workers and advisors via the orchestration adapter — `ADAPTER="$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh"`, then `bash "$ADAPTER" shutdown <handle> true` per handle (on Claude Code this expands to the native `SendMessage` with `type=shutdown_request approve=true`).
  b. **Write advisor shutdown log entries** — for each spawned advisor:
     ```bash
     printf 'Advisor shutdown: %s\nDomain: %s\n' "<advisor-name>" "<domain scope>" \
       | bash ~/.lore/scripts/write-execution-log.sh --slug "$SLUG" --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
     ```
  c. Run `TeamDelete` (Claude Code only; opencode/codex's runtime owns team teardown).

### Step 5: Promote accepted Tier 3 candidates

Step 5 is the sole Tier 3 promotion site for `/implement`. Do NOT delegate to `/remember`. Do NOT call `lore capture` directly for work-item-scoped observations — promotion goes through the verb, which delegates to `lore promote` (the canonical path: it forces `confidence=unaudited` and enforces Tier 3 schema via `validate-tier3.sh` before writing).

**Select the accepted set — the lead's judgment; the verb never selects candidates.** Inputs: the Tier 3 candidate list stashed in Step 4 §4, plus any lead-originated cross-task candidates the lead produces by reading the complete `execution-log.md` after the last batch. Review each candidate on its merits (reusability, grounding, falsifier quality) and write the accepted set to a file as a JSON array or JSONL (one Tier 3 row object per entry, `producer_role` and `source_artifact_ids` preserved from the worker's block).

**Run the promote verb on the selection — including an empty one.** Step 5's commitment is to evaluate and file the summary, not to produce non-zero promotions; "no candidates → no-op → nothing to do" is the bypass shape named in the commitment protocol. The verb makes the empty case concrete: an empty candidates file is valid input and still files the `Tier 3 promotion summary: 0 accepted, 0 rejected` execution-log entry — the committed reasoning a later auditor reads.

```bash
lore impl promote-batch "$SLUG" --candidates <file> \
  --lead-template-version "$LEAD_TEMPLATE_VERSION" \
  --worker-template-version "$WORKER_TEMPLATE_VERSION" \
  --advisor-template-version "$ADVISOR_TEMPLATE_VERSION"
```

Contract (`scripts/impl-promote-batch.sh`) — judgment in, filing out; per candidate row:

1. **Source-artifact verification** — every id in the candidate's `source_artifact_ids` must exist as a `claim_id` in THIS work item's `task-claims.jsonl`; cross-work-item references are always rejected. Rejections are named with reasons in the output and the summary log.
2. **Attribution** — `producer_role` maps to its template version (`worker` / `advisor` / `implement-lead`); an absent `producer_role` defaults to `implement-lead`, the default is injected INTO the row itself (lore-promote validates the row, not flags), and the defaulting is noted in the summary log. Any other role is rejected as mis-attribution. One `lore promote` call per candidate keeps role × template attribution intact — multi-producer synthesis is NEVER merged.
3. **Promotion** — one `lore promote` per accepted candidate (forces `confidence=unaudited`, validates via `validate-tier3.sh`, delegates the commons write to `capture.sh`). A non-zero promote exit moves the candidate to the rejected list — rejections are results, not command failures.
4. **Summary log** — one execution-log entry per invocation, always written, including `0 accepted, 0 rejected` on empty input.

Role template versions default from the implement-skill/worker/advisor templates when the flags are omitted (warn-degrade to unstamped). Exit codes: `0` batch processed (accepted/rejected lists on stdout); `1` usage error / unreadable or malformed candidates file / no match / summary-log failure; `2` ambiguous reference.

### Step 6: Closure verdict

<!-- INVARIANT — canonical closure vocabulary. scripts/impl-close.sh validates
     these exact tokens and rejects any other:
       verdict: full | partial | none
     The closure block schema below is the FIXED contract impl-close.sh writes and
     implement-closure-report.sh + the work-index projector read — do NOT rename
     fields or verdict tokens here without changing those consumers first. -->

Step 6 is the capability-anchor reconciliation: the lead compares the run against `_meta.json.intent_anchor` and decides a single trichotomous verdict — `full | partial | none` — which Step 7's close verb records. The closure failure mode this verdict catches is named in the [[knowledge:principles/workflow-design/closure-laundering-is-failure-mode-where-local|closure-laundering principle]]: substrate completion (Tier 2 evidence valid, every task checked) accepted as capability completion when a load-bearing step was mocked or deferred.

The system has four distinct closure layers. They operate on disjoint signals; none can override another, and all four must permit archive on a coordinated anchored item. The close verb runs them in load-bearing order:

1. **Task-system archive precondition** — `REMAINING_COUNT=0` after `--check-task` reconciliation. The verb hard-refuses the close (exit 1, mechanical followup filed, NO verdict recorded, NO closure block written) while any plan.md checkbox remains unchecked — the verdict is recorded only against the final task-complete run, so a stale closure row can never attach to a state the system no longer matches.
2. **Coordinated cleanup precondition** — when reconciliation state exists, every writer attempt must have valid immutable source/integrated manifests and cleanup proof from the manager archive. `full` additionally requires the latest attempt of each stream to be integrated/full/cleaned. Unproven removal across path, Git registry, or branch/ref disposition is a failed close; no verdict or archive write follows.
3. **Mechanical Followup Creation Gate** — when unchecked tasks or non-`none` `Blockers:` entries in `execution-log.md` exist, the verb files a `Deferred work:` followup in `_followups/`. This observability layer does not consult `intent_anchor` and cannot substitute for the verdict.
4. **Anchor verdict** — the lead's semantic capability assertion against `intent_anchor`. Only `full` permits archive; `partial` and `none` hold the parent open as `capability-incomplete` through the same loud, non-zero close.

**Decide the verdict — the lead's discretion-bearing read of what actually shipped.** Read the `intent_anchor` verbatim, then `notes.md`, `execution-log.md`, the run's worker reports, and any blocker context. Use the closure-laundering vocabulary verbatim (load-bearing step, mocked, deferred):

- **`full`** — the run delivers the load-bearing capability the anchor names. Write a one-line `capability_loop_summary` naming the user-facing loop now operable. Archive proceeds.
- **`partial`** — at least one load-bearing step the anchor depends on is mocked or deferred. A **non-completion**: the parent is NOT archived — it stays active as `capability-incomplete`. Write a `capability_loop_summary` that *names what shipped*, a one-line `divergence_summary` naming what was mocked or deferred, and a residue title + residue intent anchor for the deferred capability. The residue anchor must obey the [[knowledge:conventions/protocol/work-item-intake-should-store-neutral-intent-ancho|intake neutrality rule]] — describe the residue capability in neutral terms; do not smuggle the parent's framing or solution into the child.
- **`none`** — the run does not deliver the capability. Also a **non-completion**: the parent stays active as `capability-incomplete`. Write a `capability_loop_summary` naming what was attempted and a `divergence_summary` naming that no load-bearing capability was delivered. No residue child; `none` is anchor non-delivery routed through the same loud channel as `partial`, not a separate concept.

Ask via `AskUserQuestion` only if the lead cannot ground the call in the run's evidence; if the run record is unambiguous (all tasks checked off, no blockers, load-bearing steps all have direct artifact evidence), the lead decides and reports rather than prompting. The closure block the verb writes against this verdict is the fixed contract (declarative — for reading, never for hand-writing):

```
closure = {
  verdict:                 "full" | "partial" | "none",
  capability_incomplete:   bool,          # true iff verdict in {partial, none}
  capability_loop_summary: str,           # full/partial: what shipped; none: what was attempted
  divergence_summary:      str | null,    # partial/none: one line on what was mocked or deferred
  residue_followup:        str | null,    # child slug on partial; null otherwise
  verdict_at:              iso8601 str,
  intent_anchor_at_close:  str,
}
```

**Legacy fallback (no intent_anchor):** items without an anchor take only `--verdict full` — `partial`/`none` are anchor-relative verdicts and the verb refuses them. No closure block is written and the item archives via the mechanical layers alone. This preserves the cycle on pre-anchor work items without back-filling — closure-time anchor synthesis would be retroactive intake under conversational pressure, the exact failure mode the intake-side anchor moved capture to intake to avoid.

[[knowledge:architecture/plan-task-models/lore-work-check-is-not-taskcompleted-acceptance|Acceptance-layer note:]] `lore work check` (task-system layer) and the closure verdict (capability-loop layer) sit at different altitudes. The task system answers "did this artifact get produced and pass per-task checks"; the closure verdict answers "did the run deliver the capability the anchor names." The closure verdict cannot override the task-system archive precondition (a `full` verdict on a task-incomplete item is refused outright — no row is recorded at all), and the task-system precondition cannot substitute for the closure verdict (every task checked is the *input* to the verdict, not its conclusion).

**Lazy audit note:** the Stop hook triggers audit of this session's promotions; `/implement` does not invoke it explicitly. Completion remains non-blocking because the audit runs opportunistically after session end.

### Step 7: Close the run

1. **Append a session entry to `notes.md`:**
   ```markdown
   ## YYYY-MM-DDTHH:MM
   **Focus:** Implementation via /implement
   **Progress:** Completed N/M tasks across K phases
   **Tier 2 claims:** <count> written; **Tier 3 promoted:** <count> accepted, <count> rejected
   **Next:** <remaining tasks if partial, or "Implementation complete">
   ```

2. **Close through the close verb — the only legal channel for the closure write.** `lore impl close` is the sole sanctioned writer of the `_meta.json` `closure` block; hand-writing that block (or any of the close's composed artifacts) corrupts every reader of the closure contract. One invocation carries the Step 6 verdict and the run facts:

   ```bash
   lore impl close "$SLUG" --verdict <full|partial|none> \
     --summary "<capability_loop_summary>" \
     [--divergence "<one line: what was mocked or deferred>"] \
     [--residue-title "<residue title>" --residue-anchor "<residue intent anchor>"] \
     [--check-task "<task-subject>"]... \
     --tier3-accepted <N> --tier3-rejected <M> \
     --lead-template-version "$LEAD_TEMPLATE_VERSION" \
     --worker-template-version "$WORKER_TEMPLATE_VERSION" \
     --advisor-template-version "$ADVISOR_TEMPLATE_VERSION" \
     --run-started-at "$RUN_STARTED_AT"
   ```

   Per-verdict field contract (R = required, − = must be omitted; other combinations are rejected):

   | verdict | `--summary` | `--divergence` | `--residue-title` / `--residue-anchor` |
   |---|---|---|---|
   | `full` | R | − | − |
   | `partial` | R | R | R (child work item created) |
   | `none` | R | R | − |

   Pass one `--check-task <subject>` per task completed this run whose plan.md checkbox might still be unchecked — the verb reconciles from these before counting (the task system is the source of truth for completion; the checkbox is the durable record). `--tier3-accepted`/`--tier3-rejected` come from Step 5's results (defaults: accepted from the `promoted-commons.jsonl` row count, rejected `0` — display values for the report).

   Contract (`scripts/impl-close.sh`) — the composed Steps 6–7 sequence, every write through the file's sanctioned writer:

   - **Reconcile and heal:** check `--check-task` subjects into plan.md (via `update-plan-checkbox.sh`), run the work-structure heal.
   - **Task-system precondition (hard refusal):** with unchecked tasks remaining, file the mechanical followup, refuse the close — exit 1, no verdict recorded, no closure block written. Complete or re-plan, then re-run close. (Tasks-complete-but-blockers-logged files the followup and continues.)
   - **Coordinated reconciliation precondition:** when stream state exists, validate both immutable manifests and every manager archive cleanup proof before any closure write. Missing or hash-invalid evidence, a non-full latest attempt on `full`, or cleanup lacking path + Git-registry + branch/ref proof refuses the close.
   - **Partial residue child BEFORE parent closure:** on `partial`, create the child work item (with the residue title/anchor and `--related-work` back-link) and capture its slug; if creation fails, the parent closure block is NOT written and the parent is NOT archived — diagnose and re-run.
   - **Closure block write** on `_meta.json` (the one write owned here; legacy items get none), plus the `partial` notes.md cross-link naming the child slug.
   - **`retro-bundle.json` snapshot** — the nine-field producer bundle `/retro` reads (`work_item`, `tasks_completed`, `tier2_claim_ids`, `tier3_promoted_ids`, `advisor_consultations_count`, `blockers`, `template_versions`, `captured_at_sha`, `run_started_at`). Overwrite-per-run snapshot semantics; producer-only — canonical artifacts (`task-claims.jsonl`, `execution-log.md`, `notes.md`) remain historical truth and `/retro` falls back to them if the bundle is missing or malformed.
   - **One execution-log closure entry** (source: impl-verb).
   - **Closure-validity gate:** the anchored closure block is validated before any archive move — a missing/malformed block refuses without archiving; `partial`/`none` hold the parent open as `capability-incomplete`; legacy/`full` become archive-eligible once the observability steps below have run.
   - **One `kind=telemetry` scorecard row per close** (`metric: impl_close_bookkeeping` via `scorecard-append.sh`): closure verdict plus counts of verb-mediated (`source: impl-verb`) vs hand-run execution-log entries. Observability-only — never `kind=scored`, never /evolve-cited; a failed append warns and the close continues.
   - **Conformance aggregate (sampled), then archive-before-report:** after the closure block and telemetry, while the item still sits in active `_work/`, the verb decides whether to invoke `conformance-render.sh` — sole writer of the item's `closure-conformance.md`, the five-panel aggregate the coordinator reads at close (spec-time discovery manifest, woven norms, recorded dispositions, shipped diff, diff-seeded closure discovery). The eager render is **sampled, not universal**: a degraded verdict (`partial`/`none`) always renders; a routine close renders when a deterministic coin (sha256 of slug+date) clears `conformance_sampling.render_rate` (settings.json, default 0.25). A sampled-out close announces the skip and the on-demand path — `lore work conformance <slug>` reproduces the identical aggregate at any time, so the skip loses evidence eagerness, never evidence. Cost, measured 2026-07-16: ~9s wall per render, ~195-line artifact (~1.7k tokens of coordinator reading). **Sunset:** review by 2026-10-16 — retire the auto-render (rate→0, on-demand only) if the sampled window surfaces no delivery-drop finding that changed an acceptance decision; the mechanism must beat repair-on-encounter to keep its rate. Enforcement moves both directions: a norm family escalates toward blocking only on retro-mined recurrence, and de-escalates by the same evidence read in reverse — a clean window returns it to list-tier. A render failure warns and never changes archive behavior or the close exit code. Then legacy/`full` archive via `archive-work.sh` and the move is verified (item present in `_archive/`, absent from active `_work/` — FATAL on either failure); `partial`/`none` are verified still active. Archive commits before any session-terminus side effect and before the terminal report renders — prior versions of this skill treated archive as an earlier, decoupled step and observed it silently skipped roughly half the time once the report's clean-handoff feel landed; the verb removes that gap structurally.
   - **Terminal report via `implement-closure-report.sh`** — the sole terminal emitter: the Done summary + exit 0 on `full`/legacy, the isolated divergence banner + exit 3 on `partial`/`none`, and a location-vs-verdict mismatch fails without printing Done so a corrupted close cannot launder into a success report. The verb propagates the report's exit verbatim.

   Exit codes: `0` clean close (full/legacy) — Done report emitted, item archived; `1` validation error / precondition refusal; `2` ambiguous reference; `3` anchor divergence (partial/none) — banner emitted, parent held open.

3. **Emit the verb's stdout verbatim as the terminal close, and nothing further.** Do NOT hand-compose a Done block — the success summary text exists ONLY inside the report script's exit-0 branch, so the divergence path has no success prose the lead could re-emit. A non-zero exit from the close *is* the run's non-completion — report it as such; do not paper over it with a success line. On exit 3 the parent remains active and responsible for the deferred residue until the child (named in the banner, on `partial`) delivers it via its own `/spec` + `/implement` cycle.

## Handling Partial Completion

If workers hit blockers or the team can't finish all tasks:
1. Capture progress to `notes.md` via the Step 7.1 session entry
2. Reconcile plan.md from the task system — run `lore work check` for every completed task whose checkbox is still unchecked (or pass the subjects as `--check-task` if attempting a close; the close's task-system precondition will refuse and file the deferred-work followup, which is the correct loud outcome)
3. Report what completed and what's left
4. The user can re-run `/implement` later to pick up remaining tasks

## Resuming Implementation

When `/implement` is called on a work item with partially-checked `plan.md`:
- `lore impl start` re-reads `task-claims.jsonl`, so resumed workers still see prior Tier 2 evidence
- `lore impl open` excludes already-checked tasks from the manifest (they return in `already_complete`) — use `--phase`/`--task` selection to stage the remainder, accounting for cross-selection file collisions
- Report: "Resuming — N remaining tasks across M phases"
