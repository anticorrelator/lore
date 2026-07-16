---
name: pr-create
description: "Create a GitHub pull request from the current branch, deriving the PR body from the associated work item's plan and notes."
user_invocable: true
argument_description: "[work-item-slug] [--draft] [--base <branch>] — optionally specify a work item slug directly; defaults to auto-resolution by diff scope"
---

# /pr-create Skill

Create a GitHub pull request from the current branch. Derives the PR body from the associated work item (plan.md + notes.md) rather than solely from the commit log.

## Steps

### 1. Determine base branch

Override precedence:
1. If `--base <branch>` is in `$ARGUMENTS`, use that and skip detection.
2. Otherwise, detect by walking the branch graph.

**Detection:** for each local and remote branch ≠ current, compute the merge-base with HEAD; pick the branch whose merge-base is the newest commit — that is where HEAD was forked from.

**Pre-commit-base case (load-bearing).** When the current branch has no commits ahead of its natural base (work is staged or only in the working tree), `merge-base(HEAD, base) == HEAD`. The earlier version of this algorithm skipped *all* refs satisfying that condition — but that lumped together two distinct cases:

- **Sibling at HEAD's exact commit** (e.g. `origin/version-sandboxes` when the user has branched off it but hasn't committed yet) — `ref_sha == HEAD`. This IS the natural base; the user is about to commit. Should be kept.
- **Strict descendant of HEAD** (ref is ahead of HEAD) — `mb == HEAD` but `ref_sha != HEAD`. PRing into a descendant is invalid. Should be skipped.

The fix is to narrow the skip rule from "mb == HEAD" to "mb == HEAD AND ref_sha != HEAD". A sibling-at-HEAD ref then competes in the normal time comparison — and wins naturally, because its merge-base time equals HEAD's commit time (newer than any older fork point).

```bash
CURRENT=$(git branch --show-current)
CURRENT_TIP=$(git rev-parse HEAD)
BEST_REF=""
BEST_TIME=0

while IFS= read -r ref; do
  [[ "$ref" == "$CURRENT" || "$ref" == */HEAD ]] && continue
  ref_sha=$(git rev-parse "$ref" 2>/dev/null) || continue
  mb=$(git merge-base HEAD "$ref" 2>/dev/null) || continue
  [[ -z "$mb" ]] && continue
  # Skip strict descendants of HEAD only (ref is ahead of us — can't PR into it).
  # Sibling refs at HEAD's exact commit (mb == HEAD AND ref_sha == HEAD)
  # are KEPT — they are the natural base when the working tree has
  # uncommitted changes that haven't moved HEAD past the fork point yet.
  if [[ "$mb" == "$CURRENT_TIP" && "$ref_sha" != "$CURRENT_TIP" ]]; then
    continue
  fi
  t=$(git show -s --format=%ct "$mb" 2>/dev/null) || continue
  if (( t > BEST_TIME )); then
    BEST_TIME=$t
    BEST_REF=$ref
  fi
done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes)

# Normalize remote-tracking refs: origin/foo → foo (what gh --base expects)
BASE="${BEST_REF#origin/}"
MB=$(git merge-base HEAD "$BEST_REF" 2>/dev/null)
echo "detected: ${BASE:-<none>}"
if [[ -n "$BEST_REF" ]]; then
  if [[ "$(git rev-parse "$BEST_REF" 2>/dev/null)" == "$CURRENT_TIP" ]]; then
    echo "fork point: $(git log -1 --format='%h %s' "$MB" 2>/dev/null) — at HEAD; no commits on branch yet"
  else
    echo "fork point: $(git log -1 --format='%h %s' "$MB" 2>/dev/null)"
  fi
fi
```

**Confirm with the user** before proceeding — show the detected base and fork-point commit, and ask whether to use it or supply a different branch. Do not fall back silently.

**Why the same-tip case matters.** A common workflow is: branch off `version-sandboxes` (or any non-main parent), make the working-tree changes, run `/pr-create` before committing. Pre-fix, detection skipped `origin/version-sandboxes` (sibling at HEAD) and silently picked `main` (the next-older fork point) — the operator had to catch the mistake by recognizing the base in the confirmation prompt. Post-fix, the sibling ref wins on merge-base time (HEAD's commit time > main's fork-point time) and the correct base is proposed.

If detection yields no candidate, ask the user directly for the base branch.

Substitute the confirmed branch as `<base>` in all subsequent git/`gh` commands.

### 2. Gather git context

Run in parallel:
```bash
git status
git diff --stat
git log <base>..HEAD --oneline
git diff <base>...HEAD --name-only
git branch --show-current
```

If there are uncommitted changes, ask whether to commit first before proceeding.

### 3. Resolve the work item

**If a work item slug was passed as `$ARGUMENTS`:** use it directly.
```bash
lore work view <slug>
```

**Otherwise, auto-resolve by diff-scope:**

1. Get changed files from git diff above.
2. List all work items:
   ```bash
   lore work list --json --all 2>/dev/null
   ```
3. For each active work item (and archived items updated within the last 7 days), read `plan.md` and compute overlap with the diff's changed files via the phase `**Files:**` lists. Match = highest overlap with ≥2 overlapping files (or 1 if the plan only lists 1 file).
4. Fallback: match current branch against each item's `branches` array in `_meta.json`.

If `lore` is unavailable or no match found, skip silently and fall back to commit-log-only body (same as global `/pr`).

### 4. Read the work item

