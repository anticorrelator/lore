## Thread Protocol

Conversational threads persist topic-based memory across sessions at `_threads/` — capturing evolving thinking, preferences, and discussion context (not facts, which belong in the knowledge store, or goals, which belong in plans).

When `[threads] Pending session digest — process via /remember first-turn` appears in SessionStart output, run `/remember` **Step 0b** (pending digest intake). For thread scanning during a session, see `/remember` **Step 3** (entry format, `_meta.json` schema, mid-session awareness, preference accumulation).
