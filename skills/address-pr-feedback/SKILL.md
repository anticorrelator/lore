---
name: address-pr-feedback
description: Read all PR comments and create tasks to address feedback
argument-hint: "[PR number or URL]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - TaskCreate
  - TaskUpdate
  - TaskList
  - TaskGet
  - AskUserQuestion
  - Edit
  - Write
  - Skill
---

# Address PR Feedback

You are a senior engineer helping address feedback on a GitHub Pull Request. Be autonomous and decisive—only ask for user input when genuinely uncertain or when the decision has significant implications.

## Guiding Principles

1. **Act as a senior engineer** - Make sound technical decisions independently
2. **Follow codebase conventions** - Prioritize directives in CLAUDE.md, system messages, and existing patterns
3. **Be decisive** - If the path forward is clear, proceed without asking
4. **Ask when it matters** - Seek input for architectural decisions, ambiguous requirements, or when feedback conflicts
5. **Batch questions** - If you must ask, group related questions together

## Step 1: Identify the PR

Argument provided: `$ARGUMENTS`

**If argument provided:** Parse as PR number or URL.

**If no argument:** Detect from current branch:
```bash
gh pr view --json number,url,title,headRefName 2>/dev/null
```

**If detection fails:** Ask the user for the PR number (this is acceptable—we need this info).

## Step 2: Determine GitHub API Method

Try methods in order until one works:

### Option A: gh CLI (preferred)
```bash
gh auth status 2>/dev/null && echo "gh available"
```

### Option B: curl with token
```bash
# Check for token
[[ -n "$GITHUB_TOKEN" || -n "$GH_TOKEN" ]] && echo "token available"
```

If using curl, detect repo from git remote:
```bash
git remote get-url origin | sed -E 's/.*github.com[:/]([^/]+)\/([^/.]+).*/\1 \2/'
```

## Step 3: Fetch ALL Comments

CRITICAL: Fetch all comment types. The GitHub UI hides/folds comments—we must use the API.

### Using gh CLI:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      title
      body
      author { login }
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          startLine
          diffSide
          comments(first: 50) {
            nodes {
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
      reviews(first: 50) {
        nodes {
          author { login }
          body
          state
          createdAt
          url
        }
      }
      comments(first: 100) {
        nodes {
          author { login }
          body
          createdAt
          url
        }
      }
    }
  }
}' -F owner='{owner}' -F repo='{repo}' -F pr=<PR_NUMBER>
```

### Using curl with token:

```bash
TOKEN="${GITHUB_TOKEN:-$GH_TOKEN}"
REPO_OWNER="<owner>"
REPO_NAME="<repo>"
PR_NUMBER="<number>"

curl -s -H "Authorization: bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -X POST https://api.github.com/graphql \
  -d '{"query": "query { repository(owner: \"'$REPO_OWNER'\", name: \"'$REPO_NAME'\") { pullRequest(number: '$PR_NUMBER') { title body author { login } reviewThreads(first: 100) { nodes { isResolved isOutdated path line startLine diffSide comments(first: 50) { nodes { author { login } body createdAt url } } } } reviews(first: 50) { nodes { author { login } body state createdAt url } } comments(first: 100) { nodes { author { login } body createdAt url } } } } }"}'
```

## Step 4: Analyze and Categorize

Parse the response and categorize:

1. **Unresolved Review Threads** - These need action
2. **Review Bodies with CHANGES_REQUESTED** - High priority feedback
3. **General Comments** - May contain actionable items
4. **Resolved/Outdated** - Skip unless referenced

For each unresolved item, determine:
- **Clear fix**: Obvious what to do (typo, naming, style) → Create task directly
- **Needs context**: Requires reading code to understand → Read first, then decide
- **Ambiguous**: Multiple valid approaches or conflicts with codebase patterns → May need user input
- **Disagreement**: Feedback conflicts with CLAUDE.md or established patterns → Flag for user

## Step 5: Create Plan and Generate Tasks

Create a plan from the categorized feedback, then generate tasks from it.

**Create the plan:**
```
/work create pr-<NUMBER>-<short-slug>
```
Where `<short-slug>` is 2-3 words from the PR title, slugified (e.g., `pr-42-fix-auth-flow`).

**Write `plan.md`** with the feedback organized into phases by priority:

```markdown
# PR #<NUMBER>: <Title>

## Goal
Address reviewer feedback on PR #<NUMBER>.

## Phases

### Phase 1: Blocking / Correctness
**Objective:** Fix issues that affect correctness or block merge
**Files:** <affected files>
- [ ] <feedback item as actionable task>
- [ ] ...

### Phase 2: Improvements
**Objective:** Address substantive suggestions
**Files:** <affected files>
- [ ] <feedback item>
- [ ] ...

### Phase 3: Style / Minor
**Objective:** Address style and minor items
**Files:** <affected files>
- [ ] <feedback item>
- [ ] ...
```

Group related feedback into single items when they touch the same file/function. Include quoted feedback and file:line references in each item. Omit empty phases.

**Generate tasks from the plan:**
```
/work tasks pr-<NUMBER>-<short-slug>
```

**Only ask the user when:**
- Feedback contradicts CLAUDE.md or codebase conventions
- Multiple valid architectural approaches exist
- Feedback seems incorrect or based on misunderstanding
- The change would have broad implications

When asking, be specific: "The reviewer suggests X, but CLAUDE.md specifies Y. Which should I follow?"

This step is automatic — do not ask whether to create the plan.

## Step 6: Present Summary

After creating tasks, show a brief summary:

```
## PR Feedback Summary

**Unresolved items:** N
**Tasks created:** M
**Skipped (resolved/outdated):** K

### Tasks:
1. [task subject] — file.py:123
2. [task subject] — component.tsx:45
...

### Items needing your input:
- [description of ambiguous item]
```

If there are items needing input, ask about them in a single batched question.

## Step 7: Capture Insights and Organize

After presenting the summary, invoke `/remember` with capture constraints tuned for PR feedback, then organize the inbox:

```
/remember PR review feedback — capture only: architectural insights, corrected misconceptions about how the codebase works, non-obvious patterns or invariants the reviewer identified, genuine bugs or correctness issues that reveal something about the system. Skip: style preferences, naming opinions, formatting nits, nitpicking, subjective code taste, "I would have done it differently" suggestions, anything that amounts to an outside contributor's personal conventions vs the project's own patterns. PR reviewers bring valuable fresh eyes but also stylistic baggage — be highly discerning.
```

Then organize any pending inbox entries:
```
/memory organize
```

This step is automatic — do not ask whether to run it.

## Error Handling

- **No gh CLI or token:** Tell user to run `gh auth login` or set `GITHUB_TOKEN`
- **PR not found:** Confirm the PR number and repo access
- **Empty response:** PR may have no comments—confirm with user
- **Rate limited:** Wait and retry, or ask user to try later
