---
name: codex-design-review
description: "Submit a work item's prepared abstract design (Goal, Design Decisions, Narrative, Architecture Diagram) to Codex CLI for a parsimony and legibility assessment. Use during /spec after abstract synthesis and before tasks are drafted, or when registered as the spec-design ceremony evaluator."
argument_description: "<work-item-slug> [--attempt <attempt-id> --revision <revision-id>]"
---

# Codex Design Review

Submit a work item's abstract design to the Codex CLI (`codex exec`) for one question: is the design **lean and legible** — easy to understand and maintain for humans and agents, without needless machinery or scope creep? Two rounds bound the exchange: Codex proposes changes, the evaluating agent decides each one with codebase context Codex does not have, and Codex answers those decisions once. **Invoking this skill is the user's choice — once invoked, it runs autonomously.**

This skill is the parsimony/legibility counterpart to `codex-plan-review`. Where `codex-plan-review` asks what a complete Tasks plan is missing, this skill asks whether anything in the abstract design is unnecessary, ambiguous, or over-engineered. It is advisory: a verdict blocks nothing on its own. The review reads immutable prepared bytes, every plan edit stays with the seat that owns the plan, and each reviewed revision keeps its own attempt.

## When to Use

- During `/spec` after abstract synthesis (Goal, Design Decisions, Narrative, Architecture Diagram), **before** tasks are drafted
- When registered as the ceremony evaluator for `spec-design` (`lore ceremony get spec-design`)
- When a second opinion on leanness is wanted before committing to task breakdown

## Step 1: Bind the reviewed input

The reviewed input is a prepared review attempt: `reviews/<attempt-id>/` under the work item, holding `prepared.json`, `plan.md`, `tasks.json`, and `anchor.md` for one committed revision, published by `lore plan review prepare`. Every round reads those copies. The live `plan.md` is the seat's working file and is never the reviewed input, because a round that read live bytes could certify text no attempt recorded.

Resolve the store and the scripts beside the `lore` you are running, so direct script calls exercise the same checkout as the verbs:

**Recipe inputs:** none.
<!-- spec-design-review-recipe: resolve-paths -->
```bash
KNOWLEDGE_DIR="$(lore resolve)"
SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "$(command -v lore)")")/../scripts" && pwd -P)"
printf 'KNOWLEDGE_DIR=%s\nSCRIPTS_DIR=%s\n' "$KNOWLEDGE_DIR" "$SCRIPTS_DIR"
```

**Commissioned entry.** The caller — the spec protocol at its design gate, or a coordinator commissioning a review — passes `--attempt <attempt-id> --revision <revision-id>` beside the slug. It prepared that attempt under ceremony `spec-design`; nothing is published here. Skip to the read below.

**Direct entry.** Only a work item reference arrives. Resolve it to a slug, publish the live plan as a revision, and prepare a fresh attempt. An identical plan reuses its current revision (`status: current`); a changed plan publishes the next one. An abstract plan with no Tasks section publishes with zero tasks. Prepare requires the item's intent anchor, so an item without one stops here with the writer's message rather than reviewing against no anchor. Mint the attempt id as `codex-design-<UTC timestamp>-r1`, for example `codex-design-20260905T170000Z-r1`.

**Recipe inputs:** INPUT.
<!-- spec-design-review-recipe: resolve-item -->
`lore work show "$INPUT" --json | jq -er '.slug'`

**Recipe inputs:** SLUG, REASON, AUTHOR_ROLE.
<!-- spec-design-review-recipe: publish-revision -->
`lore plan revise "$SLUG" --reason "$REASON" --author-role "$AUTHOR_ROLE" --json`

`AUTHOR_ROLE` names who is publishing (`spec-lead`, `coordinator`, `designer`); the revision row records it. Read `revision_id` from the output.

