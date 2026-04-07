---
name: followup-discuss
description: "Structured discussion of followup findings with source-aware routing and action affordances"
user_invocable: true
argument_description: "<followup-id> [--finding <N>] [-- extra context]"
---

# /followup-discuss Skill

You are running a **structured followup discussion**. This skill loads a followup finding, routes behavior by source, presents a structured summary, and enters interactive discussion with source-appropriate action affordances.

## Step 1: Parse arguments

Arguments provided: `$ARGUMENTS`

Split on ` -- `: everything before is the flag section, everything after is extra context.

Parse the flag section:
1. First token = `FOLLOWUP_ID`
2. If `--finding <N>` is present, set `FINDING_INDEX` to the integer value `N`
3. If `--finding` is absent, set `FINDING_INDEX` to `-1` (whole-followup mode)

```
FOLLOWUP_ID   = first token of flag section
FINDING_INDEX = integer after --finding flag, or -1 if absent
EXTRA_CONTEXT = text after " -- " (empty if not present)
```

If no followup ID is provided, ask the user for one.

## Step 2: Load followup context

Check the system prompt for a `# Followup Context` heading. This heading is injected by the TUI when launching `followup-discuss` from the review cards view.

### 2a. System prompt path (primary)

If `# Followup Context` is present in the system prompt:

**When `FINDING_INDEX >= 0` and the block contains a `**Finding Index:**` field** (scoped-finding schema):

Extract these fields from the structured block:

| Field | Heading |
|---|---|
| Title | `**Title:**` |
| Source | `**Source:**` |
| Status | `**Status:**` |
| Finding Index | `**Finding Index:**` (e.g. `2 of 5`) |
| Finding Title | `**Finding Title:**` |
| Severity | `**Severity:**` |
| Disposition | `**Disposition:**` |
| Rationale | `**Rationale:**` |
| File | `**File:**` |
| Lens | `**Lens:**` |
| Finding Content | `## Finding Content` section body |

Set `SCOPED_MODE = true`.

**Otherwise** (whole-followup schema):

Extract these fields:

| Field | Heading |
|---|---|
| Title | `**Title:**` |
| Source | `**Source:**` |
| Status | `**Status:**` |
| Suggested Actions | `**Suggested Actions:**` (may be absent) |
| Finding Content | `## Finding Content` section body (may be absent) |

Set `SCOPED_MODE = false`.

### 2b. CLI fallback path

If `# Followup Context` is **not** present:

**When `FINDING_INDEX >= 0`** (finding-scoped mode):

```bash
lore followup view --json "$FOLLOWUP_ID"
```

Parse the JSON to get `title`, `source`, `status` fields. Then locate `lens-findings.json` in the followup directory (use the `directory` field from the JSON response, or derive it as `$(lore resolve)/_followups/$FOLLOWUP_ID/lens-findings.json`).

Read `lens-findings.json` and index into the `findings` array at position `FINDING_INDEX` (0-based). Extract the finding's `title`, `severity`, `disposition`, `rationale`, `file`, `lens`, and body fields.

**Guard:** If `FINDING_INDEX` is out of range (>= number of findings), warn the user: `Note: finding index $FINDING_INDEX is out of range — showing full followup instead.` Then set `FINDING_INDEX = -1` and `SCOPED_MODE = false` and proceed in whole-followup mode.

Set `SCOPED_MODE = true` if index was in range.

**When `FINDING_INDEX < 0`** (whole-followup mode):

```bash
lore followup view --json "$FOLLOWUP_ID"
```

Parse the JSON response to extract `title`, `source`, `status`, `suggested_actions`, and `content` fields. Set `SCOPED_MODE = false`.

If either command fails, report the error to the user and stop.

### 2c. Missing field defaults

| Field | Missing behavior |
|---|---|
| `source` | Default to `general` route |
| finding content / `content` | Proceed in summary-only mode (present available fields, skip content excerpt) |
| `suggested_actions` | Use route-default actions from Step 4 |

## Step 3: Present structured summary

**When `SCOPED_MODE = true`** (single-finding view), present:

```
## Finding: <finding-title>

**Context:** This is finding #<N+1> of <total> in followup <followup-id>
**Source:** <source>
**Severity:** <severity>
**Disposition:** <disposition>
**Rationale:** <rationale>
**File:** <file>
**Lens:** <lens>
```

If finding body content is available, include a body excerpt — the first 3–5 sentences (skip headings, take prose):

```
**Excerpt:**
<3–5 sentences from finding body>
```

If extra context was provided via `--`:

```
**Extra context:** <extra context>
```

**When `SCOPED_MODE = false`** (whole-followup view), present:

