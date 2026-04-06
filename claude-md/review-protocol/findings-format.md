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

- **lens** — Identifier for the lens that produced the findings. Built-in IDs: `correctness`, `security`, `regressions`, `thematic`, `blast-radius`, `test-quality`, `interface-clarity`, `user-impact`. Ceremony-registered lenses use their skill name as the lens ID (e.g., `codex-pr-review`). This field is not restricted to the built-in set.
- **pr** — The PR number (integer).
- **repo** — Repository in `owner/repo` format. Derived from the current git remote.
- **findings** — Array of finding objects. Empty array `[]` when the lens finds no issues.
- **severity** — One of the three levels defined in the Severity Classification section above. All severity levels are substantive and require knowledge enrichment.
- **title** — A concise summary (under 80 characters) suitable for use as a review comment heading.
- **file** — Path relative to repository root. Required for inline PR comments. Omit only for PR-level (non-file-specific) findings.
- **line** — Line number in the diff where the finding applies. Required for inline comments. Omit for file-level or PR-level findings.
- **body** — Full explanation. Should include: what the issue is, why it matters, and (for suggestions) what to do about it. Markdown formatting allowed. **Required structure:** include a `**Grounding:**` line that traces from technical mechanism to observable human/operational consequence, calibrated to the severity level:
  - *blocking*: `**Grounding:** <mechanism — what breaks, for whom, when> → <consequence — what the user experiences or what operational impact follows>.` Example: `**Grounding:** Token expiry check is skipped when `exp` is absent, so any token without that claim authenticates indefinitely — an attacker who obtains a single token retains account access permanently, surviving password resets and revocations.`
  - *suggestion*: `**Grounding:** <situation — when a real person encounters the problem> → <improvement — what changes for them>.` Example: `**Grounding:** The next engineer debugging an auth failure has to mentally reconstruct the token validation flow across three inline blocks — extracting into a named function makes the validation sequence explicit and grep-able.`
  - *question*: no `**Grounding:**` line required.

  A body missing the `**Grounding:**` line for a `blocking` or `suggestion` finding is incomplete. Presence alone is not sufficient — the orchestrator evaluates grounding quality against the rubric in `severity.md`. Grounding that stops at the technical mechanism without landing on a human/operational consequence is **weak** and will be rewritten. Unsound grounding (speculative or no causal link) triggers a severity downgrade or drop.
- **knowledge_context** — Array of knowledge store entries cited during enrichment. Each entry is a string in the format `"entry-title — relevance summary"`. Empty array `[]` when no relevant knowledge was found.

#### Validation rules

1. **At least `lens`, `pr`, `repo`, and `findings` are required** at the top level.
2. **Each finding must have `severity`, `title`, and `body`.** The `file` and `line` fields are required for inline comments but may be omitted for PR-level findings.
3. **`knowledge_context` must always be present** (empty array if no knowledge was found). This makes enrichment compliance auditable — a missing field is distinguishable from an empty result.
4. **Severity values must be exactly one of `blocking`, `suggestion`, or `question`.** No other values are accepted.

#### External Output Formatting

Before a finding body appears in external-facing output — proposed comments, followup reports, or `post-review.sh` — strip internal protocol language: `**Grounding:**`, `**Severity:**`, `**Knowledge:**`, lens attribution, compound markers. These are internal analytical scaffolding. The author should see a self-contained comment grounded in impact, not an analysis artifact.

The grounding content itself (the concrete failure scenario, improvement claim, or question) must be preserved — it is the substance of the comment. Only the protocol headers and labels are stripped.

**Uncertain framing — hedge the inference, not the observed code fact.** See `review-voice.md` for the full voice guide including uncertain framing patterns, verification urgency by severity, sentence structure, and vocabulary guidance.

**User-facing vocabulary mapping:**

| Internal value | User-facing equivalent |
|----------------|------------------------|
| `blocking` findings | `Findings requiring action` |
| `suggestion` findings | `Improvement opportunities` |
| `question` findings | `Questions` |
| Verdict: has blocking | `ACTION NEEDED` |
| Verdict: suggestions only | `SUGGESTIONS` |
| Verdict: clean | `CLEAN` |

Internal severity values remain in JSON and sidecar files for routing. User-visible output (section headers, verdict lines, finding descriptions) uses the user-facing equivalents above.

#### Review Code Block Format

Individual findings in a review report may be rendered as fenced `review` blocks. This format is used when generating proposed inline PR comments and allows downstream tooling to extract structured metadata from a markdown document.

**Block convention:**

````
```review
file: path/to/file.ext
line: 42
severity: blocking
lenses: correctness, security

**Finding title**

Detailed explanation of the finding. May include markdown formatting.

**Grounding:** What breaks for whom when conditions are met — what the user experiences or what operational impact follows.
```
````

**Front-matter fields** (key: value format, one per line):

- **file** — Path relative to repository root. Same as `finding.file`.
- **line** — Line number in the diff. Same as `finding.line`.
- **severity** — Internal routing value: one of `blocking`, `suggestion`, `question`. This is NOT a user-visible label — it is used only by sidecar generation tooling to determine handling.
- **lenses** — Comma-separated list of contributing lens IDs (e.g., `correctness, security`).

A blank line separates the front-matter from the markdown comment body. The body begins immediately after the blank line.

**`proposed-comments.json` sidecar schema:**

The sidecar is the canonical artifact for proposed inline PR comments. Review code blocks in `finding.md` are rendered from it at followup-creation time. If a review block and the sidecar diverge, the sidecar wins.

```json
{
  "comments": [
    {
      "id": "<uuid>",
      "path": "<finding.file>",
      "line": 42,
      "body": "<finding.body — markdown>",
      "severity": "blocking | suggestion | question",
      "lenses": ["correctness", "security"],
      "head_sha": "<headRefOid from gh pr view --json headRefOid>",
      "selected": true
    }
  ]
}
```

**Field derivation rules:**

- **id** — Generated UUID, unique per comment.
- **path** — Derived from `finding.file`. Required; omit the comment if `file` is absent.
- **line** — Derived from `finding.line`. Required; omit the comment if `line` is absent.
- **body** — Derived from `finding.body`. Full markdown content of the finding body.
- **severity** — Internal routing value derived from `finding.severity`. One of `blocking`, `suggestion`, `question`. Not rendered to the reviewer.
- **lenses** — Array of lens IDs that contributed to this finding.
- **head_sha** — The PR's head commit SHA, fetched via `gh pr view --json headRefOid`. Required for posting inline comments via the GitHub API.
- **selected** — Defaults to `true`. Controls whether the comment is included when the user confirms the proposed comments batch.

Fields `side` and `confidence` are intentionally omitted from this schema.

#### Output location

Each lens writes its findings JSON to the shared work item at `pr-lens-review-<PR>/notes.md` under a heading for that lens. The JSON is embedded in a fenced code block:

````
## Correctness Lens

```json
{ "lens": "correctness", "pr": 42, ... }
```
````

This structure allows multiple lenses to append findings to the same work item, and allows `post-review.sh` to extract and merge findings from all lenses.

