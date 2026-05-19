# pr-revise feedback-summary template

Used by `/pr-revise` Step 6 to present the categorized batch to the user.

```
## PR Feedback Summary

**PR:** #<number> — <title>
**Reviewed batch:** @<reviewer> (<STATE>) — N inline comments
**Readiness:** spec-needed | implement-ready
**Agreed changes:** N (direct tasks)
**Verification needed:** M (requires /spec)
**Deferred:** K
**Skipped (resolved/outdated):** J
**Knowledge enrichments:** X queries, Y citations surfaced

### Agreed Changes:
1. [task subject] — file.py:123

### Verification Directives:
1. [item] — Verify: [what to check] in `file:function`

### Items needing your input:
- [description with knowledge context]

### Deferred batches:
- @<reviewer2> (<STATE>) — N inline comments
```

If there are items needing input, ask about them in a single batched question.

If there are deferred batches, note that the user can re-invoke `/pr-revise` on the same PR to process the next batch.
