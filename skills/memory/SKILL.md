---
name: memory
description: Manage the per-project knowledge store — USE FIRST when searching for past decisions, patterns, conventions, or architecture before Grep or Explore agents. Commands: add, search, view, curate, heal, init
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
lore search "<query>" --type knowledge
```
Show the script output. For top matches, briefly summarize relevant context.

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
2. **Quality gate for medium-confidence entries:** Scan entry files for `confidence: medium` in their HTML comment metadata (typically from agent captures). Re-evaluate each against the 4-condition gate:
   - **Reusable** beyond the original task?
   - **Non-obvious** — not already covered by another entry or docs?
   - **Stable** — still accurate?
   - **High confidence** — can you verify it now?
   Drop entries that fail the gate. Upgrade passing entries to `confidence: high`.
3. **Deduplicate:** Merge entries that describe the same insight from different contexts.
4. **Backlinks:** Add missing `[[backlinks]]` cross-references between related entries.
5. **Title quality:** Improve vague or generic titles to be specific and scannable.
6. **Stale entries:** Flag or remove entries that contradict current code.
7. **Confidence calibration:** If `$KDIR/_capture_log.csv` exists, count entries with `source=stop-hook`. Compare against the number of stop-hook medium-confidence entries that passed the quality gate (upgraded) vs failed (dropped). Report the pass rate:
   - `>70%` pass rate: "Stop hook evaluator is well-calibrated"
   - `40-70%` pass rate: "Stop hook evaluator calibration is acceptable"
   - `<40%` pass rate: "Stop hook evaluator needs tightening — consider refining triggers in scripts/stop-capture-prompt.txt"
8. Report what was found and fixed:
   ```
   [curate] Done.
     Dropped: N entries (reasons)
     Merged: N duplicates
     Upgraded: N to high confidence
     Backlinks added: N
     Stop hook calibration: X/Y passed (Z%) — <assessment>
   ```
9. Run `lore heal`

**Drop authority:** Curate has explicit authority to remove entries without user confirmation when they fail the 4-condition gate. Report what was dropped in the summary so the user can object.

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
