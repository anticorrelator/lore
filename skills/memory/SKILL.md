---
name: memory
description: "Manage the per-project knowledge store — USE FIRST when searching for past decisions, patterns, conventions, or architecture before Grep or Explore agents. Commands: add, search, view, curate, heal, init"
user_invocable: true
argument_description: "[command] [args] — add <category> <title> | search <query> | view [category] [query] | curate | heal | init"
---

# /memory Skill

Manages the per-project knowledge store. Most subcommands are script calls — run and show the output.

## Route $ARGUMENTS

Match the first word of `$ARGUMENTS` to a command below. If empty, show the index.

Resolve knowledge path first:
```bash
KDIR=$(lore resolve)
```

---

### `add <category> <title>`

Quick-add directly to a category directory (bypasses inbox):

1. Write entry as `$KDIR/<category>/<slug>.md` with `# Title`, body, and `<!-- learned: ... | confidence: high | source: manual -->` metadata
2. If category directory doesn't exist, create it
3. Run `lore heal`

---

### `search <query>`
```bash
lore search "<query>" --type knowledge --scale-set <bucket>
```
Show the script output. For top matches, briefly summarize relevant context. Declare `<bucket>` per the rubric below — this is a per-query judgment, not a default.

**Scale rubric — declare explicitly at every retrieval surface:**

- **abstract** — portable principle, behavioral law, or design maxim. The claim survives generic-noun substitution: replace project-specific proper nouns with placeholders and the lesson still holds. Abstract entries make a *law*.
- **architecture** — project-level structure: decomposition, lifecycle, contracts, data model, invariants, cross-component flows, or major platform choices. Architecture entries make a *map*: "A does B, C does D, and E connects them."
- **subsystem** — local rule about one named area, feature, module, team, command family, integration, or workflow within a larger system. Concrete terms appear as participants in a local workflow rather than as the whole claim.
- **implementation** — concrete artifact fact: file, function, script, command, limit, field, test, line-level behavior. If removing the artifact name destroys the claim, classify here.

**Boundary tests:** abstract vs architecture — substitution test (does the claim survive replacing concrete proper nouns with generic placeholders, or does it become "A does B, C does D"?); architecture vs subsystem — whole-project structure or one bounded area?; subsystem vs implementation — can you state the rule without naming a specific function/file/line?

**Multi-label encoding (retrieval implication):** entries may carry one label or an *adjacent* pair (`abstract,architecture`, `architecture,subsystem`, `subsystem,implementation`); a `--scale-set` query matches an entry if any requested label is in the entry's set. The full decision tree (four tier tests + substitution test + multi-label rules) lives in the canonical `classifier` agent template (resolved via `resolve_agent_template classifier`; lore repo `agents/classifier.md`).

**±1 query pattern:** fixing a bug → `subsystem,implementation`; adding to a module → `subsystem,implementation`; modifying a component → `architecture,subsystem`; designing a feature → `abstract,architecture`.

---

### `view [category] [query]`
- No argument: run `lore index` and display the dynamic category/entry listing
- With category: `lore read <category>` (resolves knowledge, domains/, and _threads/ files)
- With category + query: `lore read <category> --query "<query>"` (matching sections full, non-matching as heading-only)
- `view inbox`: read `.md` files from `$KDIR/_inbox/`
- For threads: `lore read <slug> --type thread` or `lore read <slug> --type thread --query "<query>"`

---

### `curate`

Periodic refinement of the knowledge store (optional, not required).

Start with the mechanical pre-scan:
```bash
lore curate
```
This lists inbox remnants, medium-confidence entries, and entries missing backlinks. Then apply judgment:

