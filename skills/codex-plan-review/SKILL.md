---
name: codex-plan-review
description: "Submit a work item's prepared Tasks plan to Codex CLI for a completeness evaluation with six rated criteria and an Interface Clarity gate. Use after /spec drafts tasks and before /implement, or when registered as the spec-post-plan ceremony evaluator."
argument_description: "<work-item-slug> [--attempt <attempt-id> --revision <revision-id>]"
---

# Codex Plan Review

Submit a work item's complete plan to the Codex CLI (`codex exec`) for an independent completeness evaluation. Two rounds bound the exchange: Codex rates six criteria and proposes concrete edits, the evaluating agent decides each edit with codebase context Codex does not have, and Codex answers those decisions once. **Invoking this skill is the user's choice — once invoked, it runs autonomously.**

The review reads immutable prepared bytes: one committed revision's plan, task projection, and original anchor. Every plan edit stays with the seat that owns the plan, each reviewed revision keeps its own attempt, and the ratings that gate the result are the ratings of the bytes actually reviewed.

## When to Use

- After `/spec` drafts the Tasks section, before `/implement`
- When registered as the ceremony evaluator for `spec-post-plan` (`lore ceremony get spec-post-plan`)
- When a second opinion on plan completeness is wanted from a different model

## Step 1: Bind the reviewed input

The reviewed input is a prepared review attempt: `reviews/<attempt-id>/` under the work item, holding `prepared.json`, `plan.md`, `tasks.json`, and `anchor.md` for one committed revision, published by `lore plan review prepare`. Every round reads those copies. The live `plan.md` is the seat's working file and is never the reviewed input, because a round that read live bytes could rate text no attempt recorded.

Resolve the store and the scripts beside the `lore` you are running, so direct script calls exercise the same checkout as the verbs:

**Recipe inputs:** none.
<!-- spec-plan-review-recipe: resolve-paths -->
```bash
KNOWLEDGE_DIR="$(lore resolve)"
SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "$(command -v lore)")")/../scripts" && pwd -P)"
printf 'KNOWLEDGE_DIR=%s\nSCRIPTS_DIR=%s\n' "$KNOWLEDGE_DIR" "$SCRIPTS_DIR"
```

**Commissioned entry.** The caller — the spec protocol at its post-plan gate, or a coordinator commissioning a review — passes `--attempt <attempt-id> --revision <revision-id>` beside the slug. It prepared that attempt under ceremony `spec-post-plan`; nothing is published here. Skip to the read below.

**Direct entry.** Only a work item reference arrives. Resolve it to a slug, publish the live plan as a revision, and prepare a fresh attempt. Publication validates the plan's task grammar, anchor, dependency DAG, and close criteria and installs `tasks.json`; a plan that fails those checks stops here with the writer's message. An identical plan reuses its current revision (`status: current`); a changed plan publishes the next one. Prepare requires the item's intent anchor. Mint the attempt id as `codex-plan-<UTC timestamp>-r1`, for example `codex-plan-20260905T170000Z-r1`.

**Recipe inputs:** INPUT.
<!-- spec-plan-review-recipe: resolve-item -->
`lore work show "$INPUT" --json | jq -er '.slug'`

**Recipe inputs:** SLUG, REASON, AUTHOR_ROLE.
<!-- spec-plan-review-recipe: publish-revision -->
`lore plan revise "$SLUG" --reason "$REASON" --author-role "$AUTHOR_ROLE" --json`

`AUTHOR_ROLE` names who is publishing (`spec-lead`, `coordinator`, `designer`); the revision row records it. Read `revision_id` from the output.

**Recipe inputs:** SLUG, ATTEMPT_ID, REVISION_ID.
<!-- spec-plan-review-recipe: prepare-review -->
```bash
lore plan review prepare "$SLUG" --attempt-id "$ATTEMPT_ID" --ceremony spec-post-plan \
  --revision "$REVISION_ID" --purpose criterion-adequacy --json
```

