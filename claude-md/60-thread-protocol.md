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
3. Write thread entries with format: `## YYYY-MM-DD` + Summary, Key points, Shifts (optional), Preferences (optional), Related
4. Extract preference signals from the digest and thread entries written in step 3. For each clear, reusable preference found, update the relevant thread's `_meta.json` `accumulated_preferences` array:
   - **Existing preference:** update `last_reinforced` date and append the new entry filename to `source_entries`
   - **New preference:** add a new object with `preference`, `first_seen`, `last_reinforced` (both today), and `source_entries`
5. Delete the `_pending_digest.md` file
6. Brief feedback: `[thread: topic-name] Updated with previous session discussion`

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
**Preferences:** User preferences or working-style signals observed this session (optional — only when a clear, reusable preference is expressed or demonstrated, not one-off requests)
**Related:** [[plan:name]], [[knowledge:file#heading]]
```

### Creating New Threads

Create when a topic has >2 substantive exchanges AND doesn't match existing threads. New threads start as `tier: active`. Only pin threads after confirmed long-term relevance.

### `_meta.json` Schema

Each thread directory contains a `_meta.json` with:
```json
{
  "topic": "Human-readable thread name",
  "tier": "pinned | active | dormant",
  "created": "ISO-8601 timestamp",
  "updated": "ISO-8601 timestamp",
  "sessions": 0,
  "accumulated_preferences": [
    {
      "preference": "Short description of the preference",
      "first_seen": "YYYY-MM-DD",
      "last_reinforced": "YYYY-MM-DD",
      "source_entries": ["2026-02-06.md", "2026-02-07-s18.md"]
    }
  ]
}
```

The `accumulated_preferences` array tracks user preferences distilled from thread entries. Each entry records when the preference was first observed, when it was most recently reinforced, and which thread entry files provide evidence. Preferences are added during `/remember` and pending digest evaluation. The array may be empty but should always be present for new threads.

### Feedback Style

Use bracketed informational prefixes — short, no emoji, clearly distinct from conversation:
- `[thread: topic] Updated with today's discussion`
- `[thread: topic] Loading 3 previous entries...`
- `[thread: new] Created "deployment-strategy" from today's discussion`
