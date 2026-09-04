#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_DIR/scripts/check-report-labels.py"

setup() {
  REPORT="$BATS_TEST_TMPDIR/report.md"
}

write_report() {
  cat > "$REPORT" <<EOF
Report-schema: 1
$1 Do the thing
**Changes:** none
**Observations:** none
**Tier 2 evidence:** none
EOF
}

@test "session and Codex gates invoke the tested label checker" {
  for template in session-worker codex-worker; do
    run rg -F 'python3 ~/.lore/scripts/check-report-labels.py "$REPORT_FILE"' \
      "$REPO_DIR/agents/$template.md"
    [ "$status" -eq 0 ]
  done
}

@test "plain and bold Task reports pass the session gate identically" {
  write_report 'Task:'
  run python3 "$CHECK" "$REPORT"
  [ "$status" -eq 0 ]
  local plain_output="$output"
  write_report '**Task:**'
  run python3 "$CHECK" "$REPORT"
  [ "$status" -eq 0 ]
  [ "$output" = "$plain_output" ]
}

@test "session gate rejects missing and empty reports" {
  run python3 "$CHECK" "$REPORT"
  [ "$status" -eq 1 ]
  : > "$REPORT"
  run python3 "$CHECK" "$REPORT"
  [ "$status" -eq 1 ]
}

@test "session gate still requires every report label" {
  for label in 'Task:' '**Changes:**' '**Observations:**' '**Tier 2 evidence:**'; do
    write_report 'Task:'
    python3 - "$REPORT" "$label" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text("\n".join(line for line in p.read_text().splitlines()
                       if not line.startswith(sys.argv[2])))
PY
    run python3 "$CHECK" "$REPORT"
    [ "$status" -eq 1 ]
  done
}

@test "session gate does not treat an inline Task mention as a label" {
  write_report 'This mentions Task:'
  run python3 "$CHECK" "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Missing report labels: Task'* ]]
}

@test "structural validators stop at either Task label" {
  run python3 - "$REPO_DIR" <<'PY'
from pathlib import Path
import runpy
import sys
root = Path(sys.argv[1])
structured = runpy.run_path(str(root / 'scripts/validate-structured-report.py'))
tier = runpy.run_path(str(root / 'scripts/validate-tier-sections.py'))
for label in ('Task:', '**Task:**'):
    report = '**Observations:**\n' + label + ' Other task\n- claim: outside\nfile: x\nline_range: 1-2\nfalsifier: test\nsignificance: high\n'
    count, error = structured['find_structured_entries'](report, 'Observations')
    assert count == 0 and error
    report = '**Convention handling:**\n' + label + ' Other task\n- honored: outside\n'
    assert structured['find_convention_handling'](report)
    report = '**Tier 2 evidence:**\n- c1\n' + label + ' Other task\n'
    assert tier['check_tier2'](report) == (True, None)
PY
  [ "$status" -eq 0 ]
}