**Both entries** read the prepared attempt through the evidence reader, which checks the snapshot hashes against the committed revision. The read refuses an attempt prepared under another ceremony, an attempt holding a different revision than the one named, and an attempt whose evidence is missing or altered; the caller then fixes the identity rather than the skill guessing which input was meant.

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, SLUG, ATTEMPT_ID, REVISION_ID.
<!-- spec-plan-review-recipe: read-prepared -->
```python
import json, os, runpy, sys
from pathlib import Path
api = runpy.run_path(os.path.join(os.environ["SCRIPTS_DIR"], "work-evidence.py"))
item = Path(os.environ["KNOWLEDGE_DIR"]) / "_work" / os.environ["SLUG"]
attempt = os.environ["ATTEMPT_ID"]
try:
    prepared = api["review_prepared"](item, attempt)
except (ValueError, OSError, KeyError, TypeError) as exc:
    sys.exit("[codex-plan-review] prepared review unavailable for attempt %s: %s" % (attempt, exc))
if prepared["ceremony"] != "spec-post-plan":
    sys.exit("[codex-plan-review] attempt %s was prepared under %s, not spec-post-plan" % (attempt, prepared["ceremony"]))
if prepared["revision_id"] != os.environ["REVISION_ID"]:
    sys.exit("[codex-plan-review] attempt %s holds revision %s, not %s" % (attempt, prepared["revision_id"], os.environ["REVISION_ID"]))
tasks = json.loads((item / prepared["tasks_path"]).read_text())
print(json.dumps({"slug": os.environ["SLUG"], "attempt_id": attempt, "revision_id": prepared["revision_id"],
                  "ceremony": prepared["ceremony"], "purpose": prepared["purpose"],
                  "prepared_dir": str(item / "reviews" / attempt),
                  "plan_file": str(item / prepared["plan_path"]), "tasks_file": str(item / prepared["tasks_path"]),
                  "anchor_file": str(item / prepared["anchor_path"]),
                  "task_count": len(tasks.get("tasks", []))}))
```

State the identity before reading anything else, so the transcript shows which bytes every later rating is about. A `task_count` of zero means the revision has no Tasks section yet; that is a design-stage plan, and `codex-design-review` is the review for it.

```text
[codex-plan-review] Reviewing <slug> — attempt <attempt-id>, revision <revision-id>, ceremony spec-post-plan
  prepared: <prepared_dir> (<task_count> tasks)
```

The whole prepared `plan.md` is the reviewed text: anchor, investigations, design decisions, and every task with its close criteria. The prepared `tasks.json` is the machine projection of the same revision; consult it when judging an edit's effect on task identity or a criterion's exact argv.

## Step 2: Codex review (Round 1)

Build the prompt from the prepared anchor and the prepared plan. Codex evaluates six criteria, rates each, and proposes concrete edits for anything below ADEQUATE. The prompt names the artifact — work item and revision — so an edit whose FIND text is absent from this artifact is recognizable as a mismatch and rejected as one, rather than evaluated as advice about some sibling.

