# Ceremony lens Agent-task prompt template (Step 3b-ceremony)

Load when constructing the `Agent` task for each ceremony lens. Use the `general-purpose` subagent type.

```
# <Ceremony Lens Name> — PR #<PR_NUMBER>

Invoke the `/<skill-name>` skill on PR #<PR_NUMBER> in <owner>/<repo>:

    /<skill-name> <PR_NUMBER>

The skill fetches its own PR data — do not pre-fetch diff content, review context, or metadata.

When the skill completes, return its output verbatim. If it produced findings JSON in the standard Findings Output Format, return that JSON. If it produced a different output shape (narrative report, table, raw scanner output, etc.), return the raw text so it can be classified as supplementary in Step 3d.
```
