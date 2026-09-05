---
name: spec
description: "Create a technical specification on compiled investigator and designer positions — `/spec short` for a single-context plan, `/spec` for a parallel investigation wave; one workflow for standalone and commissioned runs"
user_invocable: true
argument_description: "[short] [--yes] [--model <id>] [name or description] — existing work item name, or a freeform description to start from. `--model` overrides every per-role binding (lead/researcher/advisor) for this invocation only; otherwise per-role models come from `resolve_model_for_role`."
---

# /spec Skill

Produces a `plan.md` inside a work item's `_work/<slug>/` directory, and publishes it as a committed revision.

One workflow serves a standalone run and a commissioned one. Standalone, the spec lead holds the seat: it reads evidence, decides the gates, and records acceptance. Commissioned by `/coordinate`, the coordinator holds the seat and the spec lead carries out the same steps and prepares the same evidence; the seat is bound once, at entry, and nothing below changes with who holds it except who reads a gate whole and records its acceptance. Investigation runs on the compiled investigator position and design on the compiled designer position, each bound to a knowledge packet built for its move; in short mode the seat reads those compiled briefs itself, in full mode it dispatches them. The verbs record execution evidence — reports, claims, revisions, reviews, results — and the seat reads that evidence and records decisions. None of these records scores an agent.

## Short Flow (`/spec short`)

Single-context path: the spec lead reads the key files itself (Step 2a) and drafts the plan without dispatching a researcher team. Single-context work is the sanctioned norm, not a degraded mode — one context that reads the code itself serves most specs well. The reading is still an investigation: the seat compiles the investigator brief, binds an attempt against the checkout it reads, and lands an investigator-shaped report through the same writers a dispatched investigator uses, so the plan's findings carry the same provenance in both modes. No native launch happens and none is claimed.

The track conditional activates at Step 2 only. From Step 3 onward, short and full paths share every step: collect findings and emit Tier-2 artifacts, strategy gate, synthesis on the designer position, design ceremony, concrete plan, task review, post-research extraction, post-plan ceremony, and terminal finalization.

## Full Flow (`/spec`)

Parallel investigation: the spec lead composes an investigation plan table (Step 2b), opens an immutable dispatch wave, executes the returned directives — sessions under ordinary placement by default, native subagents where the readiness check passes — collects findings, emits Tier-2 artifacts, and then synthesizes through the same shared downstream steps. Team ceremony engages where scale demands it: investigation breadth one context cannot hold, or unknowns that genuinely parallelize.

> **Sequencing constraint:** Do not dispatch investigators before completing Step 2. The investigation plan is a completeness checklist and user approval gate, not just a dispatch list.

## Judgment boundary

The verbs prepare evidence and persist decisions; they do not make them. Keep these kernels in seat prose: investigation questions, complexity labels, strict/permissive applicability, packet synthesis (what a receiver needs and what it should not carry), synthesis, contradiction decisions, task decomposition, evaluator normalization, whether feedback changes the plan, gate acceptance, and every harness-native dispatch or teardown call. If a verb appears able to infer one of these, stop at the boundary and supply the missing judgment explicitly.

## Recipes and packets

Every runnable command in this file is an exact recipe: its inputs are declared on the line before it as environment variables, and each recipe runs on its own in a fresh shell, so carry values between steps as variables you set from earlier output. A test executes these recipes against isolated stores through this checkout's writers, which is why a body cannot carry placeholders. Shapes shown in `text`, `json`, `yaml` or `markdown` fences are data for reading, not commands. Reusable position contracts live in `docs/position-report-contracts.md` (report shapes, writers, the dispatch reference on Tier 2 rows) and are read at the point of use rather than restated here.

A packet returned by `lore packet build` is a candidate set, not a delivery: one retrieval pass at a declared scale, nobody's judgment yet. Before any packet is handed to a position — an investigator, a designer, a commissioned session, and the compiled brief the seat itself reads in short mode — the seat reads it, drops the entries the receiver should not carry, adds what the receiver needs and retrieval missed, and records that judgment through the synthesize verb with one reason per dropped or added entry. The verb appends a superseding row under the same packet id at `delivery_stage: synthesized`: it removes each dropped entry's recorded block from the content by exact bytes, renders the added entries under `### Added by synthesis`, closes the content with a `## Left out by synthesis` list (title, path, reason) when anything was dropped, and recomputes the per-scale counts. `lore packet show` then returns that latest row, so the receiver reads what was handed on and can overrule a set-aside entry by re-pulling it when the reason does not hold against the code; the candidate row stays in the file as history. Only an `assembled` row can be synthesized, so a row already handed on is re-pulled, not repaired. Dispatch preparation (`position-bind`) refuses to prepare against a packet whose latest row is not `synthesized` unless the builder recorded a `synthesis_waiver`; `spec open` records that waiver only on the investigator packets it builds itself in its default-bindings branch, where assembly and dispatch happen in one verb, and a packet this workflow builds and supplies through its own bindings is synthesized first. The seat packet the seat reads for itself is not handed on and needs no synthesis. `SYNTHESIS_FILE` is JSON you write — `{"dropped": [{"path": "<store-relative entry path>", "reason": "..."}], "added": [{"path": "...", "reason": "..."}]}`, dropped paths from the delivered set and added paths naming knowledge entries in the store — and two empty lists are a judgment too, recorded as one:

**Recipe inputs:** PACKET_ID, SYNTHESIS_FILE.
<!-- spec-recipe: packet-synthesis -->
```bash
lore packet synthesize "$PACKET_ID" --by spec-lead --spec "$SYNTHESIS_FILE"
```

The same judgment applies to the discovered norm manifest: discovery stays complete and is retained as evidence, the Knowledge context a task or position receives carries only what it needs, and every entry set aside is listed with its reason (Step 5b item 2 names the record). A packet built and handed on without this step is search pushed down to the receiver.

---

### Step 1: Parse, resolve, and bind the seat (both modes)

1. Parse arguments:
   - Set `TRACK=short` when the first arg after `/spec` is `short`; otherwise set `TRACK=full`. The investigation step (Step 2) follows that declared track.
   - If `--yes` is present, skip all interactive confirmation gates (auto-proceed through investigation plan confirmation, strategy gate, confirm understanding, and task review). It does not skip a ceremony, a gate decision, or the archived-item confirmation.
   - If `--model <id>` is present, set `MODEL_OVERRIDE=<id>` and export the per-role overrides for this invocation: `export LORE_MODEL_LEAD=<id> LORE_MODEL_RESEARCHER=<id> LORE_MODEL_ADVISOR=<id>`. Otherwise leave `MODEL_OVERRIDE` empty and let ceremony-scoped role resolution choose each model. An explicit flag without a value is an error, not a request for the configured default.
   - The remaining text is the **input**.

2. Resolve the store, the scripts beside the `lore` you are running, and this file's version:

   **Recipe inputs:** none.
   <!-- spec-recipe: resolve-paths -->
   ```bash
   KNOWLEDGE_DIR="$(lore resolve)"
   WORK_DIR="$KNOWLEDGE_DIR/_work"
   SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "$(command -v lore)")")/../scripts" && pwd -P)"
   SKILL_FILE="$(cd "$SCRIPTS_DIR/.." && pwd -P)/skills/spec/SKILL.md"
   LEAD_TEMPLATE_VERSION="$(bash "$SCRIPTS_DIR/template-version.sh" "$SKILL_FILE")"
   printf 'KNOWLEDGE_DIR=%s\nWORK_DIR=%s\nSCRIPTS_DIR=%s\nSKILL_FILE=%s\nLEAD_TEMPLATE_VERSION=%s\n' \
     "$KNOWLEDGE_DIR" "$WORK_DIR" "$SCRIPTS_DIR" "$SKILL_FILE" "$LEAD_TEMPLATE_VERSION"
   ```

   `LEAD_TEMPLATE_VERSION` is this file's 12-hex version and stamps every entry the seat files; the compiled investigator and designer stamp their own versions, and `spec-open.sh` records its wrapper version apart from both. Then render the standing defaults and treat their output as binding for this run — settings-derived role/model maps, ceremony registrations, sampling rates, preference directives cited by title:

   **Recipe inputs:** none.
   <!-- spec-recipe: lore-defaults -->
   `lore defaults`

3. **Bind the seat.** Commissioned entry arrives with a packet id and pointer from the coordinator, who synthesized the packet before handing it on. Render it and check it against the move you were given; its entries are candidates to verify against the code, not receipt and not acceptance, and the `## Left out by synthesis` list at its end, when present, names what the coordinator set aside and why. A dispatch prepared before the verb existed carries that record as `packet-synthesis.md` beside its brief instead; read it the same way:

   **Recipe inputs:** PACKET_ID.
   <!-- spec-recipe: seat-packet-show -->
   `lore packet show "$PACKET_ID"`

   Each entry carries a byline naming who captured it and during what work; the byline locates context and says nothing about how much to trust the entry. Standalone entry has no packet yet: the seat builds its own in item 6, after the start verb has bound the slug, because the packet writer binds to a work item and nothing before `start` has resolved one.

4. Run the read-only startup verb. It owns work-reference resolution, plan-state classification, active-framework/model resolution, template-version stamping, and source provenance. It never creates a work item, repairs an index, or chooses a protocol route. `INPUT` may be empty, in which case the branch-inference sentinel is passed; `TRACK` is `short` or `full`; `MODEL_OVERRIDE` may be empty:

   **Recipe inputs:** INPUT, TRACK, MODEL_OVERRIDE.
   <!-- spec-recipe: spec-start -->
   ```bash
   START_INPUT=${INPUT:-__branch_inference__}
   START_ARGS=("$START_INPUT" --branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)" --json)
   [[ "$TRACK" == "short" ]] && START_ARGS+=(--short)
   [[ -n "$MODEL_OVERRIDE" ]] && START_ARGS+=(--model "$MODEL_OVERRIDE")
   START=$(lore spec start "${START_ARGS[@]}")
   printf '%s\n' "$START"
   ```

   Required version-1 fields are `schema_version`, `resolved`, `slug`, `archived`, `plan_state`, `intent_anchor`, `strategy_present`, `active_framework`, `effective_lead_model`, `track`, `lead_template_version`, and `provenance`. Missing declarations and unknown flags are errors; there is no default route for malformed input. Exit 2 means ambiguity: ask the user to select from the ordered candidates, then re-run with the exact slug.

5. Choose the route from the returned facts — this is seat judgment, not verb output:

   - **`resolved=false` with user input:** treat the remaining input as a freeform description and continue to Goal Refinement (Step 1b).
   - **`resolved=false` without user input:** ask what the user wants to spec; never turn the branch-inference sentinel into a work item.
   - **`archived=true`:** warn and wait for explicit confirmation; `--yes` does not answer this.
   - **`plan_state=synthesis-complete`:** load `plan.md`, read any `## Strategy` silently, and continue at Step 5.1.
   - **`plan_state=investigations-only`:** load the persisted findings and any strategy, then continue at Step 5.
   - **`plan_state=follow-up-needed`:** read the open questions and design targeted follow-up investigations (Step 6).
   - **`plan_state=incomplete`:** present the persisted material for discussion; offer the strategy gate before synthesis when no strategy exists.
   - **`plan_state=none`:** continue to Step 2.

   When `intent_anchor` is non-null, preserve it verbatim — downstream gates (the Step 5.6 verifier, `/implement` anchor prompts) detect drift by string comparison, so a paraphrase breaks the audit chain even when intent is preserved. It is the user-visible capability boundary, not a suggestion the spec may silently narrow. Startup reports the anchor; only the seat judges whether the emerging design still covers it.

6. **Standalone seat packet.** Once `SLUG` is bound (from `start`, or from Step 1b's creation), build the seat's own packet. The topic is your judgment — one line naming what this spec changes — and `SCALE_SET` is the bucket that judgment sits at, or several comma-separated (`skills/memory/SKILL.md` § Scale-Aware Navigation). Hold the printed `packet_id` as `PACKET_ID` and render it with the seat-packet-show recipe, so both entry routes read their packet the same way. The seat reads its own packet; synthesis applies when a packet is handed to someone else:

   **Recipe inputs:** SLUG, TOPIC, SCALE_SET.
   <!-- spec-recipe: seat-packet-build -->
   `lore packet build --work-item "$SLUG" --role coordinator --caller spec-lead --topic "$TOPIC" --scale-set "$SCALE_SET"`

   Read the item's evidence beside its plan — revisions, results, reviews, packets, notes — before deciding anything from the plan state alone:

   **Recipe inputs:** SLUG.
   <!-- spec-recipe: work-show -->
   `lore work show "$SLUG" --json`

### Step 1b: Goal Refinement (new work only)

When the input is a freeform description rather than an existing work item:

1. Restate your understanding in 1-2 sentences.
2. Ask 2-4 clarifying questions using `AskUserQuestion`. Target scope boundaries, constraints, and approach preferences. Do NOT ask questions answerable by reading the codebase.
3. Incorporate answers into a refined goal statement.
4. Create the work item through the sanctioned writer. Derive a slug from the description and pass `--intent-anchor` with an interpreted one-sentence capability statement that names the user-visible outcome. Audit it for looseness — alternatives ("X or Y" admits doing just one), comparatives without targets ("better," "faster" with no acceptance bar), vague verbs ("support," "improve" without naming the bar), and the meta-instruction degenerate case (user said "make a work item for that," no capability named) — before committing. The clarifying questions in step 2 should have closed most looseness; if any remains, ask one targeted question via `AskUserQuestion` before creating. See `/work create` intent-anchor guidance and `[[knowledge:conventions/protocol/work-item-intake-should-store-neutral-intent-ancho]]`. Creation precedes the seat packet: the packet writer needs the slug.

   **Recipe inputs:** TITLE, SLUG, INTENT_ANCHOR.
   <!-- spec-recipe: work-create -->
   `lore work create --title "$TITLE" --slug "$SLUG" --intent-anchor "$INTENT_ANCHOR" --json`

5. Build the seat packet (Step 1 item 6) and continue to Step 2.

If the user's description is already specific enough (clear scope, stated constraints, obvious approach), skip to step 4 — don't ask questions for the sake of asking.

---

### Step 2: Investigation — conditional on the track

### Step 2a: Short branch (`TRACK=short`)

The seat is the investigator here. It reads the compiled investigator brief bound to this reading, does the reading itself, and lands the report the brief describes. That keeps the plan's findings attributable to a versioned brief without inventing a dispatch that did not happen.

1. From conversation context and the work item, identify 3-8 key files to read. The shape of the knowledge query is `lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 5`; run it as the recipe with your topic, and read relevant entries:

   **Recipe inputs:** TOPIC, SCALE_SET, LIMIT.
   <!-- spec-recipe: knowledge-search -->
   `lore search "$TOPIC" --type knowledge --scale-set "$SCALE_SET" --json --limit "$LIMIT"`

2. Check the knowledge store index for relevant domain files.
3. Prepare discovery evidence without assigning meaning:

   **Recipe inputs:** SLUG.
   <!-- spec-recipe: spec-discover -->
   ```bash
   DISCOVERY=$(lore spec discover "$SLUG" --json)
   printf '%s\n' "$DISCOVERY"
   ```

   The version-1 result contains `coverage`, `candidates`, and `provenance`. Coverage names every scanned, missing, or unreadable source stratum; candidates retain each source's own rank and score. The verb excludes canonical Lore skill/agent identities structurally, but it never combines rankings or emits `matched`, `binding`, or `applicability` fields.

   The BM25 strata key on a single query seed — the work-item title, unless repeatable `--seed <token>` flags replace it (tokens join into one query; the wholesale tree scans are seed-insensitive and enumerate everything regardless). The seed is the only query-driven input, which is what lets `/implement`'s close re-run this same enumerator with seeds derived from the shipped diff: the two passes miss independently, and a norm the title-seeded pass ranks below the cutoff gets a second chance at close. A descriptive work-item title is what makes the spec-time half of that pair earn its keep.

4. Apply the two discovery judgments yourself:

   - **External skills and agents — strict.** Read plausible external candidates and include only those whose stated domain materially contributes to this implementation. Lore protocol skills remain toolchain, not advisors. Emit `**External skill discovery:**` with the considered set and the matched set; `Matched: none` is valid.
   - **Preferences and conventions — permissive.** Read the surfaced candidates and retain any entry the work might need to honor. Missing a binding preference is worse than carrying an inapplicable candidate into synthesis. Emit `**Preference and convention discovery:**` with coverage counts and the surfaced backlinks; `Surfaced: none` is valid.

   Candidate enumeration is hands work; strict/permissive applicability is head work. Do not ask the verb to collapse that boundary. The complete surfaced set is the audit manifest Step 5 carries into the plan; what each later receiver gets is the applicability judgment described under Recipes and packets.

5. **Bind the reading as an investigation.** Name it with an investigation id of your choosing (one id for the whole reading is the ordinary case; several when the reading has separable questions), and give it the question the reading answers. Build its packet and synthesize it (packet-synthesis recipe) — the brief is handed to a position even when the seat is the one reading it, and the binder refuses to prepare against a candidate set — then compile the investigator for the active framework, bind the attempt against the checkout you are reading, and read the frozen payload — that read is the brief you work from:

   **Recipe inputs:** SLUG, INVESTIGATION_ID, QUERY, SCALE_SET.
   <!-- spec-recipe: investigator-packet -->
   `lore packet build --work-item "$SLUG" --role investigator --caller spec-lead --topic "$INVESTIGATION_ID: $QUERY" --scale-set "$SCALE_SET"`

   **Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, POSITION, TARGET_FRAMEWORK, GUIDANCE_FILE, DESCRIPTOR_FILE.
   <!-- spec-recipe: compile-position -->
   ```bash
   lore dispatch guidance > "$GUIDANCE_FILE"
   bash "$SCRIPTS_DIR/position-compile.sh" "$POSITION" --framework "$TARGET_FRAMEWORK" \
     --kdir "$KNOWLEDGE_DIR" --guidance-file "$GUIDANCE_FILE" > "$DESCRIPTOR_FILE"
   python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["template_version"])' "$DESCRIPTOR_FILE"
   ```

   The printed value is the producer version this attempt's report stamps as `Template-version:`; hold it per attempt as `PRODUCER_TEMPLATE_VERSION`, never substituting this skill's own hash. Then normalize the bindings. `EXECUTION_ROOT` is the absolute physical path of the checkout you read (the inline case, or a fixed placement for a dispatched investigator) or empty for an ordinary session whose host supplies the tree; `REPORT_ID` is filesystem-safe and attempt-specific, fresh on every retry:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, SLUG, PACKET_ID, INVESTIGATION_ID, QUESTION, COMPLEXITY, REPORT_ID, EXECUTION_ROOT, BINDINGS_FILE.
<!-- spec-recipe: investigator-bindings -->
```python
import json, os, sys, uuid
from pathlib import Path
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from packet_builder import pointer
E = os.environ
kdir = Path(E["KNOWLEDGE_DIR"]).resolve()
if E["COMPLEXITY"] not in ("simple", "moderate", "complex"):
    sys.exit("complexity must be simple, moderate or complex")
fields = ("work_item", "task_id", "revision_id", "packet_id", "packet_pointer", "dispatch_attempt_id", "assignment",
          "report_id", "report_path", "execution_root", "mode", "consultation_id", "domain", "reply_destination")
b = dict.fromkeys(fields)
b.update(work_item=E["SLUG"], packet_id=E["PACKET_ID"], packet_pointer=pointer(kdir, E["PACKET_ID"]),
         dispatch_attempt_id="spec-" + uuid.uuid4().hex, report_id=E["REPORT_ID"],
         report_path=str(kdir / "_work" / E["SLUG"] / "worker-reports" / (E["REPORT_ID"] + ".md")),
         execution_root=E["EXECUTION_ROOT"] or None,
         assignment=json.dumps({"investigation_id": E["INVESTIGATION_ID"], "question": E["QUESTION"],
                                "complexity": E["COMPLEXITY"]}, ensure_ascii=False))
reasons = {k: "no-plan-task-assigned" for k in ("task_id", "revision_id")}
reasons.update({k: "not-applicable-to-investigator" for k in ("mode", "consultation_id", "domain", "reply_destination")})
if b["execution_root"] is None:
    reasons["execution_root"] = "the ordinary session host supplies its physical worktree"
b["absence_reasons"] = reasons
Path(E["BINDINGS_FILE"]).write_text(json.dumps(b, indent=2) + "\n")
print(json.dumps({k: b[k] for k in ("dispatch_attempt_id", "report_id", "packet_id", "execution_root")}))
```

   Author the wrapper — this skill's identity, the prefix identity lines, and the suffix note that tells the position what the brief cannot know. `ROUTE` is `inline` (the seat reads the brief itself), `native`, `chaperone` or `session`; the suffix is chosen by the bound position (an investigator gets the collector's note, a planning designer the planning note) and by the route:

**Recipe inputs:** SKILL_FILE, BINDINGS_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, ROUTE, WORK_TITLE, TARGET_FRAMEWORK, PLACEMENT_NOTE.
<!-- spec-recipe: author-wrapper -->
```python
import hashlib, json, os
from pathlib import Path
E = os.environ
skill = Path(E["SKILL_FILE"]).resolve()
sha = hashlib.sha256(skill.read_bytes()).hexdigest()
Path(E["WRAPPER_FILE"]).write_text(json.dumps({"template_id": "spec/skill", "template_version": sha[:12], "path": str(skill), "sha256": sha}))
b = json.loads(Path(E["BINDINGS_FILE"]).read_bytes())
ids = [("Packet-id", b["packet_id"]), ("Report-id", b["report_id"]), ("Revision-id", b["revision_id"]), ("Dispatch-attempt-id", b["dispatch_attempt_id"])]
Path(E["PREFIX_FILE"]).write_text("".join(f"{k}: {v}\n" for k, v in ids if v))
route, slug = E["ROUTE"], b["work_item"]
if route not in ("inline", "native", "chaperone", "session"):
    raise SystemExit("route must be inline, native, chaperone or session")
digest = ("the two environment variables LORE_POSITION_DISPATCH_MANIFEST and LORE_POSITION_DISPATCH_SHA256" if route == "session"
          else "the sha256 you compute over the manifest file the envelope names")
who = "The spec seat for " + E["WORK_TITLE"] + (" reads this brief itself" if route == "inline" else " dispatched you on the " + route + " route")
note = [f"## From the spec seat\n\n{who} for work item {slug}. The identity envelope above is the binder's record of this attempt. "
        "The Packet-id line names a packet built for this move and synthesized before this bind; lore packet show renders the synthesized row, its entries are candidates to check against the code, and when entries were set aside the Left out by synthesis list at its end names each with its reason — if a reason does not hold for what you find in the code, re-pull the entry with lore search. "
        f"Work in position_dispatch.bindings.execution_root and allocate no other tree. {E['PLACEMENT_NOTE']}"]
if b["mode"] == "planning":
    a = json.loads(b["assignment"])
    note.append("You are the designer in planning mode. The assignment (position_dispatch.bindings.assignment, JSON) names the stage (abstract or concrete), the anchor the plan must serve, "
                "the strawman when one was seeded, the landed investigation reports to read (report_paths), the applicable norm manifest (norms_file), the plan destination, and for the concrete stage "
                "the accepted revision (accepted_revision), the immutable plan it names (accepted_plan_path, with accepted_plan_sha256) and the design-gate dispositions copied in as data (dispositions, with dispositions_sha256). "
                "Read the reports at their paths and the accepted plan at its path; a packet carries neither, and the destination plan.md is what you write, not the accepted input you read. Write into the destination plan only the sections your stage owns: "
                "Goal, Narrative, Intent Anchor (the anchor verbatim with its Scope delta line, because publication runs the anchor verifier), Design Decisions and Architecture Diagram for abstract; "
                "Tasks with Verification and sizing rationale, Knowledge context and Retrieval directives for concrete, preserving the Intent Anchor section and adding its Tempting narrower implementation line. "
                f"Publish through lore plan revise {slug} --author-role designer --reason naming what changed --json and hold the returned revision_id. "
                f"Tier 2 rows you append go through evidence-append.sh --work-item {slug} with producer_role spec-lead and the position_dispatch pair copied from your envelope. "
                "Then land a design record at position_dispatch.bindings.report_path through lore coordinate report: first the lines Template-version (position_dispatch.producer.template_version), "
                f"Position-dispatch-manifest (the envelope's manifest_path) and Position-dispatch-sha256 ({digest}), then **Revision:** with the published id, **Decisions:** naming each decision and its reason, "
                "**Open questions:** with what would close each, and **Tier 2 evidence:** as a YAML list of claim ids or the word none. You implement no source and accept nothing; the seat reads the revision at its gate.")
else:
    note.append("You are the investigator. Your question is position_dispatch.bindings.assignment, a JSON object with investigation_id, question and complexity; the question is the scope, and a finding outside it goes under Worker leads or Unknowns. "
                "No Revision-id line means no plan revision exists yet; say so under Unknowns where it matters instead of inferring a task or revision. "
                "Write the report in the investigator shape docs/position-report-contracts.md names: Question, Findings, Key files, Implications, Assertions, Observations, optional Narrative, Worker leads, Unknowns. "
                f"Directly after the **Question:** line add three header lines, plain, one per line: Template-version (position_dispatch.producer.template_version), Position-dispatch-manifest (the envelope's manifest_path), Position-dispatch-sha256 ({digest}). "
                "Key files is a YAML list of existing absolute paths with no :line suffix; each grounded assertion carries claim, file, line_range, exact_snippet, normalized_snippet_hash, falsifier and a significance of low, medium or high, with file relative to the execution root and captured_at_sha naming a commit that holds the snippet at that range. "
                f"An assertion you append yourself goes through evidence-append.sh --work-item {slug} with producer_role researcher, task_id set to your investigation_id, report_id and dispatch_attempt_id copied from the envelope, and the position_dispatch pair; then list its claim_id in the report so the collector does not write it twice.")
    if route == "inline":
        note.append("The seat lands the report itself through lore coordinate report under the bound report id, appends the remaining assertions canonically, and runs the completion check that reads the headers against the reference it holds.")
    elif route == "session":
        note.append(f"Land the report yourself with printf '%s' \"$REPORT\" | lore coordinate report {slug} --report-id {b['report_id']}; exit 4 means the id was used before and is recorded under Unknowns, exit 1 means the call was wrong. Then stop and wait; the seat runs the completion check against its own reference and closes the session after collection.")
    else:
        note.append("Return the complete report as your final message and stop. The collector lands it at the assigned destination, appends the remaining assertions canonically, and only then runs the completion check; a task tool marked complete before the report is landed leaves the check reading an empty destination.")
Path(E["SUFFIX_FILE"]).write_text("\n\n".join(note) + "\n")
```

   Bind. This freezes payload, manifest and native definition under `position-dispatch/<attempt-id>/` and returns the six-field reference (`manifest_path`, `manifest_sha256`, `payload_path`, `payload_sha256`, `native_path`, `native_sha256`) — your independent copy of the attempt's identity, held per attempt and never read back from a report. `REQUIRED_BINDINGS` is `packet_id packet_pointer` for an investigator or designer; `NATIVE_MODEL` is set only on a native route. An identical retry returns the same reference; a changed payload under the same attempt refuses; a real retry mints a fresh attempt and report id:

   **Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DESCRIPTOR_FILE, BINDINGS_FILE, GUIDANCE_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, REQUIRED_BINDINGS, NATIVE_MODEL.
   <!-- spec-recipe: bind-attempt -->
   ```bash
   args=(--descriptor "$DESCRIPTOR_FILE" --bindings "$BINDINGS_FILE" --kdir "$KNOWLEDGE_DIR" --guidance-file "$GUIDANCE_FILE"
         --wrapper "$WRAPPER_FILE" --prefix-file "$PREFIX_FILE" --suffix-file "$SUFFIX_FILE")
   for field in $REQUIRED_BINDINGS; do args+=(--require "$field"); done
   [[ -n "$NATIVE_MODEL" ]] && args+=(--native-model "$NATIVE_MODEL")
   python3 "$SCRIPTS_DIR/position-bind.py" bind "${args[@]}"
   ```

   Read the frozen payload — the brief you work from, exactly as a dispatched investigator would receive it:

   **Recipe inputs:** REFERENCE_FILE.
   <!-- spec-recipe: read-payload -->
   `cat "$(jq -er '.payload_path' "$REFERENCE_FILE")"`

6. Read the files yourself — do NOT spawn subagents. Note key findings as you go.
   - **Current-state verification (mandatory before a finding becomes a design constraint):** when a design choice hinges on a current-state claim sourced from a sibling work item's `notes.md` or other uncommitted prose (not committed code or a commons entry), verify the claim against HEAD before adopting it. Notes age faster than code; a stale note silently shapes scope.
   - **Integration-seam trace:** when the work adds a field to a shared substrate (e.g., `_meta.json`) or inserts a script into an existing control-flow gate, trace three seams before drafting: (a) does an existing gate/guard intercept the new state? (b) does the denormalized read model (e.g., `_index.json`) project the field, or is it invisible to consumers? (c) does ordering (archive/move) change where a later step finds the file?
   - Each packet entry that meets code gets its verify event as you go (Step 5 item 5 names the recipes, with `VERIFY_SOURCE=investigator` while you read in this position).

7. Write the investigator-shaped report the brief describes — Question, the three identity headers, Findings, Key files, Implications, Assertions, Observations, Worker leads, Unknowns — and collect it through Step 3 exactly as a dispatched report: land it, check its identity against the reference you hold, append its assertions under `producer_role: researcher` with the pair, and run the typed completion check. `None` is a complete value under Assertions and Observations; the report records what the reading found, not a quota.

8. Present a context summary and offer the strategy gate (Step 4 below). **If `--yes`, skip the strategy prompt.**

### Step 2b: Full branch (`TRACK=full`)

1. From the feature description, identify 3-7 focused investigation questions. Each should target a specific codebase concern, be answerable by exploring files, and be independent enough to run in parallel.
2. Always include two mandatory fixed investigations (both count toward the 3-7 total):

   a. **External skill and agent applicability (strict)** — which installed *external* (non-lore) skills and agent templates should be invoked during **implementation** of this work item. Lore-managed skills (`/spec`, `/implement`, `/work`, `/memory`, `/remember`, `/retro`, `/evolve`, `/renormalize`, `/bootstrap`, `/pr-*`, `/codex-*`) are **excluded** — protocol toolchain, not advisors. The investigator filters them out before reporting matches. Key files: `<skills_dir>/*/SKILL.md`, `<agents_dir>/*.md` (resolve via `resolve_harness_install_path skills` / `resolve_harness_install_path agents`); exclusion list comes from the canonical Lore source repo (`source "$SCRIPTS_DIR/lib.sh" && printf '%s\n' "$LORE_REPO_DIR"` + `/skills/` and `/agents/`). Do not use `resolve-repo.sh` here — it returns the project's knowledge store, not the Lore source tree. Match criterion is **strict** — include only skills whose stated domain plausibly contributes to *this* work item's implementation.

   b. **Preferences and conventions applicability (permissive)** — which entries from `preferences/`, `conventions/`, and `cross-cutting-conventions/` the work might need to honor. **Inclusion criterion is permissive — the inverse of skill discovery.** The test is "is it *possible* the work might need this" — not "will we definitely apply it." Err on over-inclusion; synthesis culls. Missing an applicable preference is worse than carrying an inapplicable one through review. Key files: `$KDIR/preferences/`, `$KDIR/conventions/`, `$KDIR/cross-cutting-conventions/` (full enumeration; absent = zero) plus BM25 through the knowledge-search recipe at `subsystem,implementation` with limit 10 and at `abstract,architecture` with limit 5.
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
7. Prepare discovery evidence with the spec-discover recipe, then make the applicability decisions in seat prose. Use the returned `coverage` to see what was scanned or missing. Choose strict external-skill/agent matches and permissive preference/convention candidates yourself. Record matched external skills in `$SKILL_INVOCATION_MAP`; invoke them inline when an investigator consults that domain. `/spec` spawns no advisor agents on the default route.

8. Serialize the approved investigation plan to a JSON file and hold its path as `$INVESTIGATIONS_JSON`. The version-1 contract is exact — unknown or missing fields refuse, array order is dispatch order, and every prefetch row declares its scale rather than inheriting a default:

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

   Exactly one fixed external-skill/agent question and one fixed preference/convention question are mandatory. The seat owns every question, complexity label, prefetch query, and scale declaration; the verb validates but never invents them.

   Each investigation is dispatched to the compiled investigator brief (`agents/positions/investigator.md`, compiled for its target framework). The document's `template` field, which selects the legacy `agents/researcher.md` template for a whole wave, remains accepted by `open` for reproducing an earlier wave; it is not part of this workflow and its assembly is not described here.

   A per-investigation `dispatch` object has exactly `framework`, `route`, `model`, and `bindings`. `framework` is `codex`, `claude-code`, or `opencode`; `route` is `native` or `session`; `model` is the already-resolved native binding for that framework, checked through the same route resolver `open` uses, so a model string that belongs to a different framework refuses instead of being reinterpreted. `bindings` is the complete binder envelope: its `assignment` encodes exactly this investigation's `investigation_id`, `question`, and `complexity`; its `work_item` is this slug; its `report_path` is the coordinate-report destination `worker-reports/<report_id>.md`; its `packet_id` and `packet_pointer` name a packet that already exists for this work item with the investigator as recipient (the investigator-packet recipe builds one before a plan exists), because the binder checks supplied bindings against the canonical packet rather than building one for them. `execution_root` has two admitted shapes: a path names a fixed placement that `open` publishes against and the host later requires; on `"route": "session"` it may be `null` with a nonempty `absence_reasons.execution_root`, the ordinary case where the session host allocates the worktree, and `open` then admits the preparation and leaves publication to the host.

   **The default route is an ordinary session with a pending root.** Without a `dispatch` object, `open` supplies its own default — the researcher role's native binding for the active framework, a native route, and freshly minted identities — and that CLI default is unchanged. This workflow declares the session explicitly for every investigation, because a host-allocated worktree is the placement every framework supports and the payload then freezes against the real directory rather than the seat's. Native remains available: declare `"route": "native"` (or omit `dispatch`) for an investigation when the readiness check in item 10 is expected to pass, and let the check decide. Resolve the researcher model under the target framework, build one investigator packet per investigation (investigator-packet recipe) and synthesize it (packet-synthesis recipe — `open` checks supplied bindings against the canonical packet as a preparation and refuses a candidate set; the waiver it records covers only the packets it builds itself), write one bindings file per investigation with an empty `EXECUTION_ROOT`, then compose the declared document from your draft (the same JSON as above without `dispatch` objects) and the bindings directory, where each file is named `<investigation_id>.json`.

   The model is resolved by the target framework's adapter with `LORE_FRAMEWORK` set to that framework for the call, because each adapter refuses to run under another active framework and the shared resolver reads the active framework from that variable; a Claude seat resolving a Codex target this way gets the Codex role binding, where resolving under the active framework would hand the Codex dispatch a Claude binding — one `open` refuses when the binding names its framework (`claude-code/<model>`), and one that otherwise reaches the launch as a model the target never resolved. `ROLE` is `researcher` for an investigator and `advisor` for a designer, `CEREMONY` is `spec`, and the printed binding is carried unchanged into declare-dispatch as `MODEL`:

   **Recipe inputs:** SCRIPTS_DIR, TARGET_FRAMEWORK, ROLE, CEREMONY.
   <!-- spec-recipe: resolve-role-model -->
   ```bash
   source "$SCRIPTS_DIR/lib.sh"
   LORE_FRAMEWORK="$TARGET_FRAMEWORK" bash "$LORE_REPO_DIR/adapters/agents/$TARGET_FRAMEWORK.sh" resolve_model_for_role "$ROLE" "$CEREMONY"
   ```

