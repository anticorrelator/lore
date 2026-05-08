#!/usr/bin/env bats
# transcripts.bats — Smoke coverage for the transcript-provider package
# (Phase 5, T50).
#
# Verifies the four assertions named in the T50 task brief plus the
# shared-helpers + dispatch contract documented in
# adapters/transcripts/README.md:
#   1. provider_status() returns 'full' on claude-code.
#   2. parse_transcript returns the same message count as
#      scripts/transcript.py::parse_transcript for the same fixture
#      (byte-equivalence anchor for the claude-code-baseline invariant).
#   3. The alignment invariant len(read_raw_lines) == len(parse_transcript)
#      holds — load-bearing for windowed debug-evidence extraction in
#      extract-session-digest.py (T47).
#   4. previous_session_path returns the file at index 1 (second-most-
#      recent by mtime), not index 0 — the digest extractor relies on
#      this because the most-recent JSONL IS the current session at
#      SessionStart hook time.
#
# Plus a few extension checks (session_metadata, tool_use_timestamps,
# the shared helpers count_tool_uses + has_recent_capture +
# extract_text_blocks) so future regressions on T47/T48 surface here
# rather than inside T52/T53 consumer migrations.
#
# Style: pure bats. Skips cleanly when python3 is missing.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
PROVIDER_PKG="$REPO_DIR/adapters/transcripts"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  [ -f "$PROVIDER_PKG/__init__.py" ] || skip "adapters/transcripts/__init__.py missing"
  [ -f "$PROVIDER_PKG/claude_code.py" ] || skip "adapters/transcripts/claude_code.py missing"
  [ -f "$REPO_DIR/scripts/transcript.py" ] || skip "scripts/transcript.py missing"

  # Stage an isolated LORE_DATA_DIR so the provider's _resolve_scripts_dir
  # finds scripts/ via the symlink chain rather than touching the user's
  # ~/.lore install. The Go side does the same staging in harness_args.bats
  # via setup() — same pattern keeps tests hermetic.
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  export LORE_FRAMEWORK="claude-code"

  # Build a synthetic JSONL fixture with mixed user/assistant/tool_use/
  # tool_result entries — matches the shape produced by
  # claude-code's real transcript writer.
  TRANSCRIPT_FIXTURE="$(mktemp -t transcript-fixture.XXXXXX.jsonl)"
  python3 <<PYEOF
import json
entries = [
    {"sessionId": "test-sess-1", "timestamp": "2026-05-04T08:00:00Z",
     "type": "human",
     "message": {"role": "user", "content": "do the thing"}},
    {"sessionId": "test-sess-1", "timestamp": "2026-05-04T08:00:01Z",
     "type": "assistant",
     "message": {"role": "assistant",
                 "content": [
                     {"type": "text", "text": "Reading file."},
                     {"type": "tool_use", "name": "Read",
                      "input": {"file_path": "/tmp/foo.py"}},
                 ]}},
    {"sessionId": "test-sess-1", "timestamp": "2026-05-04T08:00:02Z",
     "type": "user",
     "message": {"role": "user",
                 "content": [{"type": "tool_result",
                              "content": "file contents here"}]}},
    {"sessionId": "test-sess-1", "timestamp": "2026-05-04T08:00:03Z",
     "type": "assistant",
     "message": {"role": "assistant",
                 "content": [
                     {"type": "tool_use", "name": "ExitPlanMode",
                      "input": {"plan": "implement X"}},
                 ]}},
]
with open("$TRANSCRIPT_FIXTURE", "w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
PYEOF
}

teardown() {
  if [ -n "${TRANSCRIPT_FIXTURE:-}" ] && [ -f "$TRANSCRIPT_FIXTURE" ]; then
    rm -f "$TRANSCRIPT_FIXTURE"
  fi
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
}

# --- Helper: run the provider package with REPO_DIR on sys.path ---
provider_py() {
  REPO_DIR="$REPO_DIR" \
  TEST_LORE_DATA_DIR="${TEST_LORE_DATA_DIR:-}" \
  LORE_DATA_DIR="${LORE_DATA_DIR:-}" \
  LORE_FRAMEWORK="${LORE_FRAMEWORK:-}" \
  python3 -c "
import os, sys
sys.path.insert(0, os.environ['REPO_DIR'])
$1
"
}

# ============================================================
# T50 hard requirements
# ============================================================

