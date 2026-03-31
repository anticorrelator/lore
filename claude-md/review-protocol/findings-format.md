### Findings Output Format

Lens skills produce structured JSON findings that can be consumed by `post-review.sh`, written to work items, or presented to the user. This schema is the contract between lens skills and downstream consumers.

#### Schema

```json
{
  "lens": "<lens-name>",
  "pr": <pr-number>,
  "repo": "<owner>/<repo>",
  "findings": [
    {
      "severity": "blocking | suggestion | question",
      "title": "Short description of the finding",
      "file": "path/to/file.ext",
      "line": 42,
      "body": "Detailed explanation of the finding. May include markdown formatting.",
      "knowledge_context": [
        "entry-title — one-line relevance summary"
      ]
    }
  ]
}
```

#### Field definitions

- **lens** — Identifier for the lens that produced the findings. One of: `correctness`, `security`, `regressions`, `thematic`, `blast-radius`, `test-quality`, `interface-clarity`.
- **pr** — The PR number (integer).
- **repo** — Repository in `owner/repo` format. Derived from the current git remote.
- **findings** — Array of finding objects. Empty array `[]` when the lens finds no issues.
- **severity** — One of the three levels defined in the Severity Classification section above. All severity levels are substantive and require knowledge enrichment.
- **title** — A concise summary (under 80 characters) suitable for use as a review comment heading.
- **file** — Path relative to repository root. Required for inline PR comments. Omit only for PR-level (non-file-specific) findings.
- **line** — Line number in the diff where the finding applies. Required for inline comments. Omit for file-level or PR-level findings.
- **body** — Full explanation. Should include: what the issue is, why it matters, and (for suggestions) what to do about it. Markdown formatting allowed. **Required structure:** include a `**Grounding:**` line that states the concrete basis for the severity claim, calibrated to the severity level:
  - *blocking*: `**Grounding:** <what breaks> for <whom> when <conditions>.` Example: `**Grounding:** Token expiry check is skipped when `exp` is absent, allowing expired tokens to authenticate any user indefinitely.`
  - *suggestion*: `**Grounding:** <specific improvement> benefits <beneficiary>.` Example: `**Grounding:** Extracting this into a named function reduces cognitive load for future maintainers reading the auth flow.`
  - *question*: no `**Grounding:**` line required.

  A body missing the `**Grounding:**` line for a `blocking` or `suggestion` finding is incomplete.
- **knowledge_context** — Array of knowledge store entries cited during enrichment. Each entry is a string in the format `"entry-title — relevance summary"`. Empty array `[]` when no relevant knowledge was found.

#### Validation rules

1. **At least `lens`, `pr`, `repo`, and `findings` are required** at the top level.
2. **Each finding must have `severity`, `title`, and `body`.** The `file` and `line` fields are required for inline comments but may be omitted for PR-level findings.
3. **`knowledge_context` must always be present** (empty array if no knowledge was found). This makes enrichment compliance auditable — a missing field is distinguishable from an empty result.
4. **Severity values must be exactly one of `blocking`, `suggestion`, or `question`.** No other values are accepted.

#### Output location

Each lens writes its findings JSON to the shared work item at `pr-lens-review-<PR>/notes.md` under a heading for that lens. The JSON is embedded in a fenced code block:

````
## Correctness Lens

```json
{ "lens": "correctness", "pr": 42, ... }
```
````

This structure allows multiple lenses to append findings to the same work item, and allows `post-review.sh` to extract and merge findings from all lenses.