**Recipe inputs:** SLUG, ATTEMPT_ID, REVISION_ID.
<!-- spec-design-review-recipe: prepare-review -->
```bash
lore plan review prepare "$SLUG" --attempt-id "$ATTEMPT_ID" --ceremony spec-design \
  --revision "$REVISION_ID" --purpose criterion-adequacy --json
```

**Both entries** read the prepared attempt through the evidence reader, which checks the snapshot hashes against the committed revision. The read refuses an attempt prepared under another ceremony, an attempt holding a different revision than the one named, and an attempt whose evidence is missing or altered; the caller then fixes the identity rather than the skill guessing which input was meant.

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, SLUG, ATTEMPT_ID, REVISION_ID.
<!-- spec-design-review-recipe: read-prepared -->
```python
import json, os, runpy, sys
from pathlib import Path
api = runpy.run_path(os.path.join(os.environ["SCRIPTS_DIR"], "work-evidence.py"))
item = Path(os.environ["KNOWLEDGE_DIR"]) / "_work" / os.environ["SLUG"]
attempt = os.environ["ATTEMPT_ID"]
try:
    prepared = api["review_prepared"](item, attempt)
except (ValueError, OSError, KeyError, TypeError) as exc:
    sys.exit("[codex-design-review] prepared review unavailable for attempt %s: %s" % (attempt, exc))
if prepared["ceremony"] != "spec-design":
    sys.exit("[codex-design-review] attempt %s was prepared under %s, not spec-design" % (attempt, prepared["ceremony"]))
if prepared["revision_id"] != os.environ["REVISION_ID"]:
    sys.exit("[codex-design-review] attempt %s holds revision %s, not %s" % (attempt, prepared["revision_id"], os.environ["REVISION_ID"]))
print(json.dumps({"slug": os.environ["SLUG"], "attempt_id": attempt, "revision_id": prepared["revision_id"],
                  "ceremony": prepared["ceremony"], "purpose": prepared["purpose"],
                  "prepared_dir": str(item / "reviews" / attempt),
                  "plan_file": str(item / prepared["plan_path"]), "tasks_file": str(item / prepared["tasks_path"]),
                  "anchor_file": str(item / prepared["anchor_path"])}))
```

State the identity before reading anything else, so the transcript shows which bytes every later judgment is about:

```text
[codex-design-review] Reviewing <slug> — attempt <attempt-id>, revision <revision-id>, ceremony spec-design
  prepared: <prepared_dir>
```

## Step 2: Select the design slice

The design slice is the prepared `plan.md` up to its first top-level `## Tasks` heading, or the legacy `## Phases` heading on older plans, or the whole file when neither exists. Headings are recognized structurally: a line that opens a level-two heading outside any fenced block. A `## Tasks` line quoted inside a fenced example is text, not a boundary. When an `## Open Questions` section follows the boundary, it is carried into the slice explicitly, so a design whose open questions were written after the tasks still shows them to the reviewer. Everything before the boundary is kept in the order the plan presents it — title, Goal and Non-Goals, Context or Investigations, Key Assertions, Narrative, Design Decisions, Architecture Diagram, Open Questions — with nothing selected by name. Tasks themselves are never included — this review is scoped to the abstract design.

**Recipe inputs:** PLAN_FILE, DESIGN_FILE.
<!-- spec-design-review-recipe: design-slice -->
```python
import json, os, re
from pathlib import Path
lines = Path(os.environ["PLAN_FILE"]).read_text().splitlines(keepends=True)
fence, headings = None, []
for index, line in enumerate(lines):
    if fence:
        if re.fullmatch(r"\s*" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", line):
            fence = None
        continue
    opened = re.match(r"\s*(`{3,}|~{3,})", line)
    if opened:
        fence = opened.group(1)
        continue
    heading = re.match(r" {0,3}##\s+(.+?)\s*#*\s*$", line)
    if heading:
        headings.append((index, heading.group(1).strip()))
