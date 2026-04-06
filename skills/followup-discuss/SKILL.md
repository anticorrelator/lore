---
name: followup-discuss
description: "Structured discussion of followup findings with source-aware routing and action affordances"
user_invocable: true
argument_description: "<followup-id> [-- extra context]"
---

# /followup-discuss Skill

You are running a **structured followup discussion**. This skill loads a followup finding, routes behavior by source, presents a structured summary, and enters interactive discussion with source-appropriate action affordances.

## Step 1: Parse arguments

Arguments provided: `$ARGUMENTS`

Split on ` -- `: everything before is the followup ID (first token), everything after is extra context.

```
FOLLOWUP_ID = first token of $ARGUMENTS
EXTRA_CONTEXT = text after " -- " (empty if not present)
```

If no followup ID is provided, ask the user for one.

## Step 2: Load followup context

Check the system prompt for a `# Followup Context` heading. This heading is injected by the TUI when launching `followup-discuss` from the review cards view.

### 2a. System prompt path (primary)

If `# Followup Context` is present in the system prompt, extract these fields:

| Field | Heading |
|---|---|
| Title | `**Title:**` |
| Source | `**Source:**` |
| Status | `**Status:**` |
| Suggested Actions | `**Suggested Actions:**` (may be absent) |
| Finding Content | `## Finding Content` section body (may be absent) |

### 2b. CLI fallback path

If `# Followup Context` is **not** present, invoke:

```bash
lore followup view --json "$FOLLOWUP_ID"
```

Parse the JSON response to extract `title`, `source`, `status`, `suggested_actions`, and `content` fields.

If this command fails, report the error to the user and stop.

### 2c. Missing field defaults

| Field | Missing behavior |
|---|---|
| `source` | Default to `general` route |
| finding content / `content` | Proceed in summary-only mode (present available fields, skip content excerpt) |
| `suggested_actions` | Use route-default actions from Step 4 |

## Step 3: Present structured summary

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

Match the `source` value against the routing table. Apply the first matching branch.

| Source value | Route | Branch |
|---|---|---|
| `pr-review` | PR review | [PR review branch](#pr-review-branch) |
| `pr-self-review` | PR review | [PR review branch](#pr-review-branch) |
| `pr-revise` | PR revision | [PR revision branch](#pr-revision-branch) |
| `implement` | Implementation | [Implementation branch](#implementation-branch) |
| `worker-*` (prefix match) | Implementation | [Implementation branch](#implementation-branch) |
| *(any other)* | General | [General branch](#general-branch) |

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
