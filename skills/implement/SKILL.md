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
| Spawn decision | Steps 3, 4 batch loop | who runs what, serialize vs merge | — (harness calls) |
| Consultation answers | Step 4.0 | `handler: lead` \| `skill` \| `agent` | `consult-log` |
| Accept/reject | Step 4 §1 | acceptance after mechanical pass | `check-report` (mechanics only) |
| Divergence-rationale assessment | Step 4 §2 | convincing / unconvincing | — (followup) |
| Tier-3 selection | Step 5 | accepted candidate set | `promote-batch` |
| Closure verdict | Steps 6–7 | `full` \| `partial` \| `none` | `close` |

## Resolve Paths

```bash
lore resolve
```
Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

Agent templates live in the lore repo under `agents/<name>.md` and surface via `resolve_agent_template <name>` (Claude Code: `~/.claude/agents/<name>.md`). Do NOT use `git rev-parse --show-toplevel` for agent paths — the current repo is the target project, not the lore repo.

**MANDATORY:** You MUST read the actual template files for `worker` and `advisor` when spawning agents — resolve each via `resolve_agent_template worker` and `resolve_agent_template advisor`. Do NOT skip this step. Do NOT generate inline agent prompts as a substitute. If the resolver fails or the files are missing, stop and report the error — never fall back to improvised prompts.

Template versions and role→model bindings come from the `lore impl start` struct (Step 1) — `$LEAD_TEMPLATE_VERSION`, `$WORKER_TEMPLATE_VERSION`, `$ADVISOR_TEMPLATE_VERSION` tag emissions produced by their matching templates and are NOT interchangeable. A version the verb could not resolve arrives as an empty string with a stderr warning; downstream scripts treat the omitted flag as "no template version" (CC-01 legacy warn+pass). Registration into `$KDIR/_scorecards/template-registry.json` happens automatically on first use by `scripts/scorecard-append.sh`.

## Protocol-to-Skill Projection (9 → 7)

Proposal §9.2 describes nine logical steps. This SKILL.md presents them as seven `### Step N` sections — a compatibility-preserving projection that keeps related concerns (load vs. verify vs. promote) on clean section boundaries:

| §9.2 Logical Step | SKILL.md Step |
|---|---|
| 1 Load tasks.json + Tier 2 evidence + prefetched commons | Step 1 |
| 2 Dispatch workers with scope, files, acceptance checks, evidence requirements | Step 2 + Step 3 |
| 3 Workers produce code + tests + Tier 2 + optional Tier 3 | Step 3 |
| 4 Lead verifies work output + Tier 2 evidence | Step 4 |
| 5 Lead separates accepted work from remembered doctrine | Step 4 |
| 6 Lead writes/updates execution evidence | Step 4 |
| 7 Lead runs Tier 3 promotion on accepted candidates | Step 5 |
| 8 Stop hook lazily triggers audit; completion non-blocking | Step 6 (reference only) |
| 9 Prepare `/retro` inputs | Step 7 |

**Lead-inline route variant.** Step 3.0 introduces a pre-dispatch short-circuit. When the plan satisfies the lead-inline conditions (single prescriptive task, no persistent advisor, no required pre-edit orchestration — file count is no longer gated), §9.2 steps 2–6 collapse into direct lead execution: the lead applies edits using its own tools, emits Tier 2 evidence with `$LEAD_TEMPLATE_VERSION`, then jumps to Step 5 → Step 6 → Step 7. No team is created and no workers spawn.

### Step 1: Start the run

1. **Parse arguments:** extract the work item reference. The `--model <id>` flag is an undocumented per-invocation override that, when present, exports `LORE_MODEL_LEAD=<id>` for the duration of this skill — it stamps only the lead role for this run and does NOT touch worker/advisor/researcher bindings. (Per-role overrides via `LORE_MODEL_<ROLE>` env vars are honored independently.) The `--yes` flag is the documented user-facing escape hatch for the Step 1.5b anchor-coverage gate's misaligned-route prompt — when present, the gate skips the `AskUserQuestion` prompt and defaults to the recommended remediation (re-spec). **`--yes` NEVER skips the gate evaluation itself** — per `inside-lore-protocol-silent-skip-is`, only the user-facing prompt is suppressed; the lead still evaluates anchor-vs-plan coverage, still files the gate row, and still respects the legacy-no-anchor branch's logged-skip contract. `--yes` does not affect any other prompt in this skill (the Step 1.2 archived-item confirmation and the Step 2 checksum-mismatch prompt remain interactive). Record `RUN_STARTED_AT` (ISO-8601 now) — Step 7's close consumes it.

