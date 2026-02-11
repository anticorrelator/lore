#!/usr/bin/env bash
# batch-spec.sh — Batch-run /spec short on work items needing plans
# Usage: bash batch-spec.sh [options]
# Discovers work items without plan.md, scores readiness, and runs
# /spec short via `claude -p` for unattended plan generation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

# --- Defaults ---
MAX_BUDGET="2.0"
MODEL="sonnet"
DRY_RUN=false
INCLUDE_SLUGS=()
EXCLUDE_SLUGS=()

# --- usage ---
usage() {
  cat <<EOF
Usage: batch-spec.sh [options]

Discover work items needing specs and batch-run /spec short on them.

Options:
  --max-budget N       Per-item cost cap in USD (default: 2.0)
  --model <model>      Model to use for spec generation (default: sonnet)
  --dry-run            Show candidates without executing
  --include <slug>     Only process these slugs (repeatable)
  --exclude <slug>     Skip these slugs (repeatable)
  -h, --help           Show this help message

Examples:
  batch-spec.sh                          # Run on all eligible items
  batch-spec.sh --dry-run                # Preview candidates only
  batch-spec.sh --include auth-refactor  # Only spec this item
  batch-spec.sh --exclude legacy-api     # Skip this item
  batch-spec.sh --max-budget 1.0         # Lower cost cap
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
# Find work items that need specs and are ready for /spec short.
# Criteria:
#   1. has_plan_doc: false in _index.json
#   2. notes.md exists in _work/<slug>/
#   3. notes.md has >5 non-comment, non-blank lines (template-only = not enough)
#   4. Passes --include/--exclude filters
# Populates global arrays:
#   CANDIDATE_SLUGS[]  — slugs that passed all criteria
#   CANDIDATE_TITLES[] — corresponding titles (parallel array)
#   SKIPPED_NO_NOTES[] — slugs skipped because notes.md missing
#   SKIPPED_THIN_NOTES[] — slugs skipped because notes.md too thin
#   SKIPPED_FILTERED[]  — slugs skipped by include/exclude filters
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
  SKIPPED_NO_NOTES=()
  SKIPPED_THIN_NOTES=()
  SKIPPED_FILTERED=()

  local cur_slug="" cur_title="" cur_has_plan=""

  while IFS= read -r line; do
    # Parse slug
    if echo "$line" | grep -q '"slug"'; then
      cur_slug=$(echo "$line" | sed 's/.*"slug"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
    fi
    # Parse title
    if echo "$line" | grep -q '"title"'; then
      cur_title=$(echo "$line" | sed 's/.*"title"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
    fi
    # Parse has_plan_doc (last field per entry — triggers processing)
    if echo "$line" | grep -q '"has_plan_doc"'; then
      if echo "$line" | grep -q 'true'; then
        cur_has_plan="true"
      else
        cur_has_plan="false"
      fi

      # Only consider items without a plan
      if [[ "$cur_has_plan" == "false" && -n "$cur_slug" ]]; then
        # Apply include/exclude filters
        if ! slug_matches_filters "$cur_slug"; then
          SKIPPED_FILTERED+=("$cur_slug")
          cur_slug="" ; cur_title="" ; cur_has_plan=""
          continue
        fi

        local notes_file="$WORK_DIR/$cur_slug/notes.md"

        # Check notes.md existence
        if [[ ! -f "$notes_file" ]]; then
          SKIPPED_NO_NOTES+=("$cur_slug")
          cur_slug="" ; cur_title="" ; cur_has_plan=""
          continue
        fi

        # Count non-blank, non-comment lines (strip template headers/comments)
        local content_lines
        content_lines=$(sed '/^$/d; /^<!--/d; /^-->/d' "$notes_file" | wc -l | tr -d ' ')

        if [[ "$content_lines" -le 5 ]]; then
          SKIPPED_THIN_NOTES+=("$cur_slug")
          cur_slug="" ; cur_title="" ; cur_has_plan=""
          continue
        fi

        CANDIDATE_SLUGS+=("$cur_slug")
        CANDIDATE_TITLES+=("$cur_title")
      fi

      # Reset for next entry
      cur_slug="" ; cur_title="" ; cur_has_plan=""
    fi
  done < "$index"

  echo "[batch-spec] Discovered ${#CANDIDATE_SLUGS[@]} candidate(s)"
  if [[ ${#SKIPPED_FILTERED[@]} -gt 0 ]]; then
    echo "[batch-spec]   Filtered out: ${#SKIPPED_FILTERED[@]}"
  fi
  if [[ ${#SKIPPED_NO_NOTES[@]} -gt 0 ]]; then
    echo "[batch-spec]   No notes.md: ${#SKIPPED_NO_NOTES[@]}"
  fi
  if [[ ${#SKIPPED_THIN_NOTES[@]} -gt 0 ]]; then
    echo "[batch-spec]   Notes too thin: ${#SKIPPED_THIN_NOTES[@]}"
  fi
}

# --- score_readiness ---
# For each candidate, analyze notes.md content density and assign a readiness score.
# Reads from CANDIDATE_SLUGS[]/CANDIDATE_TITLES[] (set by discover_candidates).
# Populates parallel arrays:
#   CANDIDATE_READINESS[]   — "high", "medium", or "low"
#   CANDIDATE_WORD_COUNT[]  — word count of notes.md
#   CANDIDATE_HEADINGS[]    — count of ### headings
#   CANDIDATE_BULLETS[]     — count of bullet points (lines starting with "- ")
#   CANDIDATE_HAS_PATHS[]   — "yes" or "no" (backtick-wrapped file paths)
#   CANDIDATE_UPDATED[]     — last_updated from _meta.json
score_readiness() {
  CANDIDATE_READINESS=()
  CANDIDATE_WORD_COUNT=()
  CANDIDATE_HEADINGS=()
  CANDIDATE_BULLETS=()
  CANDIDATE_HAS_PATHS=()
  CANDIDATE_UPDATED=()

  local i slug notes_file meta_file
  for i in "${!CANDIDATE_SLUGS[@]}"; do
    slug="${CANDIDATE_SLUGS[$i]}"
    notes_file="$WORK_DIR/$slug/notes.md"
    meta_file="$WORK_DIR/$slug/_meta.json"

    # Word count
    local word_count=0
    if [[ -f "$notes_file" ]]; then
      word_count=$(wc -w < "$notes_file" | tr -d ' ')
    fi
    CANDIDATE_WORD_COUNT+=("$word_count")

    # Count ### headings
    local heading_count=0
    if [[ -f "$notes_file" ]]; then
      heading_count=$(grep -c '^### ' "$notes_file" 2>/dev/null || true)
    fi
    CANDIDATE_HEADINGS+=("$heading_count")

    # Count bullet points (lines starting with - )
    local bullet_count=0
    if [[ -f "$notes_file" ]]; then
      bullet_count=$(grep -c '^[[:space:]]*- ' "$notes_file" 2>/dev/null || true)
    fi
    CANDIDATE_BULLETS+=("$bullet_count")

    # Check for backtick-wrapped file paths (e.g., `scripts/foo.sh`)
    local has_paths="no"
    if [[ -f "$notes_file" ]]; then
      if grep -qE '`[a-zA-Z0-9_./-]+\.[a-zA-Z]+`' "$notes_file" 2>/dev/null; then
        has_paths="yes"
      fi
    fi
    CANDIDATE_HAS_PATHS+=("$has_paths")

    # Count structured fields: **Focus**, **Concept**, **Context**
    local field_count=0
    if [[ -f "$notes_file" ]]; then
      field_count=$(grep -cE '^\*\*(Focus|Concept|Context)\*\*' "$notes_file" 2>/dev/null || true)
    fi

    # Last updated from _meta.json
    local updated=""
    if [[ -f "$meta_file" ]]; then
      updated=$(json_field "updated" "$meta_file")
    fi
    CANDIDATE_UPDATED+=("${updated:-unknown}")

    # Score readiness based on thresholds
    local readiness="low"
    if [[ "$word_count" -gt 200 ]] && [[ "$heading_count" -gt 2 || "$field_count" -gt 2 ]]; then
      readiness="high"
    elif [[ "$word_count" -gt 100 ]] || { [[ "$heading_count" -gt 1 ]] && [[ "$bullet_count" -gt 3 ]]; }; then
      readiness="medium"
    fi
    CANDIDATE_READINESS+=("$readiness")
  done

  # Summary
  local high=0 medium=0 low=0
  for r in "${CANDIDATE_READINESS[@]}"; do
    case "$r" in
      high) high=$((high + 1)) ;;
      medium) medium=$((medium + 1)) ;;
      low) low=$((low + 1)) ;;
    esac
  done
  echo "[batch-spec] Readiness scores: $high high, $medium medium, $low low"
}

# --- present_batch ---
# Display a formatted table of candidates with readiness scores and prompt for approval.
# Reads from parallel arrays populated by discover_candidates() and score_readiness().
# In dry-run mode, displays the table and returns 1 (no execution).
# Approval modes:
#   y/Y/enter = approve all candidates
#   n/N       = abort (returns 1)
#   e/edit    = open temp file with slugs for manual pruning
# After approval, CANDIDATE_SLUGS/CANDIDATE_TITLES are pruned to approved set.
# Returns 0 if approved (candidates to process), 1 if aborted or dry-run.
present_batch() {
  if [[ ${#CANDIDATE_SLUGS[@]} -eq 0 ]]; then
    echo "[batch-spec] No candidates to process."
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
  echo "=== Batch Spec Candidates ==="
  echo ""
  printf "  %-35s %-40s %-6s %5s %4s  %-10s\n" "SLUG" "TITLE" "READY" "WORDS" "SECT" "UPDATED"
  printf "  %-35s %-40s %-6s %5s %4s  %-10s\n" "----" "-----" "-----" "-----" "----" "-------"

  local i
  for i in "${!CANDIDATE_SLUGS[@]}"; do
    local slug="${CANDIDATE_SLUGS[$i]}"
    local title="${CANDIDATE_TITLES[$i]}"
    local readiness="${CANDIDATE_READINESS[$i]}"
    local words="${CANDIDATE_WORD_COUNT[$i]}"
    local sections="${CANDIDATE_HEADINGS[$i]}"
    local updated
    updated=$(_relative_date "${CANDIDATE_UPDATED[$i]}")

    # Truncate title for display
    if [[ ${#title} -gt 38 ]]; then
      title="${title:0:35}..."
    fi
    # Truncate slug for display
    if [[ ${#slug} -gt 33 ]]; then
      slug="${slug:0:30}..."
    fi

    printf "  %-35s %-40s %-6s %5s %4s  %-10s\n" "$slug" "$title" "$readiness" "$words" "$sections" "$updated"
  done

  echo ""
  echo "  Total: ${#CANDIDATE_SLUGS[@]} candidate(s)"
  echo ""

  # Dry-run: show table but don't prompt
  if [[ "$DRY_RUN" == true ]]; then
    echo "[batch-spec] Dry run — no specs will be generated."
    return 1
  fi

  # Prompt for approval
  printf "Approve batch? [Y/n/edit] "
  local reply
  read -r reply

  case "$reply" in
    n|N)
      echo "[batch-spec] Aborted."
      return 1
      ;;
    e|edit|E|Edit)
      # Write slugs to temp file for manual pruning
      local tmpfile
      tmpfile=$(mktemp /tmp/batch-spec-edit.XXXXXX)
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
        echo "[batch-spec] No items selected. Aborted."
        return 1
      fi

      # Prune candidates to approved set
      local new_slugs=() new_titles=() new_readiness=() new_words=() new_headings=() new_bullets=() new_paths=() new_updated=()
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
          new_readiness+=("${CANDIDATE_READINESS[$i]}")
          new_words+=("${CANDIDATE_WORD_COUNT[$i]}")
          new_headings+=("${CANDIDATE_HEADINGS[$i]}")
          new_bullets+=("${CANDIDATE_BULLETS[$i]}")
          new_paths+=("${CANDIDATE_HAS_PATHS[$i]}")
          new_updated+=("${CANDIDATE_UPDATED[$i]}")
        fi
      done

      CANDIDATE_SLUGS=("${new_slugs[@]}")
      CANDIDATE_TITLES=("${new_titles[@]}")
      CANDIDATE_READINESS=("${new_readiness[@]}")
      CANDIDATE_WORD_COUNT=("${new_words[@]}")
      CANDIDATE_HEADINGS=("${new_headings[@]}")
      CANDIDATE_BULLETS=("${new_bullets[@]}")
      CANDIDATE_HAS_PATHS=("${new_paths[@]}")
      CANDIDATE_UPDATED=("${new_updated[@]}")

      echo "[batch-spec] Approved ${#CANDIDATE_SLUGS[@]} item(s) after edit."
      ;;
    *)
      # y/Y/empty = approve all
      echo "[batch-spec] Approved ${#CANDIDATE_SLUGS[@]} item(s)."
      ;;
  esac

  return 0
}

# --- execute_spec ---
# Invoke `claude -p "/spec short <slug>"` for a single candidate.
# Args: $1 = index into CANDIDATE_SLUGS[], $2 = current item number, $3 = total count
# Populates per-item entries in parallel arrays:
#   RESULT_SLUGS[]       — slug processed
#   RESULT_STATUS[]      — "success", "error", or "skipped"
#   RESULT_COST[]        — cost in USD (from claude JSON output)
#   RESULT_DURATION[]    — wall-clock seconds
#   RESULT_OUTPUT_FILE[] — path to saved JSON output
#   RESULT_ERROR[]       — error message if failed, empty otherwise
execute_spec() {
  local idx="$1"
  local item_num="$2"
  local total="$3"
  local slug="${CANDIDATE_SLUGS[$idx]}"
  local readiness="${CANDIDATE_READINESS[$idx]}"

  echo "[batch-spec] ($item_num/$total) Speccing '$slug' [readiness: $readiness]..."

  # Dry-run: skip actual execution
  if [[ "$DRY_RUN" == true ]]; then
    RESULT_SLUGS+=("$slug")
    RESULT_STATUS+=("skipped")
    RESULT_COST+=("0")
    RESULT_DURATION+=("0")
    RESULT_OUTPUT_FILE+=("")
    RESULT_ERROR+=("dry-run")
    echo "[batch-spec]   Dry run — skipped"
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
    echo "[batch-spec]   Error: claude CLI not found" >&2
    return 1
  fi

  local ts
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  local output_file="$WORK_DIR/$slug/batch-spec-${ts}.json"

  local system_prompt
  system_prompt="After writing plan.md, immediately run lore work regen-tasks $slug to generate tasks.json. Do not present the plan for review or ask for feedback. Do not use AskUserQuestion. Complete the spec autonomously and report what you produced."

  local start_epoch
  start_epoch=$(date +%s)

  # Invoke claude in print mode with JSON output
  local exit_code=0
  claude -p "/spec short $slug" \
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

  if [[ $exit_code -ne 0 ]]; then
    RESULT_STATUS+=("error")
    RESULT_COST+=("0")
    RESULT_ERROR+=("claude exited with code $exit_code")
    echo "[batch-spec]   Failed (exit code $exit_code, ${duration}s)"
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
    echo "[batch-spec]   Error reported by claude (${duration}s, \$$cost)"
    return 1
  fi

  RESULT_STATUS+=("success")
  RESULT_COST+=("$cost")
  RESULT_ERROR+=("")
  echo "[batch-spec]   Done (${duration}s, \$$cost)"
  return 0
}

# --- verify_spec ---
# Post-run verification of spec output for a single work item.
# Args: $1 = slug, $2 = JSON output file from claude
# Echoes status: "completed", "partial", or "failed"
# Checks (in order):
#   1. JSON output is_error field — if true, "failed"
#   2. plan.md exists — if missing, "failed"
#   3. plan.md contains ### Phase headers — if missing, "partial"
#   4. plan.md contains - [ ] task checkboxes — if missing, "partial"
#   5. tasks.json exists — if missing, "partial"
#   6. All pass = "completed"
verify_spec() {
  local slug="$1"
  local output_file="$2"
  local plan_file="$WORK_DIR/$slug/plan.md"
  local tasks_file="$WORK_DIR/$slug/tasks.json"

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

  # Check 2: plan.md exists
  if [[ ! -f "$plan_file" ]]; then
    echo "failed"
    return 0
  fi

  # Check 3: plan.md contains ### Phase headers
  if ! grep -q '^### Phase' "$plan_file" 2>/dev/null; then
    echo "partial"
    return 0
  fi

  # Check 4: plan.md contains - [ ] task checkboxes
  if ! grep -q '^\- \[ \]' "$plan_file" 2>/dev/null; then
    echo "partial"
    return 0
  fi

  # Check 5: tasks.json exists
  if [[ ! -f "$tasks_file" ]]; then
    echo "partial"
    return 0
  fi

  echo "completed"
  return 0
}

# --- report_results ---
# Print summary of batch run and write machine-readable JSON to _batch-runs/.
# Reads from RESULT_SLUGS[], RESULT_STATUS[], RESULT_COST[], RESULT_DURATION[],
# RESULT_OUTPUT_FILE[], RESULT_ERROR[], and RESULT_VERIFY[] arrays.
# Writes JSON to _work/_batch-runs/spec-<timestamp>.json.
report_results() {
  local attempted=0 completed=0 partial=0 failed=0 skipped=0
  local total_cost=0 total_duration=0

  if [[ ${#RESULT_SLUGS[@]} -eq 0 ]]; then
    echo ""
    echo "=== Batch Spec Results ==="
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
  echo "=== Batch Spec Results ==="
  echo "Items: $attempted attempted, $completed completed, $partial partial, $failed failed"
  if [[ $skipped -gt 0 ]]; then
    echo "Skipped: $skipped (dry-run)"
  fi
  echo "Cost: \$$total_cost total"
  echo "Duration: $duration_fmt"
  echo ""

  # List each item with status
  echo "Generated plans:"
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
        printf "  %-45s (completed)\n" "_work/$slug/plan.md"
        ;;
      partial)
        local reason=""
        if [[ ! -f "$WORK_DIR/$slug/tasks.json" ]]; then
          reason=" -- no tasks.json"
        elif ! grep -q '^### Phase' "$WORK_DIR/$slug/plan.md" 2>/dev/null; then
          reason=" -- no phase headers"
        fi
        printf "  %-45s (partial%s)\n" "_work/$slug/plan.md" "$reason"
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
    echo "Review plans before running batch-implement."
  fi

  # Write machine-readable JSON
  local batch_dir="$WORK_DIR/_batch-runs"
  mkdir -p "$batch_dir"

  local ts
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  local json_file="$batch_dir/spec-${ts}.json"

  {
    echo "{"
    echo "  \"type\": \"batch-spec\","
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
  echo "[batch-spec] Results written to: $json_file"
}

# --- Main ---
# Flow: discover -> score -> present -> execute+verify loop -> report
main() {
  echo "[batch-spec] Starting batch spec generation..."
  echo "[batch-spec] Work dir: $WORK_DIR"
  echo "[batch-spec] Model: $MODEL | Max budget: \$$MAX_BUDGET | Dry run: $DRY_RUN"
  echo ""

  # Phase 1: Discover and score candidates
  discover_candidates

  if [[ ${#CANDIDATE_SLUGS[@]} -eq 0 ]]; then
    echo "[batch-spec] No candidates found. Nothing to do."
    exit 2
  fi

  score_readiness

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

  # Also track verification status per item
  RESULT_VERIFY=()

  # Phase 3: Execute and verify loop
  local total=${#CANDIDATE_SLUGS[@]}
  local batch_failed=false
  local i

  for i in "${!CANDIDATE_SLUGS[@]}"; do
    local item_num=$((i + 1))
    local slug="${CANDIDATE_SLUGS[$i]}"

    # Execute spec
    local exec_ok=true
    execute_spec "$i" "$item_num" "$total" || exec_ok=false

    # Get the index of the result we just added
    local ridx=$(( ${#RESULT_SLUGS[@]} - 1 ))

    # If execution failed, record verification as failed and stop
    if [[ "$exec_ok" == false ]]; then
      RESULT_VERIFY+=("failed")
      echo "[batch-spec] [$item_num/$total] $slug: failed (${RESULT_DURATION[$ridx]}s, \$${RESULT_COST[$ridx]}) — stopping batch"
      batch_failed=true
      break
    fi

    # If dry-run/skipped, no verification needed
    if [[ "${RESULT_STATUS[$ridx]}" == "skipped" ]]; then
      RESULT_VERIFY+=("skipped")
      continue
    fi

    # Verify spec output
    local verify_status
    verify_status=$(verify_spec "$slug" "${RESULT_OUTPUT_FILE[$ridx]}")
    RESULT_VERIFY+=("$verify_status")

    # Format duration for display
    local dur="${RESULT_DURATION[$ridx]}"
    local dur_min=$((dur / 60))
    local dur_sec=$((dur % 60))
    local dur_display="${dur_min}m ${dur_sec}s"

    case "$verify_status" in
      completed)
        echo "[batch-spec] [$item_num/$total] $slug: completed (\$${RESULT_COST[$ridx]}, $dur_display)"
        ;;
      partial)
        echo "[batch-spec] [$item_num/$total] $slug: partial (\$${RESULT_COST[$ridx]}, $dur_display) — plan.md created but missing tasks or structure"
        ;;
      failed)
        echo "[batch-spec] [$item_num/$total] $slug: failed (\$${RESULT_COST[$ridx]}, $dur_display) — stopping batch"
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