```
## Followup: <title>

**ID:** <followup-id>
**Source:** <source>
**Status:** <status>
```

If finding content is available, include a content excerpt — the first 3–5 sentences of the finding content body (skip headings, take prose):

```
**Finding excerpt:**
<3–5 sentences from finding content>
```

If extra context was provided via `--`:

```
**Context:** <extra context>
```

## Step 4: Route by source

**When `SCOPED_MODE = true`** (`FINDING_INDEX >= 0`), skip the source routing table and use the [Per-finding branch](#per-finding-branch) directly.

**When `SCOPED_MODE = false`**, match the `source` value against the routing table. Apply the first matching branch.

| Source value | Route | Branch |
|---|---|---|
| `pr-review` | PR review | [PR review branch](#pr-review-branch) |
| `pr-self-review` | PR review | [PR review branch](#pr-review-branch) |
| `pr-revise` | PR revision | [PR revision branch](#pr-revision-branch) |
| `implement` | Implementation | [Implementation branch](#implementation-branch) |
| `worker-*` (prefix match) | Implementation | [Implementation branch](#implementation-branch) |
| *(any other)* | General | [General branch](#general-branch) |

---

### Per-finding branch

Present:

```
**Available actions:**
1. Implement fix — discuss and draft code changes for this finding
2. Change disposition — update this finding's disposition in lens-findings.json
3. Explore context — read the referenced file and surrounding code
```

After presenting actions, enter interactive discussion focused on this specific finding. When the user selects an action:

- **Implement fix:**
  Discuss the finding in depth, then help draft the code changes needed. Reference the file and line number from the finding context. Do not write to disk without user confirmation.

- **Change disposition:**
  Ask the user for the new disposition value (e.g. `action`, `accepted`, `deferred`, `dismissed`). Then:
  1. Locate `lens-findings.json`: use the `directory` field from the loaded context, or derive the path as `$(lore resolve)/_followups/$FOLLOWUP_ID/lens-findings.json`
  2. Read the file, update `findings[$FINDING_INDEX].disposition` to the new value
  3. Write the file back (direct JSON manipulation — do not use an external CLI)
  4. Confirm: `Disposition updated to "<new-value>" for finding #<N+1>.`

- **Explore context:**
  Read the file referenced in the finding (`**File:**` field) and display the relevant lines around the reported line number. Provide a brief summary of the surrounding code context.

---

### PR review branch

Present:

```
**Review source:** This followup was created from a PR review.

**Available actions:**
1. Discuss findings — ask questions or explore any finding in depth
2. Post proposed comments — post selected comments to the PR via `post-proposed-review.sh`
3. Edit a comment — revise a proposed comment before posting
4. Highlight blocking items — list findings marked blocking
5. Dismiss — close this followup as resolved
```

After presenting actions, enter interactive discussion. Respond to user questions about findings. When the user selects an action:

- **Post proposed comments:**
  ```bash
  bash ~/.lore/scripts/post-proposed-review.sh "$FOLLOWUP_ID" [--dry-run]
  ```
  Offer `--dry-run` first to preview. Confirm before running without it.

- **Dismiss:**
  ```bash
  lore followup dismiss "$FOLLOWUP_ID"
  ```

---

### PR revision branch

Present:

```
**Review source:** This followup was created from a PR revision analysis.

**Available actions:**
1. Discuss revision findings — explore what changes were agreed
2. Create work item — promote agreed changes to a tracked work item
3. Dismiss — close this followup as resolved
```

When the user selects **Create work item**:

```bash
lore followup promote "$FOLLOWUP_ID"
```

---

### Implementation branch

Present:

```
**Review source:** This followup was created from an implementation session.

**Available actions:**
1. Discuss deferred work — explore what was deferred and why
2. Promote to work item — create a tracked work item for the deferred work
3. Dismiss — close this followup as resolved
```

When the user selects **Promote to work item**:

```bash
lore followup promote "$FOLLOWUP_ID"
```

---

### General branch

Present:

```
**Available actions:**
1. Discuss findings — explore the finding content
2. Promote to work item — create a tracked work item
3. Dismiss — close this followup as resolved
```

When the user selects **Promote to work item**:

```bash
lore followup promote "$FOLLOWUP_ID"
```

When the user selects **Dismiss**:

```bash
lore followup dismiss "$FOLLOWUP_ID"
```

---

## Step 5: Interactive discussion

Enter open-ended discussion. The user may ask questions, request clarification on findings, or select actions from the Step 4 menu. Respond based on the loaded finding content.

When the user is done, offer a closing action summary if any actions were taken.
