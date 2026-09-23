## Capture Protocol

Capture is a reflex, not a ceremony. When a session produces a reusable claim — a convention, a gotcha, a settled preference, a design rationale, a root cause — capture it in that turn with `lore capture`. Do not offer to capture, ask whether to, or defer to `/remember`; run the command, then mention what you captured in one line so the owner can say "don't keep that." This is the write-side twin of "run `lore search` before Grep": retrieval without capture is a store that only ever shrinks. Capture is never user-gated; only the periodic passes over the store — `/memory curate`, `/renormalize` — wait for the owner.

The gate describes what qualifies — reusable, non-obvious to a future agent, stable, verified — it is not a permission step. Judge it in your head and move. Err toward capturing: an entry is cheap to drop and an insight is expensive to lose. When you want the full calibration (tiers, orientation entries, debugging-narrative format), `/remember` **Step 2** has it; you do not need it for an ordinary fact.

The form that lands first time:

```bash
lore capture --insight "<claim>" --title "<the claim as a headline>" --context "<why it holds / how you checked>" \
  --scale <abstract|architecture|subsystem|implementation> --category <gotchas|conventions|principles|preferences|…> \
  --related-files <paths> --producer-role <your position> --protocol-slot <slot> --work-item <slug>
```

`--scale` is required (one label, or two adjacent labels comma-delimited). In a bare interactive session with no skill running, the position is `--producer-role interactive --protocol-slot Reflection` — that is the established pairing, not a placeholder. Entries show who left them and during what work; an entry captured without those shows no byline, and a byline is how the next reader finds the context behind the claim.

`--title` is the line every search result and packet leads with. Without it, the title is the claim's first eight words, usually cut off mid-sentence, so write one that states the claim.

After filing, capture compares the new entry with the live entries in the store. A `[capture] similar entry: <path> (similarity 0.NN)` line is yours to settle before moving on, because you hold the context that tells a duplicate from a neighbour. Read the entry it names:
- If it states the same claim, keep the better entry and retire the other with `lore retire <path> --superseded-by <kept>`.
- If your capture overturns it, the older entry is wrong: `lore correct` it.
- If the two only share a subject, both stand.

`[capture] similarity check skipped: <reason>` means the check didn't run, not that nothing matched. Under `--json`, `similar` lists the matches, and it is `null` with a `similar_skipped` reason when the check didn't run.

SessionStart miners are a backstop, not the writer: `mine-retrieval-misses.py` (sole writer of `_pending_captures/`) turns missed `lore search` calls that led to manual derivation into capture candidates, and `packet-assess.py` routes needed-but-missing packet gaps through the same writer. They catch what a session missed; a session that captures as it goes leaves them nothing. When `[capture] N pending candidates — process via /remember first-turn` appears in SessionStart output, run `/remember` **Step 0a** (pending captures intake).
