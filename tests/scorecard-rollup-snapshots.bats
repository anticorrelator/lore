#!/usr/bin/env bats
# scorecard-rollup-snapshots.bats — Snapshot persistence + /retro Step 3.0 lookup.
#
# Substrate side (D5): scorecard-rollup.sh writes _current.json and copies the
# same JSON content to _scorecards/snapshots/<window_end>.json. The filename
# is the top-level window_end field — file-naming key === selection key.
#
# Consumer side: /retro Step 3.0a selects the snapshot whose top-level
# window_end is the most recent value strictly earlier than the current retro
# window's start. _current.json is excluded (it lives in the parent directory
# and is not a snapshot); at-or-after-start snapshots are excluded.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
ROLLUP_SH="$REPO_DIR/scripts/scorecard-rollup.sh"
APPEND_SH="$REPO_DIR/scripts/scorecard-append.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  [ -f "$ROLLUP_SH" ] || skip "scripts/scorecard-rollup.sh missing"
  [ -f "$APPEND_SH" ] || skip "scripts/scorecard-append.sh missing"

  KDIR="$(mktemp -d)"
  mkdir -p "$KDIR/_scorecards"
  printf '%s' '{"format_version": 2}' > "$KDIR/_manifest.json"
}

teardown() {
  if [ -n "${KDIR:-}" ] && [ -d "$KDIR" ]; then
    rm -rf "$KDIR"
  fi
}

append_row() {
  bash "$APPEND_SH" --kdir "$KDIR" --row "$1" >/dev/null
}

run_rollup() {
  bash "$ROLLUP_SH" --kdir "$KDIR" >/dev/null 2>&1
}

