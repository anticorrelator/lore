#!/usr/bin/env bash
# batch-implement.sh — Batch-run /implement on work items with ready plans
# Usage: bash batch-implement.sh [options]
# Discovers work items with plan.md + tasks.json + fresh checksum, scores
# implementation risk, and runs /implement via `claude -p` for unattended execution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

# --- Defaults ---
MAX_BUDGET="5.0"
MODEL="sonnet"
DRY_RUN=false
INCLUDE_SLUGS=()
EXCLUDE_SLUGS=()

# --- usage ---
usage() {
  cat <<EOF
Usage: batch-implement.sh [options]

Discover work items with ready plans and batch-run /implement on them.

Options:
  --max-budget N       Per-item cost cap in USD (default: 5.0)
  --model <model>      Model to use for implementation (default: sonnet)
  --dry-run            Show candidates without executing
  --include <slug>     Only process these slugs (repeatable)
  --exclude <slug>     Skip these slugs (repeatable)
  -h, --help           Show this help message

Examples:
  batch-implement.sh                          # Run on all eligible items
  batch-implement.sh --dry-run                # Preview candidates only
  batch-implement.sh --include auth-refactor  # Only implement this item
  batch-implement.sh --exclude legacy-api     # Skip this item
  batch-implement.sh --max-budget 3.0         # Lower cost cap
EOF
  exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-budget)
      [[ $# -lt 2 ]] && die "Missing value for --max-budget"
      MAX_BUDGET="$2"
      shift 2
      ;;
    --model)
      [[ $# -lt 2 ]] && die "Missing value for --model"
      MODEL="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --include)
      [[ $# -lt 2 ]] && die "Missing value for --include"
      INCLUDE_SLUGS+=("$2")
      shift 2
      ;;
    --exclude)
      [[ $# -lt 2 ]] && die "Missing value for --exclude"
      EXCLUDE_SLUGS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

# --- Validate work directory ---
if [[ ! -d "$WORK_DIR" ]]; then
  die "No work directory found at $WORK_DIR. Run /work create first."
fi

# --- Slug filter helpers ---

# Check if a slug matches the include/exclude filters.
# Returns 0 (true) if the slug should be processed, 1 (false) if skipped.
slug_matches_filters() {
  local slug="$1"

  # If include list is non-empty, slug must be in it
  if [[ ${#INCLUDE_SLUGS[@]} -gt 0 ]]; then
    local found=false
    for inc in "${INCLUDE_SLUGS[@]}"; do
      if [[ "$slug" == "$inc" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" == false ]]; then
      return 1
    fi
  fi

  # Check exclude list
  if [[ ${#EXCLUDE_SLUGS[@]} -gt 0 ]]; then
    for exc in "${EXCLUDE_SLUGS[@]}"; do
      if [[ "$slug" == "$exc" ]]; then
        return 1
      fi
    done
  fi

  return 0
}

# --- Function stubs (implemented by other tasks) ---

# --- discover_candidates ---
# Find work items that have plans and are ready for /implement.
# Criteria:
#   1. has_plan_doc: true in _index.json
#   2. tasks.json exists in _work/<slug>/
#   3. plan checksum is fresh (plan.md not modified after tasks.json)
#   4. _meta.json status is not "completed" or "archived"
#   5. Passes --include/--exclude filters
# Populates global arrays:
#   CANDIDATE_SLUGS[]       — slugs that passed all criteria
#   CANDIDATE_TITLES[]      — corresponding titles (parallel array)
#   SKIPPED_NO_PLAN[]       — slugs skipped because plan.md missing
#   SKIPPED_NO_TASKS[]      — slugs skipped because tasks.json missing
#   SKIPPED_STALE_TASKS[]   — slugs skipped because tasks.json older than plan.md
#   SKIPPED_FILTERED[]      — slugs skipped by include/exclude filters
#   SKIPPED_DONE[]          — slugs skipped because already completed/archived
discover_candidates() {
  local index="$WORK_DIR/_index.json"

  # Self-heal: regenerate index if missing
  if [[ ! -f "$index" ]]; then
    "$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || true
  fi
  if [[ ! -f "$index" ]]; then
    die "No work index found at $index and could not regenerate."
  fi

  CANDIDATE_SLUGS=()
  CANDIDATE_TITLES=()
  SKIPPED_NO_PLAN=()
  SKIPPED_NO_TASKS=()
  SKIPPED_STALE_TASKS=()
  SKIPPED_FILTERED=()
  SKIPPED_DONE=()

  local cur_slug="" cur_title="" cur_has_plan="" cur_status=""

  while IFS= read -r line; do
    # Parse slug
    if echo "$line" | grep -q '"slug"'; then
      cur_slug=$(echo "$line" | sed 's/.*"slug"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
    fi
    # Parse title
    if echo "$line" | grep -q '"title"'; then
      cur_title=$(echo "$line" | sed 's/.*"title"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
    fi
    # Parse status
    if echo "$line" | grep -q '"status"'; then
      cur_status=$(echo "$line" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
    fi
    # Parse has_plan_doc (last field per entry — triggers processing)
    if echo "$line" | grep -q '"has_plan_doc"'; then
      if echo "$line" | grep -q 'true'; then
        cur_has_plan="true"
      else
        cur_has_plan="false"
      fi

      # Skip completed/archived items
      if [[ "$cur_status" == "completed" || "$cur_status" == "archived" ]]; then
        SKIPPED_DONE+=("$cur_slug")
        cur_slug="" ; cur_title="" ; cur_has_plan="" ; cur_status=""
        continue
      fi

      # Only consider items WITH a plan
      if [[ "$cur_has_plan" == "false" || -z "$cur_slug" ]]; then
        if [[ -n "$cur_slug" ]]; then
          SKIPPED_NO_PLAN+=("$cur_slug")
        fi
        cur_slug="" ; cur_title="" ; cur_has_plan="" ; cur_status=""
        continue
      fi

      # Apply include/exclude filters
      if ! slug_matches_filters "$cur_slug"; then
        SKIPPED_FILTERED+=("$cur_slug")
        cur_slug="" ; cur_title="" ; cur_has_plan="" ; cur_status=""
        continue
      fi

      local tasks_file="$WORK_DIR/$cur_slug/tasks.json"
      local plan_file="$WORK_DIR/$cur_slug/plan.md"

      # Check tasks.json existence
      if [[ ! -f "$tasks_file" ]]; then
        SKIPPED_NO_TASKS+=("$cur_slug")
        cur_slug="" ; cur_title="" ; cur_has_plan="" ; cur_status=""
        continue
      fi

      # Validate plan checksum freshness
      if [[ -f "$plan_file" ]]; then
        local current_checksum stored_checksum
        current_checksum=$(shasum -a 256 "$plan_file" | awk '{print $1}')
        stored_checksum=$(grep -o '"plan_checksum"[[:space:]]*:[[:space:]]*"[^"]*"' "$tasks_file" \
          | head -1 | sed 's/.*"plan_checksum"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

        if [[ -n "$stored_checksum" && "$current_checksum" != "$stored_checksum" ]]; then
          SKIPPED_STALE_TASKS+=("$cur_slug")
          cur_slug="" ; cur_title="" ; cur_has_plan="" ; cur_status=""
          continue
        fi
      fi

      CANDIDATE_SLUGS+=("$cur_slug")
      CANDIDATE_TITLES+=("$cur_title")

      # Reset for next entry
      cur_slug="" ; cur_title="" ; cur_has_plan="" ; cur_status=""
    fi
  done < "$index"

  echo "[batch-implement] Discovered ${#CANDIDATE_SLUGS[@]} candidate(s)"
  if [[ ${#SKIPPED_FILTERED[@]} -gt 0 ]]; then
    echo "[batch-implement]   Filtered out: ${#SKIPPED_FILTERED[@]}"
  fi
  if [[ ${#SKIPPED_NO_PLAN[@]} -gt 0 ]]; then
    echo "[batch-implement]   No plan.md: ${#SKIPPED_NO_PLAN[@]}"
  fi
  if [[ ${#SKIPPED_NO_TASKS[@]} -gt 0 ]]; then
    echo "[batch-implement]   No tasks.json: ${#SKIPPED_NO_TASKS[@]}"
  fi
  if [[ ${#SKIPPED_STALE_TASKS[@]} -gt 0 ]]; then
    echo "[batch-implement]   Stale tasks.json (run lore work regen-tasks): ${#SKIPPED_STALE_TASKS[@]}"
  fi
  if [[ ${#SKIPPED_DONE[@]} -gt 0 ]]; then
    echo "[batch-implement]   Already completed/archived: ${#SKIPPED_DONE[@]}"
  fi
}

# --- score_risk ---
# For each candidate, analyze plan structure and assign a risk score.
# Reads from CANDIDATE_SLUGS[]/CANDIDATE_TITLES[] (set by discover_candidates).
# Populates parallel arrays:
#   CANDIDATE_RISK[]        — "high", "medium", or "low"
#   CANDIDATE_PHASES[]      — number of ### Phase headers in plan.md
#   CANDIDATE_TASKS[]       — number of unchecked tasks (- [ ] checkboxes)
#   CANDIDATE_FILES[]       — number of unique file targets from tasks.json
#   CANDIDATE_HAS_OPEN_Q[]  — "yes" or "no"
#   CANDIDATE_UPDATED[]     — last_updated from _meta.json
score_risk() {
  CANDIDATE_RISK=()
  CANDIDATE_PHASES=()
  CANDIDATE_TASKS=()
  CANDIDATE_FILES=()
  CANDIDATE_HAS_OPEN_Q=()
  CANDIDATE_UPDATED=()

  local i slug plan_file tasks_file meta_file
  for i in "${!CANDIDATE_SLUGS[@]}"; do
    slug="${CANDIDATE_SLUGS[$i]}"
    plan_file="$WORK_DIR/$slug/plan.md"
    tasks_file="$WORK_DIR/$slug/tasks.json"
    meta_file="$WORK_DIR/$slug/_meta.json"

    # Count ### Phase headers in plan.md
    local phase_count=0
    if [[ -f "$plan_file" ]]; then
      phase_count=$(grep -c '^### Phase' "$plan_file" 2>/dev/null || true)
    fi
    CANDIDATE_PHASES+=("$phase_count")

    # Count unchecked task checkboxes (- [ ]) in plan.md
    local task_count=0
    if [[ -f "$plan_file" ]]; then
      task_count=$(grep -c '^\- \[ \]' "$plan_file" 2>/dev/null || true)
    fi
    CANDIDATE_TASKS+=("$task_count")

    # Count unique file targets from tasks.json
    local file_count=0
    if [[ -f "$tasks_file" ]]; then
      # Extract file_targets values — grep for quoted paths inside file_targets arrays
      file_count=$(grep -oE '"[^"]+\.[a-zA-Z]+"' "$tasks_file" 2>/dev/null \
        | sort -u | wc -l | tr -d ' ')
    fi
    CANDIDATE_FILES+=("$file_count")

    # Check for non-empty ## Open Questions section in plan.md
    local has_open_q="no"
    local oq_line_count=0
    if [[ -f "$plan_file" ]]; then
      oq_line_count=$(awk '/^## Open Questions/{found=1; next} /^## /{if(found) exit} found && NF{count++} END{print count+0}' "$plan_file")
      if [[ "$oq_line_count" -gt 0 ]]; then
        has_open_q="yes"
      fi
    fi
    CANDIDATE_HAS_OPEN_Q+=("$has_open_q")

    # Last updated from _meta.json
    local updated=""
    if [[ -f "$meta_file" ]]; then
      updated=$(json_field "updated" "$meta_file")
    fi
    CANDIDATE_UPDATED+=("${updated:-unknown}")

    # Score risk based on thresholds
    # high: >4 phases OR >15 tasks OR open questions with >3 lines
    # low: ≤2 phases AND ≤6 tasks AND no open questions
    # medium: everything else
    local risk="medium"
    if [[ "$phase_count" -gt 4 ]] || [[ "$task_count" -gt 15 ]] || [[ "$oq_line_count" -gt 3 ]]; then
      risk="high"
    elif [[ "$phase_count" -le 2 ]] && [[ "$task_count" -le 6 ]] && [[ "$has_open_q" == "no" ]]; then
      risk="low"
    fi
    CANDIDATE_RISK+=("$risk")
  done

  # Summary
  local high=0 medium=0 low=0
  for r in "${CANDIDATE_RISK[@]}"; do
    case "$r" in
      high) high=$((high + 1)) ;;
      medium) medium=$((medium + 1)) ;;
      low) low=$((low + 1)) ;;
    esac
  done
  echo "[batch-implement] Risk scores: $high high, $medium medium, $low low"
}

# --- present_batch ---
# Display a formatted table of candidates with risk scores and prompt for approval.
# Reads from parallel arrays populated by discover_candidates() and score_risk().
# In dry-run mode, displays the table and returns 1 (no execution).
# Approval modes:
#   y/Y/enter = approve all candidates
#   n/N       = abort (returns 1)
#   e/edit    = open temp file with slugs for manual pruning
# After approval, CANDIDATE_SLUGS/CANDIDATE_TITLES are pruned to approved set.
# Returns 0 if approved (candidates to process), 1 if aborted or dry-run.
present_batch() {
  if [[ ${#CANDIDATE_SLUGS[@]} -eq 0 ]]; then
    echo "[batch-implement] No candidates to process."
    return 1
  fi

  # Calculate relative date for display
  local now_epoch
  now_epoch=$(date +%s)

  _relative_date() {
    local iso_date="$1"
    if [[ -z "$iso_date" || "$iso_date" == "unknown" ]]; then
      echo "unknown"
      return
    fi
    local epoch
    epoch=$(iso_to_epoch "$iso_date")
    if [[ "$epoch" -eq 0 ]]; then
      echo "unknown"
      return
    fi
    local days_ago=$(( (now_epoch - epoch) / 86400 ))
    if [[ $days_ago -eq 0 ]]; then
      echo "today"
    elif [[ $days_ago -eq 1 ]]; then
      echo "yesterday"
    else
      echo "${days_ago}d ago"
    fi
  }

  echo ""
  echo "=== Batch Implement Candidates ==="
  echo ""
  printf "  %-35s %-35s %-6s %6s %5s %5s  %-10s\n" "SLUG" "TITLE" "RISK" "PHASES" "TASKS" "FILES" "UPDATED"
  printf "  %-35s %-35s %-6s %6s %5s %5s  %-10s\n" "----" "-----" "----" "------" "-----" "-----" "-------"

  local i
  for i in "${!CANDIDATE_SLUGS[@]}"; do
    local slug="${CANDIDATE_SLUGS[$i]}"
    local title="${CANDIDATE_TITLES[$i]}"
    local risk="${CANDIDATE_RISK[$i]}"
    local phases="${CANDIDATE_PHASES[$i]}"
    local tasks="${CANDIDATE_TASKS[$i]}"
    local files="${CANDIDATE_FILES[$i]}"
    local updated
    updated=$(_relative_date "${CANDIDATE_UPDATED[$i]}")

    # Truncate title for display
    if [[ ${#title} -gt 33 ]]; then
      title="${title:0:30}..."
    fi
    # Truncate slug for display
    if [[ ${#slug} -gt 33 ]]; then
      slug="${slug:0:30}..."
    fi

    printf "  %-35s %-35s %-6s %6s %5s %5s  %-10s\n" "$slug" "$title" "$risk" "$phases" "$tasks" "$files" "$updated"
  done

  echo ""
  echo "  Total: ${#CANDIDATE_SLUGS[@]} candidate(s)"
  echo ""

  # Dry-run: show table but don't prompt
  if [[ "$DRY_RUN" == true ]]; then
    echo "[batch-implement] Dry run — no implementations will be executed."
    return 1
  fi

  # Prompt for approval
  printf "Approve batch? [Y/n/edit] "
  local reply
  read -r reply

  case "$reply" in
    n|N)
      echo "[batch-implement] Aborted."
      return 1
      ;;
    e|edit|E|Edit)
      # Write slugs to temp file for manual pruning
      local tmpfile
      tmpfile=$(mktemp /tmp/batch-implement-edit.XXXXXX)
      {
        echo "# Remove lines to exclude items from this batch."
        echo "# Save and close to continue. Empty file = abort."
        echo ""
        for i in "${!CANDIDATE_SLUGS[@]}"; do
          echo "${CANDIDATE_SLUGS[$i]}"
        done
      } > "$tmpfile"

      local editor="${EDITOR:-vi}"
      "$editor" "$tmpfile"

      # Read back approved slugs
      local approved_slugs=()
      while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        approved_slugs+=("$line")
      done < "$tmpfile"
      rm -f "$tmpfile"

      if [[ ${#approved_slugs[@]} -eq 0 ]]; then
        echo "[batch-implement] No items selected. Aborted."
        return 1
      fi

      # Prune candidates to approved set
      local new_slugs=() new_titles=() new_risk=() new_phases=() new_tasks=() new_files=() new_open_q=() new_updated=()
      for i in "${!CANDIDATE_SLUGS[@]}"; do
        local slug="${CANDIDATE_SLUGS[$i]}"
        local matched=false
        for approved in "${approved_slugs[@]}"; do
          if [[ "$slug" == "$approved" ]]; then
            matched=true
            break
          fi
        done
        if [[ "$matched" == true ]]; then
          new_slugs+=("$slug")
          new_titles+=("${CANDIDATE_TITLES[$i]}")
          new_risk+=("${CANDIDATE_RISK[$i]}")
          new_phases+=("${CANDIDATE_PHASES[$i]}")
          new_tasks+=("${CANDIDATE_TASKS[$i]}")
          new_files+=("${CANDIDATE_FILES[$i]}")
          new_open_q+=("${CANDIDATE_HAS_OPEN_Q[$i]}")
          new_updated+=("${CANDIDATE_UPDATED[$i]}")
        fi
      done

      CANDIDATE_SLUGS=("${new_slugs[@]}")
      CANDIDATE_TITLES=("${new_titles[@]}")
      CANDIDATE_RISK=("${new_risk[@]}")
      CANDIDATE_PHASES=("${new_phases[@]}")
      CANDIDATE_TASKS=("${new_tasks[@]}")
      CANDIDATE_FILES=("${new_files[@]}")
      CANDIDATE_HAS_OPEN_Q=("${new_open_q[@]}")
      CANDIDATE_UPDATED=("${new_updated[@]}")

      echo "[batch-implement] Approved ${#CANDIDATE_SLUGS[@]} item(s) after edit."
      ;;
    *)
      # y/Y/empty = approve all
      echo "[batch-implement] Approved ${#CANDIDATE_SLUGS[@]} item(s)."
      ;;
  esac

  return 0
}

# --- execute_item ---
# Invoke `claude -p "/implement <slug>"` for a single candidate.
# Args: $1 = index into CANDIDATE_SLUGS[], $2 = current item number, $3 = total count
# Populates per-item entries in parallel arrays:
#   RESULT_SLUGS[]       — slug processed
#   RESULT_STATUS[]      — "success", "error", or "skipped"
#   RESULT_COST[]        — cost in USD (from claude JSON output)
#   RESULT_DURATION[]    — wall-clock seconds
#   RESULT_OUTPUT_FILE[] — path to saved JSON output
#   RESULT_ERROR[]       — error message if failed, empty otherwise
execute_item() {
  local idx="$1"
  local item_num="$2"
  local total="$3"
  local slug="${CANDIDATE_SLUGS[$idx]}"
  local risk="${CANDIDATE_RISK[$idx]}"

  echo "[batch-implement] ($item_num/$total) Implementing '$slug' [risk: $risk]..."

  # Save pre-run checked task count for progress detection
  local pre_checked=0
  local plan_file="$WORK_DIR/$slug/plan.md"
  if [[ -f "$plan_file" ]]; then
    pre_checked=$(grep -c '^\- \[x\]' "$plan_file" 2>/dev/null || true)
  fi

  # Dry-run: skip actual execution
  if [[ "$DRY_RUN" == true ]]; then
    RESULT_SLUGS+=("$slug")
    RESULT_STATUS+=("skipped")
    RESULT_COST+=("0")
    RESULT_DURATION+=("0")
    RESULT_OUTPUT_FILE+=("")
    RESULT_ERROR+=("dry-run")
    RESULT_PRE_CHECKED+=("$pre_checked")
    echo "[batch-implement]   Dry run — skipped"
    return 0
  fi

  # Verify claude CLI is available
  if ! command -v claude &>/dev/null; then
    RESULT_SLUGS+=("$slug")
    RESULT_STATUS+=("error")
    RESULT_COST+=("0")
    RESULT_DURATION+=("0")
    RESULT_OUTPUT_FILE+=("")
    RESULT_ERROR+=("claude CLI not found")
    RESULT_PRE_CHECKED+=("$pre_checked")
    echo "[batch-implement]   Error: claude CLI not found" >&2
    return 1
  fi

  local ts
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  local output_file="$WORK_DIR/$slug/batch-run-${ts}.json"

  local system_prompt
  system_prompt="Complete the implementation autonomously. Do not use AskUserQuestion. Do not present work for review or ask for feedback. Report what you completed."

  local start_epoch
  start_epoch=$(date +%s)

  # Invoke claude in print mode with JSON output
  local exit_code=0
  claude -p "/implement $slug" \
    --output-format json \
    --permission-mode bypassPermissions \
    --max-budget-usd "$MAX_BUDGET" \
    --model "$MODEL" \
    --append-system-prompt "$system_prompt" \
    > "$output_file" 2>&1 || exit_code=$?

  local end_epoch
  end_epoch=$(date +%s)
  local duration=$((end_epoch - start_epoch))

  RESULT_SLUGS+=("$slug")
  RESULT_DURATION+=("$duration")
  RESULT_OUTPUT_FILE+=("$output_file")
  RESULT_PRE_CHECKED+=("$pre_checked")

  if [[ $exit_code -ne 0 ]]; then
    RESULT_STATUS+=("error")
    RESULT_COST+=("0")
    RESULT_ERROR+=("claude exited with code $exit_code")
    echo "[batch-implement]   Failed (exit code $exit_code, ${duration}s)"
    return 1
  fi

  # Parse cost from JSON output (field: total_cost_usd)
  local cost="0"
  if [[ -f "$output_file" ]]; then
    cost=$(grep -o '"total_cost_usd"[[:space:]]*:[[:space:]]*[0-9.]*' "$output_file" \
      | head -1 | sed 's/.*:[[:space:]]*//' || echo "0")
    [[ -z "$cost" ]] && cost="0"
  fi

  # Check for is_error in JSON output
  local is_error="false"
  if [[ -f "$output_file" ]]; then
    is_error=$(grep -o '"is_error"[[:space:]]*:[[:space:]]*[a-z]*' "$output_file" \
      | head -1 | sed 's/.*:[[:space:]]*//' || echo "false")
    [[ -z "$is_error" ]] && is_error="false"
  fi

  if [[ "$is_error" == "true" ]]; then
    RESULT_STATUS+=("error")
    RESULT_COST+=("$cost")
    RESULT_ERROR+=("claude reported is_error=true")
    echo "[batch-implement]   Error reported by claude (${duration}s, \$$cost)"
    return 1
  fi

  RESULT_STATUS+=("success")
  RESULT_COST+=("$cost")
  RESULT_ERROR+=("")
  echo "[batch-implement]   Done (${duration}s, \$$cost)"
  return 0
}

# --- verify_item ---
# Post-run verification of implementation output for a single work item.
# Args: $1 = slug, $2 = JSON output file from claude
# Echoes status: "completed", "partial", or "failed"
# Checks:
#   1. JSON output is_error field — if true, "failed"
#   2. _meta.json status is "archived" or "completed" — "completed"
#   3. plan.md checkbox progress (checked vs total) — "partial" if some done
#   4. Otherwise "failed"
verify_item() {
  local slug="$1"
  local output_file="$2"
  local pre_checked="${3:-0}"
  local meta_file="$WORK_DIR/$slug/_meta.json"
  local plan_file="$WORK_DIR/$slug/plan.md"

  # Check 1: JSON output is_error
  if [[ -n "$output_file" && -f "$output_file" ]]; then
    local is_error
    is_error=$(grep -o '"is_error"[[:space:]]*:[[:space:]]*[a-z]*' "$output_file" \
      | head -1 | sed 's/.*:[[:space:]]*//' || echo "false")
    if [[ "$is_error" == "true" ]]; then
      echo "failed"
      return 0
    fi
  fi

  # Check 2: _meta.json status is "archived" or "completed"
  if [[ -f "$meta_file" ]]; then
    local status
    status=$(json_field "status" "$meta_file")
    if [[ "$status" == "archived" || "$status" == "completed" ]]; then
      echo "completed"
      return 0
    fi
  fi

  # Check 3: plan.md checkbox progress — compare post-run to pre-run
  if [[ -f "$plan_file" ]]; then
    local post_checked=0
    post_checked=$(grep -c '^\- \[x\]' "$plan_file" 2>/dev/null || true)

    if [[ "$post_checked" -gt "$pre_checked" ]]; then
      echo "partial"
      return 0
    fi
  fi

  # Check 4: No progress detected
  echo "failed"
  return 0
}

# --- report_results ---
# Print summary of batch run and write machine-readable JSON to _batch-runs/.
# Reads from RESULT_SLUGS[], RESULT_STATUS[], RESULT_COST[], RESULT_DURATION[],
# RESULT_OUTPUT_FILE[], RESULT_ERROR[], and RESULT_VERIFY[] arrays.
# Writes JSON to _work/_batch-runs/implement-<timestamp>.json.
report_results() {
  local attempted=0 completed=0 partial=0 failed=0 skipped=0
  local total_cost=0 total_duration=0

  if [[ ${#RESULT_SLUGS[@]} -eq 0 ]]; then
    echo ""
    echo "=== Batch Implement Results ==="
    echo "No items were processed."
    return 0
  fi

  # Tally results
  local i
  for i in "${!RESULT_SLUGS[@]}"; do
    local status="${RESULT_STATUS[$i]}"
    local verify="${RESULT_VERIFY[$i]:-unknown}"
    local cost="${RESULT_COST[$i]:-0}"
    local duration="${RESULT_DURATION[$i]:-0}"

    if [[ "$status" == "skipped" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    attempted=$((attempted + 1))

    # Use awk for floating-point cost addition
    total_cost=$(awk "BEGIN { printf \"%.2f\", $total_cost + $cost }")
    total_duration=$((total_duration + duration))

    case "$verify" in
      completed) completed=$((completed + 1)) ;;
      partial)   partial=$((partial + 1)) ;;
      *)         failed=$((failed + 1)) ;;
    esac
  done

  # Format duration as Xm Ys
  local duration_fmt
  if [[ $total_duration -ge 60 ]]; then
    duration_fmt="$((total_duration / 60))m $((total_duration % 60))s"
  else
    duration_fmt="${total_duration}s"
  fi

  # Console summary
  echo ""
  echo "=== Batch Implement Results ==="
  echo "Items: $attempted attempted, $completed completed, $partial partial, $failed failed"
  if [[ $skipped -gt 0 ]]; then
    echo "Skipped: $skipped (dry-run)"
  fi
  echo "Cost: \$$total_cost total"
  echo "Duration: $duration_fmt"
  echo ""

  # List each item with status
  echo "Implementation results:"
  for i in "${!RESULT_SLUGS[@]}"; do
    local slug="${RESULT_SLUGS[$i]}"
    local status="${RESULT_STATUS[$i]}"
    local verify="${RESULT_VERIFY[$i]:-unknown}"

    if [[ "$status" == "skipped" ]]; then
      printf "  %-45s (skipped)\n" "_work/$slug/"
      continue
    fi

    case "$verify" in
      completed)
        printf "  %-45s (completed)\n" "_work/$slug/"
        ;;
      partial)
        local plan_file="$WORK_DIR/$slug/plan.md"
        local checked=0 total_tasks=0
        if [[ -f "$plan_file" ]]; then
          checked=$(grep -c '^\- \[x\]' "$plan_file" 2>/dev/null || true)
          total_tasks=$(( checked + $(grep -c '^\- \[ \]' "$plan_file" 2>/dev/null || true) ))
        fi
        printf "  %-45s (partial -- %s/%s tasks)\n" "_work/$slug/" "$checked" "$total_tasks"
        ;;
      *)
        local error="${RESULT_ERROR[$i]:-}"
        if [[ -n "$error" ]]; then
          printf "  %-45s (failed -- %s)\n" "_work/$slug/" "$error"
        else
          printf "  %-45s (failed)\n" "_work/$slug/"
        fi
        ;;
    esac
  done

  echo ""
  if [[ $completed -gt 0 ]]; then
    echo "Review completed items before archiving."
  fi

  # Write machine-readable JSON
  local batch_dir="$WORK_DIR/_batch-runs"
  mkdir -p "$batch_dir"

  local ts
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  local json_file="$batch_dir/implement-${ts}.json"

  {
    echo "{"
    echo "  \"type\": \"batch-implement\","
    echo "  \"timestamp\": \"$(timestamp_iso)\","
    echo "  \"model\": \"$MODEL\","
    echo "  \"max_budget_per_item\": $MAX_BUDGET,"
    echo "  \"items\": ["

    local first=true
    for i in "${!RESULT_SLUGS[@]}"; do
      local slug="${RESULT_SLUGS[$i]}"
      local status="${RESULT_STATUS[$i]}"
      local verify="${RESULT_VERIFY[$i]:-unknown}"
      local cost="${RESULT_COST[$i]:-0}"
      local duration="${RESULT_DURATION[$i]:-0}"
      local error="${RESULT_ERROR[$i]:-}"

      # Determine final status for JSON
      local json_status="$verify"
      if [[ "$status" == "skipped" ]]; then
        json_status="skipped"
      elif [[ "$status" == "error" && "$verify" == "unknown" ]]; then
        json_status="failed"
      fi

      if [[ "$first" == true ]]; then
        first=false
      else
        echo "    ,"
      fi

      echo "    {"
      echo "      \"slug\": \"$slug\","
      echo "      \"status\": \"$json_status\","
      echo "      \"cost_usd\": $cost,"
      echo "      \"duration_s\": $duration"
      if [[ -n "$error" ]]; then
        # Escape quotes in error message for JSON safety
        local safe_error
        safe_error=$(echo "$error" | sed 's/"/\\"/g')
        echo "      ,\"error\": \"$safe_error\""
      fi
      echo "    }"
    done

    echo "  ],"
    echo "  \"totals\": {"
    echo "    \"attempted\": $attempted,"
    echo "    \"completed\": $completed,"
    echo "    \"partial\": $partial,"
    echo "    \"failed\": $failed,"
    echo "    \"skipped\": $skipped,"
    echo "    \"cost_usd\": $total_cost,"
    echo "    \"duration_s\": $total_duration"
    echo "  }"
    echo "}"
  } > "$json_file"

  echo ""
  echo "[batch-implement] Results written to: $json_file"
}

# --- Main ---
# Flow: discover -> score -> present -> execute+verify loop -> report
main() {
  echo "[batch-implement] Starting batch implementation..."
  echo "[batch-implement] Work dir: $WORK_DIR"
  echo "[batch-implement] Model: $MODEL | Max budget: \$$MAX_BUDGET | Dry run: $DRY_RUN"
  echo ""

  # Phase 1: Discover and score candidates
  discover_candidates

  if [[ ${#CANDIDATE_SLUGS[@]} -eq 0 ]]; then
    echo "[batch-implement] No candidates found. Nothing to do."
    exit 2
  fi

  score_risk

  # Phase 2: Present for approval
  if ! present_batch; then
    exit 0
  fi

  # Initialize result arrays
  RESULT_SLUGS=()
  RESULT_STATUS=()
  RESULT_COST=()
  RESULT_DURATION=()
  RESULT_OUTPUT_FILE=()
  RESULT_ERROR=()

  # Also track verification status and pre-run state per item
  RESULT_VERIFY=()
  RESULT_PRE_CHECKED=()

  # Phase 3: Execute and verify loop
  local total=${#CANDIDATE_SLUGS[@]}
  local batch_failed=false
  local i

  for i in "${!CANDIDATE_SLUGS[@]}"; do
    local item_num=$((i + 1))
    local slug="${CANDIDATE_SLUGS[$i]}"

    # Execute implementation
    local exec_ok=true
    execute_item "$i" "$item_num" "$total" || exec_ok=false

    # Get the index of the result we just added
    local ridx=$(( ${#RESULT_SLUGS[@]} - 1 ))

    # If execution failed, record verification as failed and stop
    if [[ "$exec_ok" == false ]]; then
      RESULT_VERIFY+=("failed")
      echo "[batch-implement] [$item_num/$total] $slug: failed (${RESULT_DURATION[$ridx]}s, \$${RESULT_COST[$ridx]}) — stopping batch"
      batch_failed=true
      break
    fi

    # If dry-run/skipped, no verification needed
    if [[ "${RESULT_STATUS[$ridx]}" == "skipped" ]]; then
      RESULT_VERIFY+=("skipped")
      continue
    fi

    # Verify implementation output
    local verify_status
    verify_status=$(verify_item "$slug" "${RESULT_OUTPUT_FILE[$ridx]}" "${RESULT_PRE_CHECKED[$ridx]}")
    RESULT_VERIFY+=("$verify_status")

    # Format duration for display
    local dur="${RESULT_DURATION[$ridx]}"
    local dur_min=$((dur / 60))
    local dur_sec=$((dur % 60))
    local dur_display="${dur_min}m ${dur_sec}s"

    case "$verify_status" in
      completed)
        echo "[batch-implement] [$item_num/$total] $slug: completed (\$${RESULT_COST[$ridx]}, $dur_display)"
        ;;
      partial)
        echo "[batch-implement] [$item_num/$total] $slug: partial (\$${RESULT_COST[$ridx]}, $dur_display) — some tasks completed but not all"
        ;;
      failed)
        echo "[batch-implement] [$item_num/$total] $slug: failed (\$${RESULT_COST[$ridx]}, $dur_display) — stopping batch"
        batch_failed=true
        break
        ;;
    esac
  done

  echo ""

  # Phase 4: Report
  report_results

  if [[ "$batch_failed" == true ]]; then
    exit 1
  fi

  exit 0
}

main "$@"