boundary = next(((index, title) for index, title in headings if title in ("Tasks", "Phases")), None)
end = boundary[0] if boundary else len(lines)
selected, carried = lines[:end], []
if boundary:
    for position, (index, title) in enumerate(headings):
        if index > boundary[0] and title == "Open Questions":
            stop = headings[position + 1][0] if position + 1 < len(headings) else len(lines)
            selected = selected + ["\n"] + lines[index:stop]
            carried.append(title)
Path(os.environ["DESIGN_FILE"]).write_text("".join(selected))
print(json.dumps({"boundary": boundary[1] if boundary else None, "boundary_line": boundary[0] + 1 if boundary else None,
                  "sections": [title for index, title in headings if index < end], "carried_after_boundary": carried,
                  "unterminated_fence": fence is not None, "lines": len(selected)}))
```

The summary names the boundary, the sections selected, and any section carried from after it. A present boundary means tasks already exist. Commissioned under `spec-design`, the caller chose a design-stage review of that revision; proceed and name the boundary in the final report. At direct entry, say so and ask whether to proceed, since `codex-plan-review` is the full-plan review:

```text
[codex-design-review] plan.md already contains Tasks (line N). This skill reviews the abstract
design only. For full-plan review, use /codex-plan-review instead.
```

An `unterminated_fence` of true means a fence never closed and everything after it was treated as fenced text; fix the plan before reviewing it.

## Step 3: Codex review (Round 1)

Build the prompt from the prepared anchor and the design slice. The anchor is the original intent the design must serve, read from the prepared copy. The prompt names the artifact — work item and revision — so a proposal that cites text absent from this artifact is recognizable as a mismatch and rejected as one, rather than evaluated as advice about some sibling.

**Recipe inputs:** SLUG, REVISION_ID, DESIGN_FILE, ANCHOR_FILE, PROMPT_FILE.
<!-- spec-design-review-recipe: design-prompt-round-1 -->
````bash
{
cat <<'PROMPT'
Review the following abstract design for one question: is it lean and legible — easy
to understand and maintain for humans and agents, without needless machinery or scope
creep? Tasks have not been drafted yet. Do not evaluate implementation detail.

**Calibration:** Prefer preserving necessary complexity over forcing minimalism. Flag
complexity only when its purpose, owner, boundary, or payoff is unclear. A design that
does exactly what the goal requires — no more, no less — is the target.

**Anchors** (keep judgment consistent across invocations):

- **Goal fit** — every major decision serves the stated goal or a stated constraint
- **Necessary machinery** — abstractions, new components, protocols, and terminology
  earn their keep against the goal; speculation ("we might need…") is not justification
- **Legibility** — a future implementer can explain the design path without
  reconstructing hidden reasoning; rationales name tradeoffs, not just benefits
- **Scope discipline** — nice-to-haves are deferred or explicitly named out of scope
- **Integration fit** — the design aligns with existing system boundaries and does not
  invent parallel concepts without cause

**Evidence status:** Assertions and findings in the design may be labeled with
evidence strength — `[verified]` (independently checked), `[unverified]` (researcher
claim), or no label (self-generated in short flow; treat as unverified). Do not
challenge a design choice merely because its supporting evidence is unverified.
Challenge only when the design contradicts verified evidence, or when no supporting
evidence exists at all.

**Intent anchor:** The <ANCHOR> block is the original intent this design must serve.
Judge the design against it; do not propose replacing it.

---

## Verdict

Return exactly one of:

- **PASS** — lean and legible; only minor wording or emphasis suggestions
- **CONCERNS** — broadly viable, but one or more decisions should be tightened before
  task drafting
- **REWORK** — likely to propagate avoidable complexity, ambiguity, or scope creep

Briefly explain the verdict (2-4 sentences) before listing proposals.

## Proposals

Surface up to **5 proposals**, ordered by severity (highest first). Omit this section
entirely if the verdict is PASS with no actionable suggestions. Each proposal uses
this format:

~~~
### Proposal N: <one-line description>

Type:       Cut | Clarify | Reframe | Challenge | Defer
Target:     Decision: <name> | Narrative | Diagram | Goal | Assertions | Open Questions
Severity:   High | Medium | Low
Concern:    <one sentence naming the specific issue>
Suggestion: <prose recommendation — what to change and how>
Why:        <one sentence tying this to a specific anchor above>
~~~

**Type definitions:**
- **Cut** — remove this element; it is not earning its keep
- **Clarify** — the element is necessary but its meaning, scope, or contract is ambiguous
- **Reframe** — the element is necessary but described in a way that obscures intent
- **Challenge** — the element's rationale is thin; argue for a different approach
- **Defer** — the element is legitimate but not needed for the current goal; move to
  Open Questions or a follow-up work item

---
PROMPT
printf '\nArtifact under review: work item %s, plan revision %s. Anchor every proposal to text in this artifact.\n' "$SLUG" "$REVISION_ID"
printf '\n<ANCHOR>\n'; cat "$ANCHOR_FILE"; printf '\n</ANCHOR>\n\n<DESIGN>\n'; cat "$DESIGN_FILE"; printf '\n</DESIGN>\n'
} > "$PROMPT_FILE"
````

Resolve the evaluator model once per invocation from the Codex harness's advisor binding under the `spec` ceremony, and pass exactly that model to Codex, so the evaluator manifest sealed later names the model that produced the verdict:

**Recipe inputs:** SCRIPTS_DIR.
<!-- spec-design-review-recipe: resolve-evaluator-model -->
```bash
source "$SCRIPTS_DIR/lib.sh"
LORE_FRAMEWORK=codex bash "$LORE_REPO_DIR/adapters/agents/codex.sh" resolve_model_for_role advisor spec
```

Submit the prompt through `codex exec` in read-only sandbox mode, reading the prompt from stdin and capturing stdout as the response. A binding with a reasoning-effort suffix splits into model and effort here:

**Recipe inputs:** SCRIPTS_DIR, MODEL, PROMPT_FILE, RESPONSE_FILE.
<!-- spec-design-review-recipe: codex-submit -->
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
if [[ ! -s "$RESPONSE_FILE" ]]; then echo "[codex-design-review] Codex returned no output" >&2; exit 1; fi
```