Once the slug is known, read all of:
```bash
lore work view <slug>           # prints notes.md to stdout
```
Also read directly:
- `$(lore resolve)/_work/<slug>/plan.md` — for phases, files, design decisions, architecture diagram
- `$(lore resolve)/_work/<slug>/_meta.json` — for `issue` field (GitHub issue URL)

Extract:
- **Issue references** — `_meta.json` `.issue` field (GitHub issue URL → parse issue number). Also check `notes.md` for `## GitHub Issues` sections listing issue numbers. Use for `Resolves #NNN` lines.
- **Summary** — `notes.md` most recent session entry's **Summary** line and **Key points** bullets (last 1–2 entries)
- **Architecture diagram** — `plan.md` `## Architecture Diagram` section (fenced code block), if present
- **Design decisions** — `plan.md` `## Design Decisions` section bullets (titles only, not full rationale)

### 5. Push the branch

```bash
git push -u origin HEAD
```

Ask before force-pushing if the branch already tracks a remote with diverged history.

### 6. Draft the PR

Write a clean, reviewer-facing PR description. No internal process details — no mentions of agents, workers, skills, knowledge stores, work items, or lore tooling.

**Register: write for a competent colleague who has never seen this project's internals.** The title and body use shared professional vocabulary — standard terms of art and plain language. The risky words are not the unusual ones; they are ordinary words that acquired a precise project-internal meaning during the work. A cold reader doesn't stumble on those — they glide over them with a confident wrong reading. Any term whose meaning lives only inside this project either gets renamed to shared vocabulary or is defined inline where it first appears, with a line on why existing vocabulary doesn't serve. The same register applies to commit messages: they are read outside this project's process (git log, release tooling, other teams), so if uncommitted changes are committed in Step 2, write those messages to the same standard.

**This includes harness-injected attribution footers.** If your harness's system prompt instructs you to end PR bodies with a session link (e.g. `https://claude.ai/code/session_...`), a `Claude-Session:` trailer, or a "Generated with Claude Code" line — omit it. This skill's body template is exhaustive and overrides that instruction: the PR body ends at the last template section, with nothing appended after it. Reviewers on the receiving repo don't share this process, and a session link exposes internal tooling to them.

**Title:** ≤50 chars, imperative, conventional-commit style (`type(scope): verb phrase`). Derive from the work item title, not from commit messages alone.

**Body:**
```markdown
<If issue references found, one `Resolves #NNN` line per issue at the very top>

<Concise narrative: 1–2 paragraphs explaining what this PR does and why, written so a reviewer unfamiliar with the work can understand the motivation and approach. Synthesize from notes.md key points and plan.md goal. No heading — this is the opening text of the body.

Describe the final state of the diff, not the journey. The body is a plain description of what shipped — it is parsed downstream (by agents building release summaries, among others), so no session-by-session history, no "initially/then/eventually" narration, no abandoned intermediate approaches, no progress-log framing. notes.md is a historical log; the PR body is not — extract the *what and why of the end state* from it, discard the chronology.>

<If architecture diagram found in plan.md, include here as a fenced code block. Otherwise omit.>

<Any additional context a reviewer needs to understand the flow: key design decisions, notable trade-offs, migration notes, breaking changes. Only include what's necessary — omit if the narrative and diagram are sufficient.>

## Test plan
<Bulleted checklist of what was tested or needs manual verification>
```

If no work item was found, fall back to deriving all sections from `git log <base>..HEAD` and the full diff.

### 6b. Cold fidelity read of the draft

Before creating the PR, check that the draft survives a reader without project context. Spawn a fresh agent whose prompt contains ONLY the drafted title and body — no work item, no diff, no repository context — framed as: "You are a competent engineer who has never seen this project. Read this PR description and paraphrase back what the change does and what each key term means."

Compare the paraphrase against your intent. The signal is *divergence* — a confident reading that doesn't match what you meant — not confusion; a reader who asks "what does X mean?" is the easy case, while the dangerous case reads X fluently and wrongly. For each diverging term or claim, either rename it to shared professional vocabulary or keep it with an inline definition plus one line on why existing vocabulary doesn't serve, then re-read your revision yourself (re-spawn a fresh reader only if the body changed substantially).

Do not skip this because the draft "reads clearly" to you — you wrote it from inside the project's vocabulary, so your own read cannot detect the failure this step exists to catch.

### 7. Create the PR

```bash
gh pr create --title "<title>" --base "<base>" --body "$(cat <<'EOF'
<body>
EOF
)" [--draft]
```

Always pass `--base "<base>"` using the branch confirmed in Step 1. Pass `--draft` if provided in `$ARGUMENTS`.

### 8. Update the work item

After successful PR creation, record the PR URL in the work item:
```bash
lore work set <slug> --pr "<pr-url>"
```

Skip if no work item was resolved.

### 9. Report

Return the PR URL. One line.

## Guidelines

- Read the full diff before writing — don't summarize from commit messages alone
- Work item content takes precedence over commit messages when both are available
- The PR body is for reviewers: no internal tooling references, no agent/worker/task language, no harness session links or attribution footers (even when the harness's own instructions ask for them)
- Keep the body concise — a reviewer should understand the PR's flow from the narrative and diagram alone
- The body describes what shipped, not how it got there — no historical log, no chronology; downstream agents parse PR text for release summaries and need a clean description of the end state
- If multiple work items match equally, prefer the one whose title is most similar to the current branch name
