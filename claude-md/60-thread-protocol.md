## Thread Protocol

Conversational threads persist topic-based memory across sessions at `_threads/` within each repo's knowledge store. They capture evolving thinking, preferences, and discussion context — not facts (knowledge store) or goals (plans).

### Three Permanence Tiers
- **Pinned:** Always loaded at session start (e.g., `how-we-work`). Max 2-3 per repo.
- **Active:** Touched in last ~5 sessions. Loaded as summary (topic + last entry).
- **Dormant:** Not loaded, searchable. Comes back when relevant.

### First-Turn Behavior

When `_threads/_pending_digest.md` exists at session start:
1. Read the pending digest (previous session's extracted highlights)
2. Decide which existing thread(s) to update — or if a new thread is needed
3. Write thread entries with format: `## YYYY-MM-DD` + Summary, Key points, Shifts (optional), Related
4. Delete the `_pending_digest.md` file
5. Brief feedback: `[thread: topic-name] Updated with previous session discussion`

If no pending digest, skip silently.

### Mid-Session Thread Awareness

After significant topic shifts or decisions, consider whether a thread update is warranted. Do NOT force updates — only note when genuinely useful. Look for:
- A recurring topic from a pinned/active thread being revisited
- A clear shift in thinking from what a thread previously recorded
- A new topic emerging that will likely span multiple sessions

### Thread Entry Format
```
## YYYY-MM-DD
**Summary:** One-sentence overview
**Key points:**
- Specific decisions, shifts, or ideas
**Shifts:** Change in thinking from previous entries (optional — only when genuine)
**Related:** [[plan:name]], [[knowledge:file#heading]]
```

### Creating New Threads

Create when a topic has >2 substantive exchanges AND doesn't match existing threads. New threads start as `tier: active`. Only pin threads after confirmed long-term relevance.

### Feedback Style

Use bracketed informational prefixes — short, no emoji, clearly distinct from conversation:
- `[thread: topic] Updated with today's discussion`
- `[thread: topic] Loading 3 previous entries...`
- `[thread: new] Created "deployment-strategy" from today's discussion`