@test "provider_status returns 'full' on claude-code" {
  run provider_py "
from adapters.transcripts import get_provider
provider = get_provider('claude-code')
support, reason = provider.provider_status()
assert support == 'full', f'expected full, got {support!r}'
assert reason == '', f'expected empty reason on full, got {reason!r}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "parse_transcript byte-equivalent to scripts/transcript.py on fixture" {
  run provider_py "
import sys, os
sys.path.insert(0, os.path.join(os.environ['REPO_DIR'], 'scripts'))
import transcript as legacy
from adapters.transcripts import get_provider
provider = get_provider('claude-code')

fixture = '$TRANSCRIPT_FIXTURE'
legacy_msgs = legacy.parse_transcript(fixture)
provider_msgs = provider.parse_transcript(fixture)
assert legacy_msgs == provider_msgs, 'byte-equivalence broke'
assert len(provider_msgs) == 4, f'expected 4 messages, got {len(provider_msgs)}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "alignment invariant: len(read_raw_lines) == len(parse_transcript)" {
  run provider_py "
from adapters.transcripts import get_provider
provider = get_provider('claude-code')

fixture = '$TRANSCRIPT_FIXTURE'
raw = provider.read_raw_lines(fixture)
parsed = provider.parse_transcript(fixture)
assert len(raw) == len(parsed), f'alignment invariant violated: {len(raw)} raw vs {len(parsed)} parsed'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "previous_session_path returns the second-most-recent JSONL ([1], not [0])" {
  # Build a synthetic project dir under ~/.claude/projects/<encoded-cwd>/
  # with three JSONL files at known mtimes, then assert that
  # previous_session_path returns the *second* (jsonl_files[1] after
  # mtime-desc sort).
  run provider_py "
import os, time
from pathlib import Path
from adapters.transcripts import get_provider

# Stage a project dir under a fake \$HOME so we don't touch the real one.
fake_home = os.environ['TEST_LORE_DATA_DIR']
os.environ['HOME'] = fake_home
cwd = '/work/test-project'
project_id = cwd.replace('/', '-')
project_dir = Path(fake_home) / '.claude' / 'projects' / project_id
project_dir.mkdir(parents=True, exist_ok=True)

# Three JSONL files with known mtimes.
files = []
for i, name in enumerate(['oldest.jsonl', 'middle.jsonl', 'newest.jsonl']):
    p = project_dir / name
    p.write_text('{}\n')
    # ascending mtime → newest.jsonl is most recent.
    os.utime(p, (1000 + i, 1000 + i))
    files.append(p)

provider = get_provider('claude-code')
result = provider.previous_session_path(cwd)
expected = str(files[1])  # 'middle.jsonl' is index 1 after mtime-desc sort
assert result == expected, f'expected second-most-recent {expected}, got {result}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ============================================================
# Extension surface (T47, T48, T56)
# ============================================================

@test "session_metadata returns sessionId + parsed timestamp from first entry" {
  run provider_py "
from datetime import datetime
from adapters.transcripts import get_provider
provider = get_provider('claude-code')

fixture = '$TRANSCRIPT_FIXTURE'
md = provider.session_metadata(fixture)
assert md['session_id'] == 'test-sess-1', f'got {md[\"session_id\"]!r}'
assert isinstance(md['session_date'], datetime), f'got {type(md[\"session_date\"]).__name__}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "tool_use_timestamps returns per-entry ts for the named tool" {
  run provider_py "
from adapters.transcripts import get_provider
provider = get_provider('claude-code')

fixture = '$TRANSCRIPT_FIXTURE'
ts = provider.tool_use_timestamps(fixture, 'ExitPlanMode')
assert ts == [(3, '2026-05-04T08:00:03Z')], f'unexpected: {ts}'
ts_empty = provider.tool_use_timestamps(fixture, 'Bash')
assert ts_empty == [], f'expected empty for unused tool: {ts_empty}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "shared helpers count_tool_uses + has_recent_capture + extract_text_blocks work over normalized schema" {
  run provider_py "
from adapters.transcripts import (
    count_tool_uses, has_recent_capture, extract_text_blocks, get_provider
)
provider = get_provider('claude-code')

fixture = '$TRANSCRIPT_FIXTURE'
msgs = provider.parse_transcript(fixture)

tu = count_tool_uses(msgs)
assert tu == 2, f'expected 2 tool_use messages, got {tu}'

hrc = has_recent_capture(msgs)
assert hrc is False, 'fixture has no lore capture invocations'

tb = extract_text_blocks(msgs)
# Two text blocks across two messages: 'do the thing' (idx 0),
# 'Reading file.' (idx 1), 'file contents here' (idx 2 tool_result).
# tool_result blocks are surfaced as text by parse_transcript so all
# three text blocks should appear.
assert len(tb) >= 2, f'expected >=2 text blocks, got {len(tb)}'
indices = [i for i, _ in tb]
assert indices == sorted(indices), 'extract_text_blocks should preserve message order'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "get_provider returns partial provider for opencode (T51 stub landed)" {
  run provider_py "
from adapters.transcripts import get_provider
provider = get_provider('opencode')
support, reason = provider.provider_status()
assert support == 'partial', f'expected partial, got {support!r}'
assert reason, 'expected non-empty degraded reason on partial provider'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "get_provider returns partial provider for codex (T51 stub landed)" {
  run provider_py "
from adapters.transcripts import get_provider
provider = get_provider('codex')
support, reason = provider.provider_status()
assert support == 'partial', f'expected partial, got {support!r}'
assert reason, 'expected non-empty degraded reason on partial provider'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "get_provider raises UnsupportedFrameworkError for unknown framework" {
  run provider_py "
from adapters.transcripts import get_provider, UnsupportedFrameworkError
try:
    get_provider('unknown-harness')
    assert False, 'expected UnsupportedFrameworkError'
except UnsupportedFrameworkError as e:
    assert 'unknown-harness' in str(e), f'unexpected error: {e}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