## Step 4: Evaluate Round 1

Read the response and extract the verdict, its explanation, and the proposals. Report the summary:

```text
[codex-design-review] Round 1 — Codex verdict for <slug>: <PASS|CONCERNS|REWORK>

  <2-4 sentence verdict explanation from Codex>

  Proposals: <N> (High: <n>, Medium: <n>, Low: <n>)
```

Evaluate each proposal against codebase context Codex does not have. Guard against **generic simplification bias** — a proposal that reads well in isolation may target an element that exists for integration safety, migration reasons, or a constraint Codex cannot see from the design alone. A proposal is advice about the design; it cannot widen or narrow the work item's scope on its own, and a proposal that would change the intent anchor is a decision for the seat, not an edit. For each proposal, decide:

- **Accept** — the concern is real and the suggestion is appropriate; apply it to the live `plan.md`
- **Modify** — the concern is real but the suggestion goes too far or misses a constraint; apply a tempered version
- **Reject** — the concern is not justified given codebase context; keep the design as-is

For each decision, report:

```text
[codex-design-review] <Accept|Modify|Reject>: Proposal N — <description>
  <one-line rationale citing the specific codebase context that informed it>
```

Record every decision in the **disposition ledger**, a JSON file the evaluating agent authors and extends round by round. It is the durable history of the exchange: the round-2 prompt is rendered from it, and the sealed dispositions are derived from it, so a decision that is not in the ledger did not happen as far as the record is concerned. The `verdict` field copies Codex's raw token byte for byte.