1. **Refile inbox remnants:** If `$KDIR/_inbox/` has `.md` files (from interrupted captures), review each and either file to the correct category or drop.
2. **Quality gate for medium-confidence entries (per-entry agent-evaluator):** Scan entry files for `confidence: medium` in their HTML comment metadata (typically from agent captures). For each entry, the evaluator (you, the agent running `/memory curate`) records a one-line verdict naming the gate-leg decision, then aggregates the verdicts into the summary report at step 7 below. The evaluator IS the quality-gate; the drop authority at step 8's "Drop authority" note still applies.

   **Per-entry verdict vocabulary** — emit exactly one of:
   - `keep <path> (4-cond | orientation)` — the entry passes one of the two gates below; cite which gate. If both pass, prefer `4-cond` (the 4-condition gate is the canonical entry shape; orientation is the cross-boundary specialization).
   - `drop <path> (<trivial-reason>)` — the entry fails BOTH gates; cite one of the four trivial-reason codes from `agents/curator.md` (the same closed vocabulary the curator-agent uses on candidate-set survivors): `low-significance | duplicate-of-survivor | high-cost-to-verify | low-surface-area`. Do not invent a fifth code — force-fit the closest and note the awkward fit in the verdict line.
   - `escalate <path> (<abstain-reason>)` — the evaluator cannot confidently apply either gate; emit a short prose reason and route through `AskUserQuestion` for user adjudication. **Calibration:** lean toward `escalate` rather than `drop` when (a) the entry is tagged `confidence: high` but the agent's read finds it failing both gates (the discrepancy itself is signal worth surfacing), or (b) dropping would orphan backlinks pointing TO this entry from other entries (the consequences extend beyond this entry).

   The escalation path is the single canonical trigger for `AskUserQuestion` in the curate flow: the evaluator decides per-entry; only abstain/ambiguous verdicts surface for human adjudication. After-the-fact human-objection on the rollup (step 7) remains the secondary review surface.

   **Gate criteria** — apply per-entry against the verdict vocabulary above. The two gates mirror Step 2 of `/remember` exactly:

   **4-condition gate** (all four must be true — for facts, gotchas, rationale, conventions, directives):
   - **Reusable** beyond the original task?
   - **Non-obvious** — non-obvious to a future agent doing similar work; not already covered by another knowledge entry or by sources a future agent loads before raw exploration?
   - **Stable** — still accurate?
   - **High confidence** — can you verify it now?

   *Whose perspective:* condition 2 is agent-centric, not reader-centric — ask "would a future agent re-derive this from sources they already read, or would they have to dig?" rather than treating the agent's knowledge state as identical to a human reader skimming the repo. The commons is curated by agents for agents; the drop-gate evaluates against that audience.

   **Orientation gate** (all five must be true — for system maps, lifecycle overviews, cross-boundary assembly):
   1. **Reusable** — likely needed by future agents on more than one task. (Recurrence is required, not "could be useful someday.")
   2. **Cross-boundary** — reconstructing the understanding requires tracing behavior across at least 2 boundaries from this set: routing layer, persistence, lifecycle phase, state index, external command, shared helper, or protocol layer. (One-file orientation isn't orientation — it's either obvious or a gotcha.)
   3. **Canonical** — states the system's intended shape, not one agent's casual paraphrase. Disagrees with code? Don't capture — fix the code or capture a gotcha.
   4. **Anchored** — names the specific files, commands, tests, or directories that verify the claim (`--related-files`). Unanchored orientation goes stale invisibly.
   5. **Stable at architecture or subsystem altitude** — tag the entry `architecture`, `subsystem`, or `architecture,subsystem`. Implementation-scale orientation is malformed — route to the 4-condition gate as a fact, or drop.

   Drop entries that fail BOTH gates. Upgrade passing entries to `confidence: high`. If an orientation-shaped entry passes the orientation gate but its current `--scale` is `implementation`, fix the scale tag — do not silently downgrade by dropping it as a fact.
3. **Deduplicate:** Merge entries that describe the same insight from different contexts.
4. **Backlinks:** Add missing `[[backlinks]]` cross-references between related entries.
5. **Title quality:** Improve vague or generic titles to be specific and scannable.
6. **Stale entries:** Flag or remove entries that contradict current code.
7. Report what was found and fixed. Include the per-entry evaluator rollup from step 2 so the user can object to specific drops or escalations:
   ```
   [curate] Done.
     Evaluated: N (kept K, dropped D, escalated E)
     Dropped: D entries
       low-significance: <count>
       duplicate-of-survivor: <count>
       high-cost-to-verify: <count>
       low-surface-area: <count>
     Escalated: E entries (surfaced via AskUserQuestion)
     Merged: N duplicates
     Upgraded: N to high confidence
     Backlinks added: N
   ```
   Omit drop-reason or escalation rows whose count is zero.
8. Run `lore heal`

**Drop authority:** Curate has explicit authority to remove entries without user confirmation when they fail **both** the 4-condition gate and the orientation gate (i.e., neither gate passes). An entry that would pass the orientation gate but is mis-tagged at `implementation` scale is not a drop — fix the scale tag instead. Report what was dropped in the summary so the user can object.

---

### `renormalize`

Redirect to `/renormalize` skill. Invoke `/renormalize` instead.

---

### `heal`
```bash
lore heal
```
Show the script output. To apply fixes: `lore heal --fix`

---

### `init [--force]`
1. Check if inside a git repo: `git rev-parse --is-inside-work-tree`
2. If yes: `lore init`
3. If no: inform user, ask for confirmation, then `lore init --force`
4. Report the created path
