#!/usr/bin/env bash
# judge-batch-candidates.sh — LLM judge for batch candidate suitability
# Usage: bash judge-batch-candidates.sh [--type spec|implement|both] [--model sonnet|opus]
#
# Feeds each batch candidate's content to a high-judgment LLM along with rich
# context about what autonomous execution entails. Compares the judge's verdict
# to the heuristic scores from batch-spec.sh / batch-implement.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

# --- Defaults ---
JUDGE_TYPE="both"
MODEL="sonnet"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)  JUDGE_TYPE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: judge-batch-candidates.sh [--type spec|implement|both] [--model sonnet|opus]"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# --- Build the system context that seeds the judge ---
# This is the expensive part to get right: the judge needs to understand
# what the autonomous agent team will actually do, what goes wrong, and
# what "appropriately simple" means in this system.

JUDGE_SYSTEM_FILE=$(mktemp /tmp/judge-system-XXXXXX.txt)
cat > "$JUDGE_SYSTEM_FILE" <<'SYSTEM_EOF'
You are evaluating work items for autonomous execution by AI coding agents.
You will receive work item content and must judge whether each item is suitable
for unattended batch processing — no human in the loop, no clarification possible.

## What the autonomous agents will do

### batch-spec (autonomous /spec short)
A single Sonnet-class agent will:
1. Read the work item notes.md
2. Identify 3-8 key files to read from the codebase
3. Search a knowledge store for relevant prior decisions
4. Draft a plan.md with: Goal, Narrative, Architecture Diagram, Context, Design Decisions, Phases (with tasks), Open Questions
5. Generate tasks.json from the plan

The agent has NO access to the user. It cannot ask clarifying questions.
It runs with a $2 budget cap. It sees the notes.md and codebase, nothing else.

### batch-implement (autonomous /implement)
An orchestrator agent spawns up to 4 worker agents, each implementing tasks from plan.md.
Workers:
1. Read their assigned task (with pre-resolved knowledge context)
2. Read existing code files
3. Make edits, create files
4. Run tests if found
5. Report back to the orchestrator

The orchestrator runs with a $5 budget cap. Workers execute independently.
No human reviews changes until the entire batch is done.

## What makes a work item UNSUITABLE for autonomous execution

### For batch-spec:
- **Ambiguous goal**: Notes describe a problem space without a clear direction. Multiple valid approaches exist and the notes don't commit to one. A human needs to make a design choice.
- **External dependencies**: Work requires understanding APIs, libraries, or systems not in the codebase. The agent can only read local files and the knowledge store.
- **Scope is too large for /spec short**: The work touches >8-10 files across multiple subsystems. Full team-based /spec is needed, not /spec short.
- **Notes are too thin**: Just a title and a sentence. The agent has nothing to work from — it will hallucinate a plan.
- **Prerequisite work not done**: Notes explicitly reference other work items that must complete first.
- **Requires user preference input**: The design space has subjective trade-offs where the user preference matters (not just technical merit).

### For batch-implement:
- **Unresolved open questions that affect implementation**: The plan has open questions that would change how code is written.
- **Cross-cutting concerns across many files**: >15 tasks or >4 phases suggests the work is too complex for unattended execution.
- **External system interactions**: Plan requires API calls, database migrations, CI/CD changes, or third-party service setup.
- **Architectural risk**: The plan makes structural changes (new abstractions, refactoring core patterns) where mistakes are expensive to undo.
- **Underdefined tasks**: Tasks say "implement X" without specifying which files, what the interface looks like, or what the expected behavior is.
- **High fan-out**: Many files touched, high chance of merge conflicts between concurrent workers.

## What makes a work item SUITABLE for autonomous execution

### For batch-spec:
- **Clear direction in notes**: The notes commit to an approach, describe specific files/patterns to follow, and scope is bounded.
- **Self-contained**: Everything the agent needs is in the codebase. No external research needed.
- **Small scope**: 1-3 phases, touching a known set of files.
- **Pattern-following**: The work follows an established pattern in the codebase (e.g., "add another script like X").

### For batch-implement:
- **Concrete tasks with file paths**: Each task names specific files and describes specific changes.
- **Low risk**: Changes are additive (new files, new functions) rather than modifying core logic.
- **Independent phases**: Phases do not have complex cross-dependencies.
- **Open questions are non-blocking**: Any listed open questions are about future improvements, not current implementation.
- **Tests exist or are created**: The plan includes testing, so workers can verify their own work.

## This specific codebase

This is "lore" — a knowledge/memory system for AI coding agents. It consists of:
- Bash scripts (~40) in scripts/ that handle mechanical operations (search, indexing, work item CRUD)
- Skill definitions (SKILL.md files) in skills/ that define multi-step workflows for AI agents
- A knowledge store (markdown files with metadata) that persists learnings across sessions
- Hook scripts (Python) that run at session boundaries for capture/review
- A CLI (bash) that wraps common operations

