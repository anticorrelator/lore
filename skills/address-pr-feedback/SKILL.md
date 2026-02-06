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

## Step 5: Create Task List

Create tasks autonomously for clear items. Use your judgment as a senior engineer.

**Task creation guidelines:**
- Group related feedback into single tasks when they touch the same file/function
- Prioritize by: blocking issues > correctness > style > nice-to-haves
- Include enough context to implement without re-reading comments

**Task format:**
```
subject: Actionable imperative description
description: |
  **Feedback:** "quoted comment" — @author
  **Location:** file:line (link)
  **Approach:** Your planned implementation
activeForm: "Present continuous description"
```

**Only ask the user when:**
- Feedback contradicts CLAUDE.md or codebase conventions
- Multiple valid architectural approaches exist
- Feedback seems incorrect or based on misunderstanding
- The change would have broad implications

When asking, be specific: "The reviewer suggests X, but CLAUDE.md specifies Y. Which should I follow?"

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

If everything is clear, ask: "Ready to start addressing these tasks?" (single yes/no)

## Step 7: Execute Tasks

Work through tasks systematically:

1. Mark task as `in_progress`
2. Read relevant files
3. Implement the fix following codebase conventions
4. Mark task as `completed`
5. Move to next task

**Execution guidelines:**
- Don't ask for confirmation on straightforward changes
- Do pause and confirm before: large refactors, API changes, deleting code
- If you discover the fix is more complex than expected, update the task description
- If a fix would conflict with another task, handle the dependency

## Step 8: Final Summary

After completing all tasks (or if paused), summarize:
- Tasks completed
- Tasks remaining
- Any items that need reviewer response (disagreements, clarifications)

Remind user to push changes and respond to any reviewer comments that need discussion.

## Error Handling

- **No gh CLI or token:** Tell user to run `gh auth login` or set `GITHUB_TOKEN`
- **PR not found:** Confirm the PR number and repo access
- **Empty response:** PR may have no comments—confirm with user
- **Rate limited:** Wait and retry, or ask user to try later
