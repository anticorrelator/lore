# Review Findings section template (Step 6e Section 3)

Load when assembling Section 3 of the followup report body. This is the **reviewer-facing cockpit** — the report lives in the reviewer's knowledge store and is read in the TUI to triage; it is never posted (only the curated Section 4 comments cross to the PR). It **retains** the severity grouping, counts, and verdict line (see `findings-format.md` → External Output Formatting → reviewer-facing surfaces), and keeps the full finding detail — mechanism anchor, caveats, lens attribution. The distilled, criticality-stripped form lives only in Section 4 / `proposed-comments.json`.

Render each finding as the **reviewer-cockpit variant** from Step 6d-ii (internal protocol labels stripped for readability; stake woven inline). Group by severity with the reviewer-facing labels (blocking → "Findings requiring action", suggestion → "Improvement opportunities", question → "Questions"). Empty severity groups render `None.` — do not omit the subheading. If zero findings overall, still emit `## Review Findings` with an explicit no-findings statement.

```markdown
## Review Findings

**Verdict:** <ACTION NEEDED / SUGGESTIONS / CLEAN>
**Findings requiring action:** <count> | **Improvement opportunities:** <count> | **Questions:** <count>

### Findings requiring action (<count>)

#### 1. [compound] <title>
**Lenses:** correctness, security
**File:** `path/to/file.ext:42`

<reviewer-cockpit body — full mechanism and caveats, internal headers stripped, stake woven inline>

**Knowledge:** [knowledge: entry-title] — relevance summary

---

### Improvement opportunities (<count>)

#### 2. <title>
**Lens:** correctness
**File:** `path/to/file.ext:87`

<reviewer-cockpit body>

---

### Questions (<count>)

#### 3. <title>
**Lens:** interface-clarity
**File:** `path/to/other.ext:15`

<open question, as written>

### Supplementary Reports

<Include only if non-conforming ceremony output exists — omit this heading entirely otherwise>

#### <skill-name> [ceremony]

<raw output from the ceremony lens>
```