**Recipe inputs:** INVESTIGATIONS_DRAFT, BINDINGS_DIR, TARGET_FRAMEWORK, MODEL, INVESTIGATIONS_JSON.
<!-- spec-recipe: declare-dispatch -->
```python
import json, os, sys
from pathlib import Path
E = os.environ
document = json.loads(Path(E["INVESTIGATIONS_DRAFT"]).read_bytes())
bindings_dir = Path(E["BINDINGS_DIR"]) if E["BINDINGS_DIR"] else None
for inv in document["investigations"]:
    if "dispatch" in inv:
        sys.exit("the draft must not carry dispatch objects; this recipe declares them")
    if bindings_dir is None:
        continue
    path = bindings_dir / (inv["id"] + ".json")
    if not path.is_file():
        sys.exit("no bindings for investigation " + inv["id"] + "; write one with investigator-bindings or leave BINDINGS_DIR empty for open's native default")
    b = json.loads(path.read_bytes())
    if json.loads(b["assignment"]) != {"investigation_id": inv["id"], "question": inv["question"], "complexity": inv["complexity"]}:
        sys.exit("bindings assignment differs from the declared investigation " + inv["id"])
    inv["dispatch"] = {"framework": E["TARGET_FRAMEWORK"], "route": "session", "model": E["MODEL"], "bindings": b}
Path(E["INVESTIGATIONS_JSON"]).write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"investigations": len(document["investigations"]), "declared_sessions": sum("dispatch" in i for i in document["investigations"])}))
```

   Supplying bindings is also how a retry names fresh attempt and report identities. Two route facts are declared here rather than discovered at launch. A native route on a framework other than the active one is supported only toward `codex`, where it becomes the chaperone route in item 10. Native subagent selection on `opencode` is unavailable under its current plugin, so an `opencode` investigation is declared `"route": "session"`; a native declaration there makes `open` refuse the wave before publication with the adapter's diagnostic. The route written into the manifest is the record of the choice, and nothing downstream substitutes another.

