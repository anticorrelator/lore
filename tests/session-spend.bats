#!/usr/bin/env bats
# session-spend.bats — Shell-level tests for scripts/session-spend.sh, the
# boundary-time spend extractor fronting the per-harness session_spend()
# providers.
#
# Coverage:
#   - claude-code --transcript: sums message.usage into the D1 vocabulary.
#   - codex --transcript: reads the terminal cumulative token_count.
#   - degradation floor (always `{"basis":"duration-only"}`, exit 0): unsupported
#     harness, no binding, codex --session-id (no path derivation), and a missing
#     artifact.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
SPEND="$REPO_DIR/scripts/session-spend.sh"

setup() {
  [ -f "$SPEND" ] || skip "session-spend.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  CC_FIXTURE="$(mktemp -t spend-cc.XXXXXX.jsonl)"
  python3 <<PYEOF
import json
rows = [
    {"type": "assistant", "message": {"role": "assistant", "model": "claude-fable-5",
        "usage": {"input_tokens": 100, "output_tokens": 10,
                  "cache_read_input_tokens": 5, "cache_creation_input_tokens": 2}}},
    {"type": "assistant", "message": {"role": "assistant", "model": "claude-fable-5",
        "usage": {"input_tokens": 20, "output_tokens": 4,
                  "cache_read_input_tokens": 1, "cache_creation_input_tokens": 0}}},
]
with open("$CC_FIXTURE", "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PYEOF

  CODEX_FIXTURE="$(mktemp -t spend-codex.XXXXXX.jsonl)"
  python3 <<PYEOF
import json
rows = [
    {"type": "turn_context", "payload": {"type": "turn_context", "model": "gpt-5.4-mini"}},
    {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage":
        {"input_tokens": 900, "cached_input_tokens": 200, "output_tokens": 60,
         "reasoning_output_tokens": 12, "total_tokens": 972}}}},
]
with open("$CODEX_FIXTURE", "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PYEOF
}

teardown() {
  rm -f "${CC_FIXTURE:-}" "${CODEX_FIXTURE:-}"
}

@test "claude-code --transcript prints the D1 spend vocabulary" {
  run bash "$SPEND" --harness claude-code --transcript "$CC_FIXTURE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.basis' <<<"$output")" = "transcript" ]
  [ "$(jq -r '.input_tokens' <<<"$output")" = "120" ]
  [ "$(jq -r '.output_tokens' <<<"$output")" = "14" ]
  [ "$(jq -r '.total_tokens' <<<"$output")" = "142" ]
  [ "$(jq -r '.harness' <<<"$output")" = "claude-code" ]
}

@test "codex --transcript prints the rollout's terminal cumulative token_count" {
  run bash "$SPEND" --harness codex --transcript "$CODEX_FIXTURE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.basis' <<<"$output")" = "rollout" ]
  [ "$(jq -r '.input_tokens' <<<"$output")" = "900" ]
  [ "$(jq -r '.cache_read_input_tokens' <<<"$output")" = "200" ]
  [ "$(jq -r '.total_tokens' <<<"$output")" = "972" ]
}

@test "unsupported harness degrades to duration-only, exit 0" {
  run bash "$SPEND" --harness bogus --transcript "$CC_FIXTURE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.basis' <<<"$output")" = "duration-only" ]
  [ "$(jq -r 'keys | length' <<<"$output")" = "1" ]
}

@test "no binding degrades to duration-only, exit 0" {
  run bash "$SPEND" --harness claude-code
  [ "$status" -eq 0 ]
  [ "$(jq -r '.basis' <<<"$output")" = "duration-only" ]
}

@test "codex --session-id degrades to duration-only (no path derivation)" {
  run bash "$SPEND" --harness codex --session-id some-uuid
  [ "$status" -eq 0 ]
  [ "$(jq -r '.basis' <<<"$output")" = "duration-only" ]
}

@test "missing transcript degrades to duration-only, exit 0" {
  run bash "$SPEND" --harness claude-code --transcript /no/such/file.jsonl
  [ "$status" -eq 0 ]
  [ "$(jq -r '.basis' <<<"$output")" = "duration-only" ]
}