2. **Run the start verb — the sole Step 1 envelope.** Do NOT improvise resolution via `ls`, `find`, `lore work show`, or directory listing, and do NOT hand-run the resolver, plan validation, branch cache, claims parsing, or model/template-version resolution it absorbs:

   ```bash
   lore impl start "$INPUT" --json
   ```

   Contract (`scripts/impl-start.sh`): resolves `<ref>` to a canonical slug via the canonical fuzzy resolver (`--branch <name>` influences fuzzy resolution only); validates `plan.md` has a `## Phases` section and ≥1 unchecked `- [ ]`; returns `_meta.json`'s title and `intent_anchor` VERBATIM (the verb computes facts only and never adjudicates the anchor); writes the branch cache — its only write — skipped for archived items and non-fatal on failure; parses prior `task-claims.jsonl` into `prior_claims.by_task` / `by_file` maps; resolves `models` and `template_versions` for lead/worker/advisor (each failure degrades to `""` with a stderr warning).

   Exit codes: `0` start struct printed (single JSON object with `--json`); `1` no match, missing `plan.md` ("No structured plan found. Run `/spec` first…"), or no unchecked tasks ("All plan tasks are already complete.") — report the verb's message and stop, do NOT fall back to broader filesystem inspection; `2` ambiguous reference — disambiguate via `AskUserQuestion` from the candidate list and re-invoke.

   Bind from the struct: `SLUG`, `ITEM_DIR` (`$WORK_DIR/<slug>`, or `$WORK_DIR/_archive/<slug>` when `archived: true`), `INTENT_ANCHOR`, the three models, the three template versions, and the prior-claims maps (these feed Step 3's per-worker Tier 2 extracts via `open`).

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
- **`capabilities`** — the active framework's adapter gates: `completion_enforcement` ∈ `native_blocking | lead_validator | self_attestation | unavailable` (shapes the Step 4 verification fork per `adapters/agents/README.md` §"Completion Enforcement Degradation Modes" — `native_blocking` rejects malformed worker reports synchronously; `lead_validator` requires the post-hoc validator; the rest degrade further) and `team_messaging` ∈ `full | partial | fallback | none` (`none` collapses to lead-inline execution per Step 3.0: no TeamCreate, no worker spawns; the skill is gated to harnesses whose `team_messaging=full` per `adapters/capabilities.json.skills.implement.requires`).
- **`manifest`** — TeamCreate first, then one TaskCreate per eligible task in `tasks.json` order, then TaskUpdate wiring ops whose `add_blocked_by` edges are complete (tasks.json edges within the selection plus collision-serialization edges). Edges pointing outside the selection surface per-task as `external_blocked_by` for the lead to wire against already-created tasks. An empty manifest is success with an explanatory `status`, not an error.
- **`collisions`** — same-file intersections among concurrent selected tasks, already folded into the manifest as serialization edges so the wiring is collision-safe. **Cross-selection collisions are NOT detected:** when dispatching a `--phase`/`--task` subset, the lead accounts for files held by unselected or still-in-flight tasks before spawning.
- **`phase_map`** and **`prior_knowledge`** — per-phase knowledge resolved through the 3-branch gate: a `retrieval_directive` resolves via `resolve-manifest.sh` (authoritative; v2 directives return `### Focal:`/`### Adjacent:` sectioned blocks, legacy flat directives a single section — the dispatcher does not branch on shape); task descriptions embedding `## Prior Knowledge` skip prefetch (the phase already carries resolved knowledge; appending would duplicate or conflict); otherwise the fallback `lore prefetch` runs ONLY when the caller declared `--fallback-scale-set <buckets>` (comma-separated from `abstract|architecture|subsystem|implementation`). Without a declaration the phase returns `status: needs-prefetch` with the suggested query — **scale is the caller's declaration, never a default.** On `needs-prefetch`, declare the bucket per the scale rubric (see `skills/memory/SKILL.md` § Scale-Aware Navigation) and re-run `open` with `--fallback-scale-set` — re-declare with intent, not habit. When the fallback branch ran, log one `Knowledge-delivery-path: lead-fallback-prefetch` line via `write-execution-log.sh` so the delivery gap is visible to /retro.
- **`tier2_extracts`** — per-task prior Tier 2 rows from `task-claims.jsonl`, matched by `task_id` or file-target overlap. These feed each worker's `{{prior_knowledge}}` injection in Step 3.
- **`skill_invocation_map`** — plan `**Related skills:**` entries (non-persistent) merged with `lore ceremony get implement` entries (tagged `source: ceremony`; the verb logs each `Ceremony-injected skill:` row), each with its `skill_template_version`. Per D3 this map is in-memory routing state for Step 4.0 — the lead invokes the skill directly; no agent spawns for these. Forward-compat: if a future ceremony schema returns `{skill, mode: "agent"}`, treat it as persistent-advisor opt-in; today no ceremony entry can request agent-mode.
- **`advisors`** — `mode: persistent` declarations only. Per D1/D2, advisor declarations without `mode: persistent` (e.g. `[must-consult]`, `[on-demand]`) are lead-handled inline on the default route and do NOT spawn advisor agents.
- **`lead_inline_conditions`** — the four gate conditions as SEPARATE fields (`single_task`, `prescriptive`, `no_persistent_advisor`, `no_required_consultation`) plus a `detail` block. Never an aggregate eligibility boolean — the lead reads conditions and decides (Step 3.0).

Exit codes: `0` manifest emitted (possibly empty with explanatory status); `1` validation error / no match / missing tasks.json / checksum mismatch; `2` ambiguous reference.

**The lead executes every harness tool call itself, in manifest order — TeamCreate first.** A CLI verb cannot invoke harness tools; the TeamCreate-first ordering is the orphan-task guard: TaskCreate calls go into whichever task list is active, so tasks created before TeamCreate land in the session's default list — invisible to workers who see the team's list, persisting as orphaned stale tasks for the rest of the session. Walk the manifest top-to-bottom:

1. **TeamCreate** with the manifest's `team_name` and `description="Implementing <work item title>"`. **`team_name` MUST be exactly `impl-<work-item-slug>`** — the slug suffix has to match the work item directory name in `$KDIR/_work/` byte-for-byte. The TaskCompleted hook (`scripts/task-completed-capture-check.sh`) derives the work-item slug by stripping the `impl-` prefix; `lore work check` and Tier 2 evidence reads use the same convention. On opencode/codex the adapter emits `delegate:plugin_team_init` / `delegate:codex_subagent_init`; invoke the documented translation.
2. **TaskCreate** per manifest entry with its `subject`, `activeForm`, `description`, tracking each `local_id` → created-task ID. Per-task descriptions are lean by design — each begins with a `**Phase:** N` line (the authoritative phase-number source) followed only by the task-specific assignment; phase-level context lives in `tasks.json → phases[N-1].phase_context`, fetched lazily by the worker via `lore work phase-context <slug> <phase-number>` after `TaskGet`. The lead does NOT embed phase context into descriptions. (Legacy `tasks.json` without `phase_context` exits 0 with empty stdout there; workers fall back to inline phase context — no regen required.)
3. **TaskUpdate(addBlockedBy=[…])** per wiring op, mapping `local_id`s through the ID map; wire any `external_blocked_by` edges against the matching already-created tasks.

**Read your team lead name** from the active harness's teams install path (resolved via `resolve_harness_install_path teams`; typically `~/.claude/teams/`) at `<teams_dir>/impl-<slug>/config.json`. Frameworks whose `install_paths.teams=unsupported` (codex today) cannot persist team config — the adapter returns a lead-side handle map instead; read the lead name from the map.

### Step 3.0: Lead-inline gate (pre-dispatch short-circuit)

**Read the four condition fields from `open`'s `lead_inline_conditions` and decide the route yourself.** The verb reports conditions as separate fields — never an aggregate boolean — because the route is a judgment, not an arithmetic AND: the `detail` block tells you *why* a condition is false, and the carve-out below turns on that distinction. Worker dispatch's value is parallelism across independent tasks plus discretion-bearing context for intent+constraints work; both vanish when the plan reduces to a single fully-determined edit. The ~22KB context tax per spawn plus TeamCreate + TaskCreate + completion round-trip is then pure overhead.

The gate fires when **all four** conditions hold:

1. **`single_task`** — `tasks.json` contains exactly one task across all phases.
2. **`prescriptive`** — the task's containing phase declares `**Task format:** prescriptive`. Intent+constraints tasks involve worker discretion; lead-inline removes that channel and is unsafe for them.
3. **`no_persistent_advisor`** — no phase declares a `mode: persistent` advisor. Non-persistent advisor declarations are lead-handled inline and do not disqualify.
4. **`no_required_consultation`** — no phase declares `**Consultations required:**` domains, the ceremony list is empty, AND plan.md's `**Related skills:**` block declares no entries. Each signals orchestration that has no inline analogue when no team exists.

   **Lead route with a lead-invoked skill in scope.** When condition 4 is false *only* because `detail.related_skills` is non-empty (and the other three hold), the lead route remains eligible *provided* the lead first invokes each in-scope skill via the `Skill` tool and records the invocation in `execution-log.md` before applying any edits (log line format: `Lead-invoked skill: <skill-name>\nDomain: <domain>\nSkill template-version: <hash>` via `write-execution-log.sh --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"`; the skill's `skill_template_version` is already in `open`'s map). If condition 4 is false because of `**Consultations required:**` or a non-empty ceremony list, fall through to Step 3 worker dispatch.

**No file-count cap.** An earlier version of this gate required ≤3 files. Evidence from the scale-registry-rename cycle (single prescriptive task, 10 verbatim file edits, no discretion) showed the cap was a proxy for "discretion required" that the other conditions already cover better. A 50-file prescriptive rename is still 50 file edits with no discretion; splitting across workers pays N × ~22KB context tax for no shaping gain. `detail.file_count_diagnostic` is logged below as telemetry but does not gate.

**If any condition fails (outside the carve-out):** skip Step 3.0 entirely and proceed to Step 3 (worker dispatch). Do not log a skip — the worker pipeline is the default.

**If all conditions hold:** apply edits inline.

1. **Log the gate firing** — one entry to `execution-log.md` so retro can attribute the route taken:
   ```bash
   printf 'Lead-inline execution: gate fired\nConditions: single task, prescriptive, no persistent advisor, no required pre-edit orchestration\nFile count (diagnostic): %d\nTask: %s\n' \
     "<file-count>" "<task-subject>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug "$SLUG" --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```
2. **Invoke in-scope skills before editing (if any),** per the condition-4 carve-out, logging each as above.
3. **Apply the edits directly** using the lead's `Read` / `Edit` / `Write` / `Bash` tools, honoring the phase's `**Verification:**` objectives. Read the task description the same way a worker would, then execute the prescriptive instructions yourself. **Reviewer-facing comment discipline applies to the lead too** — apply the drop/keep rules, drift test, and worked examples from `agents/worker.md` step 5 to any comments you write into committed source.
4. **Emit Tier 2 evidence** for any falsifiable claims the edits depend on, with `$LEAD_TEMPLATE_VERSION` — the lead is the producer:
   ```bash
   echo '<tier2-row-json>' | bash ~/.lore/scripts/evidence-append.sh --work-item "$SLUG"
   ```
   Every row MUST carry `exact_snippet` and `normalized_snippet_hash`. Compute via the canonical helper — do NOT inline the recipe (`python3 ~/.lore/scripts/snippet_normalize.py --hash <<<"$SNIPPET"`); the v1 normalization recipe lives only in `scripts/snippet_normalize.py`, and `evidence-append.sh` delegates to `validate-tier2.sh`, which rejects rows that omit either field or carry a hash that does not match.
5. **Stash any Tier 3 candidates** for Step 5 (promotion still goes through `promote-batch` with `producer_role: implement-lead`).
6. **Mark the task complete:** `lore work check "$SLUG" "<task-subject>"`.
7. **Skip Steps 3, 4, and the batch-loop shutdown** — no team to shut down. Proceed directly to **Step 5** → **Step 6** → **Step 7**.

**Sanctioned pause:** if the lead is unsure whether the prescriptive task is fully determined enough to execute without discretion, fall through to Step 3. Lead-inline is a short-circuit, not a forced route.

### Step 3: Spawn agents

**You MUST spawn workers immediately once the manifest is executed and worker prompts are assembled.** Do not pause to confirm scope. Do not echo plan-resolved open questions back to the user (the plan already encodes scope guards in task descriptions). Do not surface "this is large" as a decision request. Do not request approval to modify a skill because the skill being modified is the running skill (your prompt is loaded; file edits do not affect the current run). The only sanctioned pre-dispatch pauses: (a) item resolved to archived without confirmation (Step 1.2), (b) `tasks.json` checksum mismatch (Step 2), (c) the `worker` agent template is missing (Resolve Paths' MANDATORY clause), or (d) Step 3.0 fired and execution completed inline. Pausing for any other reason is a faster-path bypass — the cost is borne by the user as session-spanning delay; the lead pays nothing. **Why immediate dispatch matters:** one bad spawn is caught in Step 4 review; pre-dispatch confirmation does not buy safety the system already provides.

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

6. **Spawn worker agents with tier-aware emission instructions** — launch `min(recommended_workers, 4)` workers in a single message (`recommended_workers` is in the `open` struct). Use the `worker` agent template (resolve via `resolve_agent_template worker`) as base, with these injections:

   - `{{team_name}}` → `impl-<slug>`
   - `{{team_lead}}` → the lead name read from team config in Step 2
   - `{{prior_knowledge}}` → `$PRIOR_KNOWLEDGE`, followed by that worker's Tier 2 extract block (blank-line separator)
   - `{{template_version}}` → `$WORKER_TEMPLATE_VERSION`
   - Include each assigned task's `packet_id` (carried on its TaskCreate manifest entry and in `open`'s `packets` field) as a literal `Packet-id: <packet_id>` line in that worker's Task prompt — the post-session packet assessor matches this line to confirm handoff. Omit the line for tasks without a `packet_id`.

   Assign only tasks from `open`'s `initial_unblocked` set. Same-file serialization is already wired into the manifest's blockedBy edges for this selection — never parallel-dispatch same-file tasks across workers; for subset selections, also account for files held by unselected tasks (the cross-selection caveat in Step 2). After claiming (`TaskUpdate(owner=…)`), a worker-side `TaskGet` ownership re-check is the backstop for claim races.
   <!-- Sunset: remove if same-file collision / phantom-completion retro-evolution rows targeting skills/implement/SKILL.md recur from ≥3 new distinct work items within the next 20 implement cycles. -->

   Workers declare `--scale-set` at every `lore prefetch` and `lore search` call. **Scale rubric — declare explicitly at every retrieval surface:** for the four scale definitions (abstract / architecture / subsystem / implementation), boundary tests, multi-label encoding, and the ±1 query pattern, see `skills/memory/SKILL.md` § Scale-Aware Navigation. The full decision tree lives in the canonical `classifier` agent template (resolved via `resolve_agent_template classifier`).

   The worker template documents the tier-aware emission contract. Workers are required to:

   - **During task:** write each structured Tier 2 claim by piping a JSON row through `echo '<json>' | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>` before sending the completion report. One call per claim. `evidence-append.sh` is the sole-writer for `$KDIR/_work/<slug>/task-claims.jsonl`.
   - **Post task:** send a completion report to the lead containing the traditional prose fields (**Task**, **Changes**, **Tests**, **Blockers**, **Surfaced concerns**, **Consultations** — with the `handler: lead|skill|agent` discriminator), a **Tier 2 evidence:** field listing `claim_id` values written during the task, and an optional **Tier 3 candidates:** YAML block (producer_role + 13-field Tier 3 shape minus `confidence`).
   - **Naming standard:** the optional Tier 3 section MUST be labeled exactly **Tier 3 candidates:** — not "Tier 3 claims" or "Tier 3 observations". The TaskCompleted hook validates literal-prefix-match.

   **If `$ADVISORY_MIXIN` is non-empty (opt-in route only):** append the resolved mixin content after the fully resolved worker template content, separated by a blank line. **On the default route `$ADVISORY_MIXIN` is empty** — worker prompts end at the resolved worker template; workers still have the `**Consultations:**` reporting field and `## Consultation` request shape from the worker template's §Reporting Guidelines, so they can SendMessage the lead without the mixin. The lead's Step 4.0 handler answers on the next turn boundary.

   For the spawn block (`WORKER_MODEL` resolution + Task: spawn template), read `skills/implement/templates/worker-spawn.md`.

### Step 4: Collect progress

As worker messages arrive (delivered automatically), branch by message kind:

- **Consultation requests** — bodies whose first line is `## Consultation` and that carry `consultation-id:` route to Step 4.0 below. Mid-task questions; reply immediately so the worker resumes on the next turn boundary.
- **Completion reports** — bodies matching `## Reporting Guidelines` shape from `agents/worker.md` route through §1–§8.
- **Blocker messages** — anything else from a worker requiring intervention falls through to §7.

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

#### Step 4 §1–§8: Completion reports

1. **Run the mechanical report check before accepting the task — every report, no exceptions.** Save the worker's completion report body verbatim to a file (e.g. via `mktemp`), then gather the harness facts the verb cannot read itself and invoke:

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
   - **Convention-handling completeness (non-blocking).** Pass one `--woven-norm <label>` per norm you wove into this task's constraint clauses at dispatch (the stable labels are in the task description, resolved from `/spec`). The verb compares the report's dispositions against that list — missing / duplicated / unrecognized labels and `none in scope`-despite-woven-norms conflicts are surfaced as findings, never as failures. This needs only the woven-norm list — do NOT read the diff. Divergence rationales are listed verbatim; assessing them is §2's judgment, not the verb's.
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

   **On exit 3, the task is rejected — reject it.** SendMessage the report back to the worker naming the verb's `fail_reasons` (missing claim_ids, unsatisfied required domains); do NOT accept; do NOT proceed to §2. **On exit 0, acceptance remains the lead's decision** — mechanical checks alone never accept; weigh the report's substance (tests, blockers, scope) and accept or send back with guidance.

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
   printf 'Task: %s\nChanges: %s\nSkills: %s\nTier2-claims: %s\nObservations: %s\nConvention: %s\nInvestigation: %s\nBlockers: %s\nConsultations: %s\nTest result: %s\n' \
     "<task-subject>" "<worker Changes field>" "<worker Skills used field>" \
     "<comma-separated claim_ids from Tier 2 evidence>" \
     "<worker Observations field or Tier 3 candidates summary>" \
     "<worker Convention handling field + your §2 assessment outcome: clean | followup-opened: <reason>>" \
     "<worker Investigation field>" "<worker Blockers field>" "<worker Consultations field — verbatim YAML list, or 'none'>" \
     "<passed|failed|skipped>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug "$SLUG" --source implement-lead --template-version "$WORKER_TEMPLATE_VERSION"
   ```
   If the worker omitted a field, use `None`.

   **Log discipline:** one execution-log entry per task, written only after that task's worker completion report arrives — never log `pending worker report` placeholders. When a worker reports several tasks in one message, write one entry per task (batched entries lose per-task sequence and starve /retro of evidence).
   <!-- Sunset: remove if execution-log completeness retro-evolution rows targeting skills/implement/SKILL.md change-type evidence-gap recur from ≥3 new distinct work items within the next 20 implement cycles. -->

4. **Set aside Tier 3 candidates for Step 5** — if the worker report contains a `Tier 3 candidates:` YAML block, stash each entry (preserving producer_role and source_artifact_ids) for Step 5. Do NOT promote here — Step 5 is the sole promotion site.

5. **Handle blockers** — if a worker reports blockers: read the relevant code/context; send guidance via the adapter's `send_message` (on Claude Code the native `SendMessage` tool; on harnesses where the adapter returns `unsupported`, fall back to lead-only orchestration — re-spawn with a corrected prompt instead). If unresolvable, note in `notes.md` and move on.

6. **Check off completed items in plan.md** (required before the batch loop reads completion state):
   ```bash
   lore work check "$SLUG" "<task-subject>"
   ```
   `next-batch` reads completion from these checkboxes; Step 7's close reconciles any misses via `--check-task`.

Do NOT gate on reviewing diffs — workers proceed autonomously. The user reviews at the end.

#### Batch loop

When a batch of workers has all reported completion, ask the next-batch verb what is now dispatchable:

```bash
lore impl next-batch "$SLUG" [--active <task-id>]... --json --template-version "$LEAD_TEMPLATE_VERSION"
```

Contract (`scripts/impl-next-batch.sh`) — a prepare-and-return emitter; the LEAD spawns workers. Completion state is read from plan.md checkboxes — the durable record §6 maintains — by matching each tasks.json subject against `- [x]`/`- [ ]` lines; tasks whose subject matches no checkbox return as `unmatched` and count as incomplete blockers (fix the checkbox via `lore work check` and re-run). **The plan checksum is deliberately NOT enforced here** — checking boxes edits plan.md after tasks.json generation by design; the cryptographic gate is `open`'s job alone — do not reintroduce it mid-run. `--active <task-id>` (repeatable) declares tasks the lead has already dispatched and still in flight (live task state is harness-side; the lead passes it in); active tasks are excluded from the batch and count as incomplete blockers. Batch entries carry refreshed per-task Tier 2 extracts (rows workers appended in earlier batches included) and the four lead-inline condition fields. The only write is one execution-log attribution row. Exit codes: `0` batch emitted (possibly empty with explanatory `status`); `1` error / missing tasks.json or plan.md; `2` ambiguous reference.

- **Batch non-empty:** spawn `min(batch_size, max_workers)` fresh workers (same template and injections as Step 3.6, incrementing names as `worker-N`; `max_workers` is the same `min(recommended_workers, 4)` cap), with each worker's refreshed Tier 2 extract. **Same-file collision groups return as conditions, not pre-decided wiring** — those tasks must not be parallel-dispatched across workers; serialize-within-one-worker vs merge-into-one-assignment is the lead's call per group. Repeat the loop.
- **`status: all-blocked`:** every pending task is blocked or in flight — return to collecting reports (§ above) or resolve blockers (§5).
- **`status: all-complete`:** no pending tasks remain. Shut down the team:
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

The system has three distinct closure layers. They operate on disjoint signals; none can override another, and **all three** must produce a permissive outcome for archive to proceed on an anchored item. The close verb runs them in load-bearing order:

1. **Task-system archive precondition** — `REMAINING_COUNT=0` after `--check-task` reconciliation. The verb hard-refuses the close (exit 1, mechanical followup filed, NO verdict recorded, NO closure block written) while any plan.md checkbox remains unchecked — the verdict is recorded only against the final task-complete run, so a stale closure row can never attach to a state the system no longer matches.
2. **Mechanical Followup Creation Gate** — when unchecked tasks or non-`none` `Blockers:` entries in `execution-log.md` exist, the verb files a `Deferred work:` followup in `_followups/`. **Non-blocking observability** for the review loop: its firing is not proof of archive-unclear, its silence not proof of archive-clear. [[knowledge:principles/workflow-design/workflow-theater-anti-pattern-in-skill-design-steps-that|Workflow-theater guard:]] this layer surfaces *mechanical* residue only — it does NOT consult `intent_anchor`, and collapsing it into the verdict recreates the closure-laundering gap by either reading the verdict off mechanical signals or laundering blockers as anchor compliance.
3. **Anchor verdict** — the lead's semantic capability assertion against `intent_anchor`. Only `full` permits archive; `partial` and `none` are non-completions that hold the parent open as `capability-incomplete` through the same loud, non-zero close.

**Decide the verdict — the lead's discretion-bearing read of what actually shipped.** Read the `intent_anchor` verbatim, then `notes.md`, `execution-log.md`, the run's worker reports, and any blocker context. Use the closure-laundering vocabulary verbatim (load-bearing step, mocked, deferred):

- **`full`** — the run delivers the load-bearing capability the anchor names. Write a one-line `capability_loop_summary` naming the user-facing loop now operable. Archive proceeds.
- **`partial`** — at least one load-bearing step the anchor depends on is mocked or deferred. A **non-completion**: the parent is NOT archived — it stays active as `capability-incomplete`. Write a `capability_loop_summary` that *names what shipped*, a one-line `divergence_summary` naming what was mocked or deferred, and a residue title + residue intent anchor for the deferred capability. The residue anchor must obey the [[knowledge:conventions/protocol/work-item-intake-should-store-neutral-intent-ancho|intake neutrality rule]] — describe the residue capability in neutral terms; do not smuggle the parent's framing or solution into the child.
- **`none`** — the run does not deliver the capability. Also a **non-completion**: the parent stays active as `capability-incomplete`. Write a `capability_loop_summary` naming what was attempted and a `divergence_summary` naming that no load-bearing capability was delivered. No residue child; `none` is anchor non-delivery routed through the same loud channel as `partial`, not a separate concept.

Ask via `AskUserQuestion` only if the lead cannot ground the call in the run's evidence; if the run record is unambiguous (all tasks checked off, no blockers, load-bearing steps all have direct artifact evidence), the lead decides and reports rather than prompting.

The closure block the verb writes against this verdict is the fixed contract (declarative — for reading, never for hand-writing):

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

**Lazy audit note:** per §9.2 Step 8, the Stop hook lazily triggers audit of this session's promotions; `/implement` does not invoke the audit explicitly. Completion of `/implement` is non-blocking — the audit runs opportunistically after session end.

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
   - **Partial residue child BEFORE parent closure:** on `partial`, create the child work item (with the residue title/anchor and `--related-work` back-link) and capture its slug; if creation fails, the parent closure block is NOT written and the parent is NOT archived — diagnose and re-run.
   - **Closure block write** on `_meta.json` (the one write owned here; legacy items get none), plus the `partial` notes.md cross-link naming the child slug.
   - **`retro-bundle.json` snapshot** — the nine-field producer bundle `/retro` reads (`work_item`, `tasks_completed`, `tier2_claim_ids`, `tier3_promoted_ids`, `advisor_consultations_count`, `blockers`, `template_versions`, `captured_at_sha`, `run_started_at`). Overwrite-per-run snapshot semantics; producer-only — canonical artifacts (`task-claims.jsonl`, `execution-log.md`, `notes.md`) remain historical truth and `/retro` falls back to them if the bundle is missing or malformed.
   - **One execution-log closure entry** (source: impl-verb).
   - **Closure-validity gate, then archive-before-report:** legacy/`full` → archive via `archive-work.sh` and verify the move (item present in `_archive/`, absent from active `_work/` — FATAL on either failure); `partial`/`none` → hold the parent open as `capability-incomplete` (verifying it IS still active); a missing/malformed closure block → refuse without archiving. Archive is committed before the terminal report renders — prior versions of this skill placed archive earlier and observed it silently skipped roughly half the time once the report's clean-handoff feel landed; the verb removes that gap structurally.
   - **One `kind=telemetry` scorecard row per close** (`metric: impl_close_bookkeeping` via `scorecard-append.sh`): closure verdict plus counts of verb-mediated (`source: impl-verb`) vs hand-run execution-log entries. Observability-only — never `kind=scored`, never /evolve-cited; a failed append warns and the close continues.
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
