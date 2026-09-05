---
name: spec
description: "Create a technical specification — `/spec short` for single-pass plans, `/spec` for full team-based investigation"
user_invocable: true
argument_description: "[short] [--yes] [--model <id>] [name or description] — existing work item name, or a freeform description to start from. `--model` overrides every per-role binding (lead/researcher/advisor) for this invocation only; otherwise per-role models come from `resolve_model_for_role`."
---

# /spec Skill

Produces a `plan.md` inside a work item's `_work/<slug>/` directory.

## Short Flow (`/spec short`)

Single-agent path: the spec-lead reads key files directly (Step 2 `--short` branch) and drafts the plan without dispatching a researcher team. Single-context work is the sanctioned norm, not a degraded mode — one context that reads the code itself serves most specs well.

The `--short` conditional activates at Step 2 only. From Step 3 onward, short and full paths share every step: collect findings and emit Tier-2 artifacts, strategy gate, synthesis, design ceremony, task review, post-research extraction, post-plan ceremony, and terminal finalization.

## Full Flow (`/spec`)

Team-based divide-and-conquer: the spec-lead composes an investigation plan table (Step 2 full branch), dispatches parallel researcher agents, collects findings, emits Tier-2 artifacts, and then synthesizes — following the shared downstream steps. Team ceremony engages where scale demands it: investigation breadth one context cannot hold, or unknowns that genuinely parallelize.

> **Sequencing constraint:** Do not dispatch research agents before completing Step 2. The investigation plan is a completeness checklist and user approval gate, not just a dispatch list.

## Judgment boundary

The verbs prepare evidence and persist decisions; they do not make them. Keep these kernels in lead prose: investigation questions, complexity labels, strict/permissive applicability, synthesis, contradiction decisions, task decomposition, evaluator normalization, whether feedback changes the plan, and every harness-native dispatch or teardown call. If a verb appears able to infer one of these, stop at the boundary and supply the missing judgment explicitly.

---

### Step 1: Parse and resolve (both modes)

1. Parse arguments:
   - Set `TRACK=short` when the first arg after `/spec` is `short`; otherwise set `TRACK=full`. The investigation step (Step 2) follows that declared track.
   - If `--yes` is present, skip all interactive confirmation gates (auto-proceed through investigation plan confirmation, strategy gate, confirm understanding, and task review).
   - If `--model <id>` is present, set `MODEL_OVERRIDE=<id>` and export the per-role overrides for this invocation: `export LORE_MODEL_LEAD=<id> LORE_MODEL_RESEARCHER=<id> LORE_MODEL_ADVISOR=<id>`. Otherwise leave `MODEL_OVERRIDE` empty and let ceremony-scoped role resolution choose each model. An explicit flag without a value is an error, not a request for the configured default.
   - The remaining text is the **input**.