9. Open the reusable dispatch artifact from the checkout the investigators should read — `open` records its working directory as the execution root against which fixed-placement snippets and line ranges are later checked:

   **Recipe inputs:** SLUG, INVESTIGATIONS_JSON.
   <!-- spec-recipe: spec-open -->
   ```bash
   DISPATCH=$(lore spec open "$SLUG" --investigations "$INVESTIGATIONS_JSON" --json)
   printf '%s\n' "$DISPATCH"
   ```

   `open` returns `created | reused | recovered | replaced`, or refuses with the repair target. Its canonical `spec-dispatch.json` carries `input_fingerprint`, `source_fingerprint`, the source manifest, ordered directives, empty lead-side handle slots, and teardown payloads. It never calls a harness tool and never persists live handles.

   `open` also renders and validates `lore dispatch guidance` before publication or deterministic replay. A rendering failure refuses the whole dispatch wave before any investigator launches, and replay is eligible only while the stable guidance identity remains current. Each directive carries the admitted block in `payload.dispatch_guidance`, with that identity in the source fingerprint.

   On the compiled path `open` does the binding work before it publishes, one investigation at a time: it builds or checks the canonical packet (session-scoped, with no revision, because no plan exists yet; the dispatch attempt is recorded on the manifest, not on the packet), mints or checks a dispatch attempt and a report id, and freezes one immutable payload under `position-dispatch/<attempt-id>/` through the sole binder. The one exception is a declared session whose `execution_root` is `null`: `open` validates the same compilation, bindings, packet, and wrapper text and stops short of publishing, since a payload cannot be frozen without the directory it names. `payload.publication_state` records which happened, `prepared` or `pending-execution-root`. The directive's `payload` is the complete record of what the investigator receives and how the attempt is identified, with the fields a pending directive cannot yet have set to `null` rather than filled in:

   - `prompt` — the exact frozen bytes: the admitted guidance, the packet pointer, the `Packet-id:` / `Report-id:` / `Dispatch-attempt-id:` lines (and `Revision-id:` only when a revision is bound), the compiled body on prompt-text frameworks, the JSON identity envelope, and the collector's note. Send these bytes unchanged; the digest recorded for them is what a later reader checks. `null` while pending: the bytes do not exist until the host publishes them.
   - `position_dispatch` — the six-field reference the binder returned. Hold it in memory per directive. The payload carries the manifest path but cannot carry the manifest's own digest, so this returned digest is the collector's independent copy: the report's `Position-dispatch-sha256` header is checked against it and never read from it. `null` while pending; the collector obtains the same six fields after host publication (Step 3 item 4).
   - `producer` — the compiled investigator's `template_id` and `template_version`. Hold the version as `$PRODUCER_TEMPLATE_VERSION` for that directive; it is what the investigator stamps into `Template-version:` and what every capture or log line the collector writes on that report's behalf carries. `source_manifest.researcher_template_version` records the legacy template's version for readers of the wave record; it is not the producer of a compiled report.
   - `route`, `framework`, `model` — the resolved route (`native`, `session`, or `codex-chaperone` when a native request crossed to Codex), the target framework, and the exact model to pass. Resolve none of these a second time after publication: the payload bytes were frozen against them, and a re-resolution that disagreed would make the executed dispatch differ from the artifact being replayed.
   - `native_selection` — on native routes, the adapter's frozen selection: the native tool name, the fields it takes beside the prompt, which field carries the prompt, any registration file, and the readiness observation owed before selecting. `null` on session and chaperone routes.
   - `completion_input` — `position_dispatch` plus `lore_task_id` (`null` before a plan exists). This is the object Step 3 hands to the completion check; it is assigned here so that no value in it ever comes from the report. `null` while pending; the session-reference recipe returns the same object once the host has published, computed from the published bundle and never from the report.
   - `session_context` — the object `lore session request --context` reads. On a `prepared` session it is `dispatch_guidance` (the frozen prompt) and `position_dispatch`. On a pending one it is a single `position_preparation` object: the position, framework, packet id, full bindings, compiler descriptor, the admitted guidance text, a retained `activation` snapshot of the native launch inputs, a `composition` holding the wrapper identity, its retained source text, and the exact prefix and suffix bytes, and a `slug` left `null`, so the request's `--slug` supplies the session identity and has to name this work item. The composition is retained text, not an instruction to reread `spec-open.sh` at launch, so the host publishes what `open` admitted even when that script has changed since. At launch the host renders the activation again and refuses a rendering that disagrees with the snapshot; at collection `session-reference` compares the snapshot to the published `launch.json` without rendering anything. Write this object to a file and keep the file; the collector reads the final reference through it in Step 3.
   - `bindings` — the validated envelope, including `absence_reasons` naming why `task_id` and `revision_id` are null on a pre-plan investigation and, on a pending session, why `execution_root` is. Absence with a reason is a legible state; do not fill it in.
   - `wrapper_template_version` — a 12-hex digest of the `spec-open.sh` bytes that composed the wave, recorded apart from `lead_template_version` (this skill's version) and from `producer.template_version`, so each of the three texts stays attributable on its own.

   `directive.adapter` names the target framework's adapter script, which differs from the active framework's when a `dispatch.framework` was declared. Extract what a launch and its collection need from one directive:

**Recipe inputs:** DISPATCH_JSON, INVESTIGATION_ID, CONTEXT_FILE, REFERENCE_FILE.
<!-- spec-recipe: directive-context -->
```python
import json, os, sys
from pathlib import Path
E = os.environ
data = json.loads(Path(E["DISPATCH_JSON"]).read_bytes())
artifact = data.get("artifact", data)
directive = next((d for d in artifact["directives"] if d["payload"]["investigation_id"] == E["INVESTIGATION_ID"]), None)
if directive is None:
    sys.exit("investigation not in this dispatch: " + E["INVESTIGATION_ID"])
p = directive["payload"]
Path(E["CONTEXT_FILE"]).write_text(json.dumps(p["session_context"]) + "\n")
reference = None
if p.get("position_dispatch"):
    reference = {"reference": p["position_dispatch"], "completion_input": p["completion_input"]}
Path(E["REFERENCE_FILE"]).write_text(json.dumps(reference) + "\n")
print(json.dumps({"ordinal": directive["ordinal"], "route": p["route"], "framework": p["framework"], "model": p["model"],
                  "publication_state": p["publication_state"], "producer_template_version": p["producer"]["template_version"],
                  "report_id": p["bindings"]["report_id"], "dispatch_attempt_id": p["bindings"]["dispatch_attempt_id"],
                  "adapter": directive["adapter"], "teardown": directive["teardown_payload"]}))
```

   `REFERENCE_FILE` holds `null` for a pending directive until the session-reference recipe fills the same shape after host publication.

10. Execute the returned directives in ordinal order. This is the harness-dispatch judgment kernel: `open` prepared each launch and recorded its identity; deciding when to launch, making the native call, and holding the returned handles in the seat's in-memory handle map are yours. Store handles only there, populate the matching teardown payload with the live handle at shutdown time, and do not write handles back into `spec-dispatch.json`.

    The bytes an investigator receives are `payload.prompt`, exactly. The guidance floor is already the first component of those bytes, admitted when `open` ran, so nothing is rerendered or prepended at launch; a launch that edits, re-renders, or supplements the prompt breaks the digest a later reader checks against `payload_sha256`. A missing block or a failed adapter admission ends before the native spawn.

    Route by `payload.route` and `payload.framework`:

    - **Native, Claude Code** (`native_selection.tool` is `Agent`). The compiled definition has to exist under a name the running session's agent inventory offers before it can be selected, and the binder owns that file. `AGENTS_SCOPE` is an absolute, physically resolved `.claude/agents` directory the running session already watches (`resolve_harness_install_path agents` names the user-level one); on Codex leave it empty, because Codex consumes prepared text directly and nothing is registered:

      **Recipe inputs:** SCRIPTS_DIR, MANIFEST_PATH, MANIFEST_SHA256, AGENTS_SCOPE.
      <!-- spec-recipe: native-input -->
      ```bash
      if [[ -n "$AGENTS_SCOPE" ]]; then
        python3 "$SCRIPTS_DIR/position-bind.py" register-native "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE" >&2
        python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
      else
        python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256"
      fi
      ```

      The registration file is named by the selection name — `lore-position-` plus a digest over the compiled definition, the attempt, and the model — so two models on one compiled version register under two names and an identical retry finds its identical file. `native-input` returns `tool`, `tool_input` (`subagent_type`, `model`, and `prompt` filled with the exact payload), and `readiness: {kind: native-agent-inventory, selection_name}`. Before the call, check that `selection_name` is among the `subagent_type` values the live `Agent` tool offers. A file on disk is not that check: a shell cannot see which directories the session watched at startup or whether a higher-precedence definition shadows the name, and a definition written into a directory the session never watched is not loaded. When the name is absent, the directive stays undispatched on this route and the wave's record names the readiness boundary; selecting a generic agent type instead would attribute the report to text the investigator never read, so the investigation is retried as a declared session under fresh identities. Then call `Agent` with `subagent_type`, `model`, and `prompt` from `tool_input`, plus the tool's own required `description` and whatever team, name, or background fields the live schema asks for. Do not rename `prompt`, drop `model`, alter the prompt bytes, or add a parameter for the manifest digest; the child reads the manifest path from its payload and computes the digest itself.

    - **Native, Codex** (`native_selection.tool` is `spawn_agent`). Run the native-input recipe with an empty `AGENTS_SCOPE`. `tool_input` carries the split model and effort keys plus `message` filled with the exact payload, and `readiness` is `{kind: native-tool-schema, tool: spawn_agent}`: the check owed is that the tool exposed in your session accepts those fields. Supplement only the caller fields the live schema requires — a `task_name`, non-inheriting fork settings — and pass everything else as returned. A model or effort value the tool rejects is reported as rejected, not dropped.

    - **Native, OpenCode.** Not reachable here: `open` refuses the wave before publication because the adapter has no native selection under the current plugin. Declare `"route": "session"` for the OpenCode investigation and open the wave again.

    - **Chaperone** (`route` is `codex-chaperone`, set when a native request named `codex` from a different active framework). Dispatch through the existing Codex chaperone route: the chaperone receives `payload.model` through the adapter's model splitting and `payload.prompt` as the exact Codex prompt, and it relays what Codex returned. Tell it the return shape is the investigator report — Question, Findings, Key files, Implications, Assertions, Observations, Worker leads, Unknowns — so it relays the body verbatim rather than gating it on worker labels. A relay reshaped into worker fields would replace the finding with a claim the investigator never made.

    - **Session** (`route` is `session`). The context file written by the directive-context recipe is what the request carries; keep it. `SESSION_SLUG` is the derived `<slug>--w<n>`; the report still belongs to the base work item. Enqueue with exactly one placement stance (`TARGET_INSTANCE` names one live instance, otherwise any instance may claim), with `MODEL` and `TARGET_FRAMEWORK` named explicitly from the payload, and with the worktree pair only under fixed placement:

      **Recipe inputs:** SESSION_SLUG, TARGET_FRAMEWORK, MODEL, CONTEXT_FILE, TARGET_INSTANCE, MIN_VINTAGE, WORKTREE_ID, EXECUTION_DIR.
      <!-- spec-recipe: request-session -->
      ```bash
      args=(--type worker --slug "$SESSION_SLUG" --framework "$TARGET_FRAMEWORK" --model "$MODEL"
            --context "$CONTEXT_FILE" --initiator agent --json)
      if [[ -n "$TARGET_INSTANCE" ]]; then args+=(--target "$TARGET_INSTANCE"); else args+=(--anywhere); fi
      [[ -n "$MIN_VINTAGE" ]] && args+=(--min-vintage "$MIN_VINTAGE")
      [[ -n "$WORKTREE_ID" ]] && args+=(--worktree-id "$WORKTREE_ID" --execution-dir "$EXECUTION_DIR")
      lore session request "${args[@]}"
      ```

      The same recipe serves both publication states, and the worktree pair follows the state. A `prepared` context carries a published reference whose payload was frozen against `bindings.execution_root`, so a manager that holds that fixed placement passes the pair with that exact directory; the host revalidates the reference against the directory it actually launches in and refuses any other, because a payload cannot be re-rooted once its digest is recorded. A `pending-execution-root` context is enqueued with an empty pair: the request admits the preparation and refuses an `--execution-dir`, since the root is the host's to supply. Either way the slugged request derives its required project directory from the work item's declared source checkout, which fixes which instance may claim the row and not the directory the child runs in; a session-hosted seat seeds that declaration once with `lore work source-checkout <slug>` from its own provenance, and the request is refused with that remedy until it exists. The placement stance is checked before anything is derived from the slug, because an unstated stance used to mean silently unplaced; the derived required project directory is the stronger axis and still governs the claim, so `--anywhere` on a slugged request does not widen where the session may run. Do not add `--position`: the context is already admitted position preparation or a published reference, and `--position` would read it as new generic bindings, which carry no spec wrapper, prefix, or collector's note and would drop that text and its attribution. A pre-plan investigator session is admitted with `task_id` and `revision_id` explicitly absent, because the position-aware requirements ask an investigator session for a packet id and pointer, not a plan task. At launch the host calls the same sole binder: on a pending context it publishes the admitted compilation, bindings, and retained wrapper text against the worktree it allocated, and on a prepared one it verifies the reference and the exact root; a publication or activation failure there returns an error before the process spawns, and the diagnostic is what to read, not a reason to pick another route. Publication records prepared input and nothing more; whether the process launched, and whether a report comes back, are read from the session's own lifecycle and from Step 3.

    `team_messaging != full` removes only shared team state. Codex still executes investigator fanout while `subagents=partial`, then its adapter teardown resolves to lead-mediated `TaskUpdate status=completed`. Collapse to the short branch only when `subagents=none`, and say so in the plan. On a full team-messaging harness, the seat may create the shared team before executing spawn directives and tear it down after investigator completion.

---

### Step 3: Collect findings and emit Tier-2 artifacts

As investigator reports arrive, or when the seat's own inline report is written in short mode:

1. Write each finding to the `## Investigations` section of `plan.md` using the investigation entry format from the Plan.md Template below. Both modes use `## Investigations`; short mode may add a `## Context` summary of the local reading beside it, never instead of it.
2. **Preserve `**Findings:**` verbatim** — copy findings exactly as reported. When Findings say the question's premise did not hold, that sentence is the finding: it goes in as written and shapes synthesis, and re-asking the question in narrower words would replace the finding with the answer the plan expected.
3. **Preserve `**Observations:**` verbatim** — copy investigator observations exactly as reported. Do not rephrase, merge, or summarize. These are mechanism-level patterns, design rationale, and structural footprint signals that feed the Step 5.4 capture step. `None` is a complete value on the compiled path; there is no observation count to reach.
4. **Land the report before anything reads it.** The report is evidence of record only as the file the sole writer lands at the destination assigned at dispatch; the message, tool result, or transcript that carried it is transport. Land its content unchanged, under the report id from the attempt's bindings; the writer reads the body through a command substitution, which drops trailing newlines, and appends exactly one, so the landed file is the report's content and not a byte-for-byte copy of the transport, and the header and identity checks below read content, not trailing bytes. A session lands its own report at the bound path; validate that file rather than re-copying the relay:

   **Recipe inputs:** SLUG, REPORT_ID, REPORT_BODY_FILE.
   <!-- spec-recipe: land-report -->
   `lore coordinate report "$SLUG" --report-id "$REPORT_ID" < "$REPORT_BODY_FILE"`

   The writer is write-once — an existing path refuses with exit 4 — so a retry never overwrites the report that came back. It validates destination and bytes, not shape, so an investigator-shaped body lands through it exactly as a worker report does. A report whose headers turn out not to match this attempt is landed first all the same; it is the record of what came back, and the mismatch is caught below.

   On a directive that `open` left `pending-execution-root`, the seat holds no reference yet: the host publishes the payload at launch. Read that publication independently, from the context file retained at enqueue:

   **Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, CONTEXT_FILE.
   <!-- spec-recipe: session-reference -->
   `python3 "$SCRIPTS_DIR/position-bind.py" session-reference --kdir "$KNOWLEDGE_DIR" < "$CONTEXT_FILE"`

   It exits nonzero whenever it cannot return a validated reference, and its diagnostic says which situation that is: no manifest exists yet for the attempt, which is what an unlaunched or refused session looks like from here, or a bundle exists and fails a check, which a store made inaccessible or a bundle damaged after a real launch also produces. Nonzero therefore establishes that the collector holds no independent reference, and nothing about whether the session launched; launch and error state are read from the session's own lifecycle, not inferred from this exit. On success it returns `reference` (the same six manifest, payload, and native fields a prepared directive carries), `completion_input`, the actual `bindings` including the host's root, `producer`, `publication_state: prepared`, and `delivery_proven: false`. Write that output to the directive's `REFERENCE_FILE`. The command checks the published bundle against the admitted preparation and reads nothing from the report. A report that arrives while the command still exits nonzero is landed all the same, and the investigation stays unaccepted with the command's diagnostic and the lifecycle evidence recorded beside it: without a validated reference there is nothing to check the report's headers against. Repair what the diagnostic names when it is repairable and run the command again; where it is not, the directive is retried under fresh identities. `delivery_proven: false` is literal: the reference establishes what was prepared, and only the landed report and the completion check say what came back.

   Then check the report's identity against what you hold, not against the report. `REFERENCE_FILE` is the six-field reference from the bind-attempt recipe, or the session-reference output, or the directive-context output for a prepared directive; the recipe reads whichever shape it is given:

**Recipe inputs:** REPORT_PATH, REFERENCE_FILE.
<!-- spec-recipe: check-identity -->
```python
import hashlib, json, os, sys
from pathlib import Path
ref = json.load(open(os.environ["REFERENCE_FILE"]))
ref = ref.get("reference", ref)
manifest = Path(ref["manifest_path"])
raw = manifest.read_bytes()
if hashlib.sha256(raw).hexdigest() != ref["manifest_sha256"]:
    sys.exit("held reference does not match the manifest bytes; do not read this report against it")
producer = json.loads(raw)["producer"]["template_version"]
headers = dict(l.split(": ", 1) for l in Path(os.environ["REPORT_PATH"]).read_text().splitlines()[:16] if ": " in l)
want = {"Template-version": producer, "Position-dispatch-manifest": str(manifest), "Position-dispatch-sha256": ref["manifest_sha256"]}
bad = [k for k, v in want.items() if headers.get(k) != v]
sys.exit("report answers another input; re-dispatch under fresh ids. mismatched: " + ", ".join(bad) if bad else 0)
```

   The child computed its digest by reading the manifest its payload named; the seat's copy came back from the binder at publication, or from `session-reference` reading that publication. Agreement means the report answers this attempt. Disagreement means it answers some other input, and the directive is retried under fresh attempt and report identities (Step 2b item 8, explicit `dispatch.bindings`).

5. **Emit Tier-2 artifacts** — for each grounded investigator assertion, in both modes:
   - Format the claim as a JSON row with the evidence fields (`claim`, `file`, `line_range`, `exact_snippet`, `normalized_snippet_hash`, `falsifier`, `significance`) plus producer/template provenance and `change_context` (`diff_ref`, `changed_files[]`, `summary`). `changed_files[]` must include the row's `file`; `summary` should name why the current investigation made the claim relevant. `exact_snippet` and `normalized_snippet_hash` are REQUIRED for every row: `exact_snippet` is the verbatim content at `file:line_range` that grounds the claim, and `normalized_snippet_hash` is the sha256 hex of the v1-normalized snippet. Compute the hash via the canonical helper — the normalization recipe lives only in `scripts/snippet_normalize.py` and is never inlined here. See `architecture/artifacts/tier2-evidence-schema.md` for the full schema and `scripts/validate-tier2.sh` for the canonical required-field set:

     **Recipe inputs:** SCRIPTS_DIR, SNIPPET.
     <!-- spec-recipe: snippet-hash -->
     `python3 "$SCRIPTS_DIR/snippet_normalize.py" --hash <<<"$SNIPPET"`

   - Producer vocabulary at this writer is legacy: `producer_role` is `researcher` for every compiled investigator's assertion — the dispatched investigator and the seat reading inline in Step 2a alike — because the validator's accepted set was not widened when the position was named and the completion check matches assertions to rows under that role. `template_version` is `$PRODUCER_TEMPLATE_VERSION` for that attempt. Rows the seat authors in its own voice at synthesis (Step 5) carry `spec-lead`; the two never mix on one row. `task_id` follows the attempt's bindings, not the prose around them: before a plan exists the row has no plan task, so `task_id` carries the investigation id, and the row also carries `report_id` and `dispatch_attempt_id` from the bindings, which is what lets the completion check match a grounded assertion to this attempt rather than to an identical assertion from an earlier one. The check binds a pre-plan row by those two ids and does not compare its task label; the investigation id there is the protocol's requirement, so a wrong label is an authoring defect the seat's read catches, not the check. When bindings bind `task_id` (together with `revision_id`; the check requires both bound or both absent), the row carries that task id. The row also carries the attempt's manifest pair, as one optional object copied from the reference you hold and never from the report: `"position_dispatch": {"manifest_path": <retained manifest_path>, "manifest_sha256": <retained manifest_sha256>}`. The writer resolves it against the immutable manifest and checks that the manifest binds this work item and the row's `report_id` and `dispatch_attempt_id`; a pair that does not resolve stores the row with unknown attribution and its reason, and a row without the pair is a legacy row. The shape and the copy rule are in `docs/position-report-contracts.md` § The dispatch reference on Tier 2 rows.
   - An investigator may have appended some of its own assertions under the same `researcher` vocabulary and pair; each such assertion lists its `claim_id` in the report. Append only the assertions that carry no `claim_id`, so no canonical row is written twice for one claim.
   - Append the row via the sole writer:

     **Recipe inputs:** SCRIPTS_DIR, SLUG, ROW_FILE.
     <!-- spec-recipe: append-tier2 -->
     `bash "$SCRIPTS_DIR/evidence-append.sh" --file "$ROW_FILE" --work-item "$SLUG"`

     `evidence-append.sh` is the sole writer of `$KDIR/_work/<slug>/task-claims.jsonl`; it rejects missing snippets and invalid or mismatched normalized hashes. On rejection, fix and retry the row or log the failure to `execution-log.md`. Never write the JSONL directly — direct writes bypass validation and are treated as corrupt. A rejected row leaves no canonical row, and the completion check below then reports that assertion as ungrounded; the failure surfaces where it can be read, which is the reason not to type a row around it.
   - After successful append, write a human-readable mirror entry to `$KDIR/_work/<slug>/evidence.md`. Do not write a mirror entry for a row that failed validation.
   - **Absence semantics:** if no assertions exist, both `task-claims.jsonl` and `evidence.md` may be absent — absence means "no Tier-2 claims captured this session," not "work was fully verified." An investigator report with `None` under Assertions creates no row and no mirror.

6. **Run the typed completion check** on every compiled investigator report, dispatched or inline, after the report is landed and its assertions are canonical. `REFERENCE_FILE` is the same file the identity check read; `TASK_ID` is empty before a plan exists and is the bound task otherwise:

**Recipe inputs:** SCRIPTS_DIR, REFERENCE_FILE, TASK_ID.
<!-- spec-recipe: typed-completion -->
```bash
python3 - "$REFERENCE_FILE" "$TASK_ID" <<'PY' | bash "$SCRIPTS_DIR/task-completed-capture-check.sh"
import json, sys
ref = json.load(open(sys.argv[1]))
completion = ref.get("completion_input") or {"position_dispatch": ref.get("reference", ref), "lore_task_id": sys.argv[2] or None}
print(json.dumps(completion))
PY
```

   The completion input is the directive's `payload.completion_input`, or the `completion_input` that `session-reference` returned, or the bound reference with the task explicitly absent for an inline attempt. Either way it was computed from the published bundle, and no member of it came from the report. Exit 0 means the landed report carries the assigned identity headers, every label the investigator contract requires, Key files whose listed paths are existing absolute files (`None`, `none` and an empty list are accepted, as the report contract documents), and grounded assertions that each match one canonical row for this attempt whose snippet is found at the named commit and line range under the execution root. It does not compare an assertion's `significance` with its row's, does not check a pre-plan row's task label, and does not parse Observations beyond requiring the section non-empty; those stay authoring requirements the seat reads for. Exit 2 names on stderr what did not hold; `docs/position-report-contracts.md` § Investigator report keeps the refused list and the authoring list apart. The check reads the report at the destination the manifest assigned, which is why landing comes first. It is invoked explicitly on every spec route because no spec route completes through a native `TaskCompleted` hook: a Claude `Agent` subagent returns rather than completing a team task, Codex and OpenCode have no blocking hook, a session ends on its own lifecycle, and the inline seat is not a hook. A pass establishes checkable references. Whether the findings answer the question well enough to synthesize from stays the seat's judgment, and nothing here accepts the investigation on the seat's behalf.

7. **Route the rest of the report to its readers.**
   - `**Worker leads:**` reaches the off-scale writer through the execution log. Append one entry per report whose body carries the `Worker leads:` line and its bullets verbatim, stamped with the producer's version as `--template-version`, your own as `--filing-template-version`, and the attempt's manifest pair from the reference you hold; `write-execution-log.sh` resolves the pair, writes `Producer-attribution:` beside the two `Position-dispatch-*` lines, and forwards a non-`None` payload to `off-scale-append.sh` under the `researcher` producer role and the producer's resolved version. The two pair flags travel together or not at all (an empty `MANIFEST_PATH` drops both, the legacy no-pair path), and a reference that does not resolve reads `unknown` rather than borrowing any template's version. `None` produces no sidecar row and is the ordinary case:

     **Recipe inputs:** SCRIPTS_DIR, SLUG, INVESTIGATION_ID, REPORT_ID, WORKER_LEADS, PRODUCER_TEMPLATE_VERSION, LEAD_TEMPLATE_VERSION, MANIFEST_PATH, MANIFEST_SHA256.
     <!-- spec-recipe: log-worker-leads -->
     ```bash
     args=(--slug "$SLUG" --source spec-lead --template-version "$PRODUCER_TEMPLATE_VERSION" --filing-template-version "$LEAD_TEMPLATE_VERSION")
     [[ -n "$MANIFEST_PATH" ]] && args+=(--position-dispatch-manifest "$MANIFEST_PATH" --position-dispatch-sha256 "$MANIFEST_SHA256")
     printf 'Investigation: %s\nReport-id: %s\nWorker leads: %s\n' "$INVESTIGATION_ID" "$REPORT_ID" "$WORKER_LEADS" \
       | bash "$SCRIPTS_DIR/write-execution-log.sh" "${args[@]}"
     ```

   - `**Unknowns:**` are read by whoever plans next. Carry them into Step 5b's Open Questions, or into a follow-up manifest at Step 6 when they gate a design decision.
   - A packet entry the investigator corrected or disputed already has its event in the trust ledger through `lore verify`; the collector does not re-verify it. When a correction changes the ground a still-running sibling investigation stands on, relay it now through the messaging the route offers (a message to the sibling on a team-messaging harness, `lore session send` to a session). Where the route has none, it travels in the landed report and reaches the sibling's question at synthesis — later, but not lost.

8. **Full branch only:** When all investigations are complete:
   - Execute each directive's teardown payload with its in-memory handle where the route left one. A Claude `Agent` subagent returned with its report and holds no handle; on Codex the live adapter returns the lead-mediated `TaskUpdate task_id=<handle> status=completed` directive; a session closes through its own lifecycle after collection. Do not infer teardown from `team_messaging`: the prepared payload and current adapter are the contract.
   - Run `TeamDelete` (Claude Code only, and only when a shared team was created; opencode/codex adapters require no explicit teardown — runtime owns lifecycle).

9. Append an investigation summary to `execution-log.md`. This entry is the seat's, so it carries the seat's version; the per-report producer versions were recorded in item 7:

   **Recipe inputs:** SCRIPTS_DIR, SLUG, COUNT, TOPICS, LEAD_TEMPLATE_VERSION.
   <!-- spec-recipe: log-investigation-summary -->
   ```bash
   printf 'Investigations: %s\nTopics: %s\n' "$COUNT" "$TOPICS" \
     | bash "$SCRIPTS_DIR/write-execution-log.sh" --slug "$SLUG" --source spec-lead --template-version "$LEAD_TEMPLATE_VERSION"
   ```

10. **Journal the investigation milestone.** The findings, Tier-2 rows, and investigation summary are all durable at this point, so a hosted session emits one `step_completed` row for the parent spec session — individual investigator reports and Tier-2 appends never emit steps. Call the recipe with `STEP_ID=spec:investigation` and `STEP_LABEL="Investigation collected"`; the same recipe journals `spec:design` (Step 5a) and `spec:plan-ready` (Step 5.5), and each id is stable so a replay lands on the same row. The three `LORE_SESSION_*` variables are inputs the hosting session exports and the recipe inherits — `session-step.sh` requires all three — and they are empty on an unhosted run, which skips silently. Replay is idempotent, and a failed append warns and moves on; it never rolls back the milestone it was reporting:

    **Recipe inputs:** SCRIPTS_DIR, STEP_ID, STEP_LABEL, LORE_SESSION_INSTANCE, LORE_SESSION_SLUG, LORE_SESSION_TYPE.
    <!-- spec-recipe: journal-step -->
    ```bash
    if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
      bash "$SCRIPTS_DIR/session-step.sh" --step-id "$STEP_ID" --step-label "$STEP_LABEL" \
        || echo "[spec] Warning: $STEP_ID not journaled; the persisted artifacts remain authoritative." >&2
    fi
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

**Recipe inputs:** KNOWLEDGE_DIR, SLUG.
<!-- spec-recipe: read-surfaced-concerns -->
```bash
SC_FILE="$KNOWLEDGE_DIR/_work/$SLUG/surfaced_concerns.jsonl"
if [[ -f "$SC_FILE" ]]; then cat "$SC_FILE"; else echo "[spec] No surfaced concerns file for $SLUG."; fi
```

If present and non-empty, read each pending entry (no `status` field = unresolved):
- Scope boundary / unresolved question → add to `## Open Questions`
- Dubious design assumption → add to `## Design Decisions` open question or refine the relevant decision
- Architectural observation → treat as additional research finding for Step 5

This step is **read-only** — do not modify `surfaced_concerns.jsonl`.

---

### Step 5: Synthesize — abstract plan

Produce the conceptual frame first before committing to a task breakdown. The abstract design is the planning designer's work: in short mode the seat compiles the designer brief, binds a planning attempt and reads the frozen payload itself; in full mode it dispatches the same position. Either way the designer's output is the abstract plan published as a revision, and the seat reads that revision at the design gate.

1. **Assign the design.** The assignment names everything a designer cannot find in a packet: the stage (`abstract`), the anchor verbatim, the seeded strawman when one exists, the landed investigation reports by path, the applicable norm manifest, and the destination plan. It is refused when a report path does not exist. The concrete stage (Step 5b) additionally requires the accepted revision id and the file holding the gate's dispositions, and the recipe copies the accepted inputs into the assignment rather than pointing at them: the exact path and sha256 of the immutable plan under `revisions/<accepted>/plan.md`, and the dispositions' parsed contents with the sha256 of the bytes they were read from. The recipe checks that the snapshot exists and is a 12-hex id; it does not read `revisions.jsonl`, so the accepted id is the caller's to supply from the gate record — the sealed review's `revision_id`, or the revision the acceptance projection names — and the recorded `accepted_plan_sha256` is what a reader compares with that revision's `plan_sha256` in the ledger to tell a drifted snapshot from the committed one. The bind hashes the assignment into the payload, so a later edit to the dispositions file changes nothing the designer reads; a pointer alone would not freeze it:

**Recipe inputs:** KNOWLEDGE_DIR, SLUG, STAGE, ANCHOR, STRAWMAN_FILE, REPORT_PATHS, NORMS_FILE, ACCEPTED_REVISION, DISPOSITIONS_FILE, ASSIGNMENT_FILE.
<!-- spec-recipe: designer-assignment -->
```python
import hashlib, json, os, re, sys
from pathlib import Path
E = os.environ
item = Path(E["KNOWLEDGE_DIR"]).resolve() / "_work" / E["SLUG"]
stage = E["STAGE"]
if stage not in ("abstract", "concrete"):
    sys.exit("stage must be abstract or concrete")
reports = [p for p in E["REPORT_PATHS"].split() if p]
missing = [p for p in reports if not Path(p).is_file()]
if missing:
    sys.exit("landed report missing: " + ", ".join(missing))
norms = E["NORMS_FILE"] or None
if norms and not Path(norms).is_file():
    sys.exit("norm manifest missing: " + norms)
strawman = Path(E["STRAWMAN_FILE"]).read_text() if E["STRAWMAN_FILE"] else None
accepted = E["ACCEPTED_REVISION"] or None
dispositions_file = E["DISPOSITIONS_FILE"] or None
if stage == "abstract" and (accepted or dispositions_file):
    sys.exit("the abstract stage precedes the design gate; it takes no accepted revision or dispositions")
accepted_plan = plan_sha = dispositions = dispositions_sha = None
if stage == "concrete":
    if not (accepted and re.fullmatch(r"[0-9a-f]{12}", accepted)):
        sys.exit("the concrete stage requires the accepted 12-hex revision id")
    plan_path = item / "revisions" / accepted / "plan.md"
    if not plan_path.is_file():
        sys.exit("accepted revision is not committed for this item: " + accepted)
    if not (dispositions_file and Path(dispositions_file).is_file()):
        sys.exit("the concrete stage requires the design-gate dispositions file")
    raw = Path(dispositions_file).read_bytes()
    dispositions = json.loads(raw)
    dispositions_sha = hashlib.sha256(raw).hexdigest()
    accepted_plan = str(plan_path)
    plan_sha = hashlib.sha256(plan_path.read_bytes()).hexdigest()
assignment = {"position": "designer", "mode": "planning", "stage": stage, "work_item": E["SLUG"],
              "anchor": E["ANCHOR"] or None, "strawman": strawman, "report_paths": reports, "norms_file": norms,
              "destination": str(item / "plan.md"), "accepted_revision": accepted,
              "accepted_plan_path": accepted_plan, "accepted_plan_sha256": plan_sha,
              "dispositions": dispositions, "dispositions_sha256": dispositions_sha}
Path(E["ASSIGNMENT_FILE"]).write_text(json.dumps(assignment, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"stage": stage, "reports": len(reports), "accepted_revision": accepted,
                  "accepted_plan_path": accepted_plan, "dispositions_sha256": dispositions_sha}))
```

   `NORMS_FILE` is the retained discovery manifest for this run — the complete permissive set from Step 2 with your applicability judgment beside each entry (`norm-context-dispositions.json` in the item, or the full `**Related preferences/conventions:**` block once it exists). The dispositions the concrete stage copies in are the gate's record as it was decided: the sealed review's `dispositions.json` (`reviews/<attempt-id>/sealed/dispositions.json`) when a review was sealed, or, when the seat recorded acceptance in `notes.md`, the JSON projection of that acceptance written by the acceptance-projection recipe in the filing contract — the recipe parses `DISPOSITIONS_FILE` as JSON, and a Markdown note is not that input. Build the designer's packet at the altitude a design fork sits at (abstract or architecture, usually), synthesize it with the packet-synthesis recipe before anything binds against it, then bind the planning attempt with mode `planning`. The binder's revision field stays absent with its reason — the packet writer binds revisions only to plan tasks, and an abstract plan has none — so the assignment is where the accepted revision, its immutable plan path and the dispositions travel on the concrete stage, and the envelope's null task and revision keep their stated reasons:

   **Recipe inputs:** SLUG, TOPIC, SCALE_SET.
   <!-- spec-recipe: designer-packet -->
   `lore packet build --work-item "$SLUG" --role designer --caller spec-lead --topic "$TOPIC" --scale-set "$SCALE_SET"`

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, SLUG, PACKET_ID, ASSIGNMENT_FILE, REPORT_ID, EXECUTION_ROOT, BINDINGS_FILE.
<!-- spec-recipe: designer-bindings -->
```python
import json, os, sys, uuid
from pathlib import Path
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from packet_builder import pointer
E = os.environ
kdir = Path(E["KNOWLEDGE_DIR"]).resolve()
assignment = json.loads(Path(E["ASSIGNMENT_FILE"]).read_bytes())
if assignment.get("mode") != "planning" or assignment.get("work_item") != E["SLUG"]:
    sys.exit("assignment must be a planning-mode designer assignment for this work item")
fields = ("work_item", "task_id", "revision_id", "packet_id", "packet_pointer", "dispatch_attempt_id", "assignment",
          "report_id", "report_path", "execution_root", "mode", "consultation_id", "domain", "reply_destination")
b = dict.fromkeys(fields)
b.update(work_item=E["SLUG"], packet_id=E["PACKET_ID"], packet_pointer=pointer(kdir, E["PACKET_ID"]), mode="planning",
         dispatch_attempt_id="design-" + uuid.uuid4().hex, report_id=E["REPORT_ID"],
         report_path=str(kdir / "_work" / E["SLUG"] / "worker-reports" / (E["REPORT_ID"] + ".md")),
         execution_root=E["EXECUTION_ROOT"] or None, assignment=json.dumps(assignment, ensure_ascii=False))
reasons = {"task_id": "planning designs the whole plan, not one task",
           "revision_id": ("no revision exists before the abstract design" if assignment["stage"] == "abstract"
                           else "the designer packet is session-scoped; the accepted revision is named in the assignment")}
reasons.update({k: "consultation fields do not apply to planning mode" for k in ("consultation_id", "domain", "reply_destination")})
if b["execution_root"] is None:
    reasons["execution_root"] = "the ordinary session host supplies its physical worktree"
b["absence_reasons"] = reasons
Path(E["BINDINGS_FILE"]).write_text(json.dumps(b, indent=2) + "\n")
print(json.dumps({k: b[k] for k in ("dispatch_attempt_id", "report_id", "packet_id", "mode")}))
```

   Compile the designer with `POSITION=designer` (compile-position recipe), author the wrapper (author-wrapper recipe; the planning note is chosen by the bound mode), then either bind inline or for a native or fixed-placement launch (bind-attempt recipe with `REQUIRED_BINDINGS="packet_id packet_pointer"`, `NATIVE_MODEL` set only on a native route; the designer model resolves through the `advisor` role under ceremony `spec`), or prepare an ordinary session whose host supplies the tree:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DESCRIPTOR_FILE, BINDINGS_FILE, GUIDANCE_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, SESSION_SLUG, CONTEXT_FILE.
<!-- spec-recipe: prepare-session -->
```bash
python3 - "$SCRIPTS_DIR" "$KNOWLEDGE_DIR" "$DESCRIPTOR_FILE" "$BINDINGS_FILE" "$GUIDANCE_FILE" "$WRAPPER_FILE" "$PREFIX_FILE" "$SUFFIX_FILE" "$SESSION_SLUG" > "$CONTEXT_FILE" <<'PY'
import importlib.util, json, sys
from pathlib import Path
scripts, kdir, descriptor, bindings, guidance, wrapper, prefix, suffix, slug = sys.argv[1:]
sys.path.insert(0, scripts)
spec = importlib.util.spec_from_file_location("binder", Path(scripts) / "position-bind.py")
binder = importlib.util.module_from_spec(spec); spec.loader.exec_module(binder)
context = binder.prepare_session_input(json.loads(Path(descriptor).read_bytes()), json.loads(Path(bindings).read_bytes()),
                                       Path(kdir), Path(guidance).read_bytes(), slug=slug, wrapper=json.loads(Path(wrapper).read_bytes()),
                                       prefix=Path(prefix).read_bytes(), suffix=Path(suffix).read_bytes())
print(json.dumps(context))
PY
```

   A prepared session enqueues through the request-session recipe with an empty worktree pair and is collected through the session-reference recipe; a native launch goes through the native-input recipe and its readiness check, and a failed check falls back to a session under fresh identities, never to a generic agent. In short mode the seat reads the payload (read-payload recipe) and does the design work itself under that brief. A coordinator commissioning only the design uses these same recipes and skips the rest of this skill; the artifacts are the same.

2. **What the designer produces.** Synthesis organizes the itemized findings; it does not narrate over them. Keep each finding's provenance intact and cite items rather than restating them in looser words — prose that absorbs the itemized record is where evidence quietly drops out. The Narrative section is the deliberate exception: it tells the story, while the record underneath stays itemized.

   **Seeded strawman baseline.** When the assignment carries a coordinator-authored strawman design, synthesis diffs against it rather than starting from a blank page. The strawman holds the burden of proof: any design decision that adds mechanism beyond it names, in its `**Rationale:**`, what the strawman concretely fails to do — a finding that the simple shape *works* is a decision to keep it, recorded as such. Overturning the strawman on evidence is legitimate and expected; overturning it because the itemized findings each suggested an addition is the failure mode this baseline exists to catch. Where no strawman was seeded, nothing changes.

   - **Goal** — what we're building/changing and why (1 paragraph). Write it in a controlled register, unconditionally: sentences of at most 25 words, active voice, present tense where possible, one idea per sentence, common words over rare ones, noun clusters of at most three words, no internal vocabulary except technical names grounded at first use. Certified simplified-English compliance is not claimed; the rules bind as written.
   - **Design Decisions** — use the `### DN: Title` format from the template. Each decision requires `**Decision:**`, `**Rationale:**`, `**Alternatives considered:**`, and `**Applies to:**` fields. Number decisions sequentially (D1, D2, ...).
   - **Narrative** — synthesize goal and chosen approach into a `## Narrative` section (1-2 paragraphs). Place it after `## Goal`. Write for a reader who wants the story without reading all sections. Draw from Goal and Design Decisions. Omit file paths and task lists. Use the Goal's controlled register where it costs no precision; when the register and technical precision conflict, precision wins — say the precise thing.
   - **Intent Anchor** — when the assignment carries an anchor (`_meta.json.intent_anchor` is present), render a `## Intent Anchor` section immediately after `## Narrative`: the anchor body verbatim, then a `**Scope delta:**` line (default `none — anchor preserved unchanged`; a narrowing is named here). This belongs to the abstract stage because publication runs the anchor verifier on every revision: a plan with an anchor and no `## Intent Anchor` section is refused with code 2, and one without the `**Scope delta:**` line with code 4, so an abstract plan missing either cannot reach its design gate. The `**Tempting narrower implementation:**` heading is added by the concrete stage (Step 5b item 0), which preserves the section and does not create it. Omit the section entirely when the item has no anchor.
   - **Architecture Diagram (conditional)** — include a `## Architecture Diagram` section when the work touches 2+ distinct modules. Read the diagram conventions first:

     **Recipe inputs:** SCRIPTS_DIR.
     <!-- spec-recipe: diagram-conventions -->
     `cat "$SCRIPTS_DIR/../claude-md/review-protocol/followup-template.md"`

     Diagram types: call chain (invocation paths), state machine (state transitions), data flow (data transforms). Write a plain-text ASCII diagram inside a fenced code block using box-drawing characters. Do NOT use Mermaid or other diagram DSLs — the TUI renderer cannot interpret them. A higher-priority instruction in force for the run governs the format choice when one exists.

3. **Publish the abstract revision.** The designer publishes the abstract plan through the revision writer; an abstract plan with no Tasks section publishes with zero tasks, identical bytes return the current revision (`status: current`), and changed bytes publish the next one. Publication runs `verify-plan-intent-anchor.sh` before generating tasks, so on an anchored item the `## Intent Anchor` section and its `**Scope delta:**` line from item 2 have to be in the plan before this first publication; a refusal here names the verifier's code (2 section missing, 3 body diverges, 4 Scope delta missing) and publishes nothing. The returned `revision_id` is what the design gate reads and what the concrete stage later names as accepted:

   **Recipe inputs:** SLUG, REASON, AUTHOR_ROLE.
   <!-- spec-recipe: publish-revision -->
   `lore plan revise "$SLUG" --reason "$REASON" --author-role "$AUTHOR_ROLE" --json`

   `AUTHOR_ROLE` is `designer` for a designer publication and `spec-lead` for a seat edit; the revision row records it. The designer then lands its design record at the bound report path (land-report recipe) — the three identity headers, the published revision, the decisions with reasons, the open questions with what would close them, and the Tier 2 claim ids — and the seat checks its headers with the check-identity recipe. The typed completion check reads worker and investigator reports only, so for a designer the identity check and the published revision are the collected evidence; nothing types a completion row for it.

4. **Consumption-verification checkpoint** — before the abstract plan is presented, report the outcome for each prefetched commons entry actually checked against code during investigation or design. Held and contradicted both count — a confirmation is signal, not ceremony. Skip entries never tested; grounded-or-nothing means every report needs the code anchor trio, so an entry you can't anchor is an entry you didn't verify. `VERIFY_SOURCE` is the position that did the checking: `investigator` while reading in Step 2a, `designer` in this step, `spec-lead` for a check the seat made in its own voice.

   A contradicted entry is resolved in the same call: `--resolution` is required on every contradicted report, and the front rejects a contradicted call that names no resolution, so a contradiction never lands without a recorded resolution. Two resolutions, and the fork turns on exactly two questions — how confident you are, and whether your evidence sits at the claim's altitude:

   - `corrected` — repair the entry in place. Choose this when the code settled the question and your evidence covers the claim's scope. The entry stays live with a dated correction and `status: corrected`; the repair is itself a claim the next reader will check against the code.
   - `disputed` — leave a dated, reasoned dispute marker on the entry: what you observed, why you didn't correct. Choose this when your confidence is low, or when your evidence is narrower than the claim — single-callsite evidence must not narrow a scope-exceeding claim, and the front refuses such a correction with `disputed-required`. The marker travels with the entry, visible in retrieval, until a later agent with the context to settle it does.

   **Recipe inputs:** KNOWLEDGE_PATH, VERIFY_SOURCE, FILE, LINE_RANGE, SNIPPET, CYCLE_ID, TEMPLATE_VERSION.
   <!-- spec-recipe: verify-held -->
   ```bash
   lore verify "$KNOWLEDGE_PATH" held \
     --source "$VERIFY_SOURCE" --protocol-slot Synthesis --cycle-id "$CYCLE_ID" --template-version "$TEMPLATE_VERSION" \
     --file "$FILE" --line-range "$LINE_RANGE" --exact-snippet "$SNIPPET"
   ```

   **Recipe inputs:** KNOWLEDGE_PATH, VERIFY_SOURCE, RESOLUTION, FILE, LINE_RANGE, SNIPPET, CYCLE_ID, TEMPLATE_VERSION, SLUG, RATIONALE, CLAIM_TEXT, FALSIFIER, SUPERSEDED_TEXT, REPLACEMENT_TEXT, CONFIDENCE, EVIDENCE_SCOPE, CLAIM_SCALE, DISPUTE_NOTE.
   <!-- spec-recipe: verify-contradicted -->
   ```bash
   args=("$KNOWLEDGE_PATH" contradicted --resolution "$RESOLUTION"
         --source "$VERIFY_SOURCE" --protocol-slot Synthesis --cycle-id "$CYCLE_ID" --template-version "$TEMPLATE_VERSION"
         --file "$FILE" --line-range "$LINE_RANGE" --exact-snippet "$SNIPPET" --work-item "$SLUG"
         --rationale "$RATIONALE" --claim-text "$CLAIM_TEXT" --falsifier "$FALSIFIER")
   case "$RESOLUTION" in
     corrected) args+=(--superseded-text "$SUPERSEDED_TEXT" --replacement-text "$REPLACEMENT_TEXT"
                      --confidence "$CONFIDENCE" --evidence-scope "$EVIDENCE_SCOPE" --claim-scale "$CLAIM_SCALE") ;;
     disputed)  args+=(--dispute-note "$DISPUTE_NOTE") ;;
     *) echo "resolution must be corrected or disputed: $RESOLUTION" >&2; exit 1 ;;
   esac
   lore verify "${args[@]}"
   ```

   The corrected branch passes the repair itself — `--superseded-text` and `--replacement-text` — plus the inputs the front weighs: `--confidence <high|medium|low>` (only `high` corrects; anything less routes to the marker), `--evidence-scope <single-callsite|multi-callsite|systemic>`, and `--claim-scale <implementation|subsystem|architecture|abstract>` — the same scale rubric entries and `--scale-set` declarations already use, which makes the altitude test concrete: `single-callsite` evidence against a claim above `implementation` scale is the one combination the front refuses. The disputed branch passes `--dispute-note` — what you observed and why you did not correct. A refusal exits 3 with `[verify] disputed-required: <reason>` and writes nothing; re-run with `RESOLUTION=disputed`. `CYCLE_ID` is `spec-<topic>-<YYYY-MM-DD>`.

   Events land in `$KDIR/_trust/trust-events.jsonl` (contract: `architecture/trust-ledger/README.md` in the knowledge store). Run these from the source repo's root, not from inside the knowledge store — `lore` resolves the store and records branch provenance from the current directory. Emission is non-blocking — synthesis continues immediately; re-running an identical invocation is a silent no-op (the writers dedupe and retries heal by stable IDs).

5. Present the abstract plan (Goal, Design Decisions, Narrative, Architecture Diagram) to the user for review, naming the published revision.

**Discovery findings integration:**
- **Related skills block (strict):** If the fixed investigation (full branch) or Step 2a skill scan (short branch) reported matched *external* skills, add a `**Related skills:**` block to the `## Context` or `## Investigations` section. Lore-toolchain skills are not eligible for this block — they're protocol, not advisors:
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
  **This block is the audit manifest, not the worker delivery channel.** It exists so a reviewer (and the post-plan ceremony) can see every preference/convention discovery surfaced. Workers do not read top-level plan.md sections — a worker's packet is built at dispatch from its task's `**Knowledge context:**` backlinks and `**Files:**` seeds through the shared packet builder. Distribution into per-task Knowledge context happens in Step 5b item 2 — see that step for the per-task placement rule and the applicability judgment that keeps a task's delivery to what it needs. Entries that don't bind to any specific task still appear here; the manifest also catches them during review even when they have no per-task home.

  Keep this block at the **full permissive surfaced set** regardless of what binds to a task. The manifest is permissive; the *weave* into task lines is strict (Step 5b "Deliverable contract gate" — only scope-overlapping judgment-class norms become constraint clauses). A backlink staying here while its norm is also woven into a task is correct: the manifest is provenance, the task line is delivery.

  The block is also a parse target: at close, the conformance renderer reads it as the spec-time discovery panel of `closure-conformance.md` and cross-tabulates each label against woven norms, recorded dispositions, and the shipped diff. Keep every bullet in the `[[knowledge:...]] — annotation` shape with a substantive annotation — a thinned or malformed manifest doesn't just weaken review, it blinds the closure read to norms nobody dispositioned.
- **Advisor declarations:** For each matched skill whose domain overlaps a task's owned surface, consider adding an `**Advisors:**` entry to that task. Set mode by the task's complexity — `must-consult` if the skill defines invariants workers must respect, `on-demand` otherwise.

### Ceremony outcome filing contract

Apply this contract after every terminal evaluator attempt in Steps 5a and 5.5. The evaluator supplies evidence; the seat decides the normalized protocol outcome. Never parse evaluator prose into a disposition. The two registered ceremonies stay distinct: an attempt names `spec-design` or `spec-post-plan`, and a review prepared under one ceremony never files under the other. Filing an outcome confers no authority the protocol did not already grant: acceptance, checkoff, and close keep their existing owners, and no review outcome gates dispatch on its own.

**Who holds the gate.** The seat-holder reads a gate and records its acceptance. Standalone, that is the spec lead: it prepares the attempts, invokes every registered evaluator itself, seals where it is the evaluator, and records acceptance. Commissioned, it is the coordinator, and the split follows what the landed review skills do: `codex-design-review` and `codex-plan-review` seal the attempt they evaluated and file the outcome under the agent that runs them, treating that agent as the plan-owning seat, and neither accepts a switch that defers the seal. So the commissioned spec lead publishes the revision, prepares one attempt per registered evaluator (item 1 below), posts one note naming the revision and every prepared attempt id, and waits: it invokes no review skill, seals nothing for that gate, and does not treat its own read as acceptance. The coordinator invokes each registered skill against its prepared attempt — the seal and the filing that invocation performs are the coordinator's — reads the revision whole, and either records acceptance in `notes.md`, projecting it to JSON with the acceptance-projection recipe so the concrete stage can copy it in, or authors and seals the review itself and uses its sealed `dispositions.json`. When no evaluator is registered, the coordinator is the evaluator on the commissioned route (item 3 below). Deciding whether a revision published after an evaluator's final round needs a fresh invocation is part of holding the gate and belongs to the same seat-holder. Evaluator evidence and the seat's acceptance are two records; the second is never inferred from the first.

The note names every attempt the lead prepared, space-separated in `ATTEMPT_IDS`. `POST_EDIT_REVISION` is empty when the note is posted before evaluation; it names the revision a review skill published after its final round when the lead posts again after the evaluators' terminal filings, so the record of what is awaited names both the revision that was reviewed and the one the coordinator will read for the gate decision:

**Recipe inputs:** SLUG, CEREMONY, REVISION_ID, ATTEMPT_IDS, POST_EDIT_REVISION.
<!-- spec-recipe: awaiting-note -->
```bash
[[ -n "$ATTEMPT_IDS" ]] || { echo "the awaiting note names at least one prepared attempt" >&2; exit 1; }
if [[ -n "$POST_EDIT_REVISION" ]]; then
  printf 'Awaiting %s gate decision: reviewed revision %s, prepared attempts %s; revision %s was published after the final round and no attempt has read it. The commissioned lead seals nothing for this gate; the coordinator decides whether %s needs a fresh invocation and records acceptance here, naming the revision it read, or authors and seals the review.\n' \
    "$CEREMONY" "$REVISION_ID" "$ATTEMPT_IDS" "$POST_EDIT_REVISION" "$POST_EDIT_REVISION" | lore work note "$SLUG"
else
  printf 'Awaiting %s gate decision: revision %s, prepared attempts %s. The commissioned lead prepared these attempts and seals nothing for this gate; the coordinator invokes each registered evaluator against its attempt, reads the revision whole, and records acceptance here or authors and seals the review.\n' \
    "$CEREMONY" "$REVISION_ID" "$ATTEMPT_IDS" | lore work note "$SLUG"
fi
```

When the seat accepts a gate in `notes.md` rather than by sealing a review, the concrete designer-assignment still needs the gate's dispositions as JSON, and a Markdown note is not that input. The seat projects its acceptance once, into `reviews/<ceremony>-acceptance-<revision>.json` in the item, in the dispositions-ledger shape the seal writer validates — `outcome: completed`, `verdict: ACCEPTED`, one `criterion-adequacy` judgment whose rationale names the `notes.md` entry (`NOTE_REF`, the entry's `## <timestamp>` heading) and the revision read, and an empty `dispositions` list. The file is authored input, written by no ledger writer and read by no review reader as an attempt (it is a file directly under `reviews/`, not an attempt directory); the recipe refuses an uncommitted or malformed revision and a second projection for the same gate and revision with different content, and prints the path to pass as `DISPOSITIONS_FILE`:

**Recipe inputs:** KNOWLEDGE_DIR, SLUG, CEREMONY, REVISION_ID, NOTE_REF.
<!-- spec-recipe: acceptance-projection -->
```bash
[[ "$CEREMONY" == spec-design || "$CEREMONY" == spec-post-plan ]] || { echo "ceremony must be spec-design or spec-post-plan" >&2; exit 1; }
[[ "$REVISION_ID" =~ ^[0-9a-f]{12}$ && -f "$KNOWLEDGE_DIR/_work/$SLUG/revisions/$REVISION_ID/plan.md" ]] || { echo "acceptance names a committed 12-hex revision of $SLUG" >&2; exit 1; }
[[ -n "$NOTE_REF" ]] || { echo "acceptance names the notes.md entry that recorded it" >&2; exit 1; }
OUT="$KNOWLEDGE_DIR/_work/$SLUG/reviews/$CEREMONY-acceptance-$REVISION_ID.json"
mkdir -p "$(dirname "$OUT")"
jq -n --arg ceremony "$CEREMONY" --arg revision "$REVISION_ID" --arg note "$NOTE_REF" \
  '{schema_version: 1, outcome: "completed", verdict: "ACCEPTED", reason: null,
    judgments: [{purpose: "criterion-adequacy",
                 judgment: ("the seat read revision " + $revision + " whole at the " + $ceremony + " gate and accepted it"),
                 rationale: ("acceptance recorded in notes.md at " + $note + " for revision " + $revision), result_ids: []}],
    dispositions: []}' > "$OUT.tmp"
if [[ -e "$OUT" ]]; then
  cmp -s "$OUT" "$OUT.tmp" || { rm -f "$OUT.tmp"; echo "an acceptance projection for $CEREMONY at $REVISION_ID already exists with different content" >&2; exit 1; }
  rm -f "$OUT.tmp"
else
  mv "$OUT.tmp" "$OUT"
fi
printf '%s\n' "$OUT"
```