```json
{
  "schema_version": 1,
  "skill": "codex-design-review",
  "rounds": [
    {
      "round": 1,
      "attempt_id": "codex-design-20260905T170000Z-r1",
      "revision_id": "af6eae2cc818",
      "verdict": "CONCERNS",
      "proposals": [
        {
          "number": 1,
          "description": "Cut the second cache layer",
          "type": "Cut",
          "severity": "High",
          "disposition": "Reject",
          "rationale": "The layer exists for the migration path in scripts/migrate.sh, which the design slice does not show.",
          "applied": null
        },
        {
          "number": 2,
          "description": "Clarify who owns the packet ledger",
          "type": "Clarify",
          "severity": "Medium",
          "disposition": "Modify",
          "rationale": "Ownership is real but already fixed by the sole-writer rule; the decision names the writer instead of adding a component.",
          "applied": "D3 now names scripts/packet-append.sh as the ledger's sole writer."
        }
      ]
    }
  ]
}
```

**Applying edits.** Accepted and modified proposals are applied to the live `plan.md`, never to the prepared copy. The edited plan is then published as a revision and a fresh attempt is prepared for it, because Codex must answer against the bytes that now exist and a sealed verdict must name the revision it judged. Use `publish-revision` with a reason naming the round, then `prepare-review` with the round-2 attempt id — the round-1 attempt id with `-r2` appended — and the new revision, then `read-prepared` and `design-slice` against the new attempt. The round-1 attempt stays prepared and unsealed; its verdict and every disposition travel in the ledger sealed with the final attempt, so nothing pretends the superseded bytes were certified.

If every proposal was rejected, the plan is unchanged and round 2 rereads the same attempt. If every proposal was accepted, or there were none, no answer is owed: skip to Step 7 with the attempt that now holds the reviewed bytes (the fresh attempt when edits were applied, the original one otherwise).

## Step 5: Codex response (Round 2)

Render the ledger into the round-2 prompt beside the current design slice. The recipe refuses when round 1 left nothing to answer, which is the case Step 4 already routed past this step.

**Recipe inputs:** SLUG, REVISION_ID, DESIGN_FILE, ANCHOR_FILE, LEDGER_FILE, PROMPT_FILE.
<!-- spec-design-review-recipe: design-prompt-round-2 -->
```python
import json, os, sys
from pathlib import Path
ledger = json.loads(Path(os.environ["LEDGER_FILE"]).read_text())
first = ledger["rounds"][0]
if not any(p["disposition"] in ("Modify", "Reject") for p in first["proposals"]):
    sys.exit("[codex-design-review] round 2 is not needed: every round-1 proposal was accepted or none was made")
parts = ["You previously reviewed this abstract design and proposed changes. The reviewing agent\n"
         "evaluated them against codebase context and recorded these dispositions:\n\n## Disposition Ledger\n"]
for p in first["proposals"]:
    parts.append("\n### Proposal %s: %s\nDisposition: %s\nRationale: %s\n" % (p["number"], p["description"], p["disposition"], p["rationale"]))
    if p["disposition"] == "Modify":
        parts.append("Applied version: %s\n" % p["applied"])
parts.append("""
---

Review the updated design below. Re-issue a verdict (PASS | CONCERNS | REWORK) and
focus your proposals on:

1. **Re-proposing rejected items** — only if you have a substantive counter-argument
   that engages with the stated rationale, not just repetition. A rejection citing
   specific codebase context is usually decisive.
2. **Refining modifications** — if a modification missed the point of your proposal
   (e.g., preserved the concern in a different form), propose a refined version.
3. **New concerns** — if the applied changes revealed issues not visible in the
   original design.

Same proposal format and 5-proposal cap as Round 1. Do not re-propose accepted items.
The <ANCHOR> block is unchanged and remains the intent the design must serve.
""")
parts.append("\nArtifact under review: work item %s, plan revision %s. Anchor every proposal to text in this artifact.\n" % (
    os.environ["SLUG"], os.environ["REVISION_ID"]))
parts.append("\n<ANCHOR>\n%s\n</ANCHOR>\n\n<DESIGN>\n%s\n</DESIGN>\n" % (
    Path(os.environ["ANCHOR_FILE"]).read_text(), Path(os.environ["DESIGN_FILE"]).read_text()))
Path(os.environ["PROMPT_FILE"]).write_text("".join(parts))
```