**Recipe inputs:** SLUG, REVISION_ID, PLAN_FILE, ANCHOR_FILE, PROMPT_FILE.
<!-- spec-plan-review-recipe: plan-prompt-round-1 -->
````bash
{
cat <<'PROMPT'
Review the following technical specification plan for completeness. For any gaps found, propose concrete text edits to the plan.

The <ANCHOR> block is the original intent anchor the plan must serve; judge the plan against it and do not propose replacing it. The plan's work is a flat list of tasks under a `## Tasks` heading, each with a deliverable, owned files, and executable close criteria; dependencies between tasks are explicit.

Evaluate against these criteria:

1. **Objective and Scope** — Is the objective specific and measurable? Are non-goals explicit? Does every task serve the stated objective, or does the plan drift into hypothetical future needs, tangential cleanups, or unnecessary generalizations? A plan that does less but achieves the goal is better than one that does more.

2. **Evidence and Uncertainty** — Do the investigations address the major unknowns implied by the goal and design decisions? Are assertions presented with supporting evidence? Are risks and unresolved questions explicitly surfaced and classified as blocking or deferrable? Flag cases where a task depends on something the plan acknowledges as uncertain.

3. **Interface Clarity** — The goal of this criterion is long-term maintainability and legibility by both LLM agents and humans, and keeping abstractions rot-resistant so interfaces stay correct as implementations evolve. Does the plan make each new or materially changed boundary clear enough that another developer could implement or call it without inferring behavior from the eventual code? For each important boundary surface introduced or changed (module, exported type/function, config surface, protocol, persistence shape), the plan should state: (a) what responsibility it owns and what remains outside it, (b) the semantic shape of the inputs/outputs or states it exchanges, (c) the caller-visible behavior contract — success, failure/absence semantics, and any important side effects or lifecycle constraints, (d) where it is wired in or how callers reach it. `ADEQUATE` means those points are clear for the important seams. Exact helper signatures, full per-function contracts, and implementation-level detail are not required unless they materially affect callers, interoperability, or migration. Flag: ambiguous ownership, conflated error/absence states, implicit side effects or ordering constraints, valid use that depends on reading implementation, or plans that freeze incidental API detail without clarifying the real contract.

4. **Design Coherence** — Are design decisions justified with explicit alternatives and trade-offs? Are module boundaries clean — does each component have a single, clear responsibility? Flag unclear boundaries, responsibilities split across modules without clear ownership, or design choices presented without rationale.

5. **Execution Readiness** — Are tasks ordered through explicit dependencies that form a sensible DAG? Are tasks sized appropriately — actionable units rather than bloated multi-concern items or trivial micro-edits? Could an implementer start work from this plan without having to rediscover core intent?

6. **Validation and Traceability** — Does each task have executable close criteria that test what it delivers? Can you trace a line from goal → investigations → decisions → tasks → verification without gaps? Flag: tasks that don't map to any decision, decisions unsupported by investigations, verification that doesn't prove the goal, or open questions that silently invalidate later tasks.

For each criterion (1–6), rate as: STRONG / ADEQUATE / WEAK / MISSING
For each rating, provide a brief reasoning paragraph explaining *why* you assigned that rating.

## Proposed Edits

For every WEAK or MISSING criterion, propose concrete edits to the plan that would bring it to ADEQUATE. Use this exact format for each edit — multiple edits are expected:

~~~
### Edit: <short description>
Criterion: <which criterion this addresses>

FIND:
```
<exact text from the plan to locate the insertion/replacement point — 1-3 lines of context>
```

REPLACE:
```
<replacement text, or the FIND text with new content inserted>
```
~~~

If the fix is a pure addition with no existing text to replace, use:

~~~
### Edit: <short description>
Criterion: <which criterion this addresses>

AFTER:
```
<exact text from the plan that the new content should follow>
```

INSERT:
```
<new content to add>
```
~~~

Rules for proposed edits:
- Each edit must be self-contained — do not reference other edits
- FIND blocks must contain verbatim text from the plan (enough to be unique)
- Edits should be minimal — fix the gap, don't rewrite surrounding content
- Do not propose edits for STRONG or ADEQUATE criteria
- Do not add implementation detail — keep edits at plan level (contracts, shapes, responsibilities)
- Do not renumber or delete existing tasks; a task's heading is its identity

---
PROMPT
printf '\nArtifact under review: work item %s, plan revision %s. Every FIND and AFTER block must quote text from this artifact.\n' "$SLUG" "$REVISION_ID"
printf '\n<ANCHOR>\n'; cat "$ANCHOR_FILE"; printf '\n</ANCHOR>\n\n<PLAN>\n'; cat "$PLAN_FILE"; printf '\n</PLAN>\n'
} > "$PROMPT_FILE"
````

Resolve the evaluator model once per invocation from the Codex harness's advisor binding under the `spec` ceremony, and pass exactly that model to Codex, so the evaluator manifest sealed later names the model that produced the ratings:

**Recipe inputs:** SCRIPTS_DIR.
<!-- spec-plan-review-recipe: resolve-evaluator-model -->
```bash
source "$SCRIPTS_DIR/lib.sh"
LORE_FRAMEWORK=codex bash "$LORE_REPO_DIR/adapters/agents/codex.sh" resolve_model_for_role advisor spec
```

Submit the prompt through `codex exec` in read-only sandbox mode, reading the prompt from stdin and capturing stdout as the response. A binding with a reasoning-effort suffix splits into model and effort here:

**Recipe inputs:** SCRIPTS_DIR, MODEL, PROMPT_FILE, RESPONSE_FILE.
<!-- spec-plan-review-recipe: codex-submit -->
```bash
source "$SCRIPTS_DIR/lib.sh"
routing=$(bash "$LORE_REPO_DIR/adapters/agents/codex.sh" split_model_variant "$MODEL")
cmd=(codex exec --sandbox read-only --skip-git-repo-check)
for pair in $routing; do
  case "$pair" in
    model=*) cmd+=(-m "${pair#model=}") ;;
    reasoning_effort=*) cmd+=(-c "model_reasoning_effort=\"${pair#reasoning_effort=}\"") ;;
  esac
done
"${cmd[@]}" - < "$PROMPT_FILE" > "$RESPONSE_FILE"
if [[ ! -s "$RESPONSE_FILE" ]]; then echo "[codex-plan-review] Codex returned no output" >&2; exit 1; fi
```