**Bound attempts (schema 2).** When the plan has a committed revision, prepare the review input before the evaluator reads anything. The reviewer then judges exact immutable bytes, and the filed outcome records the revision that was actually reviewed rather than whatever head is live at filing time.

1. Prepare the review input. `PURPOSE` is `criterion-adequacy` for both spec ceremonies (the design ceremony judges the abstract stage under that purpose and says so in its judgment; an abstract draft has no task criteria to certify); `EXECUTION_WORKTREE` is empty for that purpose and required for `integration`:

   **Recipe inputs:** SLUG, ATTEMPT_ID, CEREMONY, REVISION_ID, PURPOSE, EXECUTION_WORKTREE.
   <!-- spec-recipe: review-prepare -->
   ```bash
   args=("$SLUG" --attempt-id "$ATTEMPT_ID" --ceremony "$CEREMONY" --revision "$REVISION_ID" --purpose "$PURPOSE" --json)
   [[ -n "$EXECUTION_WORKTREE" ]] && args+=(--execution-worktree "$EXECUTION_WORKTREE")
   lore plan review prepare "${args[@]}"
   ```

   Prepare copies the named revision's plan and tasks, together with the original anchor, under `reviews/<attempt-id>/` and publishes the directory in one rename. `prepared_path` in its output names the file `reviews/<attempt-id>/prepared.json`; the evaluator reads the directory that holds it, and both review skills refuse the file path. Capture the prepare output to a file and derive the directory from it — this is the value `--prepared` takes:

   **Recipe inputs:** PREPARE_RESULT.
   <!-- spec-recipe: prepared-dir -->
   ```bash
   PREPARED_DIR="$(dirname "$(jq -er '.prepared_path' "$PREPARE_RESULT")")"
   [[ -f "$PREPARED_DIR/prepared.json" ]] || { echo "prepared directory does not hold prepared.json: $PREPARED_DIR" >&2; exit 1; }
   printf '%s\n' "$PREPARED_DIR"
   ```

   One attempt serves one evaluator. The seal is write-once per attempt id and refuses different output or a different evaluator manifest under an id already sealed, and the outcome writer keys existing filings by attempt id with the advisor in the semantic identity, so a second evaluator sealing or filing under the first evaluator's attempt collides. Prepare a separate attempt for each registered evaluator against the same revision — `<ceremony>-<evaluator>-<UTC timestamp>-r1`, so the skill's own `-r2` round follows its lineage — and keep each evaluator's later rounds under its own lineage. `--revision` may name a historical revision explicitly; that revision is the one the outcome binds to. The `integration` purpose requires an execution worktree that can still be inspected, because its code identity is frozen into the prepared record; that digest covers the execution worktree and nothing outside it, and the one exclusion is this attempt's own review directory, listed under `source_exclusions`. Prepare requires the item's intent anchor. A prepare interrupted before the rename leaves no accepted attempt and a retry may publish; once the rename lands, the accepted attempt stays and an exact retry verifies it and keeps the frozen source identity even when the worktree has moved on. Direct the evaluator at the prepared copies, never at the live plan.

2. The reviewer authors judgments and findings. Criterion adequacy and integration against the original anchor are the reviewer's to judge. Task acceptance and execution records are not: acceptance stays with the seat, and execution evidence lives in results. The reviewer may read code, run commands, and describe in prose what a command does, but the ledger has no fields for executor state, exit codes, or argv, and a judgment never creates a result row; execution evidence the review relies on is cited by result ID. Each purpose gets its own judgment, the prepared purpose must appear, and an integration review may add a separate criterion-adequacy judgment. An empty `result_ids` list states that no execution evidence was cited; it is not a claim that none was consulted, so the judgment prose should say what the citations leave unverified.

3. The seat normalizes. Choose exactly one outcome: `completed | failed | skipped | needs-decision`. Preserve the evaluator's raw verdict byte-for-byte. `skipped` and `needs-decision` require a reason; `completed` and `failed` forbid one. Record this normalization in the dispositions ledger before sealing, so the sealed bytes carry the decision beside the review it was made from:

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

   When no evaluator is registered, the seat-holder is the evaluator: it reads the whole relevant revision, authors `output.md` and the dispositions ledger, and its manifest names this skill as the locator with `final_round` 1:

   **Recipe inputs:** SCRIPTS_DIR, SKILL_FILE, FRAMEWORK, MODEL, EVALUATOR_JSON.
   <!-- spec-recipe: seat-evaluator-manifest -->
   ```bash
   VERSION="$(bash "$SCRIPTS_DIR/template-version.sh" "$SKILL_FILE")"
   jq -n --arg locator "skills/spec/SKILL.md" --arg version "$VERSION" --arg framework "$FRAMEWORK" --arg model "$MODEL" \
     '{evaluator_locator: $locator, evaluator_template_version: $version, framework: $framework, model: $model, final_round: 1}' \
     > "$EVALUATOR_JSON"
   cat "$EVALUATOR_JSON"
   ```

4. Seal once, then extract the evidence manifest to a file outside `reviews/`:

   **Recipe inputs:** SLUG, ATTEMPT_ID, REVIEW_OUTPUT, DISPOSITIONS_JSON, EVALUATOR_JSON, SEAL_RESULT, EVIDENCE_JSON.
   <!-- spec-recipe: review-seal -->
   ```bash
   lore plan review seal "$SLUG" --attempt-id "$ATTEMPT_ID" \
     --output "$REVIEW_OUTPUT" --dispositions "$DISPOSITIONS_JSON" \
     --evaluator-manifest "$EVALUATOR_JSON" --json > "$SEAL_RESULT"
   jq '.evidence_manifest' "$SEAL_RESULT" > "$EVIDENCE_JSON"
   ```

   Seal checks every cited result ID against its canonical results row and refuses missing, ambiguous, or malformed IDs and wrong output hashes. It freezes the cited rows with their full output envelopes into `cited-results.json`; those copies are review evidence, never result appends, and later replays verify the frozen citations instead of rereading live results. The whole sealed directory publishes in one rename. A failure before that rename leaves no accepted artifact and a retry may publish; after it, a retry verifies the immutable bytes and refuses a changed output, ledger, or evaluator under the same attempt id. The manifest is returned in the seal's JSON result and is not written under the review; extracting it is the caller's only step, and no identity field is hand-composed. The schema 2 manifest carries the evaluator fields plus the review path and hash, the revision, the purpose, and source hashes derived from the sealed bytes.

5. File the already-made judgment with the unchanged arguments. `EVALUATOR` is the review skill's own name (`codex-design-review`, `codex-plan-review`) when that skill ran, because the advisor is part of the outcome's semantic identity and the skill files under its own name; `ATTEMPT_ID` is the attempt that skill invocation prepared and sealed. For the seat's own review it is `spec-lead`. `REASON` is empty except for `skipped` and `needs-decision`:

   **Recipe inputs:** SLUG, CEREMONY, EVALUATOR, ATTEMPT_ID, NORMALIZED_OUTCOME, RAW_VERDICT, EVIDENCE_JSON, REASON.
   <!-- spec-recipe: spec-outcome -->
   ```bash
   args=(--ceremony "$CEREMONY" --advisor "$EVALUATOR" --attempt-id "$ATTEMPT_ID"
         --outcome "$NORMALIZED_OUTCOME" --verdict "$RAW_VERDICT" --evidence-manifest "$EVIDENCE_JSON" --json)
   [[ -n "$REASON" ]] && args+=(--reason "$REASON")
   lore spec outcome "$SLUG" "${args[@]}"
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

   `completed` and `failed` require every evidence field. `skipped` and `needs-decision` keep every field present but may use explicit `null` when evidence is unavailable. Missing fields are errors, never defaults. Schema 1 outcomes stay legacy and unbound in every reader because no revision was recorded when the evidence was filed. A registered evaluator that cannot execute is a filed `skipped` attempt, never a silent omission. `EVALUATOR` is the registered evaluator's name and `PLAN_FILE` the plan it would have read:

   **Recipe inputs:** SCRIPTS_DIR, SLUG, CEREMONY, EVALUATOR, ATTEMPT_ID, FRAMEWORK, PLAN_FILE, REASON, EVIDENCE_JSON.
   <!-- spec-recipe: file-unavailable -->
   ```bash
   [[ -n "$REASON" ]] || { echo "an unavailable evaluator is filed with the reason it could not run" >&2; exit 1; }
   PLAN_SHA="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$PLAN_FILE")"
   jq -n --arg locator "$EVALUATOR" --arg framework "$FRAMEWORK" --arg plan "$PLAN_SHA" \
     '{schema_version: 1, evaluator_locator: $locator, evaluator_template_version: null, framework: $framework, model: null, final_round: null, disposition_ledger_sha256: null, source_plan_sha256: $plan}' \
     > "$EVIDENCE_JSON"
   lore spec outcome "$SLUG" --ceremony "$CEREMONY" --advisor "$EVALUATOR" --attempt-id "$ATTEMPT_ID" \
     --outcome skipped --verdict UNAVAILABLE --evidence-manifest "$EVIDENCE_JSON" --reason "$REASON" --json
   ```

### Step 5a: Design ceremony evaluation

**Ceremonies always run.** No flag skips this step; no flag is required to run it. Don't ask whether to invoke them — invoke. Judgment applies to acting on the output, not to running the step.

**Recipe inputs:** CEREMONY, SLUG.
<!-- spec-recipe: ceremony-get -->
`lore ceremony get "$CEREMONY" --work-item "$SLUG"`

With `CEREMONY=spec-design`: if the result is a non-empty JSON array, prepare one attempt per registered skill for the published abstract revision (review-prepare recipe, `spec-design`, `criterion-adequacy`, a distinct `ATTEMPT_ID` for each skill as the filing contract item 1 names), derive each prepared directory (prepared-dir recipe), and invoke each skill against its own prepared input, so the evaluator reads immutable bytes:
```
/<skill-name> <slug> --prepared <PREPARED_DIR for that skill's attempt> --attempt <that attempt-id> --ceremony spec-design --revision <revision-id>
```
This evaluates the abstract plan. The review skill runs its rounds, applies the seat's accepted edits, publishes and prepares a fresh attempt when it owes the evaluator an answer, seals the attempt it evaluated, and files the outcome under its own name; the seat then reads the result and decides what the plan does with it. Who invokes the skill follows the seat: standalone, the spec lead invokes each skill itself; commissioned, the spec lead stops after preparing the attempts and posting the awaiting note (`ATTEMPT_IDS` listing all of them, `POST_EDIT_REVISION` empty), and the coordinator invokes each skill against its attempt, because the skill seals and files under the agent running it and that agent has to be the seat. If WEAK or MISSING areas are identified, revise the abstract plan before proceeding to Step 5b. No evaluators are registered by default — opt-in via `lore ceremony add spec-design <skill>`. A registered evaluator that cannot run is filed `skipped` through the file-unavailable recipe under its own attempt.

An empty array means the bound seat-holder reads the whole abstract revision as the evaluator: standalone, the spec lead prepares, authors, seals (seat-evaluator-manifest and review-seal recipes) and files (spec-outcome recipe with `EVALUATOR=spec-lead`); commissioned, the spec lead prepares the attempt and posts the awaiting note, and the coordinator reads and records — in `notes.md`, projected with the acceptance-projection recipe, or as its own sealed review.

After each evaluator reaches a terminal attempt, the seat-holder makes the outcome judgment and files it under `--ceremony spec-design` using the ceremony outcome filing contract (a review skill has already filed its own; an exact replay is reused). A revision round receives a new attempt id; never overwrite the evidence identity of an earlier round. When the review skill's rounds end with edits applied, the skill seals the attempt it evaluated and publishes the edited plan (publish-revision recipe) as a revision it did not read; it prepares no attempt for that revision and names it in its final report as published after the final round. Whether that post-edit revision needs a fresh evaluator invocation is the seat-holder's decision at the gate, made reading the revision whole: an edit that changed what the review judged gets a fresh invocation under a fresh attempt id, and an edit that only applied what the review already accepted may be accepted by the seat directly, with the acceptance record naming the revision it read. Either way the sealed attempt keeps its identity and the earlier revision is never relabeled as the reviewed one. Commissioned, that decision is the coordinator's like the acceptance itself; when the coordinator's evaluator run published such a revision, the spec lead posts the awaiting note again with `POST_EDIT_REVISION` set, naming the reviewed revision, the published one and the sealed attempts, and seals nothing. An outcome of `needs-decision` is a durable open judgment; the design stage does not advance past it.

When every evaluator holds a terminal disposition, the gate decision is recorded, and any accepted revisions are persisted — including the no-evaluator case — a hosted session journals the design milestone with the journal-step recipe, `STEP_ID=spec:design` and `STEP_LABEL="Design accepted"`. One row marks the accepted design state; evaluator attempts and individual revision rounds do not emit. Hold the accepted revision id: the concrete stage binds to it.

### Step 5b: Synthesize — concrete plan

Draft concrete implementation sections on top of the accepted abstract plan. This is the designer's continuation: the same position, a fresh bound attempt. Author the assignment with `STAGE=concrete`, the accepted revision and the file holding the gate's dispositions — the sealed review's `dispositions.json`, or the acceptance projection when the seat accepted in notes (designer-assignment recipe, which copies the dispositions in as data and names the immutable plan under `revisions/<accepted>/plan.md` with both files' digests, so the bound payload holds the accepted inputs rather than pointers to files that can still change), build a fresh designer packet at the concrete altitude (subsystem or implementation) and synthesize it (designer-packet, packet-synthesis), bind fresh (designer-bindings, compile-position, author-wrapper, then bind-attempt or prepare-session and request-session), and read or dispatch as in Step 5. A designer cannot draft approved concrete work before the design gate has happened, which is why the continuation binds to the accepted revision rather than to the head. When the concrete plan is drafted, the designer publishes it through the publish-revision recipe and lands its design record; the seat checks the record's identity and reads the revision.

0. **Intent anchor** — if the work item has an `intent_anchor` in `_meta.json`, the abstract stage (Step 5 item 2) already rendered the `## Intent Anchor` section in `plan.md` immediately after `## Narrative` and before `## Strategy`/`## Context`, with the anchor body **verbatim** from `_meta.json.intent_anchor` — no quoting, prefix label, or paraphrase — and its `**Scope delta:**` line, because the abstract publication ran the verifier. The concrete stage preserves that section as accepted and checks it: the body still matches the anchor, and the `**Scope delta:**` line (default `none — anchor preserved unchanged`) names any narrowing this stage introduces. Before decomposing, name the tempting narrower implementation that would appear successful while violating the anchor; ensure the Goal, task constraints, and Verification cover the load-bearing promise or explicitly label the scope delta.

   Add the `**Tempting narrower implementation:**` heading under the `**Scope delta:**` line and fill it in. The anchor body and `**Scope delta:**` line are **verifier-enforced** — every publication and the Step 5.6 gate refuse to regenerate tasks if missing or divergent. The `**Tempting narrower implementation:**` body is template-prescribed but not verifier-enforced — its presence forces the author to confront the failure mode, but the content is free-text that no parser can adjudicate. For work items without an `intent_anchor` field, the section is absent at both stages — the Step 5.6 verifier skips with a one-line stderr info message.

