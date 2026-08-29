## Capture Protocol

Capture is enforced structurally: SessionStart miners sweep the previous session for knowledge the store failed to deliver — `mine-retrieval-misses.py` (sole writer of `_pending_captures/`) turns missed `lore search` calls that led to manual derivation into capture candidates, and `packet-assess.py` routes needed-but-missing packet gaps through the same writer — and worker templates in `/implement` and `/spec` include a capture step.

When `[capture] N pending candidates — process via /remember first-turn` appears in SessionStart output, run `/remember` **Step 0a** (pending captures intake). For interactive capture during a session, run `/remember` **Step 2** (4-condition gate OR orientation gate, categories, calibration, manual CLI form).
