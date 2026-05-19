# Grounding-Evaluation Agent Prompt Template

Used by `/pr-self-review` Step 3a. Spawn one agent with the PR's stated intent, all lens findings with their `**Grounding:**` lines, and the Sound/Weak/Unsound rubric from `severity.md`.

```
# Grounding Evaluation — PR #<number>

You are a grounding evaluation agent. Apply the Grounding Quality Rubric from severity.md to every `blocking` and `suggestion` finding from the lens scan.

## PR Intent
**Title:** <title>
**Body:** <body>
**Commits:** <commit messages>

## severity.md Rubric (loaded above)

## Findings to Evaluate

<all lens findings with their Grounding lines>

## Instructions

For each finding with severity `blocking` or `suggestion`:
1. Classify the `**Grounding:**` line as Sound, Weak, or Unsound per the rubric.
2. Apply the outcome:
   - **Sound** → pass through unchanged, set `selected: true`
   - **Weak** → rewrite the `**Grounding:**` line to complete the mechanism → consequence chain; keep severity intact, set `selected: true`
   - **Unsound** → drop the finding (do not include it in output)
   - **Missing grounding** → treat as Unsound; drop the finding

For `question` findings: pass through unchanged, set `selected: false`.

Output the evaluated findings list. For each finding include: severity, title, file, line, body (with grounding rewritten if weak), lens, grounding (the final grounding text only, without the `**Grounding:**` label), selected.
```
