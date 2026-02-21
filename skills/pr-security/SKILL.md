---
name: pr-security
description: "Focused lens review: evaluate security vulnerabilities, edge cases, and adversarial paths in a PR. Use /pr-review for integrated multi-lens coverage."
user_invocable: true
argument_description: "[PR_number_or_URL] — PR to analyze for security vulnerabilities, input validation, auth/authz issues, and adversarial paths"
---

# /pr-security Skill

Focused variant. For holistic coverage, use `/pr-review`.

You are running the **security lens** — a focused review that evaluates PR changes for security vulnerabilities, edge cases, and adversarial attack paths. This lens examines input validation, injection risks, auth/authz boundaries, cryptographic misuse, secrets exposure, and concurrency issues. It complements the 8-point agent-code checklist in `/pr-review`; it targets security concerns, not general correctness.

Findings are structured JSON written to a shared work item. Posting to GitHub is a separate step via `post-review.sh`.

## Step 1: Identify PR

Argument provided: `$ARGUMENTS`

Parse the first token as a PR number (digits) or GitHub URL. Extract the numeric PR identifier.

If no PR identifier is found, ask the user for the PR number.

Resolve the repo owner/name from the git remote:
```bash
REMOTE_URL=$(git remote get-url origin)
```
Extract `OWNER/REPO` from the remote URL.

## Step 2: Fetch PR Data and Diff

```bash
bash ~/.lore/scripts/fetch-pr-data.sh <PR_NUMBER>
```

```bash
gh pr diff <PR_NUMBER>
```

```bash
gh pr view <PR_NUMBER> --json files,title,body,commits
```

From the fetched data, identify:
- **Changed files** and which contain security-relevant changes (auth, input handling, crypto, secrets, external API calls, user-facing endpoints)
- **PR intent** from the title, body, and commit messages
- **Existing reviews** — filter out `isOutdated: true` threads. Note any security concerns already raised to avoid duplication.

## Step 3: Security Analysis

Read the shared review protocol (severity classification, enrichment, findings format) and the Security Lens Methodology:
```bash
cat claude-md/70-review-protocol.md
```

For each file with security-relevant changes, apply the Security Lens Methodology defined in the protocol:

**3a. Input validation** — For every function that accepts external input (user data, API parameters, file contents, environment variables, URL parameters):
- Is input validated before use? Check for type, length, range, and format validation
- Are validation errors handled explicitly (not silently swallowed)?
- Is validation applied at the boundary, not deferred to internal code?

**3b. Injection risk analysis** — For code that constructs queries, commands, or markup from dynamic data:
- SQL: parameterized queries or ORM, not string concatenation
- Command execution: argument arrays, not shell string interpolation
- HTML/template: context-aware escaping, not raw interpolation
- Path traversal: canonicalization and prefix validation for file paths built from input

**3c. Auth/authz boundary violations** — For code that gates access to resources or operations:
- Is authentication checked before authorization?
- Are authorization checks applied at the resource level, not just the route level?
- Do new endpoints or operations inherit the correct auth middleware?
- Are permission escalation paths possible (e.g., modifying a role check without updating dependent checks)?

**3d. Cryptographic misuse** — For code that uses cryptographic operations:
- Are deprecated algorithms used (MD5, SHA1 for security, ECB mode, DES)?
- Are keys/IVs hardcoded or derived from predictable sources?
- Is random number generation using a cryptographically secure source?
- Are comparison operations constant-time where timing attacks are relevant?

**3e. Secrets exposure** — For code changes that handle credentials, tokens, or keys:
- Are secrets logged, included in error messages, or exposed in responses?
- Are secrets stored in environment variables or secret managers, not in code?
- Do new configuration files or environment variable additions introduce secret storage?
- Are secrets removed from version control if previously committed?

**3f. Edge cases (empty/null/concurrent)** — Security-specific edge cases beyond general correctness:
- Empty or null values that bypass validation (e.g., empty string passing a "not null" check)
- Race conditions in authentication or authorization checks (TOCTOU)
- Concurrent access to shared resources without proper synchronization
- Integer overflow or underflow in security-critical calculations (e.g., permission bitmasks)

**3g. Adversarial path analysis** — Think like an attacker:
- What is the most valuable asset accessible through this code path?
- What is the minimum effort to reach that asset from an unauthenticated state?
- Are there paths that combine individually-benign operations into a harmful sequence?
- Does this change widen the attack surface (new endpoints, new input sources, new dependencies)?

**Scoping for large diffs:** If more than ~10 files have security-relevant changes, prioritize: (1) authentication/authorization boundaries, (2) external input handlers, (3) cryptographic operations, (4) new endpoints or API surfaces. Apply full methodology to priority files; do a lighter pass on the rest.

## Step 4: Knowledge Enrichment

**Mandatory for every finding.** For each finding, query the knowledge store:
```bash
lore search "<finding topic>" --type knowledge --json --limit 3
```

Attach relevant citations as `knowledge_context` entries in the finding. Follow the enrichment gate and output cap from the shared protocol. If no relevant knowledge is found, set `knowledge_context` to an empty array.

### Investigation Escalation

If a finding involves cross-boundary security concerns (auth checks spanning multiple modules, permission propagation across layers) and the knowledge store has no relevant entries, escalate per the Investigation Escalation protocol in `70-review-protocol.md`. Budget: maximum 2 escalations per lens run.

## Step 5: Write Findings

**5a. Build findings JSON** conforming to the Findings Output Format schema in `claude-md/70-review-protocol.md`:
```json
{
  "lens": "security",
  "pr": <PR_NUMBER>,
  "repo": "<OWNER>/<REPO>",
  "findings": [...]
}
```

Classify each finding using the Severity Classification definitions. Default to `suggestion` when uncertain between blocking and suggestion. Typical severity patterns for this lens:
- Injection vulnerabilities, auth bypass, secrets exposure: **blocking**
- Missing input validation that could be exploited: **blocking**
- Deprecated crypto algorithms with no active exploit: **suggestion**
- Missing rate limiting or hardening: **suggestion**
- Unclear security implications of a design choice: **question**

**5b. Present findings** to the user grouped by severity (blocking first, then suggestions, then questions). For each finding show: severity, title, file:line, body, and knowledge context.

**5c. Write to work item.** Create or update the shared lens review work item:
```
/work create pr-lens-review-<PR_NUMBER>
```

If the work item already exists, load it instead of creating a duplicate. Append the findings JSON under a `## Security Lens` heading in `notes.md` as a fenced JSON code block.

**5d. Notify about posting.** After writing findings, remind the user:
> Findings written to work item. To post as a PR review, run:
> ```bash
> bash ~/.lore/scripts/post-review.sh <findings.json> --pr <PR_NUMBER> [--dry-run]
> ```

## Step 6: Capture

```
/remember PR security analysis from PR #<N> — capture: security patterns and conventions observed in the codebase, auth/authz architecture, input validation approaches, cryptographic usage patterns, secrets management practices. Use confidence: medium for reviewer observations. Skip: findings specific to this PR that don't generalize, style preferences.
```

## Error Handling

- **No gh CLI or not authenticated:** Tell user to run `gh auth login`
- **PR not found:** Confirm the PR number and repo access
- **Empty diff:** PR may have no changes — confirm with user
- **No findings:** Report "Security lens: no findings" and write empty findings array to the work item
