### Review Selection

After fetching PR data, present reviews as batches grouped by reviewer. The user selects which batch to work through; other batches are deferred, not mixed in.

#### Presentation format

List each review submission as a selectable batch:

```
1. @reviewer-a (CHANGES_REQUESTED) — 5 inline comments, submitted 2025-06-10T14:32:00Z
2. @reviewer-b (APPROVED) — 2 inline comments, submitted 2025-06-10T16:05:00Z
3. Orphan comments — 3 comments (ungrouped, see below)
```

Each entry shows: reviewer login, review state, inline comment count, and submission timestamp. Order by submission time (earliest first).

#### Orphan comment grouping

Comments not attached to a review submission are grouped by time proximity. Comments posted within a ~5 minute window of each other are treated as a single batch. Comments outside that window are treated individually. Present orphan batches after named reviewer batches.

#### Selection behavior

- The user selects one or more batches by number (e.g., "1" or "1, 3").
- The selected batch becomes the working set for the current review pass.
- Unselected batches are noted as deferred — they can be revisited in a subsequent pass.
- If only one reviewer batch exists (plus any orphans), skip selection and work through it directly.

All consuming skills (`/pr-review`, `/pr-self-review`, `/pr-pair-review`, `/pr-revise`) reference this step after fetching PR data and before applying the review checklist or categorization logic.