## Step 3: Evaluate Round 1

Read the response and extract the six ratings and every proposed edit. Report the summary:

```text
[codex-plan-review] Round 1 — Codex evaluation for <slug>

  Objective and Scope:         <rating>
  Evidence and Uncertainty:    <rating>
  Interface Clarity:           <rating>
  Design Coherence:            <rating>
  Execution Readiness:         <rating>
  Validation and Traceability: <rating>

  Proposed edits: <N>
```

Evaluate each proposed edit against codebase context Codex does not have. An edit is advice about the plan; it cannot widen or narrow the work item's scope on its own, and an edit that would change the intent anchor, retire a task, or alter a close criterion's meaning is a decision for the seat, not a text substitution. For each edit, decide:

- **Accept** — the edit addresses a real gap and is consistent with the codebase; apply it to the live `plan.md`
- **Modify** — the edit identifies a real gap but the proposed text is wrong or incomplete given codebase context; apply a corrected version
- **Reject** — the edit is unnecessary, incorrect, or conflicts with established architecture or conventions; do not apply

For each decision, report:

```text
[codex-plan-review] <Accept|Modify|Reject>: <edit description>
  <one-line rationale — what codebase context informed the decision>
```

Record the ratings and every decision in the **disposition ledger**, a JSON file the evaluating agent authors and extends round by round. It is the durable history of the exchange: the round-2 prompt is rendered from it, the sealed dispositions and the scorecard rows are derived from it, so a rating or decision that is not in the ledger did not happen as far as the record is concerned. Ratings are copied exactly as Codex wrote them; `verdict` is the gate label for that round, computed from Interface Clarity by the rule in Step 6.

```json
{
  "schema_version": 1,
  "skill": "codex-plan-review",
  "rounds": [
    {
      "round": 1,
      "attempt_id": "codex-plan-20260905T170000Z-r1",
      "revision_id": "af6eae2cc818",
      "verdict": "GATE FAILED",
      "ratings": {
        "Objective and Scope": "STRONG",
        "Evidence and Uncertainty": "ADEQUATE",
        "Interface Clarity": "WEAK",
        "Design Coherence": "ADEQUATE",
        "Execution Readiness": "ADEQUATE",
        "Validation and Traceability": "WEAK"
      },
      "edits": [
        {
          "description": "State the packet writer's failure semantics",
          "criterion": "Interface Clarity",
          "disposition": "Accept",
          "rationale": "scripts/packet-append.sh refuses a duplicate id with exit 4; the plan never said so.",
          "applied": null
        },
        {
          "description": "Add a criterion for the archive reader",
          "criterion": "Validation and Traceability",
          "disposition": "Modify",
          "rationale": "The reader is already exercised by tests/test_plan_review.bats; the criterion names that file instead of a new script.",
          "applied": "Task 2 close criteria now run tests/test_plan_review.bats."
        }
      ]
    }
  ]
}
```

**Applying edits.** Accepted and modified edits are applied to the live `plan.md`, never to the prepared copy. The edited plan is then published as a revision and a fresh attempt is prepared for it, because Codex must re-rate the bytes that now exist and a sealed rating must name the revision it judged. Use `publish-revision` with a reason naming the round — publication re-validates the task grammar and criteria and regenerates `tasks.json`, so an edit that broke either is refused here rather than discovered at implement — then `prepare-review` with the round-2 attempt id (the round-1 attempt id with `-r2` appended) and the new revision, then `read-prepared` against the new attempt. The round-1 attempt stays prepared and unsealed; its ratings and every disposition travel in the ledger sealed with the final attempt, so nothing pretends the superseded bytes were rated.

If every edit was rejected, the plan is unchanged and round 2 rereads the same attempt. If every edit was accepted, or there were none, no answer is owed: skip to Step 5.5 with the attempt that now holds the reviewed bytes (the fresh attempt when edits were applied, the original one otherwise), and the round-1 ratings stand as final.

## Step 4: Codex response (Round 2)

Render the ledger into the round-2 prompt beside the current prepared plan. The recipe refuses when round 1 left nothing to answer, which is the case Step 3 already routed past this step.