2. Resolve the knowledge path and standing defaults:
   ```bash
   lore resolve
   lore defaults
   ```
   Set `KNOWLEDGE_DIR` to the first result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`. The second renders the standing defaults in force (settings-derived role/model maps, ceremony registrations, sampling rates, preference directives cited by title); treat its output as binding for this run.

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

   The BM25 strata key on a single query seed — the work-item title, unless repeatable `--seed <token>` flags replace it (tokens join into one query; the wholesale tree scans are seed-insensitive and enumerate everything regardless). The seed is the only query-driven input, which is what lets `/implement`'s close re-run this same enumerator with seeds derived from the shipped diff: the two passes miss independently, and a norm the title-seeded pass ranks below the cutoff gets a second chance at close. A descriptive work-item title is what makes the spec-time half of that pair earn its keep.

7. Apply the two discovery judgments yourself:

   - **External skills and agents — strict.** Read plausible external candidates and include only those whose stated domain materially contributes to this implementation. Lore protocol skills remain toolchain, not advisors. Emit `**External skill discovery:**` with the considered set and the matched set; `Matched: none` is valid.
   - **Preferences and conventions — permissive.** Read the surfaced candidates and retain any entry the work might need to honor. Missing a binding preference is worse than carrying an inapplicable candidate into synthesis. Emit `**Preference and convention discovery:**` with coverage counts and the surfaced backlinks; `Surfaced: none` is valid.

   Candidate enumeration is hands work; strict/permissive applicability is head work. Do not ask the verb to collapse that boundary.

8. Present a context summary and offer the strategy gate (Step 4 below). **If `--yes`, skip the strategy prompt.**

### Step 2b: Full branch (default, no `--short` flag)

1. From the feature description, identify 3-7 focused investigation questions. Each should target a specific codebase concern, be answerable by exploring files, and be independent enough to run in parallel.
2. Always include two mandatory fixed investigations (both count toward the 3-7 total): a. External skill and agent applicability (strict)... b. Preferences and conventions applicability (permissive)...

   a. **External skill and agent applicability (strict)** — which installed *external* (non-lore) skills and agent templates should be invoked during **implementation** of this work item. Lore-managed skills (`/spec`, `/implement`, `/work`, `/memory`, `/remember`, `/retro`, `/evolve`, `/renormalize`, `/bootstrap`, `/pr-*`, `/codex-*`) are **excluded** — protocol toolchain, not advisors. The researcher filters them out before reporting matches. Key files: `<skills_dir>/*/SKILL.md`, `<agents_dir>/*.md` (resolve via `resolve_harness_install_path skills` / `resolve_harness_install_path agents`); exclusion list comes from the canonical Lore source repo (`source ~/.lore/scripts/lib.sh && printf '%s\n' "$LORE_REPO_DIR"` + `/skills/` and `/agents/`). Do not use `resolve-repo.sh` here — it returns the project's knowledge store, not the Lore source tree. Match criterion is **strict** — include only skills whose stated domain plausibly contributes to *this* work item's implementation.

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

   Each investigation is dispatched to the compiled investigator brief (`agents/positions/investigator.md`, compiled for its target framework) unless the document says otherwise. Two optional declarations change that:

   - `"template": "researcher"` at the document root selects the legacy researcher template (`agents/researcher.md`) for the whole wave. It exists so a wave can be reproduced with the inputs an earlier wave used; the payload then carries `template_path` and `template_version` and no compiled producer. A document naming any other template is refused, because no other legacy template answers investigation questions.
   - A per-investigation `dispatch` object with exactly `framework`, `route`, `model`, and `bindings`. Omit it and `open` supplies the defaults: the researcher role's model binding for the active framework (a `--model` pin from Step 1 already reaches it through `LORE_MODEL_RESEARCHER`), a native route, and freshly minted identities. Declare it when an investigation has to run on another framework or a chosen model. `framework` is `codex`, `claude-code`, or `opencode`; `route` is `native` or `session`; `model` is the already-resolved native binding for that framework, checked through the same route resolver the default uses, so a model string that belongs to a different framework refuses instead of being reinterpreted. `bindings` is the complete binder envelope. When you supply it, its `assignment` must encode exactly this investigation's `investigation_id`, `question`, and `complexity`; its `work_item` must be this slug; and its `report_path` must be the coordinate-report destination `worker-reports/<report_id>.md`, because that writer is the only one that lands reports. Its `execution_root` has two admitted shapes. A path names a fixed placement: the checkout is known now, `open` publishes against it, and the host later requires that exact directory. On `"route": "session"` it may instead be `null` with a nonempty `absence_reasons.execution_root`, for the ordinary case where the session host allocates the worktree the investigator will read; `open` then admits the preparation and leaves publication to the host, because the root is part of the frozen payload identity and a root guessed now would have to be refused at launch. Do not put the lead's own working directory in place of a root that is not yet known. Its `packet_id` and `packet_pointer` name a packet that already exists for this work item with the investigator as recipient (`lore packet build --work-item <slug> --role investigator --caller spec-lead --topic "<query>" --scale-set <buckets>` builds one before a plan exists), because the binder checks supplied bindings against the canonical packet rather than building one for them. Supplying bindings is how a retry names fresh attempt and report identities, and how a session on an ordinary host is declared; a first native dispatch normally leaves them to `open`. The legacy template path accepts no `dispatch` object.

   Two route facts are declared here rather than discovered at launch. A native route on a framework other than the active one is supported only toward `codex`, where it becomes the chaperone route in item 10. Native subagent selection on `opencode` is unavailable under its current plugin, so an `opencode` investigation is declared `"route": "session"`; a native declaration there makes `open` refuse the wave before publication with the adapter's diagnostic. The route written into the manifest is the record of the choice, and nothing downstream substitutes another.

9. Open the reusable dispatch artifact from the checkout the investigators should read — `open` records its working directory as the execution root against which their snippets and line ranges are later checked:

   ```bash
   DISPATCH=$(lore spec open "$SLUG" --investigations "$INVESTIGATIONS_JSON" --json)
   ```

   `open` returns `created | reused | recovered | replaced`, or refuses with the repair target. Its canonical `spec-dispatch.json` carries `input_fingerprint`, `source_fingerprint`, the source manifest, ordered directives, empty lead-side handle slots, and teardown payloads. It never calls a harness tool and never persists live handles.

   `open` also renders and validates `lore dispatch guidance` before publication or deterministic replay. A rendering failure refuses the whole dispatch wave before any investigator launches, and replay is eligible only while the stable guidance identity remains current. Each directive carries the admitted block in `payload.dispatch_guidance`, with that identity in the source fingerprint.

   On the compiled path `open` does the binding work before it publishes, one investigation at a time: it builds a canonical packet from the investigation's prefetch (session-scoped, with no revision, because no plan exists yet; the dispatch attempt is recorded on the manifest, not on the packet), mints a dispatch attempt and a report id, and freezes one immutable payload under `position-dispatch/<attempt-id>/` through the sole binder. The one exception is a declared session whose `execution_root` is `null`: `open` validates the same compilation, bindings, packet, and wrapper text and stops short of publishing, since a payload cannot be frozen without the directory it names. `payload.publication_state` records which happened, `prepared` or `pending-execution-root`. The directive's `payload` is the complete record of what the investigator receives and how the attempt is identified, with the fields a pending directive cannot yet have set to `null` rather than filled in:

   - `prompt` — the exact frozen bytes: the admitted guidance, the packet pointer, the `Packet-id:` / `Report-id:` / `Dispatch-attempt-id:` lines (and `Revision-id:` only when a revision is bound), the compiled body on prompt-text frameworks, the JSON identity envelope, and the collector's note. Send these bytes unchanged; the digest recorded for them is what a later reader checks. `null` while pending: the bytes do not exist until the host publishes them.
   - `position_dispatch` — the six-field reference the binder returned (`manifest_path`, `manifest_sha256`, `payload_path`, `payload_sha256`, `native_path`, `native_sha256`). Hold it in memory per directive. The payload carries the manifest path but cannot carry the manifest's own digest, so this returned digest is the collector's independent copy: the report's `Position-dispatch-sha256` header is checked against it and never read from it. `null` while pending; the collector obtains the same six fields after host publication (Step 3 item 4) and holds them in this place.
   - `producer` — the compiled investigator's `template_id` and `template_version`. Hold the version as `$PRODUCER_TEMPLATE_VERSION` for that directive; it is what the investigator stamps into `Template-version:` and what every capture or log line the collector writes on that report's behalf carries. The legacy path carries `template_path` and `template_version` instead. `source_manifest.researcher_template_version` records the legacy template's version on both paths for readers of the wave record; it is not the producer of a compiled report.
   - `route`, `framework`, `model` — the resolved route (`native`, `session`, or `codex-chaperone` when a native request crossed to Codex), the target framework, and the exact model to pass. Resolve none of these a second time after publication: the payload bytes were frozen against them, and a re-resolution that disagreed would make the executed dispatch differ from the artifact being replayed.
   - `native_selection` — on native routes, the adapter's frozen selection: the native tool name, the fields it takes beside the prompt, which field carries the prompt, any registration file, and the readiness observation owed before selecting. `null` on session and chaperone routes.
   - `completion_input` — `position_dispatch` plus `lore_task_id` (`null` before a plan exists). This is the object Step 3 hands to the completion check; it is assigned here so that no value in it ever comes from the report. `null` while pending; the reference command in Step 3 item 4 returns the same object once the host has published, computed from the published bundle and never from the report.
   - `session_context` — the object `lore session request --context` reads, in one of two shapes. On a `prepared` session it is `dispatch_guidance` (the same frozen prompt) and `position_dispatch`. On a pending one it is a single `position_preparation` object: the position, framework, packet id, full bindings, compiler descriptor, the admitted guidance text, a retained `activation` snapshot of the native launch inputs, a `composition` holding the wrapper identity, its retained source text, and the exact prefix and suffix bytes, and a `slug` left `null`, so the request's `--slug` supplies the session identity and has to name this work item. The composition is retained text, not an instruction to reread `spec-open.sh` at launch, so the host publishes what `open` admitted even when that script has changed since. The activation snapshot is read differently at the two later points: at launch the host renders the activation again and refuses a rendering that disagrees with the snapshot, since a drifted renderer would launch something other than what was admitted; at collection `session-reference` compares the snapshot to the published `launch.json` without rendering anything, so a renderer that has moved by then cannot change what the reference says. Write this object to a file and keep the file; the collector reads the final reference through it in Step 3.
   - `bindings` — the validated envelope, including `absence_reasons` naming why `task_id` and `revision_id` are null on a pre-plan investigation and, on a pending session, why `execution_root` is. Absence with a reason is a legible state; do not fill it in.
   - `wrapper_template_version` — a 12-hex digest of the `spec-open.sh` bytes that composed the wave, recorded apart from `lead_template_version` (this skill's version) and from `producer.template_version`, so each of the three texts stays attributable on its own.

   `directive.adapter` names the target framework's adapter script, which differs from the active framework's when a `dispatch.framework` was declared.

10. Execute the returned directives in ordinal order. This is the harness-dispatch judgment kernel: `open` prepared each launch and recorded its identity; deciding when to launch, making the native call, and holding the returned handles in the lead's in-memory handle map are yours. Store handles only there, populate the matching teardown payload with the live handle at shutdown time, and do not write handles back into `spec-dispatch.json`.

    The bytes an investigator receives are `payload.prompt`, exactly. On the compiled path the guidance floor is already the first component of those bytes, admitted when `open` ran, so nothing is rerendered or prepended at launch; a launch that edits, re-renders, or supplements the prompt breaks the digest a later reader checks against `payload_sha256`. On the legacy path (`template: researcher`) the payload is assembled here instead: `payload.dispatch_guidance` verbatim, then the researcher template at `payload.template_path`, then the question and `prior_knowledge`. A missing block or a failed adapter admission ends before the native spawn on either path.

    Route by `payload.route` and `payload.framework`:

    - **Native, Claude Code** (`native_selection.tool` is `Agent`). The compiled definition has to exist under a name the running session's agent inventory offers before it can be selected, and the binder owns that file. Register it, then prepare the call:

      ```bash
      python3 ~/.lore/scripts/position-bind.py register-native "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
      python3 ~/.lore/scripts/position-bind.py native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
      ```

      `$AGENTS_SCOPE` is an absolute, physically resolved `.claude/agents` directory the running session already watches (the project's or the user's). The registration file is named by the selection name — `lore-position-` plus a digest over the compiled definition, the attempt, and the model — so two models on one compiled version register under two names and an identical retry finds its identical file. `native-input` returns `tool`, `tool_input` (`subagent_type`, `model`, and `prompt` filled with the exact payload), and `readiness: {kind: native-agent-inventory, selection_name}`. Before the call, check that `selection_name` is among the `subagent_type` values the live `Agent` tool offers. A file on disk is not that check: a shell cannot see which directories the session watched at startup or whether a higher-precedence definition shadows the name, and a definition written into a directory the session never watched is not loaded. When the name is absent, the directive stays undispatched and the wave's record names the readiness boundary; selecting a generic agent type instead would attribute the report to text the investigator never read. Then call `Agent` with `subagent_type`, `model`, and `prompt` from `tool_input`, plus the tool's own required `description` and whatever team, name, or background fields the live schema asks for. Do not rename `prompt`, drop `model`, alter the prompt bytes, or add a parameter for the manifest digest; the child reads the manifest path from its payload and computes the digest itself.

    - **Native, Codex** (`native_selection.tool` is `spawn_agent`). Run `native-input` without `--scope`; nothing is registered, because Codex consumes prepared text directly. `tool_input` carries the split model and effort keys plus `message` filled with the exact payload, and `readiness` is `{kind: native-tool-schema, tool: spawn_agent}`: the check owed is that the tool exposed in your session accepts those fields. Supplement only the caller fields the live schema requires — a `task_name`, non-inheriting fork settings — and pass everything else as returned. A model or effort value the tool rejects is reported as rejected, not dropped.

    - **Native, OpenCode.** Not reachable here: `open` refuses the wave before publication because the adapter has no native selection under the current plugin. Declare `"route": "session"` for the OpenCode investigation and open the wave again.

    - **Chaperone** (`route` is `codex-chaperone`, set when a native request named `codex` from a different active framework). Dispatch through the existing Codex chaperone route: the chaperone receives `payload.model` through the adapter's model splitting and `payload.prompt` as the exact Codex prompt, and it relays what Codex returned. Tell it the return shape is the investigator report — Question, Findings, Key files, Implications, Assertions, Observations, Worker leads, Unknowns — so it relays the body verbatim rather than gating it on worker labels. A relay reshaped into worker fields would replace the finding with a claim the investigator never made.

    - **Session** (`route` is `session`). Write `payload.session_context` to a file, keep the file, and enqueue with `payload.model` and `payload.framework` named explicitly:

      ```bash
      lore session request --type worker --slug "<slug>--w<n>" --anywhere --context "$CONTEXT_FILE" \
        --model "$MODEL" --framework "$FRAMEWORK" [--worktree-id <id> --execution-dir <path>]
      ```

      The same command serves both publication states, and the worktree flags follow the state. A `prepared` context carries a published reference whose payload was frozen against `bindings.execution_root`, so a manager that holds that fixed placement passes the pair of worktree flags with that exact directory; the host revalidates the reference against the directory it actually launches in and refuses any other, because a payload cannot be re-rooted once its digest is recorded. A `pending-execution-root` context is enqueued with no worktree flags: the request admits the preparation and refuses an `--execution-dir`, since the root is the host's to supply. Either way the slugged request derives its required project directory from the work item's declared source checkout, which fixes which instance may claim the row and not the directory the child runs in. `--anywhere` is the placement stance: the request refuses to enqueue without exactly one explicit stance, checked before it derives anything from the slug, because an unstated stance used to mean silently unplaced. The stance is a claim-side declaration and is separate from the worktree pair, which describes the child's directory; and the derived required project directory is the stronger axis and still governs the claim, so `--anywhere` on a slugged request does not widen where the session may run. Do not add `--position`: the context is already admitted position preparation or a published reference, and `--position` would read it as new generic bindings, which carry no spec wrapper, prefix, or collector's note and would drop that text and its attribution. A pre-plan investigator session is admitted with `task_id` and `revision_id` explicitly absent, because the position-aware requirements ask an investigator session for a packet id and pointer, not a plan task. At launch the host calls the same sole binder: on a pending context it publishes the admitted compilation, bindings, and retained wrapper text against the worktree it allocated, and on a prepared one it verifies the reference and the exact root; a publication or activation failure there returns an error before the process spawns, and the diagnostic is what to read, not a reason to pick another route. Publication records prepared input and nothing more; whether the process launched, and whether a report comes back, are read from the session's own lifecycle and from Step 3.

    `team_messaging != full` removes only shared team state. Codex still executes investigator fanout while `subagents=partial`, then its adapter teardown resolves to lead-mediated `TaskUpdate status=completed`. Collapse to the short branch only when `subagents=none`. On a full team-messaging harness, the lead may create the shared team before executing spawn directives and tear it down after investigator completion.

---

### Step 3: Collect findings and emit Tier-2 artifacts

As investigator reports arrive (or after direct file reading in short branch):

1. Write each finding to the `## Investigations` section of `plan.md` using the investigation entry format from the Plan.md Template below.
2. **Preserve `**Findings:**` verbatim** — copy findings exactly as reported. When Findings say the question's premise did not hold, that sentence is the finding: it goes in as written and shapes synthesis, and re-asking the question in narrower words would replace the finding with the answer the plan expected.
3. **Preserve `**Observations:**` verbatim** — copy investigator observations exactly as reported. Do not rephrase, merge, or summarize. These are mechanism-level patterns, design rationale, and structural footprint signals that feed the Step 5.4 capture step. `None` is a complete value on the compiled path; there is no observation count to reach.
4. **Land the report before anything reads it** (full branch, compiled path). The report is evidence of record only as the file the sole writer lands at the destination assigned at dispatch; the message, tool result, or transcript that carried it is transport. Land it verbatim, under the report id from the directive's bindings:

   ```bash
   printf '%s' "$REPORT_BODY" | lore coordinate report <slug> --report-id "$REPORT_ID"
   ```

   The writer is write-once — an existing path refuses — so a retry never overwrites the report that came back. It validates destination and bytes, not shape, so an investigator-shaped body lands through it exactly as a worker report does. A report whose headers turn out not to match this attempt is landed first all the same; it is the record of what came back, and the mismatch is caught in step 6.

   On a directive that `open` left `pending-execution-root`, the lead holds no reference yet: the host publishes the payload at launch. Read that publication independently, from the context file retained at enqueue:

   ```bash
   python3 ~/.lore/scripts/position-bind.py session-reference --kdir "$KNOWLEDGE_DIR" < "$CONTEXT_FILE"
   ```

   It exits nonzero whenever it cannot return a validated reference, and its diagnostic says which situation that is: no manifest exists yet for the attempt, which is what an unlaunched or refused session looks like from here, or a bundle exists and fails a check, which a store made inaccessible or a bundle damaged after a real launch also produces. Nonzero therefore establishes that the collector holds no independent reference, and nothing about whether the session launched; launch and error state are read from the session's own lifecycle, not inferred from this exit. On success it returns `reference` (the same six manifest, payload, and native fields a prepared directive carries), `completion_input`, the actual `bindings` including the host's root, `producer`, `publication_state: prepared`, and `delivery_proven: false`. Hold `reference` and `completion_input` for the directive in the places `open` left `null`. The command checks the published bundle against the admitted preparation (bindings, descriptor, guidance, wrapper text, reconstructed payload, packet, physical root, and the published `launch.json` against the retained activation snapshot rather than a fresh rendering, so a renderer that has moved since admission cannot change what the reference says) and reads nothing from the report. A report that arrives while the command still exits nonzero is landed all the same, as the record of what came back, and the investigation stays unaccepted with the command's diagnostic and the lifecycle evidence recorded beside it: without a validated reference there is nothing to check the report's headers against, so the identity check below cannot pass, and the read that failed does not say what history produced the report. Repair what the diagnostic names when it is repairable, such as an inaccessible store, and run the command again; where it is not, the directive is retried under fresh identities as below. `delivery_proven: false` is literal: the reference establishes what was prepared, and only the landed report and the completion check say what came back.

   Then check the report's identity against what the lead holds, not against the report: `Template-version` equals `$PRODUCER_TEMPLATE_VERSION`, and `Position-dispatch-manifest` / `Position-dispatch-sha256` equal the retained `position_dispatch.manifest_path` and `manifest_sha256`. The child computed its digest by reading the manifest its payload named; the lead's copy came back from the binder at publication, or from `session-reference` reading that publication. Agreement means the report answers this attempt. Disagreement means it answers some other input, and the directive is retried under fresh attempt and report identities (Step 2b item 8, explicit `dispatch.bindings`).

5. **Emit Tier-2 artifacts** — for each investigator assertion (full branch) or lead-observed task-scoped grounding claim (short branch):
   - Format the claim as a JSON row with the evidence fields (`claim`, `file`, `line_range`, `exact_snippet`, `normalized_snippet_hash`, `falsifier`, `significance`) plus producer/template provenance and `change_context` (`diff_ref`, `changed_files[]`, `summary`). `changed_files[]` must include the row's `file`; `summary` should name why the current investigation/change made the claim relevant. `exact_snippet` and `normalized_snippet_hash` are REQUIRED for every row: `exact_snippet` is the verbatim content at `file:line_range` that grounds the claim, and `normalized_snippet_hash` is the sha256 hex of the v1-normalized snippet. Compute the hash via the canonical helper — do NOT inline the recipe:
     ```bash
     python3 ~/.lore/scripts/snippet_normalize.py --hash <<<"$SNIPPET"
     ```
     The v1 normalization recipe (curly→straight quotes, `\s+`→single space, trim, sha256 lowercase hex) lives only in `scripts/snippet_normalize.py`. See `architecture/artifacts/tier2-evidence-schema.md` for the full schema.
   - Producer vocabulary at this writer is legacy: `producer_role` is `researcher` for an investigator's assertion, because the validator's accepted set was not widened when the position was named, and `template_version` is `$PRODUCER_TEMPLATE_VERSION`. `task_id` follows the directive's bindings, not the prose around them. When the bindings bind `task_id` (together with `revision_id`; the completion check requires both bound or both absent), the row carries that task id, because the check matches a bound assertion to its canonical row by task id and finds no row filed under the investigation label. Before a plan exists the row has no plan task, so `task_id` carries the collector's own vocabulary — the investigation id, or the native task id on a route that created one. In both cases the row also carries `report_id` and `dispatch_attempt_id` from the directive's bindings; on a pre-plan attempt those two members are what lets the completion check in step 6 match a grounded assertion to this attempt rather than to an identical assertion from an earlier one. The row also carries the attempt's manifest pair, as one optional object copied from the reference the lead holds and never from the report: `"position_dispatch": {"manifest_path": <retained manifest_path>, "manifest_sha256": <retained manifest_sha256>}`. The writer resolves it against the immutable manifest and checks that the manifest binds this work item and the row's `report_id` and `dispatch_attempt_id`, plus the plan task when one is bound; a pre-plan manifest binds no task, so the investigation label on the row is not compared to it. A pair that does not resolve stores the row with unknown attribution and its reason, and nothing fills that in from the researcher template on disk; a row without the pair is a legacy row and reads as before. The shape and the copy rule are in `docs/position-report-contracts.md` § The dispatch reference on Tier 2 rows.
   - An investigator may have appended some of its own assertions, under the same `researcher` vocabulary and carrying the same pair, copied from its envelope's `manifest_path` and the digest it computed for its headers; each such assertion lists its `claim_id` in the report. Append only the assertions that carry no `claim_id`, so no canonical row is written twice for one claim.
   - Append the row via the sole-writer:
     ```bash
     echo '<json-row>' | bash ~/.lore/scripts/evidence-append.sh --work-item <slug>
     ```
     `evidence-append.sh` is the sole writer of `$KDIR/_work/<slug>/task-claims.jsonl`; it rejects missing snippets and invalid or mismatched normalized hashes. On rejection, fix and retry the row or log the failure to `execution-log.md`. Never write the JSONL directly — direct writes bypass validation and are treated as corrupt. A rejected row leaves no canonical row, and the completion check below then reports that assertion as ungrounded; the failure surfaces where it can be read, which is the reason not to type a row around it.
   - After successful append, write a human-readable mirror entry to `$KDIR/_work/<slug>/evidence.md`. Do not write a mirror entry for a row that failed validation.
   - **Absence semantics:** if no assertions or lead-observed task claims exist, both `task-claims.jsonl` and `evidence.md` may be absent — absence means "no Tier-2 claims captured this session," not "work was fully verified." An investigator report with `None` under Assertions creates no row and no mirror.

6. **Run the typed completion check** (full branch, compiled path), after the report is landed and its assertions are canonical:

   ```bash
   printf '%s' "$COMPLETION_INPUT_JSON" | bash ~/.lore/scripts/task-completed-capture-check.sh
   ```

   `$COMPLETION_INPUT_JSON` is the directive's `payload.completion_input`, or, on a directive that was pending at `open`, the `completion_input` that `session-reference` returned in item 4: the retained `position_dispatch` reference and `lore_task_id` (`null` before a plan). Either way it was computed from the published bundle, and no member of it came from the report. Exit 0 means the landed report carries the assigned identity headers, every label the investigator contract requires, and grounded assertions that each match one canonical row for this attempt. Exit 2 names on stderr what did not hold. The check reads the report at the destination the manifest assigned, which is why landing comes first. It is invoked explicitly on every spec route because no spec route completes through a native `TaskCompleted` hook: a Claude `Agent` subagent returns rather than completing a team task, Codex and OpenCode have no blocking hook, and a session ends on its own lifecycle. A pass establishes checkable references. Whether the findings answer the question well enough to synthesize from stays the lead's judgment, and nothing here accepts the investigation on the lead's behalf.

7. **Route the rest of the report to its readers.**
   - `**Worker leads:**` reaches the off-scale writer through the execution log. Append one entry per report whose body carries the `Worker leads:` line and its bullets verbatim, stamped with the producer's version as `--template-version`, your own as `--filing-template-version`, and the attempt's manifest pair from the reference you hold; `write-execution-log.sh` resolves the pair, writes `Producer-attribution:` beside the two `Position-dispatch-*` lines, and forwards a non-`None` payload to `off-scale-append.sh` under the `researcher` producer role and the producer's resolved version.
     ```bash
     printf 'Investigation: %s\nReport-id: %s\nWorker leads: %s\n' "<investigation-id>" "$REPORT_ID" "<value verbatim>" \
       | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source spec-lead \
           --template-version "$PRODUCER_TEMPLATE_VERSION" \
           --filing-template-version "$LEAD_TEMPLATE_VERSION" \
           --position-dispatch-manifest "<retained manifest_path>" \
           --position-dispatch-sha256 "<retained manifest_sha256>"
     ```
     The two pair flags travel together or not at all, and a reference that does not resolve reads `unknown` rather than borrowing any template's version. On the legacy path (`template: researcher`) there is no pair; pass the researcher template's version as `--template-version` and drop the two flags. `None` produces no sidecar row and is the ordinary case.
   - `**Unknowns:**` are read by whoever plans next. Carry them into Step 5b's Open Questions, or into a follow-up manifest at Step 6 when they gate a design decision.
   - A packet entry the investigator corrected or disputed already has its event in the trust ledger through `lore verify`; the collector does not re-verify it. When a correction changes the ground a still-running sibling investigation stands on, relay it now through the messaging the route offers (a message to the sibling on a team-messaging harness). Where the route has none, it travels in the landed report and reaches the sibling's question at synthesis — later, but not lost.

8. **Full branch only:** When all investigations are complete:
   - Execute each directive's teardown payload with its in-memory handle where the route left one. A Claude `Agent` subagent returned with its report and holds no handle; on Codex the live adapter returns the lead-mediated `TaskUpdate task_id=<handle> status=completed` directive; a session closes through its own lifecycle. Do not infer teardown from `team_messaging`: the prepared payload and current adapter are the contract.
   - Run `TeamDelete` (Claude Code only, and only when a shared team was created; opencode/codex adapters require no explicit teardown — runtime owns lifecycle).

9. Append an investigation summary to `execution-log.md`. This entry is the lead's, so it carries the lead's version; the per-report producer versions were recorded in step 7:
   ```bash
   printf 'Investigations: %d\nTopics: %s\n' \
     "<N>" "<comma-separated investigation topics>" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source spec-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

10. **Journal the investigation milestone.** The findings, Tier-2 rows, and investigation summary are all durable at this point, so a hosted session emits one `step_completed` row for the parent spec session — individual investigator reports and Tier-2 appends never emit steps:
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

Produce the conceptual frame first before committing to a task breakdown.

Synthesis organizes the itemized findings; it does not narrate over them. Keep each finding's provenance intact and cite items rather than restating them in looser words — prose that absorbs the itemized record is where evidence quietly drops out. The Narrative section is the deliberate exception: it tells the story, while the record underneath stays itemized.

**Seeded strawman baseline (calibration, 2026-08-26).** When the dispatch brief carries a coordinator-authored strawman design, synthesis diffs against it rather than starting from a blank page. The strawman holds the burden of proof: any design decision that adds mechanism beyond it names, in its `**Rationale:**`, what the strawman concretely fails to do — a finding that the simple shape *works* is a decision to keep it, recorded as such. Overturning the strawman on evidence is legitimate and expected; overturning it because the itemized findings each suggested an addition is the failure mode this baseline exists to catch. Where no strawman was seeded, nothing changes.

1. **Goal** — what we're building/changing and why (1 paragraph). Write it in a controlled register, unconditionally: sentences of at most 25 words, active voice, present tense where possible, one idea per sentence, common words over rare ones, noun clusters of at most three words, no internal vocabulary except technical names grounded at first use. Certified simplified-English compliance is not claimed; the rules bind as written.
2. **Design Decisions** — use the `### DN: Title` format from the template. Each decision requires `**Decision:**`, `**Rationale:**`, `**Alternatives considered:**`, and `**Applies to:**` fields. Number decisions sequentially (D1, D2, ...).
3. **Draft Narrative** — synthesize goal and chosen approach into a `## Narrative` section (1-2 paragraphs). Place it after `## Goal`. Write for a reader who wants the story without reading all sections. Draw from Goal and Design Decisions. Omit file paths and task lists. Use the Goal's controlled register where it costs no precision; when the register and technical precision conflict, precision wins — say the precise thing.
4. **Architecture Diagram (conditional)** — after drafting Narrative, include a `## Architecture Diagram` section when the work touches 2+ distinct modules.

   Read diagram conventions:
   ```bash
   cat ~/.lore/claude-md/review-protocol/followup-template.md
   ```

   Diagram types: call chain (invocation paths), state machine (state transitions), data flow (data transforms). Write a plain-text ASCII diagram inside a fenced code block using box-drawing characters. Do NOT use Mermaid or other diagram DSLs — the TUI renderer cannot interpret them.

5. **Consumption-verification checkpoint** — before finalizing synthesis, report the outcome for each prefetched commons entry you actually checked against code during investigation. Held and contradicted both count — a confirmation is signal, not ceremony. Skip entries you never tested; grounded-or-nothing means every report needs the code anchor trio, so an entry you can't anchor is an entry you didn't verify.

   A contradicted entry is yours to resolve in the same call — there is no queue to file it into and no one behind you to hand it to. `--resolution <corrected|disputed>` is required on every contradicted report; the front rejects a contradicted call that names no resolution, so a contradiction never lands without an owner. Two resolutions, and the fork turns on exactly two questions — how confident you are, and whether your evidence sits at the claim's altitude:

   - `corrected` — repair the entry in place. Choose this when the code settled the question and your evidence covers the claim's scope. The entry stays live with a dated correction and `status: corrected`; the repair is itself a claim the next reader will check against the code, which is exactly what makes it yours to make.
   - `disputed` — leave a dated, reasoned dispute marker on the entry: what you observed, why you didn't correct. Choose this when your confidence is low, or when your evidence is narrower than the claim — single-callsite evidence must not narrow a scope-exceeding claim, and the front refuses such a correction with `disputed-required`. The marker travels with the entry, visible in retrieval, until a later agent with the context to settle it does.

   ```bash
   # Entry confirmed by investigation:
   lore verify <knowledge-path> held \
     --source spec-lead \
     --protocol-slot Synthesis \
     --cycle-id "spec-<topic>-$(date +%Y-%m-%d)" \
     --template-version "$LEAD_TEMPLATE_VERSION" \
     --file <absolute-path> --line-range <N-M> --exact-snippet "<verbatim code>"

   # Entry falsified by investigation — resolve it in the same call:
   lore verify <knowledge-path> contradicted \
     --resolution <corrected|disputed> \
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

   The corrected branch additionally passes the repair itself — `--superseded-text` and `--replacement-text` — plus the inputs the front weighs: `--confidence <high|medium|low>` (only `high` corrects; anything less routes to the marker), `--evidence-scope <single-callsite|multi-callsite|systemic>`, and `--claim-scale <implementation|subsystem|architecture|abstract>` — the same scale rubric entries and `--scale-set` declarations already use, which makes the altitude test concrete: `single-callsite` evidence against a claim above `implementation` scale is the one combination the front refuses. The disputed branch passes `--dispute-note` — what you observed and why you did not correct. A refusal exits 3 with `[verify] disputed-required: <reason>` and writes nothing; re-run with `--resolution disputed`.

   Events land in `$KDIR/_trust/trust-events.jsonl` (contract: `architecture/trust-ledger/README.md` in the knowledge store). Run these from the source repo's root, not from inside the knowledge store — `lore` resolves the store and records branch provenance from the current directory. Emission is non-blocking — synthesis continues immediately; re-running an identical invocation is a silent no-op (the writers dedupe and retries heal by stable IDs).

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
  **This block is the audit manifest, not the worker delivery channel.** It exists so a reviewer (and the post-plan ceremony) can see every preference/convention discovery surfaced. Workers do not read top-level plan.md sections — `/implement` consumes per-task `**Knowledge context:**` backlinks (Step 3.1 directive branch resolves them via `resolve-manifest.sh` into worker `{{prior_knowledge}}`). Distribution into per-task Knowledge context happens in Step 5b #2 (concordance-assisted annotation) — see that step for the per-task placement rule. Entries that don't bind to any specific task still appear here; the manifest also catches them during review even when they have no per-task home.

  Keep this block at the **full permissive surfaced set** regardless of what binds to a task. The manifest is permissive; the *weave* into task lines is strict (Step 5b "Deliverable contract gate" — only scope-overlapping judgment-class norms become constraint clauses). A backlink staying here while its norm is also woven into a task is correct: the manifest is provenance, the task line is delivery.

  The block is also a parse target: at close, the conformance renderer reads it as the spec-time discovery panel of `closure-conformance.md` and cross-tabulates each label against woven norms, recorded dispositions, and the shipped diff. Keep every bullet in the `[[knowledge:...]] — annotation` shape with a substantive annotation — a thinned or malformed manifest doesn't just weaken review, it blinds the closure read to norms nobody dispositioned.
- **Advisor declarations:** For each matched skill whose domain overlaps a task's owned surface, consider adding an `**Advisors:**` entry to that task. Set mode by the task's complexity — `must-consult` if the skill defines invariants workers must respect, `on-demand` otherwise.

### Ceremony outcome filing contract

Apply this contract after every terminal evaluator attempt in Steps 5a and 5.5. The evaluator supplies evidence; the lead decides the normalized protocol outcome. Never parse evaluator prose into a disposition. The two registered ceremonies stay distinct: an attempt names `spec-design` or `spec-post-plan`, and a review prepared under one ceremony never files under the other. Filing an outcome confers no authority the protocol did not already grant: acceptance, checkoff, and close keep their existing owners, and no review outcome gates dispatch on its own.

**Bound attempts (schema 2).** When the plan has a committed revision, prepare the review input before the evaluator reads anything. The reviewer then judges exact immutable bytes, and the filed outcome records the revision that was actually reviewed rather than whatever head is live at filing time.

1. Prepare the review input:

   ```bash
   lore plan review prepare "$SLUG" --attempt-id "$ATTEMPT_ID" \
     --ceremony <spec-design|spec-post-plan> \
     --revision "$REVISION_ID" \
     --purpose <criterion-adequacy|integration> \
     [--execution-worktree "$WORKTREE"]
   ```

   Prepare copies the named revision's plan and tasks, together with the original anchor, under `reviews/<attempt-id>/` and publishes the directory in one rename. `--revision` may name a historical revision explicitly; that revision is the one the outcome binds to. The `integration` purpose requires an execution worktree that can still be inspected, because its code identity is frozen into the prepared record. That digest covers the execution worktree and nothing outside it: earlier review evidence enters the identity only when it lives inside that worktree, and the knowledge store is not code identity. The one exclusion is this attempt's own review directory, listed under `source_exclusions`. A prepare interrupted before the rename leaves no accepted attempt and a retry may publish; once the rename lands, the accepted attempt stays and an exact retry verifies it. An exact retry compares the request against the committed record and keeps the frozen source identity even when the worktree has moved on. Direct the evaluator at the prepared copies, never at the live plan.

2. The reviewer authors judgments and findings. Criterion adequacy and integration against the original anchor are the reviewer's to judge. Task acceptance and execution records are not: acceptance stays with the lead, and execution evidence lives in results. The reviewer may read code, run commands, and describe in prose what a command does, but the ledger has no fields for executor state, exit codes, or argv, and a judgment never creates a result row; execution evidence the review relies on is cited by result ID. Each purpose gets its own judgment, the prepared purpose must appear, and an integration review may add a separate criterion-adequacy judgment. An empty `result_ids` list states that no execution evidence was cited; it is not a claim that none was consulted, so the judgment prose should say what the citations leave unverified.

3. The lead normalizes. Choose exactly one outcome: `completed | failed | skipped | needs-decision`. Preserve the evaluator's raw verdict byte-for-byte. `skipped` and `needs-decision` require a reason; `completed` and `failed` forbid one. Record this normalization in the dispositions ledger before sealing, so the sealed bytes carry the decision beside the review it was made from:

   ```json
   {
     "schema_version": 1,
     "outcome": "completed",
     "verdict": "<raw evaluator verdict>",
     "reason": null,
     "judgments": [
       {"purpose": "criterion-adequacy", "judgment": "<authored>", "rationale": "<authored>", "result_ids": []}
     ],
     "dispositions": [
       {"finding": "<text>", "disposition": "<text>", "reason": "<text>"}
     ]
   }
   ```

   The evaluator manifest names exactly the evaluator identity and nothing else:

   ```json
   {
     "evaluator_locator": "<skill or agent locator>",
     "evaluator_template_version": "<12 lowercase hex>",
     "framework": "<active framework>",
     "model": "<effective evaluator model>",
     "final_round": 2
   }
   ```

4. Seal once, then extract the evidence manifest to a file outside `reviews/`:

   ```bash
   lore plan review seal "$SLUG" --attempt-id "$ATTEMPT_ID" \
     --output "$REVIEW_OUTPUT" --dispositions "$DISPOSITIONS_JSON" \
     --evaluator-manifest "$EVALUATOR_JSON" > "$SEAL_RESULT"
   jq '.evidence_manifest' "$SEAL_RESULT" > "$EVIDENCE_JSON"
   ```

   Seal checks every cited result ID against its canonical results row and refuses missing, ambiguous, or malformed IDs and wrong output hashes. It freezes the cited rows with their full output envelopes into `cited-results.json`; those copies are review evidence, never result appends, and later replays verify the frozen citations instead of rereading live results. The whole sealed directory publishes in one rename. A failure before that rename leaves no accepted artifact and a retry may publish; after it, a retry verifies the immutable bytes and refuses a changed output, ledger, or evaluator under the same attempt id. The manifest is returned in the seal's JSON result and is not written under the review; extracting it is the caller's only step, and no identity field is hand-composed. The schema 2 manifest carries the evaluator fields plus the review path and hash, the revision, the purpose, and source hashes derived from the sealed bytes.

5. File the already-made judgment with the unchanged arguments:

   ```bash
   lore spec outcome "$SLUG" \
     --ceremony <spec-design|spec-post-plan> \
     --advisor "$EVALUATOR" --attempt-id "$ATTEMPT_ID" \
     --outcome "$NORMALIZED_OUTCOME" --verdict "$RAW_VERDICT" \
     --evidence-manifest "$EVIDENCE_JSON" [--reason "$REASON"]
   ```

   With a schema 2 manifest, filing revalidates the complete prepared, sealed, and citation bytes and checks that ceremony, attempt, outcome, verdict, and reason match the sealed ledger; a conflicting identity is refused rather than reconciled. The recorded revision is the reviewed one, not the live head. Exact replay is idempotent; reusing an attempt id for different semantics is a refused collision. `needs-decision` may return `status=partial` when its auxiliary resolution row fails to append; exact retry recovers only that sink without duplicating the outcome.

**Unbound attempts (schema 1).** When no prepared revision exists, because the item predates revision publishing or because a registered evaluator could not run, file with the version-1 manifest instead:

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

   `completed` and `failed` require every evidence field. `skipped` and `needs-decision` keep every field present but may use explicit `null` when evidence is unavailable. Missing fields are errors, never defaults. Schema 1 outcomes stay legacy and unbound in every reader because no revision was recorded when the evidence was filed. A registered evaluator that cannot execute is a filed `skipped` attempt, never a silent omission.

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

1. **Tasks** — the plan holds its tasks directly, one `### Task N:` block each. Every block carries `**Deliverable:**`, `**Files:**`, and exactly one `- [ ]` checkbox line; optional `**Scope:**` / `**Knowledge context:**` / `**Retrieval directive:**` / `**Consultations required:**` / `**Advisors:**` / `**Task format:**` / `**Knowledge delivery:**` / `**Close criteria:**` blocks follow as the work needs them. The heading number is the task's id — `### Task 3:` is `task-3` — and it stays fixed as earlier work is checked off and when the subject after the colon is renamed, because revisions, reviews, and results are keyed to that id. A legacy heading or checklist form may carry an explicit `[id: task-N]` marker; a normal flat heading needs none. Deleting a task retires its id — the next new task takes the next unused number rather than the retired one, so a result recorded against the old id cannot be read as evidence for a different task. `**Close criteria:**` is an optional fenced JSON array of executable checks, each with `id`, `intent`, `argv`, `cwd`, `timeout`, `expected_exit`, and an optional `applicability` predicate; task generation hashes the complete definition into a criterion version and carries the exact command fields into the worker brief. A task without the block is legible as having no executable criteria, which is an absence of evidence rather than a pass. The plan itself carries `**Verification:**` once, plus whichever sizing rationale the band below requires.

   **Sizing band.** Give every task one **design center** and at least one real design choice to make about it. A *design center* is the single interface, mechanism, or subsystem whose shape the worker decides; the term earns its place because the vocabulary already in use — scope, deliverable, file set — measures how much a task *touches*, and the band turns on how much a task *decides*. A deliverable spanning several independent design centers splits even when the parts run serially: chained tasks keep their own acceptance boundaries, their own reports, and their own premise-wrong exits.

   Argue the sizing decision in writing, whichever way it went. Each direction is priced, and the Step 5.6 finalize gate refuses a plan that argues neither:

   - **Split rationale** — required when the plan carries more than one task. Name what the split buys — parallel wall-time, separate acceptance boundaries, fresh context per worker, worker-tier separation, a scoped premise-wrong exit — against what it costs in spawn ceremony, brief duplication, and integration risk.
   - **Merge rationale** — required when the plan carries exactly one task. Name the one design center the parts share.

   Keeping one task because merging asked nothing of you is the outcome this band exists to prevent. Both blocks live at plan level, above the first `### Task N:` heading.

   **No residue (floor).** Fold work that is solely verification, capture, cleanup, a single CLI invocation, or a sub-edit of another task into the implementation task it serves. This bounds task size from below and is not weighable against the band.

   **Context-envelope ceiling.** A task's owned file set plus its brief must fit one worker's context envelope with working room to read, reason, and edit. When they do not, the split is **forced** — regardless of judgment class or of what the band concluded — because an over-large task reads as well-formed on the page yet fails *in flight* on worker-context exhaustion, the most expensive discovery point there is. This is a level-1 correctness-of-execution constraint (execution capacity), the sibling of the capability ceiling that keeps judgment-dense work off a model that cannot hold it — **not** a weighable extra condition and **not** an aesthetic size threshold. It bounds task size from above exactly as **no residue** bounds it from below; between that floor and this ceiling, size stays structure-gated — never trimmed to hit a size target.

   **Judgment class and the band.** Each task line carries a judgment class (`mechanical | standard | judgment-dense`; see the Judgment-class marker below) that `/implement` routes to a worker-tier binding — mechanical to a cheaper model, judgment-dense to a stronger one. Tier separation is one of the things a split buys: pulling a judgment-dense core away from a mechanical shell routes each to its own tier instead of paying the strong-model rate across the whole deliverable, so a judgment-density transition is a design-center boundary and a legitimate split point. A uniform same-mechanism sweep stays one task regardless of worker tier — one worker doing one read-modify-write pass beats N fresh agents repeating the same edit, and spawn overhead dwarfs the model-spend saving. The tipping point is judgment density, not file count.

   **Explicit dependencies.** `generate-tasks.py` chains tasks that share a file, so declare nothing for those. For an ordering no shared file expresses, end the consuming task's line with `[depends-on: task-3, task-5]` — the marker names producer tasks by heading number and seeds `blockedBy` before file-overlap chaining appends to it. Place it with the other trailing markers, after any `[[knowledge:...]]` backlinks.

   **Output contract.** When a task finalizes an interface, contract, schema, or substrate that later tasks consume as stable input, declare it inside that task's `**Scope:**` block as `- Output contract: <what this task fixes and later tasks may rely on>`, and end each consuming task's line with `[depends-on: task-N]`. The line is the producer's acceptance declaration, read by its worker and by the lead; the scheduler never interprets its prose. The dependency edge carries the ordering — an incomplete or failed producer keeps its consumers blocked, and a completed one releases them to rely on what it declared.

   **Deliverable contract gate.** Every task line names a durable artifact outcome — what gets built, refactored, authored, migrated, wired, or added. The valid primary verbs are: Implement / Refactor / Author / Migrate / Add support for / Wire... The following primary verbs are **never tasks** — they belong elsewhere: Verify / Check / Inspect / Run / Capture / Append / Cross-link / Note / Document-only.

   A valid task line states the **deliverable**, the **owned file or surface**, and at least one **design or integration constraint** that scopes the worker's choices. Write the constraint's *why* in the codebase's own vocabulary — the actual symbol, flag, or error string it protects, not a paraphrase. Rationale is what a handoff loses first, and a worker who knows the reason can adapt when the letter of the constraint doesn't fit what the code turns out to be. When the task responds to a concrete failure, include the reproduction handle — the exact failing command, test case, or input — ranked above architectural narrative: a pointer the worker can run outranks a description of what it would show.

   **Judgment-class marker (required).** Every task line ends with a trailing `[class: mechanical | standard | judgment-dense]` marker, placed after any `[[knowledge:...]]` backlinks so the deliverable verb stays first. It declares the **judgment class** — the worker tier `/implement` routes the task to:
   - **mechanical** — deterministic edits: uniform text substitution, one known transform swept across files, scaffolding. No design judgment; routes to the cheapest worker binding.
   - **standard** — ordinary implementation judgment (the common default): local design choices a competent worker makes without novel reasoning. Routes to plain `worker`.
   - **judgment-dense** — novel design, cross-cutting reasoning, subtle correctness, or security-sensitive surface. Routes to the strongest worker binding.

   The class is **explicit on every line** — the Step 5.6 finalize gate refuses an unannotated task line. An unclassed line is not treated as `standard`: a legacy plan with no markers still regenerates (routing as plain `worker`), but re-finalizing it demands annotation.

   <!-- INVARIANT — canonical /spec weave and task-grammar vocabulary. Keep these terms
        stable; the /implement worker report's `Convention handling:` field and the lead's
        completeness comparison key on them, and the task generator and closure
        conformance renderer parse them literally. Drift silently breaks the handoff.
          - "constraint clause" — the imperative norm woven into a task line
          - "woven norm" / "binding norm" — a surfaced norm that became a constraint clause
          - "stable label" — the entry slug/title the backlink resolves to; the
            identifier shared with the worker report and the lead comparison
          - `honor <stable-label>` — the task-line token that, paired with a same-line
            knowledge backlink, is extracted into `tasks.json` as `woven_norms`
          - `**Related preferences/conventions:**` — the audit-manifest block label the
            closure conformance renderer parses as the spec-time panel of
            `closure-conformance.md`
          - `### Task N:` — the unit heading the generator's flat branch discriminates on;
            N is the task's id
          - `[depends-on: task-N]` — the trailing task-line marker parsed into `blockedBy`
          - `- Output contract:` — the `**Scope:**` bullet declaring what a task fixes for
            its consumers -->
   **Weave binding judgment-class norms into the constraint clause.** When a preference/convention from Step 2 discovery *binds* to a task, render it as an imperative **constraint clause** in the task line itself — the instruction the worker executes — not only as a `**Knowledge context:**` backlink the worker must choose to fetch. The clause **names the norm by its stable label** (the entry slug/title the backlink resolves to) so the worker's `Convention handling:` report and the lead's completeness comparison reference the same identifier. Keep the backlink for provenance even when the norm is woven.

   A norm *binds* only when **both** hold (strict weave):
   - **Scope-overlap** — its `related_files`, file-path globs, ceremony scope, or activity domain intersect this task's owned files, deliverable, or surface.
   - **Judgment-class** — compliance is a judgment a one-line deterministic check could not make. Mechanical/lint-class norms (file-header rules, scaffolding-marker bans, structural lint) are **never woven** — they route to the hook arm of `route-conventions-by-enforcement-class-delivery-vs`. Judgment-class but no scope-overlap → backlink only (no constraint clause); neither → top-level manifest only.

   Weave only this binding subset — never the full permissive surfaced set, never mechanical norms. The top-level `**Related preferences/conventions:**` audit manifest stays unchanged (Step 5 — full permissive set); strict weaving into task lines is what prevents task-description bloat and dilution.

   Example bound task line:
   ```
   - [ ] Implement the retry wrapper in `src/net/client.py` — surface partial failures rather than swallowing them; honor `error-messages-name-the-failed-operation-and-the-fix` (name the failed operation and the corrective action in every raised error). [[knowledge:conventions/error-messages-name-the-failed-operation-and-the-fix]] [class: standard]
   ```

   Route invalid units:

   - **"Verify X" / "Check Y"** → the plan's `**Verification:**` bar; never its own task, never duplicated into a task description.
   - **"Capture Z" / "Append session note"** → lead-side step once the plan closes (`lore capture` or `notes.md`); not worker work.
   - **Single-line edits, single CLI invocations, sub-edits** → fold into the adjacent implementation task.

   **Task format (intent+constraints).** Default. State what the change accomplishes, what not to do, and what success looks like at the deliverable level. Opt into prescriptive format with `**Task format:** prescriptive` for mechanical work where step-by-step instructions are required.

   **Verification (the plan's acceptance bar).** Write `**Verification:**` once, at plan level, as 0 to 3 observable-behavior criteria — the bar the lead honors at plan close. Task generation renders those bullets into every worker brief as plan-owned close criteria, and a worker self-checks only the bullets its own diff can affect, naming the rest as not-self-checked. Omitting the block declares no additional bar. The template's anti-pattern list governs what a bullet may say; the suite-shaped bar is the one to watch, because suite-level certification happens once at integration and a bar that asks for it pushes that cost onto every worker.

   Verification prose and a task's `**Close criteria:**` block are different instruments. The prose states what the lead judges at close; a criterion states an exact command whose exit code can be recorded, so the two live side by side and neither replaces the other. A criterion's `argv` runs without an implicit shell and its `cwd` resolves inside the execution worktree, which is why the command is written as a literal argument list rather than a shell line. An `applicability` predicate is its own object with `argv`, `cwd`, `timeout`, `applicable_exit`, and `inapplicable_exit`, where the two exits are distinct; it carries no criterion `id`, `intent`, or `expected_exit` of its own. Its absence means the criterion always applies. Declared criteria are executed by `lore criteria run <slug> <task-id> <criterion-id>`, which resolves the criterion from the selected immutable revision and records an immutable result row. The runner takes identity only: `--execution-worktree <root>` plus either `--packet-id <id>` (a schema 2 packet fixes task, revision, and dispatch attempt, and any `--revision` or `--dispatch-attempt-id` given alongside must agree) or `--revision <rid> --unbound-reason <text>` when no packet exists. It accepts no command, output, state, exit, result, or skip override, so the recorded outcome is what the declaration produces, not what a caller asserts. The criterion version is a hash of the complete canonical definition, covering argv, cwd, timeout, expected exit, and applicability, so changing any of these yields a new version through a new plan revision. Author criteria knowing the run is exact: stdin is `/dev/null`, stdout and stderr are captured together as bytes, the process group is terminated at the declared timeout, a nonmatching exit or a signal or a timeout records `fail`, and a launch, cwd, output-persistence, or source-access failure records `unavailable` rather than either pass or fail. A predicate that observes its inapplicable exit records `skipped` and the command does not run; any predicate outcome other than its two declared exits records `unavailable`. A check that spans several tasks belongs to a named integration task that owns it. A result records that a command exited a certain way against a recorded code identity; whether that criterion is adequate for the task, and whether the criteria together cover the original anchor, remain the reviewer's authored judgments citing result IDs.

   **Premise-wrong exit (standing, every task).** A task brief hands its worker two sanctioned outcomes, not one: the deliverable, or the report "this cannot be built as scoped — here is what blocked me," naming the premise that failed contact with the code. The second is a first-class result from a colleague closer to the ground than the plan was; it routes to Step 6 follow-up investigation instead of forcing an approximation of a wrong plan. Never write a task whose only expressible outcome is success.

2. **Concordance-assisted annotation** — after drafting the tasks, widen each task's `**Knowledge context:**` block:
   ```bash
   lore prefetch "<task deliverable> <key file paths>" --type knowledge --limit 5 --scale-set=<bucket>
   ```
   Declare `--scale-set` explicitly for every prefetch call. Missing declaration is an error.

   **Scale rubric** — declare `--scale-set` explicitly on every prefetch. The four tiers (`abstract`, `architecture`, `subsystem`, `implementation`), boundary tests, multi-label encoding rules, and the ±1 query pattern live in `skills/memory/SKILL.md` Scale-Aware Navigation — read that section before declaring if the right bucket is not obvious. For decision-tree details see the `classifier` agent template (lore repo `agents/classifier.md`).

   Add relevant entries as `[[knowledge:...]]` backlinks with "— why relevant" annotations. Investigation findings are the primary source; concordance is a widener.

   **Distribute surfaced preferences/conventions into per-task Knowledge context (mandatory).** The top-level `**Related preferences/conventions:**` block from Step 2 discovery is an audit manifest — it does not reach workers. Backlinks live at exactly two altitudes: the task, and the cross-cutting manifest. To wire into worker `{{prior_knowledge}}`, distribute each surfaced entry into `**Knowledge context:**` of every task whose surface plausibly overlaps:

   - **Scope-overlap test:** an entry overlaps when its `related_files`, file-path globs, ceremony scope, or activity domain intersects the task's `**Files:**`, deliverable, or owned subsystem. Apply permissively — the Step 2 surfacing gate carries through to distribution. If a reviewer would expect the worker aware of the entry while editing the task's files, distribute.
   - **Format:** add as `[[knowledge:preferences/<entry>]]` (or `conventions/`, or `cross-cutting-conventions/`) in `**Knowledge context:**`, with a worker-facing "— what to honor at implement time" annotation. Implementation-facing means tell the worker what to *do*, not just what it says.
   - **Distribute to multiple tasks when warranted.** A convention touching several tasks' files belongs in each of their Knowledge context blocks — duplication is correct here because each task is its own worker with its own seeds. Do not consolidate across tasks.
   - **No-overlap entries stay in the top-level manifest only.** If after permissive review an entry binds to no task, leave it solely in `**Related preferences/conventions:**` — the manifest preserves the audit trail.
   - **Distribution is permissive; weaving is strict — two separate channels.** This step (per-task `**Knowledge context:**`) carries every scope-overlapping entry, judgment-class or not, as a backlink — the worker can dismiss inapplicable ones. Weaving into a task's constraint clause (Deliverable contract gate above) is the *strict* subset: only the judgment-class entries that also scope-overlap the task become imperative constraint clauses naming the norm by its stable label. A judgment-class entry that binds to a task gets **both** — the backlink here (provenance + `{{prior_knowledge}}` seed) and the woven clause in the task line (the instruction the worker executes). A mechanical entry gets only the backlink (it is never woven).
   - **Why distribute here:** `/implement` Step 3.1 (directive branch) resolves seeds via `resolve-manifest.sh` from `**Knowledge context:**` backlinks + `**Files:**` paths. Distributing here flows entries through seeds → directive → worker `{{prior_knowledge}}` without new protocol surface in `/implement`.

3. **Retrieval directive derivation** — after concordance widening, populate `**Retrieval directive:**` for each task. Derivable from the task's own content alone; no user input. Directives resolve per task at dispatch, so each one is derived from that task's files and knowledge context, never from a neighbour's.

   **Per-topic decomposition (v2 — default):** the directive is a list of `(topic, scale_set, [activity_vocab])` — **exactly one focal topic** plus **up to five adjacent topics**. Each topic fires its own BM25 OR query at its own scale_set; the worker prompt's `## Prior Knowledge` block ends up sectioned (`### Focal: <topic>` / `### Adjacent: <topic>`).

   - **Focal topic.** The task's primary subject. Default `scale_set: subsystem,implementation`. Seeds: the task's owned files (from `**Files:**`) plus `[[knowledge:...]]` entries in `**Knowledge context:**` about that subsystem. Prefer **title-vocabulary terms** (the entry's title tokens) over the topic label — title vocabulary resolves to entries the index can rank, while raw `knowledge:...` strings tokenize as a single literal and miss the index.
   - **Adjacent topics (≤5).** Subsystems the task touches but does not own. Default `scale_set` one tier above focal's bottom — typically `architecture,subsystem`. Seeds: title-vocabulary terms from canonical entries about *that adjacent subsystem* — not the topic label, not the focal seeds. Weak seeds (right scale, wrong entries) are the dominant failure mode — re-derive from adjacent entries' titles and resolved paths.
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

   **Omission rule:** if a task has neither `**Knowledge context:**` backlinks nor `**Files:**` entries, omit the `**Retrieval directive:**` block and add a comment: `<!-- no directive: no backlinks or files to derive seeds from -->`.

   **Position:** place `**Retrieval directive:**` immediately after `**Knowledge delivery:**` (or after `**Files:**` when `**Knowledge delivery:**` is absent) and before `**Knowledge context:**`.

4. **Open Questions** — anything investigations couldn't resolve.

5. Present the synthesized plan to the user for review.

---

### Step 5.0: Review context cost estimates (advisory)

```bash
lore work regen-tasks <slug>
```

Inspect the context cost summary as a sanity check — a single task far larger than its peers may signal an under-decomposed deliverable worth a closer read. Cost diagnostics are advisory only; the sizing band and the Deliverable contract gate in Step 5b are the binding gates. Do not split tasks merely because they fall above an avg-comparison threshold, and do not merge tasks merely because they fall below one. The avg-comparison heuristic is post-hoc and uniform-thinness blind; trust the intrinsic gates instead.

On an item that has adopted revisions, this entry point composes `lore plan revise <slug>`: the revision writer validates plan, anchor, DAG, and criteria, stages plan and task snapshots, appends a revision row, and installs `tasks.json` through its existing writer. An identical regeneration returns the current revision without appending, so repeating this step costs nothing in history. The structural validation it performs is separate from the semantic disposition it records. A plan that parses and wires cleanly still carries `pending` anchor coverage and review requirement until someone authors them, because structural equality says nothing about whether the changed tasks cover the anchor or need a fresh review. The disposition can be supplied with the revision or later against its id:

```bash
lore plan revise <slug> --reason "split task 3 into tasks 3 and 6" --author-role designer --decisions decisions.json
lore plan revise <slug> --decision-for <revision_id> --decision-id <token> --decisions decisions.json
```

The second form records a decision against an existing revision and creates no new revision; the same decision id replays exactly. `decisions.json` may hold `anchor_coverage`, `review_requirement`, and `dispatch_decision`; the dispatch decision belongs to the coordinator and is normally recorded during `/implement` rather than here. The field shapes and an example are in `docs/protocol-evidence.md`.

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

For each task, run `lore search "<task deliverable keywords>" --scale-set subsystem,implementation --limit 3`. If results exist but the task has no `**Knowledge context:**` block, add the most relevant entry as a backlink with an implementation-facing annotation.

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
3. Re-check affected tasks that depended on the corrected assumption.
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

Before finalizing, present the plan's tasks as structured summaries. This is a separate gate from Step 5.1 — that validates understanding; this validates the work plan.

1. For each task, produce:
   ```
   Task N: <Name>
     Deliverable: <what this task produces>
     Mechanism:   <HOW — specific technical approach, 1-3 sentences>
     Files:       <owned file surface>
     Depends on:  <task ids from [depends-on: ...], or "file overlap only" / "none">
   ```
2. Present all task summaries. Before them, add:
   ```
   Workers: N (max concurrent from task DAG topology)
   ```
   Read `recommended_workers` from `tasks.json`. End with: `Review the tasks above. Approve to proceed, or request changes.`
3. **Wait for explicit approval.** **If `--yes`, skip (auto-approve).**
4. If user requests changes: revise the affected tasks in `plan.md`, re-present only changed summaries. Repeat until approved.
5. If user needs new investigation: suggest re-running `/spec <slug>`.

---

### Step 5.4: Post-research extraction

Invoke `/remember` scoped to the spec investigation. **Always invoke it — even when no observation appears to meet the gate.** The gate lives in `/remember`; rejecting candidates is `/remember`'s job, not the lead's. Pre-filtering observations because "nothing qualifies, so `/remember` would be a no-op" is the bypass shape named in the commitment protocol. A run that captures zero entries is a valid terminal so long as `/remember` actually evaluated the observations.

**Capture posture: generous in, exacting in form.** Verification happens downstream, at consumption — every entry meets real code when a later agent reads it, and entries that fail that contact get corrected or disputed on the spot by the reader who caught them. So the expensive mistake is a malformed entry, not an extra one: don't spend effort predicting whether a future session will need an insight; spend it putting the insight in the form that lets that session retrieve and check it. Every capture written or promoted here takes the five-part form:

1. **Contrastive pair** — what to do *and* what it replaces or avoids: "use X; the tempting Y fails because Z." The avoid-half carries the hard-won part.
2. **The codebase's own vocabulary** — actual symbol names, actual error strings, never a paraphrase. Retrieval matches on similarity to a future agent's working context, and that context is made of real identifiers.
3. **Explicit applicability trigger** — "applies when you touch X and see Y." Distillation strips applicability cues, so the entry must re-supply its own.
4. **Extracted from surprises, not summaries** — capture what contradicted an expectation during investigation, drawn from the evidence itself, not from an agent's self-narration about its work.
5. **Provenance pointer** — `file:line@SHA` anchoring the claim; this is the anchor `lore verify` checks.

Every `lore capture` call must carry provenance flags; for captures promoted from researcher observations, preserve the original producer's attribution:

- **Lead-original insights:** `--producer-role spec-lead --protocol-slot Synthesis --work-item <slug> --template-version $LEAD_TEMPLATE_VERSION`
- **Investigator-sourced observations:** `--producer-role researcher --capturer-role spec-lead --source-artifact-ids <report ids from the directives' bindings> --protocol-slot Synthesis --work-item <slug> --template-version $PRODUCER_TEMPLATE_VERSION` — the version of the compiled brief (or, on the explicit legacy path, of the researcher template) that produced the report the observation came from, taken from that report's directive. `researcher` is the capture writer's legacy vocabulary for the investigator position; it names the position at that boundary and adds nothing to the entry's standing.
- **Multi-producer synthesis:** one capture call per distinct producer — never merge.

```
/remember Research findings from <work item title> — Read all **Observations:** entries from investigation reports in plan.md and evaluate each: mechanism-level patterns, design rationale, and structural footprint signals all qualify; implementation facts already expressed in Tier-2 assertions do not. Also capture cross-investigation synthesis patterns not surfaced individually. Shape every capture in the five-part form: contrastive pair, the codebase's own vocabulary, explicit applicability trigger, surprise-derived content, provenance pointer.

Apply the provenance flags above on every `lore capture`.
```

**Settle what investigation crossed.** Investigation is where open questions get answered and hypotheses meet their settling tests — a research pass that reads the code an unsettled entry is about routinely crosses the test the entry names without noticing. Before leaving this step, sweep the `### Open questions` and `### Hypotheses` sections of your session context and prefetches against what the researchers established. A question this investigation answered: capture the answer as a regular entry, then settle the question — `lore claim settle <path> --kind-status answered --source spec-lead --work-item <slug> --note "..."`, naming the answering entry in the note. A hypothesis whose settling test the research walked past: record one observation — `lore claim corroborate <path> --direction <supports|undermines> --source spec-lead --work-item <slug> --note "..."` — and settle it when the result was decisive. This is the consuming-side mirror of `/implement`'s salvage pass: capture files new unsettled claims, this sweep retires old ones. "Nothing crossed" is a complete answer.

---

### Step 5.4a: Theory of the touched subsystem

Name the subsystem this plan touches, and put its theory page in order while the synthesis is still in one head — once the tasks disperse it, nobody holds the full picture again until the next spec. If a theory page exists for the subsystem (the `### Theory` section of your session context or prefetch), read it against what investigation just taught you and revise whatever no longer describes the code; a theory describes the code, the code never answers to the theory, and whoever changes a subsystem changes its page in the same change — this step is that rule applied to the spec seat. If no page exists and the subsystem is coherent enough to deserve one, write it:

```bash
lore capture --kind theory --subsystem <name> --category architecture --scale architecture,subsystem --insight "<how the subsystem actually works>"
```

Put the subsystem's deliberate absences — what it deliberately does not do, and why — in the entry body alongside how it works; the absences are the part a later reader cannot recover from the code. Two outcomes complete this step with nothing written: the page is already current, and this plan touches no subsystem coherent enough to have one. The step blocks nothing — it holds no gate over the ceremony or finalization that follow.

---

### Step 5.5: Post-plan ceremony evaluation

**Ceremonies always run before terminal finalization.** No flag skips this step; no flag is required to run it. Judgment applies to acting on output, not to whether the registered obligation executes.

```bash
EVALUATORS=$(lore ceremony get spec-post-plan --work-item <slug>)
```

Invoke every registered evaluator. Present its output to the user. If the lead accepts changes, revise `plan.md`, repeat the affected review gates, and run a fresh evaluator attempt. After each terminal attempt, make the normalized outcome judgment and file it under `--ceremony spec-post-plan` using the ceremony outcome filing contract.

Do not finalize while a post-plan result still requires a plan edit or human decision. `needs-decision` is durable evidence of that open judgment, not permission to route around it.

Run Step 5.6's three lead-owned preflight asserts now, without finalizing: sweep the plan's named **paths, symbols, and packages** against the live tree (marking unresolvable names `(unverified)`), check every instructed invocation against the **live script**, and check that **Tier-2 emission instructions** point to the canonical validator contract. If any assert — or the finalize verb itself — refuses, fix `plan.md` and re-run the affected ceremony before Step 5.6 invokes `lore spec finalize`.

With the post-plan ceremony terminal and all three preflight asserts passing, a hosted session journals the plan-ready milestone before entering Step 5.6:

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

**Lead-owned preflight (three prose asserts the verb cannot run):** validate the plan against live sources, never from memory: (1) every path, symbol, and package the plan names resolves against the live tree — a mechanical grep or lookup per name; mark anything that doesn't resolve `(unverified)` where it appears, so the marking itself is the falsifier a later reader checks; (2) any script invocation block the plan instructs agents to run must match the live script's current flags (check `--help` or source — script schemas drift faster than plans); (3) Tier-2 emission instructions point at the validator's canonical required-field set rather than enumerating fields inline. Fix `plan.md` first if any fails — a deterministic script can assert JSON structure, but adjudicating prose against live sources is the lead's judgment.

Then close the plan through the finalize verb. Do not hand-run its composed checks or writers; `finalize` owns backlink verification, the intent-anchor hard gate, task regeneration, healing, retrieval-directive assertions, its `spec-verb` atom, and last-write telemetry:

```bash
lore spec finalize <slug>
```

Show the verb's output. The anchor gate enforces structural anchor preservation and scope-delta attestation, not semantic non-drift — semantic alignment between the anchor and the rest of the plan remains a spec-author responsibility, with downstream reviewers (e.g., `/codex-plan-review`) as the semantic backstop. A no-anchor work item reports the gate as `skipped` with the verifier's reason (absence is legible, not silent).

**Refusal handling:**
- **Exit 3 (intent-anchor gate) or an emission-contract assert failure:** surface the named diagnostic (verifier code 2 = section missing, 3 = body diverges, 4 = `**Scope delta:**` missing; contract failures name the failing task), fix `plan.md`, and re-run `lore spec finalize <slug>` until it passes.
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

When emitting `plan.md` in Step 5b (including item 0's Intent Anchor render), read `skills/spec/templates/plan.md` for the canonical plan structure. The sidecar holds the full fenced template — Goal, Narrative, Intent Anchor, Strategy, Context, Investigations, Design Decisions, Architecture Diagram, Tasks, Open Questions, Related — with the inline HTML-comment guidance preserved alongside each section it governs.
