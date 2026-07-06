#!/usr/bin/env bash
# session-spend.sh — Extract a session's token spend as a normalized JSON object.
#
# Usage:
#   session-spend.sh --harness <id> --transcript <path>
#   session-spend.sh --harness <id> --session-id <uuid> [--cwd <dir>]
#
# Options:
#   --harness <id>       Harness id (claude-code | opencode | codex). Required.
#   --transcript <path>  Explicit path to the session artifact (claude-code
#                        transcript / codex rollout). Takes precedence over
#                        --session-id.
#   --session-id <uuid>  Session id. For claude-code the transcript path is
#                        derived as ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl
#                        (needs --cwd); for opencode it keys the live sqlite
#                        store. codex rollout paths are date-nested and not
#                        addressable from a session id, so codex --session-id
#                        degrades to duration-only.
#   --cwd <dir>          Working directory, for claude-code transcript derivation.
#                        Defaults to $PWD.
#
# Front for the per-harness session_spend() extractors in
# adapters/transcripts/<fw>.py. It consults the spend_telemetry capability row,
# resolves the harness's session artifact, and prints the normalized spend JSON
# on stdout — or `{"basis":"duration-only"}` on any gap (unsupported harness,
# unresolvable binding, missing/unparseable artifact, or extractor failure).
# Always exits 0: the TUI shells out to this at session teardown and must never
# block or abort on a spend gap.
#
# This is a boundary-time extractor. It runs at the session boundary, when the
# artifact still exists, because the append-only telemetry it feeds outlives the
# transcripts it joins to — retrospective bulk mining of rotated transcripts is
# out of contract (see conventions/append-only-telemetry-logs-outlive-session-transcr).
# It prints JSON; it never writes the session journal (the sole writer,
# session-event-append.sh, appends the enriched row).
#
# Exit codes:
#   0  always (spend JSON or the duration-only object printed on stdout).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

HARNESS=""
TRANSCRIPT=""
SESSION_ID=""
CWD=""

emit_duration_only() {
  printf '%s\n' '{"basis":"duration-only"}'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="${2:-}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --cwd) CWD="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *)
      echo "session-spend: unknown argument: $1" >&2
      emit_duration_only
      ;;
  esac
done

[[ -n "$HARNESS" ]] || { echo "session-spend: --harness is required" >&2; emit_duration_only; }
command -v python3 &>/dev/null || { echo "session-spend: python3 not found; degrading" >&2; emit_duration_only; }

# --- Capability gate: only harnesses whose spend_telemetry row is non-`none`
#     have a working extractor. jq/caps failures degrade, never fail. ---
SUPPORT="$(framework_spend_telemetry_field support "$HARNESS" 2>/dev/null || echo unsupported)"
if [[ "$SUPPORT" == "none" || "$SUPPORT" == "unsupported" || -z "$SUPPORT" ]]; then
  emit_duration_only
fi

# --- Resolve the artifact binding to hand the provider ---
PROVIDER_ARG=""
if [[ -n "$TRANSCRIPT" ]]; then
  PROVIDER_ARG="$TRANSCRIPT"
elif [[ -n "$SESSION_ID" ]]; then
  case "$HARNESS" in
    claude-code)
      # Deterministic transcript path: the encoded-cwd directory replaces every
      # '/' in the cwd with '-' (mirrors extract-session-digest.py::find_project_dir).
      RESOLVED_CWD="${CWD:-$PWD}"
      ENCODED="${RESOLVED_CWD//\//-}"
      PROVIDER_ARG="$HOME/.claude/projects/$ENCODED/$SESSION_ID.jsonl"
      ;;
    opencode)
      # OpenCode spend lives in a store keyed by session id, not a file path.
      PROVIDER_ARG="$SESSION_ID"
      ;;
    codex)
      # Rollout paths are date-nested; a session id does not address one.
      emit_duration_only
      ;;
    *)
      emit_duration_only
      ;;
  esac
else
  # No binding supplied.
  emit_duration_only
fi

# --- Invoke the per-harness extractor; any failure prints duration-only ---
SPEND_JSON="$(PYTHONPATH="$LORE_REPO_DIR" python3 - "$HARNESS" "$PROVIDER_ARG" <<'PYEOF'
import json, sys
try:
    from adapters.transcripts import get_provider
    prov = get_provider(sys.argv[1])
    fn = getattr(prov, "session_spend", None)
    spend = fn(sys.argv[2]) if fn is not None else None
    if not isinstance(spend, dict):
        spend = {"basis": "duration-only"}
    print(json.dumps(spend))
except Exception:
    print(json.dumps({"basis": "duration-only"}))
PYEOF
)"

if [[ -z "$SPEND_JSON" ]]; then
  emit_duration_only
fi
printf '%s\n' "$SPEND_JSON"
exit 0