Submit with `codex-submit`, the same model, and a fresh response file.

## Step 6: Evaluate Round 2

Parse the round-2 response and apply the same Accept/Modify/Reject evaluation as Step 4, adding a `round: 2` entry to the ledger with the attempt and revision it reviewed. Report:

```text
[codex-design-review] Round 2 — Codex verdict for <slug>: <PASS|CONCERNS|REWORK>

  Re-proposed: <N> | Refined: <N> | New: <N> | Accepted: <N> | Rejected: <N>
```

This is the final round — no further iteration. Accepted and modified round-2 proposals are applied to the live `plan.md` and published with `publish-revision`; that revision is one this review did not read. The verdict sealed in Step 7 belongs to the attempt round 2 judged, and the final report names both revisions so the seat can decide whether the post-edit revision needs a fresh invocation.

## Step 7: Seal the reviewed attempt and file the outcome

Seal exactly the attempt the final round judged: round 2's attempt when a second round ran, otherwise the attempt Step 4 finished on. Sealing happens once per attempt; a retry with identical bytes is reused, a retry with different bytes is refused, and nothing here writes a result row or edits any plan.

Compose the review output from the raw responses and the ledger, so the sealed prose carries both what Codex said and what was decided about it:

**Recipe inputs:** ROUND1_RESPONSE_FILE, ROUND2_RESPONSE_FILE, LEDGER_FILE, REVIEW_OUTPUT.
<!-- spec-design-review-recipe: compose-review-output -->
```bash
{
  printf '# Codex design review — round 1\n\n'
  cat "$ROUND1_RESPONSE_FILE"
  if [[ -n "$ROUND2_RESPONSE_FILE" ]]; then
    printf '\n\n# Codex design review — round 2\n\n'
    cat "$ROUND2_RESPONSE_FILE"
  fi
  printf '\n\n# Disposition ledger\n\n```json\n'
  cat "$LEDGER_FILE"
  printf '\n```\n'
} > "$REVIEW_OUTPUT"
```

Normalize the outcome. This is an authored decision, not a parse of Codex's prose: `completed` when the exchange reached a verdict the seat can act on, whatever that verdict is; `needs-decision` with a reason when the two-round cap left a High-severity proposal unresolved between Codex and the evaluating agent; `failed` when Codex could not review the input; `skipped` with a reason when Codex could not run at all. The `criterion-adequacy` judgment is the design-stage judgment this ceremony admits — whether the abstract design adequately serves the anchor — and says so plainly, because an abstract plan has no task criteria to certify. `result_ids` is always empty: this reviewer runs no commands and cites no execution evidence.

**Recipe inputs:** LEDGER_FILE, OUTCOME, REASON, JUDGMENT, RATIONALE, DISPOSITIONS_FILE.
<!-- spec-design-review-recipe: compose-dispositions -->
```python
import json, os, sys
from pathlib import Path
ledger = json.loads(Path(os.environ["LEDGER_FILE"]).read_text())
labels = {"Accept": "accepted", "Modify": "modified", "Reject": "rejected"}
dispositions = []
for entry in ledger["rounds"]:
    for p in entry["proposals"]:
        if p["disposition"] not in labels:
            sys.exit("[codex-design-review] unknown disposition in round %s proposal %s: %s" % (entry["round"], p["number"], p["disposition"]))
        dispositions.append({"finding": "Round %s, Proposal %s: %s" % (entry["round"], p["number"], p["description"]),
                             "disposition": labels[p["disposition"]], "reason": p["rationale"]})
