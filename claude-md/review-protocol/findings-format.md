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
- **body** — Full explanation. Should include: what the issue is and the stake. Markdown formatting allowed. **Required structure:** include a `**Grounding:**` line that states the **path to manifestation**, written for a reviewer who has never seen this code — the *trigger* (what someone does, in usage terms, to reach this) and the *manifestation* (what they would observe). This line is the seed for the posted comment.
  - *blocking*: `**Grounding:** <trigger, in usage terms> → <what the reviewer would observe>.` Example: `**Grounding:** If a token from an external provider omits \`exp\`, the expiry check is skipped — that token then authenticates indefinitely and keeps working after a password reset.`
  - *suggestion*: `**Grounding:** <when this is felt in ordinary use or maintenance> → <what it costs the person who hits it>.` Example: `**Grounding:** The retry loop is duplicated across 3 callsites — the next person tuning backoff changes one and silently misses the other two.`
  - *question*: no `**Grounding:**` line required — the question body is the stake.

  A `blocking` or `suggestion` finding missing the `**Grounding:**` line is incomplete. Presence alone is not sufficient: the orchestrator runs each finding through the **Materiality Gate** in `severity.md`, which is applied by *tracing that path*. A finding whose realistic trigger is contrived/unreachable, or whose outcome is an inherent consequence of a deliberate action with nothing the code could reasonably do, is **dropped** — never rewritten to sound material. A bare code-state with no trigger or symptom (one a reviewer unfamiliar with the code could not situate) is not grounded. A finding that turns on context the reviewer cannot see is routed to a `question`.
- **knowledge_context** — Array of knowledge store entries cited during enrichment. Each entry is a string in the format `"entry-title — relevance summary"`. Empty array `[]` when no relevant knowledge was found.

#### Validation rules

1. **At least `lens`, `pr`, `repo`, and `findings` are required** at the top level.
2. **Each finding must have `severity`, `title`, and `body`.** The `file` and `line` fields are required for inline comments but may be omitted for PR-level findings.
3. **`knowledge_context` must always be present** (empty array if no knowledge was found). This makes enrichment compliance auditable — a missing field is distinguishable from an empty result.
4. **Severity values must be exactly one of `blocking`, `suggestion`, or `question`.** No other values are accepted.

#### External Output Formatting

Posted comments are a **curated, neutral** artifact, not a projection of the findings list. Two rules govern what crosses the wall to the PR author:

1. **Strip internal scaffolding.** Remove `**Grounding:**`, `**Severity:**`, `**Knowledge:**`, lens attribution, and compound markers. The stake *content* (the conditional fact) is preserved — it is the substance of the comment — but the labels are not.
2. **Strip criticality.** No severity word and no verdict crosses by default — not "blocking," not "critical," not "must fix." The conditional stake already hands the criticality call to the reader (who knows whether the condition holds). The reviewer may opt to re-add a criticality lead on a specific comment when they judge it warranted (a Phase-2 per-comment affordance); absent that opt-in, posted comments are neutral.

The result is an input to the reader's triage, not a directive: trigger (in usage terms) → what the reviewer would observe → optional soft fix (framed as a question or light suggestion, never a confident prescription). Default to one line. Posted comments need not be 1:1 with the reviewer-facing findings list — immaterial findings (the `minor (N)` tally) are never posted, and several findings may collapse or reshape into fewer comments.

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

Observed code fact stated directly — what fails if the condition holds.
Optional soft fix as a question or light suggestion.
```
````

The `severity` and `lenses` lines are internal routing metadata read by sidecar tooling — they are **not** rendered into the comment the author sees. The body carries no severity word: the conditional in the stake is what lets the reader assign criticality.

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

