## Capture Protocol

Capture is enforced structurally: SessionStart miners sweep the previous session for knowledge the store failed to deliver — `mine-retrieval-misses.py` (sole writer of `_pending_captures/`) turns missed `lore search` calls that led to manual derivation into capture candidates, and `packet-assess.py` routes needed-but-missing packet gaps through the same writer — and worker templates in `/implement` and `/spec` include a capture step.

When `[capture] N pending candidates — process via /remember first-turn` appears in SessionStart output, run `/remember` **Step 0a** (pending captures intake). For interactive capture during a session, run `/remember` **Step 2** (4-condition gate OR orientation gate, categories, calibration, manual CLI form).

Pass `--producer-role <your position> --work-item <slug>` on every capture. Entries now show who left them and during what work; an entry captured without those shows no byline at all, and a byline is how the next reader finds the context behind the claim.