document = {"schema_version": 1, "outcome": os.environ["OUTCOME"], "verdict": ledger["rounds"][-1]["verdict"],
            "reason": os.environ["REASON"] or None,
            "judgments": [{"purpose": "criterion-adequacy", "judgment": os.environ["JUDGMENT"],
                           "rationale": os.environ["RATIONALE"], "result_ids": []}],
            "dispositions": dispositions}
Path(os.environ["DISPOSITIONS_FILE"]).write_text(json.dumps(document, indent=2) + "\n")
```

The evaluator manifest names this skill file's version, the framework and model that produced the verdict, and the final round:

**Recipe inputs:** SCRIPTS_DIR, MODEL, FINAL_ROUND, EVALUATOR_FILE.
<!-- spec-design-review-recipe: evaluator-manifest -->
```bash
source "$SCRIPTS_DIR/lib.sh"
version=$(bash "$SCRIPTS_DIR/template-version.sh" "$LORE_REPO_DIR/skills/codex-design-review/SKILL.md")
jq -n --arg version "$version" --arg model "$MODEL" --argjson round "$FINAL_ROUND" \
  '{evaluator_locator: "skills/codex-design-review/SKILL.md", evaluator_template_version: $version,
    framework: "codex", model: $model, final_round: $round}' > "$EVALUATOR_FILE"
```

Seal, then extract the evidence manifest to a file outside `reviews/`:

**Recipe inputs:** SLUG, ATTEMPT_ID, REVIEW_OUTPUT, DISPOSITIONS_FILE, EVALUATOR_FILE, SEAL_RESULT, EVIDENCE_FILE.
<!-- spec-design-review-recipe: seal-review -->
```bash
lore plan review seal "$SLUG" --attempt-id "$ATTEMPT_ID" --output "$REVIEW_OUTPUT" \
  --dispositions "$DISPOSITIONS_FILE" --evaluator-manifest "$EVALUATOR_FILE" --json > "$SEAL_RESULT"
jq -e '.evidence_manifest' "$SEAL_RESULT" > "$EVIDENCE_FILE"
```

File the outcome with the same outcome, verdict, and reason the ledger sealed; the writer refuses a filing that disagrees with the sealed judgment, and an exact replay by the caller — the spec protocol filing the same attempt under the same advisor name — is reused rather than duplicated.

**Recipe inputs:** SLUG, ATTEMPT_ID, OUTCOME, VERDICT, REASON, EVIDENCE_FILE.
<!-- spec-design-review-recipe: file-outcome -->
```bash
args=("$SLUG" --ceremony spec-design --advisor codex-design-review --attempt-id "$ATTEMPT_ID"
      --outcome "$OUTCOME" --verdict "$VERDICT" --evidence-manifest "$EVIDENCE_FILE" --json)
if [[ -n "$REASON" ]]; then args+=(--reason "$REASON"); fi
lore spec outcome "${args[@]}"
```

## Step 8: Final report

```text
[codex-design-review] COMPLETE — <slug>
  Reviewed: attempt <attempt-id>, revision <revision-id> (sealed; outcome <outcome>)
  Final verdict: <PASS|CONCERNS|REWORK>
  Rounds: <1|2> | Proposals applied: <N accepted + N modified> | Rejected: <N>
  Current revision: <revision-id> (same as reviewed | published after the final round; not reviewed)
  <If the slice found a Tasks or Phases boundary: name it here.>
  <If CONCERNS or REWORK: list the top remaining concerns — ones not addressed —
   so the seat can decide whether to revise before task drafting.>
```

This skill is **advisory**. A CONCERNS or REWORK verdict does not block the spec flow; the seat decides whether to revise the abstract design before task drafting, and acceptance of the design is recorded by the seat separately from this evidence. When significant changes were applied, suggest re-reading the Narrative and Architecture Diagram so both still describe the simplified design before proceeding.
