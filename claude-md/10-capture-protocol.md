## Capture Protocol

Capture is enforced structurally: a Stop hook evaluates every session for uncaptured discoveries, and worker templates in `/implement` and `/spec` include a capture step.

When `[capture] N pending candidates — process via /remember first-turn` appears in SessionStart output, run `/remember` **Step 0a** (pending captures intake). For interactive capture during a session, run `/remember` **Step 2** (4-condition gate, categories, calibration, manual CLI form).

Tier 3 candidates must carry producer-side `delta: covered | extends | contradicts | absent`. `covered` means already covered, `absent` means new, `extends` means updates an existing entry, and `contradicts` means conflicts with an existing entry. `closest_entry` is required for `extends` and `contradicts`. Keep `delta` classification separate from routing; `/remember`, `/spec`, or `/implement` decides whether the candidate is dropped, captured/promoted, updated, or sent through correction handling.