**Recipe inputs:** SLUG, REVISION_ID, PLAN_FILE, ANCHOR_FILE, LEDGER_FILE, PROMPT_FILE.
<!-- spec-plan-review-recipe: plan-prompt-round-2 -->
```python
import json, os, sys
from pathlib import Path
ledger = json.loads(Path(os.environ["LEDGER_FILE"]).read_text())
first = ledger["rounds"][0]
if not any(e["disposition"] in ("Modify", "Reject") for e in first["edits"]):
    sys.exit("[codex-plan-review] round 2 is not needed: every round-1 edit was accepted or none was proposed")
parts = ["You previously reviewed this plan and proposed edits. The reviewing agent evaluated your proposals "
         "against codebase context and made the following dispositions:\n\n## Disposition Ledger\n"]
for e in first["edits"]:
    parts.append("\n### %s\nCriterion: %s\nDisposition: %s\nRationale: %s\n" % (e["description"], e["criterion"], e["disposition"], e["rationale"]))
    if e["disposition"] == "Modify":
        parts.append("Modified version applied: %s\n" % e["applied"])
parts.append("""
---

Review the updated plan below. Focus on:

1. **Re-rate** all 6 criteria against the updated plan, using the same STRONG / ADEQUATE / WEAK / MISSING scale and a brief reasoning paragraph for each.
2. **Respond to rejections** — if you still believe a rejected edit addresses a genuine gap, re-propose it with a counter-argument that accounts for the stated rationale. Only re-propose if you have a substantive reason the rejection was wrong, not just to repeat yourself.
3. **Respond to modifications** — if a modification missed the point of your original edit, propose a refined version. If the modification adequately addresses the gap, accept it.
4. **New edits** — if the changes introduced new gaps or revealed issues not visible in the original plan, propose new edits using the same FIND/REPLACE or AFTER/INSERT format.

Do not re-propose edits that were accepted. Do not re-propose rejected edits without a new argument. The <ANCHOR> block is unchanged and remains the intent the plan must serve.
""")
parts.append("\nArtifact under review: work item %s, plan revision %s. Every FIND and AFTER block must quote text from this artifact.\n" % (
    os.environ["SLUG"], os.environ["REVISION_ID"]))
parts.append("\n<ANCHOR>\n%s\n</ANCHOR>\n\n<PLAN>\n%s\n</PLAN>\n" % (
    Path(os.environ["ANCHOR_FILE"]).read_text(), Path(os.environ["PLAN_FILE"]).read_text()))
Path(os.environ["PROMPT_FILE"]).write_text("".join(parts))
```

Submit with `codex-submit`, the same model, and a fresh response file.

## Step 5: Evaluate Round 2

Parse the round-2 response and apply the same Accept/Modify/Reject evaluation as Step 3, adding a `round: 2` entry to the ledger with the re-rated criteria and the attempt and revision it reviewed. If Codex re-proposed a rejected edit with a counter-argument that changes the assessment, accept it; if the counter-argument introduces no new information, maintain the rejection. Report:

```text
[codex-plan-review] Round 2 — Codex response for <slug>

  <updated ratings>

  Re-proposed: <N> | New: <N> | Accepted: <N> | Rejected: <N>
```

This is the final round — no further iteration. Accepted and modified round-2 edits are applied to the live `plan.md` and published with `publish-revision`; that revision is one this review did not rate. The ratings sealed and captured below belong to the attempt round 2 judged, and the final report names both revisions so the seat can decide whether the post-edit revision needs a fresh invocation.

## Step 5.5: Capture the verdict to scorecards

Codex's verdict against the spec plan is itself signal — `/evolve` cites these rows when judging the `/spec` template's accuracy over time — so the six ratings and the gate land in `_scorecards/rows.jsonl` attributed to the **spec** template, the producer of the artifact under review, not to this reviewer. The recipe reads the final round's ratings from the ledger, refuses a ledger that does not name exactly the six criteria with valid ratings, computes the gate by the Step 6 rule, prints both, and then hands the rows to `codex-verdict-capture.sh`, which appends six `criterion:*` rows and one `gate` row through the sole scorecard writer. A capture failure is reported and does not stop the review: the gate result printed above it stands, and the rows are simply absent.