1. **Tasks** — the plan holds its tasks directly, one `### Task N:` block each. Every block carries `**Deliverable:**`, `**Files:**`, and exactly one `- [ ]` checkbox line; optional `**Scope:**` / `**Knowledge context:**` / `**Retrieval directive:**` / `**Consultations required:**` / `**Advisors:**` / `**Task format:**` / `**Knowledge delivery:**` / `**Close criteria:**` blocks follow as the work needs them. The heading number is the task's id — `### Task 3:` is `task-3` — and it stays fixed as earlier work is checked off and when the subject after the colon is renamed, because revisions, reviews, and results are keyed to that id. A legacy heading or checklist form may carry an explicit `[id: task-N]` marker; a normal flat heading needs none. Deleting a task retires its id — the next new task takes the next unused number rather than the retired one, so a result recorded against the old id cannot be read as evidence for a different task. `**Close criteria:**` is an optional fenced JSON array of executable checks, each with `id`, `intent`, `argv`, `cwd`, `timeout`, `expected_exit`, and an optional `applicability` predicate; task generation hashes the complete definition into a criterion version and carries the exact command fields into the worker brief. A task without the block is legible as having no executable criteria, which is an absence of evidence rather than a pass. The plan itself carries `**Verification:**` once, plus whichever sizing rationale the band below requires.

   **Sizing band.** Give every task one **design center** and at least one real design choice to make about it. A *design center* is the single interface, mechanism, or subsystem whose shape the worker decides; the term earns its place because the vocabulary already in use — scope, deliverable, file set — measures how much a task *touches*, and the band turns on how much a task *decides*. A deliverable spanning several independent design centers splits even when the parts run serially: chained tasks keep their own acceptance boundaries, their own reports, and their own premise-wrong exits.

   Argue the sizing decision in writing, whichever way it went. Each direction is priced, and the Step 5.6 finalize gate refuses a plan that argues neither:

   - **Split rationale** — required when the plan carries more than one task. Name what the split buys — parallel wall-time, separate acceptance boundaries, fresh context per worker, worker-tier separation, a scoped premise-wrong exit — against what it costs in spawn ceremony, brief duplication, and integration risk.
   - **Merge rationale** — required when the plan carries exactly one task. Name the one design center the parts share.

   A one-task plan without a merge rationale, or a multi-task plan without a split rationale, is refused at finalize; the rationale is what shows the sizing was decided rather than defaulted. Both blocks live at plan level, above the first `### Task N:` heading.

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
   - **"Capture Z" / "Append session note"** → seat-side step once the plan closes (`lore capture` or `notes.md`); not worker work.
   - **Single-line edits, single CLI invocations, sub-edits** → fold into the adjacent implementation task.

   **Task format (intent+constraints).** Default. State what the change accomplishes, what not to do, and what success looks like at the deliverable level. Opt into prescriptive format with `**Task format:** prescriptive` for mechanical work where step-by-step instructions are required.

   **Verification (the plan's acceptance bar).** Write `**Verification:**` once, at plan level, as 0 to 3 observable-behavior criteria — the bar the seat honors at plan close. Task generation renders those bullets into every worker brief as plan-owned close criteria, and a worker self-checks only the bullets its own diff can affect, naming the rest as not-self-checked. Omitting the block declares no additional bar. The template's anti-pattern list governs what a bullet may say; the suite-shaped bar is the one to watch, because suite-level certification happens once at integration and a bar that asks for it pushes that cost onto every worker.

   Verification prose and a task's `**Close criteria:**` block are different instruments. The prose states what the seat judges at close; a criterion states an exact command whose exit code can be recorded, so the two live side by side and neither replaces the other. A criterion's `argv` runs without an implicit shell and its `cwd` resolves inside the execution worktree, which is why the command is written as a literal argument list rather than a shell line. An `applicability` predicate is its own object with `argv`, `cwd`, `timeout`, `applicable_exit`, and `inapplicable_exit`, where the two exits are distinct; it carries no criterion `id`, `intent`, or `expected_exit` of its own. Its absence means the criterion always applies. Declared criteria are executed by `lore criteria run <slug> <task-id> <criterion-id>`, which resolves the criterion from the selected immutable revision and records an immutable result row. The runner takes identity only: `--execution-worktree <root>` plus either `--packet-id <id>` (a schema 2 packet fixes task, revision, and dispatch attempt, and any `--revision` or `--dispatch-attempt-id` given alongside must agree) or `--revision <rid> --unbound-reason <text>` when no packet exists. It accepts no command, output, state, exit, result, or skip override, so the recorded outcome is what the declaration produces, not what a caller asserts. The criterion version is a hash of the complete canonical definition, covering argv, cwd, timeout, expected exit, and applicability, so changing any of these yields a new version through a new plan revision. Author criteria knowing the run is exact: stdin is `/dev/null`, stdout and stderr are captured together as bytes, the process group is terminated at the declared timeout, a nonmatching exit or a signal or a timeout records `fail`, and a launch, cwd, output-persistence, or source-access failure records `unavailable` rather than either pass or fail. A predicate that observes its inapplicable exit records `skipped` and the command does not run; any predicate outcome other than its two declared exits records `unavailable`. A check that spans several tasks belongs to a named integration task that owns it. Budget a criterion from a measured development run of the same command, with margin, and never from a guess. A result records that a command exited a certain way against a recorded code identity; whether that criterion is adequate for the task, and whether the criteria together cover the original anchor, remain the reviewer's authored judgments citing result IDs.

   **Premise-wrong exit (standing, every task).** A task brief hands its worker two sanctioned outcomes, not one: the deliverable, or the report "this cannot be built as scoped — here is what blocked me," naming the premise that failed contact with the code. The second is a first-class result from a colleague closer to the ground than the plan was; it routes to Step 6 follow-up investigation instead of forcing an approximation of a wrong plan. Never write a task whose only expressible outcome is success.

2. **Concordance-assisted annotation** — after drafting the tasks, widen each task's `**Knowledge context:**` block. Declare `--scale-set` explicitly for every prefetch call; a missing declaration is an error:

   **Recipe inputs:** TOPIC, SCALE_SET.
   <!-- spec-recipe: prefetch -->
   `lore prefetch "$TOPIC" --type knowledge --limit 5 --scale-set "$SCALE_SET"`

   `TOPIC` is the task deliverable and its key file paths. **Scale rubric** — the four tiers (`abstract`, `architecture`, `subsystem`, `implementation`), boundary tests, multi-label encoding rules, and the ±1 query pattern live in `skills/memory/SKILL.md` Scale-Aware Navigation — read that section before declaring if the right bucket is not obvious. For decision-tree details see the `classifier` agent template (lore repo `agents/classifier.md`).

   Add relevant entries as `[[knowledge:...]]` backlinks with "— why relevant" annotations. Investigation findings are the primary source; concordance is a widener.

   **Distribute surfaced preferences/conventions into per-task Knowledge context (mandatory), and judge applicability as you do.** The top-level `**Related preferences/conventions:**` block from Step 2 discovery is an audit manifest — it does not reach workers. Backlinks live at exactly two altitudes: the task, and the cross-cutting manifest. To reach a worker's packet, distribute each surfaced entry into `**Knowledge context:**` of every task whose surface plausibly overlaps, and record the entries you set aside for that task with their reasons (the item's `norm-context-dispositions.json` is the durable place; the brief's synthesis record points at it):

   - **Scope-overlap test:** an entry overlaps when its `related_files`, file-path globs, ceremony scope, or activity domain intersects the task's `**Files:**`, deliverable, or owned subsystem. Apply permissively — the Step 2 surfacing gate carries through to distribution. If a reviewer would expect the worker aware of the entry while editing the task's files, distribute.
   - **Format:** add as `[[knowledge:preferences/<entry>]]` (or `conventions/`, or `cross-cutting-conventions/`) in `**Knowledge context:**`, with a worker-facing "— what to honor at implement time" annotation. Implementation-facing means tell the worker what to *do*, not just what it says.
   - **Distribute to multiple tasks when warranted.** A convention touching several tasks' files belongs in each of their Knowledge context blocks — duplication is correct here because each task is its own worker with its own seeds. Do not consolidate across tasks.
   - **No-overlap entries stay in the top-level manifest only.** If after permissive review an entry binds to no task, leave it solely in `**Related preferences/conventions:**` — the manifest preserves the audit trail, and the set-aside list carries the reason.
   - **Distribution is permissive; weaving is strict — two separate channels.** This step (per-task `**Knowledge context:**`) carries every scope-overlapping entry, judgment-class or not, as a backlink — the worker can dismiss inapplicable ones. Weaving into a task's constraint clause (Deliverable contract gate above) is the *strict* subset: only the judgment-class entries that also scope-overlap the task become imperative constraint clauses naming the norm by its stable label. A judgment-class entry that binds to a task gets **both** — the backlink here (provenance + packet seed) and the woven clause in the task line (the instruction the worker executes). A mechanical entry gets only the backlink (it is never woven).
   - **Why distribute here:** at dispatch, `lore impl open` builds each task's packet through the shared packet builder from the task's `**Knowledge context:**` backlinks and `**Files:**` paths (the retrieval directive below is what it resolves), and the implement seat synthesizes that packet before the worker reads it. Distributing here flows entries through seeds → directive → packet without new protocol surface in `/implement`.

3. **Retrieval directive derivation** — after concordance widening, populate `**Retrieval directive:**` for each task. Derivable from the task's own content alone; no user input. Directives resolve per task at dispatch, so each one is derived from that task's files and knowledge context, never from a neighbour's.

   **Per-topic decomposition (v2 — default):** the directive is a list of `(topic, scale_set, [activity_vocab])` — **exactly one focal topic** plus **up to five adjacent topics**. Each topic fires its own BM25 OR query at its own scale_set; the worker's `## Prior Knowledge` block ends up sectioned (`### Focal: <topic>` / `### Adjacent: <topic>`).

   - **Focal topic.** The task's primary subject. Default `scale_set: subsystem,implementation`. Seeds: the task's owned files (from `**Files:**`) plus `[[knowledge:...]]` entries in `**Knowledge context:**` about that subsystem. Prefer **title-vocabulary terms** (the entry's title tokens) over the topic label — title vocabulary resolves to entries the index can rank, while raw `knowledge:...` strings tokenize as a single literal and miss the index.
   - **Adjacent topics (≤5).** Subsystems the task touches but does not own. Default `scale_set` one tier above focal's bottom — typically `architecture,subsystem`. Seeds: title-vocabulary terms from canonical entries about *that adjacent subsystem* — not the topic label, not the focal seeds. Weak seeds (right scale, wrong entries) are the dominant failure mode — re-derive from adjacent entries' titles and resolved paths.
   - **Activity vocabulary (optional, per topic).** Attach when topic files imply a recurring practice (writing tests, emitting telemetry, capturing). Look up tokens from `$KDIR/_meta/activity-vocab.yaml` by matching its file-path globs against the topic's owned files; **do not invent activity tokens inline**. The activity-vocab file is the single authority. When present, the topic fires one extra BM25 OR query at the same `scale_set` with these tokens (`query_kind=activity`).
   - **Strict v2 invariant.** A v2 directive MUST have exactly one `role: focal` entry. Zero-focal or multi-focal v2 is a hard parse error in `generate-tasks.py` — not silently accepted, not normalized to legacy. If no genuine focal candidate emerges (e.g., purely cross-cutting refactor), emit the legacy flat directive — that path remains valid for rollout compatibility.

   **Seeds derivation (mandatory):** per topic, collect from two sources — (a) `[[knowledge:...]]` backlinks in `**Knowledge context:**` whose subject matches the topic, resolved to the entry's title vocabulary and path terms before emitting, because a raw `knowledge:` string will not tokenize; (b) `**Files:**` paths the topic owns (verbatim). Deduplicate per topic. Empty seed union → the topic itself is suspect; drop it rather than emit an empty `seeds:` bullet.

   **Defaults:** `hop_budget: 1`. Per-section limits: focal `limit: 8`, adjacent `limit: 4` (tunable). `scale_set:` is **mandatory per topic**; omitting is an error. Pick `abstract`, `architecture`, `subsystem`, or `implementation`; multi-label form (e.g., `architecture,subsystem`) is allowed for adjacent pairs. Omit `filters:` unless type or category filtering adds value.

   **Format (v2 — default):** seeds are title vocabulary and owned paths, so the example shows both forms as the generator reads them:
   ```yaml
   retrieval_directive:
     version: 2
     topics:
       - role: focal
         topic: "<short label>"
         seeds:
           - "<title-vocabulary terms resolved from a Knowledge context backlink>"
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
   The legacy form continues to resolve to a single focal topic at the declared `scale_set` so existing plans don't break; its backlink seeds are accepted there for compatibility, while the v2 form takes the resolved title vocabulary.

   **Omission rule:** if a task has neither `**Knowledge context:**` backlinks nor `**Files:**` entries, omit the `**Retrieval directive:**` block and add a comment: `<!-- no directive: no backlinks or files to derive seeds from -->`.

   **Position:** place `**Retrieval directive:**` immediately after `**Knowledge delivery:**` (or after `**Files:**` when `**Knowledge delivery:**` is absent) and before `**Knowledge context:**`.

4. **Open Questions** — anything investigations couldn't resolve, including the Unknowns collected in Step 3.

5. Publish the concrete plan (publish-revision recipe, `AUTHOR_ROLE=designer`) and present the synthesized plan to the user for review, naming the revision.

---

### Step 5.0: Review context cost estimates (advisory)

**Recipe inputs:** SLUG.
<!-- spec-recipe: regen-tasks -->
`lore work regen-tasks "$SLUG"`

Inspect the context cost summary as a sanity check — a single task far larger than its peers may signal an under-decomposed deliverable worth a closer read. Cost diagnostics are advisory only; the sizing band and the Deliverable contract gate in Step 5b are the binding gates. Do not split tasks merely because they fall above an avg-comparison threshold, and do not merge tasks merely because they fall below one. The avg-comparison heuristic is post-hoc and uniform-thinness blind; trust the intrinsic gates instead.

On an item that has adopted revisions, this entry point composes `lore plan revise <slug>`: the revision writer validates plan, anchor, DAG, and criteria, stages plan and task snapshots, appends a revision row, and installs `tasks.json` through its existing writer. An identical regeneration returns the current revision without appending, so repeating this step costs nothing in history. The structural validation it performs is separate from the semantic disposition it records. A plan that parses and wires cleanly still carries `pending` anchor coverage and review requirement until someone authors them, because structural equality says nothing about whether the changed tasks cover the anchor or need a fresh review. The disposition is recorded against a revision id and creates no new revision; the same decision id replays exactly:

**Recipe inputs:** SLUG, REVISION_ID, DECISION_ID, DECISIONS_FILE.
<!-- spec-recipe: plan-decision -->
`lore plan revise "$SLUG" --decision-for "$REVISION_ID" --decision-id "$DECISION_ID" --decisions "$DECISIONS_FILE"`

`decisions.json` may hold `anchor_coverage`, `review_requirement`, and `dispatch_decision`; the dispatch decision belongs to the coordinator and is normally recorded during `/implement` rather than here. The field shapes and an example are in `docs/protocol-evidence.md`.

### Step 5.0a: Verify backlinks

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, SLUG.
<!-- spec-recipe: verify-backlinks -->
`bash "$SCRIPTS_DIR/verify-plan-backlinks.sh" "$KNOWLEDGE_DIR/_work/$SLUG/plan.md" "$KNOWLEDGE_DIR" --fix`

Output: `{verified: N, corrected: [...], unresolved: [...]}`.
- If corrections applied: note them briefly.
- If unresolved backlinks remain: carry forward to Step 5.1 as `[broken backlink]` bullets.
- If all resolved: proceed silently.

The Step 5.6 finalize verb re-runs backlink verification terminally; this early pass exists to surface broken links before the Step 5.1 review, not to replace the terminal check.

### Step 5.0b: Knowledge context block audit

For each task, run the knowledge-search recipe with the task deliverable keywords as `TOPIC`, `SCALE_SET=subsystem,implementation` and `LIMIT=3`. If results exist but the task has no `**Knowledge context:**` block, add the most relevant entry as a backlink with an implementation-facing annotation.

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
5. If user needs new investigation: suggest re-running `/spec <slug>`, which resumes at the persisted state and can open a targeted follow-up wave (Step 6).

---

### Step 5.4: Post-research extraction

Capture happened at discovery: investigators and the designer capture reusable insights through `lore capture` the moment the code surprises them, and the collector never repeats a capture the report says was already made. This step is the scoped recall over what remains. Invoke `/remember` scoped to the spec investigation. **Always invoke it — even when no observation appears to meet the gate.** The gate lives in `/remember`; rejecting candidates is `/remember`'s job, not the seat's, so every uncaptured observation is handed to it and none is filtered out beforehand. A run that captures zero entries is a valid terminal so long as `/remember` actually evaluated the observations.

**Capture posture: generous in, exacting in form.** Verification happens downstream, at consumption — every entry meets real code when a later agent reads it, and entries that fail that contact get corrected or disputed on the spot by the reader who caught them. So the expensive mistake is a malformed entry, not an extra one: don't spend effort predicting whether a future session will need an insight; spend it putting the insight in the form that lets that session retrieve and check it. Every capture written or promoted here takes the five-part form:

1. **Contrastive pair** — what to do *and* what it replaces or avoids: "use X; the tempting Y fails because Z." The avoid-half carries the hard-won part.
2. **The codebase's own vocabulary** — actual symbol names, actual error strings, never a paraphrase. Retrieval matches on similarity to a future agent's working context, and that context is made of real identifiers.
3. **Explicit applicability trigger** — "applies when you touch X and see Y." Distillation strips applicability cues, so the entry must re-supply its own.
4. **Extracted from surprises, not summaries** — capture what contradicted an expectation during investigation, drawn from the evidence itself, not from an agent's self-narration about its work.
5. **Provenance pointer** — `file:line@SHA` anchoring the claim; this is the anchor `lore verify` checks.

Every `lore capture` call carries provenance flags, and a capture promoted from an investigator observation preserves the original producer's attribution. `PRODUCER_ROLE` is `spec-lead` for a seat-original insight (then `CAPTURER_ROLE` and `SOURCE_ARTIFACT_IDS` are empty and `TEMPLATE_VERSION` is the seat's), or `researcher` for an investigator-sourced observation (then `CAPTURER_ROLE=spec-lead`, `SOURCE_ARTIFACT_IDS` names the report ids from the attempts' bindings, and `TEMPLATE_VERSION` is that attempt's compiled producer version). `researcher` is the capture writer's legacy vocabulary for the investigator position; it names the position at that boundary and adds nothing to the entry's standing. One capture call per distinct producer — never merge:

**Recipe inputs:** INSIGHT, SCALE, SLUG, PRODUCER_ROLE, CAPTURER_ROLE, SOURCE_ARTIFACT_IDS, TEMPLATE_VERSION.
<!-- spec-recipe: capture-observation -->
```bash
args=(--insight "$INSIGHT" --scale "$SCALE" --producer-role "$PRODUCER_ROLE" --protocol-slot Synthesis --work-item "$SLUG" --template-version "$TEMPLATE_VERSION")
case "$PRODUCER_ROLE" in
  spec-lead) [[ -z "$CAPTURER_ROLE$SOURCE_ARTIFACT_IDS" ]] || { echo "a seat-original capture names no other capturer or source report" >&2; exit 1; } ;;
  researcher) [[ "$CAPTURER_ROLE" == spec-lead && -n "$SOURCE_ARTIFACT_IDS" ]] || { echo "an investigator-sourced capture names capturer spec-lead and its source report ids" >&2; exit 1; }
              args+=(--capturer-role "$CAPTURER_ROLE" --source-artifact-ids "$SOURCE_ARTIFACT_IDS") ;;
  *) echo "producer must be spec-lead or researcher: $PRODUCER_ROLE" >&2; exit 1 ;;
