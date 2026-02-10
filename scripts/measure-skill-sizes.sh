#!/usr/bin/env bash
# measure-skill-sizes.sh — Measure skill file sizes and compare against a git ref
# Usage: bash measure-skill-sizes.sh [--compare <git-ref>]
# Output: Table of skill sizes with optional before/after comparison

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Parse arguments ---
COMPARE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compare)
      COMPARE_REF="$2"
      shift 2
      ;;
    *)
      echo "Usage: measure-skill-sizes.sh [--compare <git-ref>]" >&2
      exit 1
      ;;
  esac
done

# --- Output ---
if [[ -n "$COMPARE_REF" ]]; then
  # Comparison mode
  printf "%-25s %8s %8s %8s %6s\n" "Skill" "Before" "After" "Saved" "%"
  printf "%-25s %8s %8s %8s %6s\n" "─────────────────────────" "────────" "────────" "────────" "──────"

  total_before=0
  total_after=0

  for skill_dir in "$REPO_DIR"/skills/*/; do
    skill_name=$(basename "$skill_dir")
    skill_file="$skill_dir/SKILL.md"
    [[ -f "$skill_file" ]] || continue

    after=$(wc -l < "$skill_file" | tr -d '[:space:]')
    before=$(git -C "$REPO_DIR" show "$COMPARE_REF:skills/$skill_name/SKILL.md" 2>/dev/null | wc -l | tr -d '[:space:]')

    if [[ -z "$before" ]] || [[ "$before" == "0" ]]; then
      printf "%-25s %8s %8s %8s %5s%%\n" "$skill_name" "(new)" "$after" "-" "-"
      total_after=$((total_after + after))
    else
      saved=$((before - after))
      if [[ "$before" -gt 0 ]]; then
        pct=$(printf "%.1f" "$(echo "scale=1; $saved * 100 / $before" | bc)")
      else
        pct="0.0"
      fi
      printf "%-25s %8s %8s %8s %5s%%\n" "$skill_name" "$before" "$after" "$saved" "$pct"
      total_before=$((total_before + before))
      total_after=$((total_after + after))
    fi
  done

  total_saved=$((total_before - total_after))
  if [[ "$total_before" -gt 0 ]]; then
    total_pct=$(printf "%.1f" "$(echo "scale=1; $total_saved * 100 / $total_before" | bc)")
  else
    total_pct="0.0"
  fi

  printf "%-25s %8s %8s %8s %6s\n" "─────────────────────────" "────────" "────────" "────────" "──────"
  printf "%-25s %8s %8s %8s %5s%%\n" "Total" "$total_before" "$total_after" "$total_saved" "$total_pct"
  echo ""
  echo "Estimated token savings: ~$(( total_saved * 10 )) tokens (assuming ~10 tokens/line)"
else
  # Simple mode — just current sizes
  printf "%-25s %8s %10s\n" "Skill" "Lines" "Est.Tokens"
  printf "%-25s %8s %10s\n" "─────────────────────────" "────────" "──────────"

  total_lines=0
  for skill_dir in "$REPO_DIR"/skills/*/; do
    skill_name=$(basename "$skill_dir")
    skill_file="$skill_dir/SKILL.md"
    [[ -f "$skill_file" ]] || continue

    lines=$(wc -l < "$skill_file" | tr -d '[:space:]')
    tokens=$((lines * 10))
    total_lines=$((total_lines + lines))
    printf "%-25s %8s %10s\n" "$skill_name" "$lines" "$tokens"
  done

  total_tokens=$((total_lines * 10))
  printf "%-25s %8s %10s\n" "─────────────────────────" "────────" "──────────"
  printf "%-25s %8s %10s\n" "Total" "$total_lines" "$total_tokens"
fi
