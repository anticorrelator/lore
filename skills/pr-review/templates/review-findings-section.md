# Review Findings section template (Step 6e Section 3)

Load when assembling Section 3 of the followup report body. This is the **author-facing** report surface — severity-neutral by design (see `findings-format.md` → External Output Formatting): severity drives ordering, never tier headers or a verdict line.

```markdown
## Review Findings

<All retained findings as a single numbered list in the reviewer's importance order. Internal
severity drives the ORDER only — no verdict line, no severity counts, no tier subheadings.
Each finding: observed fact → conditional stake, internal scaffolding stripped per 6d-ii.
Questions are interleaved by importance, phrased as the open question itself. If there are zero
findings, state "No findings." and omit the list.>

1. `path/to/file.ext:42` — <observed fact → conditional stake>
2. `path/to/file.ext:87` — <observed fact → conditional stake>
3. `path/to/other.ext:15` — <open question, as written>

### Supplementary Reports

<Include only if non-conforming ceremony output exists — omit this heading entirely otherwise>

#### <skill-name> [ceremony]

<raw output from the ceremony lens>
```