**Recipe inputs:** SCRIPTS_DIR, SLUG, LEDGER_FILE.
<!-- spec-plan-review-recipe: capture-ratings -->
```bash
source "$SCRIPTS_DIR/lib.sh"
verdict=$(jq -ec '
  ["Objective and Scope", "Evidence and Uncertainty", "Interface Clarity", "Design Coherence",
   "Execution Readiness", "Validation and Traceability"] as $names
  | .rounds[-1].ratings as $r
  | if ($r | keys | sort) != ($names | sort) then error("ratings must name exactly the six criteria") else . end
  | if ([$r[]] | all(. == "STRONG" or . == "ADEQUATE" or . == "WEAK" or . == "MISSING")) then . else error("ratings must be STRONG, ADEQUATE, WEAK or MISSING") end
  | {ratings: $r, gate: (if ($r["Interface Clarity"] == "STRONG" or $r["Interface Clarity"] == "ADEQUATE") then "pass" else "fail" end)}' "$LEDGER_FILE")
printf 'gate=%s\ninterface_clarity=%s\n' "$(jq -r '.gate' <<<"$verdict")" "$(jq -r '.ratings["Interface Clarity"]' <<<"$verdict")"
spec_version=$(bash "$SCRIPTS_DIR/template-version.sh" "$LORE_REPO_DIR/skills/spec/SKILL.md")
if ! bash "$SCRIPTS_DIR/codex-verdict-capture.sh" --source-ceremony spec --producer-template-version "$spec_version" \
    --verdict-json "$verdict" --work-item "$SLUG"; then
  echo "[codex-plan-review] Warning: verdict capture failed; the gate result above stands and the scorecard rows are absent." >&2
fi
```

## Step 6: Final gate evaluation

The plan **passes the gate** when **Interface Clarity is rated STRONG or ADEQUATE** in the final round. That is the only blocking criterion; the other five are advisory — reported, never gating. The gate label is the value Step 5.5 printed and the `verdict` recorded for the final round.

```text
[codex-plan-review] GATE <PASSED|FAILED> — Interface Clarity: <rating>
  Rounds: <1|2> | Edits applied: <N accepted + N modified> | Rejected: <N>
  Advisory: <any remaining WEAK/MISSING criteria and their ratings>
```

If the gate failed (Interface Clarity still WEAK or MISSING after the final round), list the specific remaining gaps so the seat can decide how to proceed. The gate is evaluator evidence; acceptance of the plan is the seat's decision and is recorded separately.

## Step 7: Seal the reviewed attempt and file the outcome

Seal exactly the attempt the final round judged: round 2's attempt when a second round ran, otherwise the attempt Step 3 finished on. Sealing happens once per attempt; a retry with identical bytes is reused, a retry with different bytes is refused, and nothing here writes a result row or edits any plan.

Compose the review output from the raw responses and the ledger, so the sealed prose carries what Codex said, the ratings of each round, and what was decided:

**Recipe inputs:** ROUND1_RESPONSE_FILE, ROUND2_RESPONSE_FILE, LEDGER_FILE, REVIEW_OUTPUT.
<!-- spec-plan-review-recipe: compose-review-output -->
```bash
{
  printf '# Codex plan review — round 1\n\n'
  cat "$ROUND1_RESPONSE_FILE"
  if [[ -n "$ROUND2_RESPONSE_FILE" ]]; then
    printf '\n\n# Codex plan review — round 2\n\n'
    cat "$ROUND2_RESPONSE_FILE"
  fi
  printf '\n\n# Disposition ledger\n\n```json\n'
  cat "$LEDGER_FILE"
  printf '\n```\n'
} > "$REVIEW_OUTPUT"
```

Normalize the outcome. This is an authored decision, not a parse of Codex's prose: `completed` when the exchange produced final ratings the seat can act on, whether the gate passed or failed; `needs-decision` with a reason when the two-round cap left the gate failed on a disagreement the evaluating agent could not settle from codebase context; `failed` when Codex could not review the input; `skipped` with a reason when Codex could not run at all. The `criterion-adequacy` judgment states whether the plan's tasks and close criteria adequately cover the anchor, in the evaluating agent's words. `result_ids` is always empty: this reviewer runs no commands and cites no execution evidence.

**Recipe inputs:** LEDGER_FILE, OUTCOME, REASON, JUDGMENT, RATIONALE, DISPOSITIONS_FILE.
<!-- spec-plan-review-recipe: compose-dispositions -->
```python
import json, os, sys
from pathlib import Path
ledger = json.loads(Path(os.environ["LEDGER_FILE"]).read_text())
labels = {"Accept": "accepted", "Modify": "modified", "Reject": "rejected"}
dispositions = []
for entry in ledger["rounds"]:
    for e in entry["edits"]:
        if e["disposition"] not in labels:
            sys.exit("[codex-plan-review] unknown disposition in round %s edit %r: %s" % (entry["round"], e["description"], e["disposition"]))
        dispositions.append({"finding": "Round %s, %s: %s" % (entry["round"], e["criterion"], e["description"]),
                             "disposition": labels[e["disposition"]], "reason": e["rationale"]})