# /retro Step 3.0a selection algorithm — file/line-anchored mirror of the
# prose in skills/retro/SKILL.md §3.0a. Picks the snapshot whose top-level
# window_end is the max value strictly earlier than $current_start.
# Excludes $KDIR/_scorecards/_current.json (parent dir, not a snapshot) and
# any candidate whose window_end is missing/empty.
select_prior_snapshot() {
  local current_start="$1"
  local snap_dir="$KDIR/_scorecards/snapshots"
  [ -d "$snap_dir" ] || { echo ""; return 0; }
  local picked=""
  local picked_we=""
  local f we
  shopt -s nullglob
  for f in "$snap_dir"/*.json; do
    we=$(jq -r '.window_end // empty' "$f" 2>/dev/null)
    [ -z "$we" ] && continue
    [ "$we" = "null" ] && continue
    # strict inequality — equal-to-start is NOT eligible
    if [[ "$we" < "$current_start" ]]; then
      if [ -z "$picked_we" ] || [[ "$we" > "$picked_we" ]]; then
        picked="$f"
        picked_we="$we"
      fi
    fi
  done
  shopt -u nullglob
  echo "$picked"
}

# ============================================================
# Substrate side: rollup writes a snapshot per invocation, filename matches
# the top-level window_end field, both snapshots persist when window_end
# differs across rollups.
# ============================================================

@test "rollup: writes snapshot with filename === top-level window_end (single rollup)" {
  append_row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"accuracy","value":0.5,"sample_size":2,"window_start":"2026-04-01T00:00:00Z","window_end":"2026-04-30T00:00:00Z"}'

  run_rollup

  # _current.json carries top-level window_end = max(summaries[].window_end)
  local cur_we
  cur_we=$(jq -r '.window_end' "$KDIR/_scorecards/_current.json")
  [ "$cur_we" = "2026-04-30T00:00:00Z" ]

  # Snapshot file uses the same value as filename.
  [ -f "$KDIR/_scorecards/snapshots/2026-04-30T00:00:00Z.json" ]

  # Snapshot content === _current.json content (byte-identical).
  cmp -s "$KDIR/_scorecards/_current.json" \
         "$KDIR/_scorecards/snapshots/2026-04-30T00:00:00Z.json"
}

@test "rollup: two invocations with distinct window_end persist as two snapshots" {
  # First window: April. Append a row, roll up, then capture filename.
  append_row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"accuracy","value":0.5,"sample_size":2,"window_start":"2026-04-01T00:00:00Z","window_end":"2026-04-30T00:00:00Z"}'
  run_rollup

  [ -f "$KDIR/_scorecards/snapshots/2026-04-30T00:00:00Z.json" ]

  # Second window: May. Append a second row whose window_end is later, then
  # roll up again — the new max(summaries[].window_end) is the May value.
  append_row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"accuracy","value":0.7,"sample_size":2,"window_start":"2026-05-01T00:00:00Z","window_end":"2026-05-31T00:00:00Z"}'
  run_rollup

  # The earlier snapshot still persists (no retention policy — D5).
  [ -f "$KDIR/_scorecards/snapshots/2026-04-30T00:00:00Z.json" ]
  # The new snapshot is named for the later window_end.
  [ -f "$KDIR/_scorecards/snapshots/2026-05-31T00:00:00Z.json" ]

  # _current.json now carries the later window_end.
  local cur_we
  cur_we=$(jq -r '.window_end' "$KDIR/_scorecards/_current.json")
  [ "$cur_we" = "2026-05-31T00:00:00Z" ]

  # Snapshot count is exactly 2.
  local snap_count
  snap_count=$(ls "$KDIR/_scorecards/snapshots" | wc -l | tr -d ' ')
  [ "$snap_count" = "2" ]
}

@test "rollup: empty rows.jsonl falls back window_end to generated_at and still snapshots" {
  : > "$KDIR/_scorecards/rows.jsonl"
  run_rollup

  local cur_we cur_ga
  cur_we=$(jq -r '.window_end' "$KDIR/_scorecards/_current.json")
  cur_ga=$(jq -r '.generated_at' "$KDIR/_scorecards/_current.json")
  # Empty-summary fallback: window_end === generated_at.
  [ "$cur_we" = "$cur_ga" ]
  [ -n "$cur_we" ] && [ "$cur_we" != "null" ]

  # Snapshot exists at <window_end>.json.
  [ -f "$KDIR/_scorecards/snapshots/${cur_we}.json" ]
}

# ============================================================
# Consumer side: /retro Step 3.0a fixture — multi-snapshot lookup picks
# the most-recent-strictly-prior snapshot, NOT _current.json and NOT any
# at-or-after snapshot.
# ============================================================

@test "/retro Step 3.0a: picks max-strictly-earlier snapshot, not _current.json, not at-or-after" {
  # Build a fixture with three snapshots and a _current.json. snapshots
  # spanning Feb / Mar / May; the current retro window starts 2026-04-15.
  # Expected pick: the March snapshot (max strictly earlier than 04-15).
  mkdir -p "$KDIR/_scorecards/snapshots"

  # Helper: write a snapshot whose top-level window_end matches the filename.
  write_snap() {
    local we="$1"
    printf '%s' "{\"generated_at\":\"$we\",\"window_end\":\"$we\",\"source\":\"_scorecards/rows.jsonl\",\"row_count\":0,\"corrupt_row_count\":0,\"summaries\":[]}" \
      > "$KDIR/_scorecards/snapshots/${we}.json"
  }

  write_snap "2026-02-28T00:00:00Z"
  write_snap "2026-03-31T00:00:00Z"
  # Equal-to-start: must NOT be selected (strict inequality).
  write_snap "2026-04-15T00:00:00Z"
  # After the start: must NOT be selected.
  write_snap "2026-05-31T00:00:00Z"

  # _current.json sits in the parent directory; the algorithm must NOT pick it.
  printf '%s' '{"generated_at":"2026-05-31T00:00:00Z","window_end":"2026-05-31T00:00:00Z","source":"_scorecards/rows.jsonl","row_count":0,"corrupt_row_count":0,"summaries":[]}' \
    > "$KDIR/_scorecards/_current.json"

  local picked
  picked=$(select_prior_snapshot "2026-04-15T00:00:00Z")
  [ -n "$picked" ]
  # Filename === window_end of the chosen snapshot.
  [ "$(basename "$picked")" = "2026-03-31T00:00:00Z.json" ]
  # And it does NOT come from the parent directory (not _current.json).
  [ "$(dirname "$picked")" = "$KDIR/_scorecards/snapshots" ]
}

@test "/retro Step 3.0a: skips snapshots whose window_end is missing or invalid" {
  mkdir -p "$KDIR/_scorecards/snapshots"

  # Valid prior snapshot.
  printf '%s' '{"generated_at":"2026-03-31T00:00:00Z","window_end":"2026-03-31T00:00:00Z","source":"_scorecards/rows.jsonl","row_count":0,"corrupt_row_count":0,"summaries":[]}' \
    > "$KDIR/_scorecards/snapshots/2026-03-31T00:00:00Z.json"

  # Missing window_end field — must be excluded.
  printf '%s' '{"generated_at":"2026-04-10T00:00:00Z","source":"_scorecards/rows.jsonl","row_count":0,"corrupt_row_count":0,"summaries":[]}' \
    > "$KDIR/_scorecards/snapshots/missing-we.json"

  # Empty window_end — must be excluded.
  printf '%s' '{"generated_at":"2026-04-12T00:00:00Z","window_end":"","source":"_scorecards/rows.jsonl","row_count":0,"corrupt_row_count":0,"summaries":[]}' \
    > "$KDIR/_scorecards/snapshots/empty-we.json"

  local picked
  picked=$(select_prior_snapshot "2026-04-15T00:00:00Z")
  [ "$(basename "$picked")" = "2026-03-31T00:00:00Z.json" ]
}

@test "/retro Step 3.0a: no eligible prior snapshot returns empty selection" {
  mkdir -p "$KDIR/_scorecards/snapshots"

  # Only at-or-after snapshots exist.
  printf '%s' '{"window_end":"2026-04-15T00:00:00Z","summaries":[]}' \
    > "$KDIR/_scorecards/snapshots/2026-04-15T00:00:00Z.json"
  printf '%s' '{"window_end":"2026-05-31T00:00:00Z","summaries":[]}' \
    > "$KDIR/_scorecards/snapshots/2026-05-31T00:00:00Z.json"

  local picked
  picked=$(select_prior_snapshot "2026-04-15T00:00:00Z")
  [ -z "$picked" ]
}
