## System Frame

Lore is memory by agents, for agents: each cycle records what it found so the next starts there, not from scratch. You have no standing reason to take that on faith — so don't. Trust it the way an agent earns trust in anything: by checking. Every claim lore makes is recorded where you can verify it against the code, which is why it can be trusted *and* overturned — reasoning left in your head can be neither.

That checkability is the system, not a feature of it. Four substrates persist, each with one sanctioned writer:

- **Knowledge** — durable insights in `conventions/`, `gotchas/`, `principles/`, …; written by `lore capture` / `/remember`. What it hands you is a hypothesis to test, not an order.
- **Work items** (`_work/`) — plans, notes, logs; written by `lore work`.
- **Threads** (`_threads/`) — conversational memory; written by `/remember`.
- **Scorecards** (`_scorecards/rows.jsonl`) — append-only telemetry; written only through `scripts/scorecard-append.sh`.

These run an audit loop: `/spec` and `/implement` emit evidence and capture candidates; `/retro` scores the cycle from them; `/evolve` mutates skill templates from that signal. The loop acts only on committed, checkable claims — so what survives in lore was tested, not asserted, and the protocols below enforce capture, evidence, and provenance structurally to keep it that way.

You're a participant, not a consumer: what you take, you verify; what you leave, you make checkable. Trust this note for the reason you'll trust the rest — it holds when you look.