esac
lore capture "${args[@]}"
```

```
/remember Research findings from <work item title> — Read all **Observations:** entries from investigation reports in plan.md and evaluate each: mechanism-level patterns, design rationale, and structural footprint signals all qualify; implementation facts already expressed in Tier-2 assertions do not, and an observation the report marks as already captured is not captured again. Also capture cross-investigation synthesis patterns not surfaced individually. Shape every capture in the five-part form: contrastive pair, the codebase's own vocabulary, explicit applicability trigger, surprise-derived content, provenance pointer.

Apply the provenance flags above on every `lore capture`.
```

**Settle what investigation crossed.** Investigation is where open questions get answered and hypotheses meet their settling tests — a research pass that reads the code an unsettled entry is about routinely crosses the test the entry names without noticing. Before leaving this step, sweep the `### Open questions` and `### Hypotheses` sections of your session context and packets against what the investigators established. A question this investigation answered: capture the answer as a regular entry, then settle the question, naming the answering entry in the note. A hypothesis whose settling test the research walked past: record one observation, and settle it when the result was decisive. `KIND_STATUS` is empty to corroborate only, or the settled status (`answered`, `dissolved`, `supported`, `refuted`) to settle as well. This is the consuming-side mirror of `/implement`'s salvage pass: capture files new unsettled claims, this sweep retires old ones. "Nothing crossed" is a complete answer:

**Recipe inputs:** KNOWLEDGE_PATH, DIRECTION, NOTE, SLUG, KIND_STATUS.
<!-- spec-recipe: claim-record -->
```bash
lore claim corroborate "$KNOWLEDGE_PATH" --direction "$DIRECTION" --source spec-lead --work-item "$SLUG" --note "$NOTE"
[[ -z "$KIND_STATUS" ]] || lore claim settle "$KNOWLEDGE_PATH" --kind-status "$KIND_STATUS" --source spec-lead --work-item "$SLUG" --note "$NOTE"
```

---

### Step 5.4a: Theory of the touched subsystem

Name the subsystem this plan touches, and review its theory page before the tasks disperse the work: this step runs after synthesis and before the plan is handed to `/implement`, while the investigation findings and the design are both in the plan and readable together. If a theory page exists for the subsystem (the `### Theory` section of your session context or packet), read it against what investigation just taught you and revise whatever no longer describes the code; a theory describes the code, the code never answers to the theory, and whoever changes a subsystem changes its page in the same change — this step is that rule applied to the spec seat. If no page exists and the subsystem is coherent enough to deserve one, write it:

**Recipe inputs:** SUBSYSTEM, INSIGHT, SLUG, TEMPLATE_VERSION.
<!-- spec-recipe: capture-theory -->
```bash
lore capture --kind theory --subsystem "$SUBSYSTEM" --category architecture --scale architecture,subsystem \
  --insight "$INSIGHT" --producer-role spec-lead --protocol-slot Synthesis --work-item "$SLUG" --template-version "$TEMPLATE_VERSION"
```

Put the subsystem's deliberate absences — what it deliberately does not do, and why — in the entry body alongside how it works; the absences are the part a later reader cannot recover from the code. Two outcomes complete this step with nothing written: the page is already current, and this plan touches no subsystem coherent enough to have one. The step blocks nothing — it holds no gate over the ceremony or finalization that follow.

---

### Step 5.5: Post-plan ceremony evaluation

**Ceremonies always run before terminal finalization.** No flag skips this step; no flag is required to run it. Judgment applies to acting on output, not to whether the registered obligation executes.

Run the ceremony-get recipe with `CEREMONY=spec-post-plan`. First publish the live plan: the designer's concrete publication (Step 5b item 5) preceded Step 5.0a's backlink repair, Step 5.0b's Knowledge context additions, Step 5.2's corrections and Step 5.3's approved task edits, and each of those edits the live `plan.md` and publishes nothing, while prepare reads the named revision's snapshot and not the live file. Run the publish-revision recipe with `AUTHOR_ROLE=spec-lead` and a `REASON` naming those steps; `status: current` means no byte changed since the designer's publication and the id is the same, `published` returns the id the review will read. If those edits reached an abstract section — Goal, Narrative, Intent Anchor, Design Decisions or Architecture Diagram — repeat the design gate (Step 5a) on that revision under fresh attempts before continuing. Then prepare one attempt per registered evaluator for the returned revision (review-prepare recipe, `--ceremony spec-post-plan`, purpose `criterion-adequacy`, a distinct `ATTEMPT_ID` for each skill), derive each prepared directory (prepared-dir recipe), and invoke each evaluator against its own attempt:
```
/<skill-name> <slug> --prepared <PREPARED_DIR for that skill's attempt> --attempt <that attempt-id> --ceremony spec-post-plan --revision <revision-id>
```
Present its output to the user. Who invokes follows the seat as in Step 5a: standalone, the spec lead; commissioned, the coordinator, after the spec lead has prepared the attempts and posted the awaiting note naming the revision and all of them. The post-plan review judges the full Tasks plan: the original anchor, the task DAG, the constraints, and the executable criteria, with its six completeness ratings and the Interface Clarity gate filed by the review skill through its own writers beside the sealed judgment. When the seat accepts changes after the evaluator's final round, revise `plan.md` and publish the revision; as at the design gate, the review skill seals the attempt it evaluated and prepares none for the post-edit revision, and the seat-holder decides whether that revision needs a fresh invocation — a change to what was judged repeats the affected gate under a fresh attempt id, an edit that only applied accepted findings is accepted by the seat naming the revision it read, and a concrete-stage edit that reached the abstract sections repeats the design gate too. After each terminal attempt, the seat-holder makes the normalized outcome judgment and files it under `--ceremony spec-post-plan` using the ceremony outcome filing contract; the filing names the review skill and the attempt it sealed. No registered evaluator means the bound seat-holder reads the whole concrete revision, as in Step 5a — standalone, the spec lead seals and files under `spec-lead`; commissioned, the spec lead posts the awaiting note and the coordinator records acceptance (notes plus the acceptance-projection recipe) or seals.

Do not finalize while a post-plan result still requires a plan edit or human decision. `needs-decision` is durable evidence of that open judgment, not permission to route around it.

Run Step 5.6's three seat-owned preflight asserts now, without finalizing: sweep the plan's named **paths, symbols, and packages** against the live tree (marking unresolvable names `(unverified)`), check every instructed invocation against the **live script**, and check that **Tier-2 emission instructions** point to the canonical validator contract. If any assert — or the finalize verb itself — refuses, fix `plan.md` and re-run the affected ceremony before Step 5.6 invokes `lore spec finalize`.

With the post-plan ceremony terminal, the gate decision recorded, and all three preflight asserts passing, a hosted session journals the plan-ready milestone before entering Step 5.6 (journal-step recipe, `STEP_ID=spec:plan-ready`, `STEP_LABEL="Plan ready"`). Finalization emits no step of its own — `lore spec finalize` keeps the later, distinct `terminus_reached` row, and a refused preflight or finalize synthesizes no step history.

---

### Step 5.6: Finalize through the spec verb

**Seat-owned preflight (three prose asserts the verb cannot run):** validate the plan against live sources, never from memory: (1) every path, symbol, and package the plan names resolves against the live tree — a mechanical grep or lookup per name; mark anything that doesn't resolve `(unverified)` where it appears, so the marking itself is the falsifier a later reader checks; (2) any script invocation block the plan instructs agents to run must match the live script's current flags (check `--help` or source — script schemas drift faster than plans); (3) Tier-2 emission instructions point at the validator's canonical required-field set rather than enumerating fields inline. Fix `plan.md` first if any fails — a deterministic script can assert JSON structure, but adjudicating prose against live sources is the seat's judgment.

Then close the plan through the finalize verb. Do not hand-run its composed checks or writers; `finalize` owns backlink verification, the intent-anchor hard gate, revision publication, healing, retrieval-directive assertions, the judgment-class and sizing-rationale gate, its `spec-verb` atom, and last-write telemetry:

**Recipe inputs:** SLUG, LEAD_TEMPLATE_VERSION.
<!-- spec-recipe: spec-finalize -->
`lore spec finalize "$SLUG" --template-version "$LEAD_TEMPLATE_VERSION"`

Show the verb's output. At its task-generation boundary finalize publishes the authored live `plan.md` through the ordinary revision writer: a fresh or adopted item acquires a committed revision, identical bytes reuse the current revision without a new history row, and changed bytes publish the next revision. Reviews sealed against earlier revisions keep their identity; finalization never relabels them. The anchor gate enforces structural anchor preservation and scope-delta attestation, not semantic non-drift — semantic alignment between the anchor and the rest of the plan remains a spec-author responsibility, with downstream reviewers (e.g., `/codex-plan-review`) as the semantic backstop. A no-anchor work item reports the gate as `skipped` with the verifier's reason (absence is legible, not silent).

**Refusal handling:**
- **Exit 3 (intent-anchor gate) or an emission-contract assert failure:** surface the named diagnostic (verifier code 2 = section missing, 3 = body diverges, 4 = `**Scope delta:**` missing; contract failures name the failing task), fix `plan.md`, and re-run the finalize recipe until it passes.
- **Exit 2 (ambiguous reference):** re-run with the exact slug.
- **Exit 1 (validation, precondition, publication, or composed-script failure):** fix the named diagnostic before re-running.

A refused finalize emits no telemetry row and no `spec-verb` atom; re-running after a fix appends a fresh point-event row per run — expected, not duplication.

---

### Step 6: Iterate and suggest retro

If gaps are identified (from evaluator feedback, a premise-wrong worker report, or user review):
- Author a targeted follow-up investigation document, open it with the spec-open recipe, execute the returned directives, and collect through Step 3.
- Append new findings to the Investigations section.
- Update the synthesis through the designer stages that the change touches, and publish the revision.

Run heal after any changes:

**Recipe inputs:** none.
<!-- spec-recipe: work-heal -->
`lore work heal`

Record the session in notes before leaving — focus, what was published, what remains:

**Recipe inputs:** SLUG, NOTE_FILE.
<!-- spec-recipe: work-note -->
`lore work note "$SLUG" < "$NOTE_FILE"`

After finalization, suggest:
```
Consider `/retro <slug>` to evaluate knowledge system effectiveness for this spec.
```

---

## Commissioned investigation and design on their own

A coordinator may commission an investigation or a design without running this whole skill, and the artifacts are the same ones this skill produces. For an investigation: build and synthesize an investigator packet (investigator-packet, packet-synthesis), compile the investigator (compile-position), write the bindings (investigator-bindings, with an empty `EXECUTION_ROOT` for an ordinary session or the fixed checkout for a placed one), author the wrapper (author-wrapper, `ROUTE=session` or `native`), then prepare-session and request-session, or bind-attempt and native-input; collect exactly as Step 3 does — land-report, session-reference or the held reference, check-identity, append-tier2, typed-completion, log-worker-leads. For a design: designer-assignment with the stage, designer-packet, packet-synthesis, designer-bindings, compile-position, author-wrapper, and the same launch recipes; the designer publishes through publish-revision and lands its design record, and the commissioning seat checks its identity and reads the revision. The gates stay with whoever holds the seat. A designer answering for one task's domain during implementation is a consultation, not a planning commission, and it uses the route `skills/implement/SKILL.md` Step 3 already lands ("Persistent advisors are compiled designers"): a session-scoped designer packet synthesized before the bind, consultation-mode bindings with `consultation_id`, `domain` and `reply_destination`, the worker's real task and revision carried in the assignment while the envelope's `task_id` and `revision_id` stay null with their reasons, and the reply shape and filing in `docs/position-report-contracts.md` § Designer outputs. A packet built with `--task` is bound to the worker's own dispatch attempt for that task and revision, and the binder compares packet and bindings attempt ids, so it cannot bind a designer's fresh attempt; this skill supplies nothing new for that case. The taskless shape above, with both null and their reasons stated, is for investigation and design that precede or span the plan.

## Plan.md Template

When emitting `plan.md` in Step 5 and Step 5b (including item 0's Intent Anchor render), read `skills/spec/templates/plan.md` for the canonical plan structure. The sidecar holds the full fenced template — Goal, Narrative, Intent Anchor, Strategy, Context, Investigations, Design Decisions, Architecture Diagram, Tasks, Open Questions, Related — with the inline HTML-comment guidance preserved alongside each section it governs.
