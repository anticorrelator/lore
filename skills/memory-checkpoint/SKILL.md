---
name: memory-checkpoint
description: Review the current session for uncaptured insights and untracked plans — invoke when you feel Claude should be remembering more
user_invocable: true
argument_description: "[optional focus area or 'auto' to capture without asking]"
---

# /memory-checkpoint Skill

Pause and review the current session for uncaptured knowledge and untracked plans. This is the manual safety net — use it when you suspect insights or design decisions are going unrecorded.

## Resolve Knowledge Path

```bash
bash ~/.project-knowledge/scripts/resolve-repo.sh
```

Set `KNOWLEDGE_DIR` to the result. If the knowledge store doesn't exist, run `/memory init` first.

## Step 1: Scan for uncaptured insights

Review the full conversation context and identify moments that match capture triggers:

- A design decision was made with non-obvious rationale
- Something was discovered to work differently than expected
- A debugging session revealed a non-obvious root cause
- A pattern was found that repeats across the codebase
- A gotcha or pitfall was encountered
- The user corrected a misconception or shared domain knowledge
- A workaround was used (and the reason why matters)

For each candidate, assess against the 4-condition gate:
1. Reusable (beyond this task)?
2. Non-obvious (not in existing docs)?
3. Stable (won't change soon)?
4. High confidence (verified)?

## Step 2: Check plan status

- Is there an active plan for the current work? Check `_plans/` for branch match or recent activity.
- If no plan exists, check the auto-trigger conditions:
  - Design discussion (choosing between approaches, trade-offs)?
  - Multi-step implementation (>2-3 files)?
  - Ambiguous scope (goal stated but path unclear)?
  - System/meta changes (tooling, config, process)?
  - Cross-session work (won't finish this conversation)?
- If a plan exists, does it need a session notes update?

## Step 3: Present findings

Format:
```
Checkpoint review:

Captures (N candidates):
1. "<insight summary>" — [all 4 conditions met / reason to skip]
2. "<insight summary>" — [all 4 conditions met / reason to skip]

Plan status:
- [No active plan — should create because: <reason>]
  OR
- [Active plan: <name> — [current / needs update: <what changed>]]
  OR
- [No plan needed — <reason>]
```

## Step 4: Act

**If the user invoked `/checkpoint auto`:**
- Capture all insights that pass the gate (append to `_inbox.md`)
- Create or update plans as needed
- Report what was done

**Otherwise:**
- Wait for user to approve/modify/reject each item
- "Capture all" / "drop the 2nd one" / "skip the plan" are all valid responses
- Then execute approved actions

## Step 5: Resume work

After the checkpoint, return to whatever was being worked on. The checkpoint is a pause, not a redirect.
