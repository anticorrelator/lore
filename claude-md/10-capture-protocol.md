## Capture Protocol

Capture is enforced structurally: a Stop hook evaluates every session for uncaptured discoveries, and worker templates in `/implement` and `/spec` include a capture step.

When `[capture] N pending candidates — process via /remember first-turn` appears in SessionStart output, run `/remember` **Step 0a** (pending captures intake). For interactive capture during a session, run `/remember` **Step 2** (4-condition gate, categories, calibration, manual CLI form).