final = ledger["rounds"][-1]
dispositions.append({"finding": "Round %s ratings" % final["round"],
                     "disposition": "; ".join("%s: %s" % (name, rating) for name, rating in final["ratings"].items()),
                     "reason": "Interface Clarity %s; gate %s." % (final["ratings"]["Interface Clarity"], final["verdict"])})
document = {"schema_version": 1, "outcome": os.environ["OUTCOME"], "verdict": final["verdict"],
            "reason": os.environ["REASON"] or None,
            "judgments": [{"purpose": "criterion-adequacy", "judgment": os.environ["JUDGMENT"],
                           "rationale": os.environ["RATIONALE"], "result_ids": []}],
            "dispositions": dispositions}
Path(os.environ["DISPOSITIONS_FILE"]).write_text(json.dumps(document, indent=2) + "\n")
```

The evaluator manifest names this skill file's version, the framework and model that produced the ratings, and the final round:

**Recipe inputs:** SCRIPTS_DIR, MODEL, FINAL_ROUND, EVALUATOR_FILE.
<!-- spec-plan-review-recipe: evaluator-manifest -->
```bash
source "$SCRIPTS_DIR/lib.sh"
version=$(bash "$SCRIPTS_DIR/template-version.sh" "$LORE_REPO_DIR/skills/codex-plan-review/SKILL.md")
jq -n --arg version "$version" --arg model "$MODEL" --argjson round "$FINAL_ROUND" \
  '{evaluator_locator: "skills/codex-plan-review/SKILL.md", evaluator_template_version: $version,
    framework: "codex", model: $model, final_round: $round}' > "$EVALUATOR_FILE"
```

Seal, then extract the evidence manifest to a file outside `reviews/`:

**Recipe inputs:** SLUG, ATTEMPT_ID, REVIEW_OUTPUT, DISPOSITIONS_FILE, EVALUATOR_FILE, SEAL_RESULT, EVIDENCE_FILE.
<!-- spec-plan-review-recipe: seal-review -->
```bash
lore plan review seal "$SLUG" --attempt-id "$ATTEMPT_ID" --output "$REVIEW_OUTPUT" \
  --dispositions "$DISPOSITIONS_FILE" --evaluator-manifest "$EVALUATOR_FILE" --json > "$SEAL_RESULT"
jq -e '.evidence_manifest' "$SEAL_RESULT" > "$EVIDENCE_FILE"
```

File the outcome with the same outcome, verdict, and reason the ledger sealed; the writer refuses a filing that disagrees with the sealed judgment, and an exact replay by the caller — the spec protocol filing the same attempt under the same advisor name — is reused rather than duplicated.

**Recipe inputs:** SLUG, ATTEMPT_ID, OUTCOME, VERDICT, REASON, EVIDENCE_FILE.
<!-- spec-plan-review-recipe: file-outcome -->
```bash
args=("$SLUG" --ceremony spec-post-plan --advisor codex-plan-review --attempt-id "$ATTEMPT_ID"
      --outcome "$OUTCOME" --verdict "$VERDICT" --evidence-manifest "$EVIDENCE_FILE" --json)
if [[ -n "$REASON" ]]; then args+=(--reason "$REASON"); fi
lore spec outcome "${args[@]}"
```

## Step 8: Final report

```text
[codex-plan-review] COMPLETE — <slug>
  Reviewed: attempt <attempt-id>, revision <revision-id> (sealed; outcome <outcome>)
  Gate: <PASSED|FAILED> — Interface Clarity: <rating>
  Rounds: <1|2> | Edits applied: <N accepted + N modified> | Rejected: <N>
  Scorecard: <7 rows appended | capture failed; rows absent>
  Current revision: <revision-id> (same as reviewed | published after the final round; not rated)
  Advisory: <any remaining WEAK/MISSING criteria and their ratings>
```

Every accepted edit was already published through `lore plan revise`, which regenerated `tasks.json` for that revision; no separate regeneration step follows. Acceptance of the plan, dispatch, and finalization keep their existing owners; this report is evidence for those decisions, not one of them.