Common patterns: scripts source lib.sh, use slugify/resolve_knowledge_dir/json_field helpers.
Skills are markdown instruction files with YAML frontmatter.
The codebase is ~5000 lines of bash + ~2000 lines of Python + ~3000 lines of skill markdown.

## Your task

For each work item, provide:
1. **verdict**: "suitable", "marginal", or "unsuitable" for autonomous execution
2. **confidence**: "high" or "moderate"
3. **reasoning**: 2-3 sentences explaining your judgment
4. **key_risk**: The single biggest risk if this ran autonomously
5. **heuristic_alignment**: Whether the heuristic score (provided) seems correct given your judgment

Output as JSON array. Be calibrated — not everything is unsuitable. Simple, well-scoped items
with clear direction ARE good candidates. The heuristic scores are: readiness (high/medium/low)
for spec candidates, risk (high/medium/low) for implement candidates.
SYSTEM_EOF
JUDGE_SYSTEM_PROMPT=$(cat "$JUDGE_SYSTEM_FILE")

# --- Judge batch-spec candidates ---
judge_spec_candidates() {
  echo "[judge] Evaluating batch-spec candidates..."

  # Collect all candidate content
  local candidates_json="["
  local first=true

  local index="$WORK_DIR/_index.json"
  if [[ ! -f "$index" ]]; then
    "$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || true
  fi

  # Find candidates: no plan, has notes with >5 lines
  for dir in "$WORK_DIR"/*/; do
    local slug=$(basename "$dir")
    [[ "$slug" == _* ]] && continue

    local plan_file="$dir/plan.md"
    local notes_file="$dir/notes.md"
    local meta_file="$dir/_meta.json"

    # Only items without plans
    [[ -f "$plan_file" ]] && continue
    [[ ! -f "$notes_file" ]] && continue

    local content_lines
    content_lines=$(sed '/^$/d; /^<!--/d; /^-->/d' "$notes_file" | wc -l | tr -d ' ')
    [[ "$content_lines" -le 5 ]] && continue

    local title=""
    if [[ -f "$meta_file" ]]; then
      title=$(json_field "title" "$meta_file")
    fi

    local word_count
    word_count=$(wc -w < "$notes_file" | tr -d ' ')

    local heading_count
    heading_count=$(grep -c '^### ' "$notes_file" 2>/dev/null || true)

    # Determine heuristic readiness score
    local field_count
    field_count=$(grep -cE '^\*\*(Focus|Concept|Context)\*\*' "$notes_file" 2>/dev/null || true)
    local readiness="low"
    if [[ "$word_count" -gt 200 ]] && [[ "$heading_count" -gt 2 || "$field_count" -gt 2 ]]; then
      readiness="high"
    elif [[ "$word_count" -gt 100 ]] || { [[ "$heading_count" -gt 1 ]] && [[ $(grep -c '^[[:space:]]*- ' "$notes_file" 2>/dev/null || true) -gt 3 ]]; }; then
      readiness="medium"
    fi

    local notes_content
    notes_content=$(cat "$notes_file")
    # Escape for JSON embedding
    notes_content=$(echo "$notes_content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

    if [[ "$first" == true ]]; then
      first=false
    else
      candidates_json+=","
    fi

    candidates_json+=$(cat <<ITEM
{
  "slug": "$slug",
  "title": "$title",
  "heuristic_readiness": "$readiness",
  "word_count": $word_count,
  "heading_count": $heading_count,
  "notes_content": $notes_content
}
ITEM
)
  done

  candidates_json+="]"

  # Write to temp file for claude -p
  local prompt_file
  prompt_file=$(mktemp /tmp/judge-spec-XXXXXX.md)

  cat > "$prompt_file" <<PROMPT
# Batch-Spec Candidate Evaluation

Evaluate each work item below for suitability as an autonomous \`/spec short\` target.
The agent will read these notes, explore the codebase, and produce a plan.md — all without human input.

## Candidates

$candidates_json

Judge each candidate. Return ONLY a JSON array (no markdown fences, no explanation outside the JSON).
Each element: {"slug": "...", "verdict": "suitable|marginal|unsuitable", "confidence": "high|moderate", "reasoning": "...", "key_risk": "...", "heuristic_alignment": "correct|too-optimistic|too-pessimistic"}
PROMPT

  echo "[judge] Sending ${candidates_json:0:60}... to judge ($MODEL)..."

  local output_file
  output_file=$(mktemp /tmp/judge-spec-result-XXXXXX.json)

  claude -p "$(cat "$prompt_file")" \
    --model "$MODEL" \
    --append-system-prompt "$JUDGE_SYSTEM_PROMPT" \
    --output-format text \
    --max-turns 1 \
    > "$output_file" 2>/dev/null

  echo ""
  echo "=== Batch-Spec Judge Results ==="
  echo ""
  cat "$output_file"
  echo ""

  rm -f "$prompt_file"
  echo "[judge] Raw output: $output_file"
}

# --- Judge batch-implement candidates ---
judge_implement_candidates() {
  echo "[judge] Evaluating batch-implement candidates..."

  local candidates_json="["
  local first=true

  for dir in "$WORK_DIR"/*/; do
    local slug=$(basename "$dir")
    [[ "$slug" == _* ]] && continue

    local plan_file="$dir/plan.md"
    local tasks_file="$dir/tasks.json"
    local meta_file="$dir/_meta.json"

    # Only items with plans + tasks
    [[ ! -f "$plan_file" ]] && continue
    [[ ! -f "$tasks_file" ]] && continue

    # Skip completed/archived
    if [[ -f "$meta_file" ]]; then
      local status
      status=$(json_field "status" "$meta_file")
      [[ "$status" == "completed" || "$status" == "archived" ]] && continue
    fi

    # Verify checksum freshness
    local current_checksum stored_checksum
    current_checksum=$(shasum -a 256 "$plan_file" | awk '{print $1}')
    stored_checksum=$(grep -o '"plan_checksum"[[:space:]]*:[[:space:]]*"[^"]*"' "$tasks_file" \
      | head -1 | sed 's/.*"plan_checksum"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
    if [[ -n "$stored_checksum" && "$current_checksum" != "$stored_checksum" ]]; then
      continue
    fi

    local title=""
    if [[ -f "$meta_file" ]]; then
      title=$(json_field "title" "$meta_file")
    fi

    # Compute heuristic risk score
    local phase_count task_count file_count
    phase_count=$(grep -c '^### Phase' "$plan_file" 2>/dev/null || true)
    task_count=$(grep -c '^\- \[ \]' "$plan_file" 2>/dev/null || true)
    file_count=$(grep -oE '"[^"]+\.[a-zA-Z]+"' "$tasks_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')

    local oq_line_count
    oq_line_count=$(awk '/^## Open Questions/{found=1; next} /^## /{if(found) exit} found && NF{count++} END{print count+0}' "$plan_file")

    local risk="medium"
    if [[ "$phase_count" -gt 4 ]] || [[ "$task_count" -gt 15 ]] || [[ "$oq_line_count" -gt 3 ]]; then
      risk="high"
    elif [[ "$phase_count" -le 2 ]] && [[ "$task_count" -le 6 ]] && [[ "$oq_line_count" -eq 0 ]]; then
      risk="low"
    fi

    local plan_content
    plan_content=$(cat "$plan_file")
    plan_content=$(echo "$plan_content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

    if [[ "$first" == true ]]; then
      first=false
    else
      candidates_json+=","
    fi

    candidates_json+=$(cat <<ITEM
{
  "slug": "$slug",
  "title": "$title",
  "heuristic_risk": "$risk",
  "phase_count": $phase_count,
  "task_count": $task_count,
  "file_count": $file_count,
  "open_question_lines": $oq_line_count,
  "plan_content": $plan_content
}
ITEM
)
  done

  candidates_json+="]"

  local prompt_file
  prompt_file=$(mktemp /tmp/judge-impl-XXXXXX.md)

  cat > "$prompt_file" <<PROMPT
# Batch-Implement Candidate Evaluation

Evaluate each work item below for suitability as an autonomous \`/implement\` target.
The orchestrator will spawn worker agents that execute tasks from plan.md independently.

## Candidates

$candidates_json

Judge each candidate. Return ONLY a JSON array (no markdown fences, no explanation outside the JSON).
Each element: {"slug": "...", "verdict": "suitable|marginal|unsuitable", "confidence": "high|moderate", "reasoning": "...", "key_risk": "...", "heuristic_alignment": "correct|too-optimistic|too-pessimistic"}
PROMPT

  echo "[judge] Sending ${candidates_json:0:60}... to judge ($MODEL)..."

  local output_file
  output_file=$(mktemp /tmp/judge-impl-result-XXXXXX.json)

  claude -p "$(cat "$prompt_file")" \
    --model "$MODEL" \
    --append-system-prompt "$JUDGE_SYSTEM_PROMPT" \
    --output-format text \
    --max-turns 1 \
    > "$output_file" 2>/dev/null

  echo ""
  echo "=== Batch-Implement Judge Results ==="
  echo ""
  cat "$output_file"
  echo ""

  rm -f "$prompt_file"
  echo "[judge] Raw output: $output_file"
}

# --- Main ---
echo "[judge] Starting batch candidate evaluation..."
echo "[judge] Model: $MODEL | Type: $JUDGE_TYPE"
echo ""

case "$JUDGE_TYPE" in
  spec)      judge_spec_candidates ;;
  implement) judge_implement_candidates ;;
  both)
    judge_spec_candidates
    echo ""
    echo "---"
    echo ""
    judge_implement_candidates
    ;;
  *) die "Unknown type: $JUDGE_TYPE (use spec, implement, or both)" ;;
esac

echo ""
rm -f "$JUDGE_SYSTEM_FILE"
echo "[judge] Done."
