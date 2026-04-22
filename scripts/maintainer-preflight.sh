#!/usr/bin/env bash
# maintainer-preflight.sh — Safety backstop for maintainer mutation verbs
#
# Phase 9 safety net: when a maintainer invokes a verb that mutates shared
# templates (/evolve applying edits, retro aggregate producing a pooled
# output for downstream mutation), a failed `git push` at the end of the
# session is a silent footgun — the mutation committed locally, but the
# federation never sees it. This preflight runs up front to surface the
# push-path failure mode before any work happens.
#
# The check is intentionally light:
#   - resolve role via scripts/lib.sh:resolve_role
#   - if role != maintainer → exit 0 silently (not our concern)
#   - if role == maintainer → run `git push --dry-run origin HEAD` and surface
#     stderr verbatim when it fails; exit 0 regardless (warn, don't block)
#
# The operator may legitimately have a read-only remote (fork-based workflow,
# air-gapped review, etc.). Blocking would be presumptuous; warning is
# sufficient because the target audience knows the role implication.
#
# Session-idempotence: the caller (e.g., /evolve Step 1) passes
# `--session-marker <path>` pointing at a tmp file or session-scoped state
# location. If the marker exists, the preflight has already run this
# session and we short-circuit. If not, we run the check and touch the
# marker. This prevents the warning from replaying on every /evolve in
# the same session.
#
# Usage:
#   maintainer-preflight.sh [--session-marker <path>] [--repo-dir <path>] [--json]
#
# Exit codes:
#   0   role != maintainer, OR preflight ran (with or without warning)
#   1   usage error
#
# The caller distinguishes "warned" from "clean" by reading stdout/stderr or
# the JSON output; exit code is always 0 on successful preflight so that
# upstream scripts and skills do not block on this.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SESSION_MARKER=""
REPO_DIR=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
Usage: maintainer-preflight.sh [--session-marker <path>] [--repo-dir <path>] [--json]

Options:
  --session-marker <path>  Path to a file that, if present, short-circuits the
                           check. The script touches this file after running
                           the check so subsequent calls in the same session
                           are no-ops. Defaults to empty (always runs).
  --repo-dir <path>        Run git checks against this directory. Defaults to
                           the current working directory.
  --json                   Emit a single JSON object on stdout describing the
                           outcome. Default is bracketed human-readable text.

Outcome fields (JSON mode):
  {
    "ran": true|false,                // false when short-circuited
    "role": "maintainer" | "contributor",
    "short_circuit_reason": "marker-present" | null,
    "push_dry_run_ok": true|false|null,  // null when not run
    "warning": "<text>" | null
  }
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-marker)
      SESSION_MARKER="$2"
      shift 2
      ;;
    --repo-dir)
      REPO_DIR="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[preflight] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

REPO_DIR="${REPO_DIR:-$(pwd)}"

emit_json() {
  local ran="$1" role="$2" short_circuit="$3" push_ok="$4" warning="$5"
  RAN="$ran" ROLE="$role" SHORT_CIRCUIT="$short_circuit" \
    PUSH_OK="$push_ok" WARNING="$warning" python3 -c '
import json, os
def parse_bool(v):
    if v == "true": return True
    if v == "false": return False
    return None
out = {
    "ran": parse_bool(os.environ.get("RAN","false")),
    "role": os.environ.get("ROLE",""),
    "short_circuit_reason": os.environ.get("SHORT_CIRCUIT") or None,
    "push_dry_run_ok": parse_bool(os.environ.get("PUSH_OK","")),
    "warning": os.environ.get("WARNING") or None,
}
print(json.dumps(out, indent=2))
'
}

# --- Resolve role — bail early if not maintainer ---
ROLE=$(resolve_role)
if [[ "$ROLE" != "maintainer" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    emit_json "false" "$ROLE" "" "" ""
  fi
  exit 0
fi

# --- Session short-circuit ---
if [[ -n "$SESSION_MARKER" && -f "$SESSION_MARKER" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    emit_json "false" "$ROLE" "marker-present" "" ""
  fi
  exit 0
fi

# --- Actual preflight: git push --dry-run origin HEAD ---
# Run in the specified repo dir. If not a git repo or no origin, emit a
# warning with a specific reason rather than pretending all is well.
WARNING=""
PUSH_OK="true"
if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  WARNING="not a git repository: $REPO_DIR"
  PUSH_OK="false"
elif ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
  WARNING="no 'origin' remote configured in $REPO_DIR — maintainer edits will commit locally but cannot be pushed for federation"
  PUSH_OK="false"
else
  # Run the dry-run push against origin HEAD. Capture stderr for the
  # warning body; suppress stdout (git -> stderr on dry-run is normal).
  PUSH_STDERR=$(git -C "$REPO_DIR" push --dry-run origin HEAD 2>&1 >/dev/null || true)
  PUSH_RC=$?
  if [[ $PUSH_RC -ne 0 ]] || echo "$PUSH_STDERR" | grep -qiE 'rejected|forbidden|permission|denied|unauthori[sz]ed|authentication failed|could not read|fatal:'; then
    # Trim to ~3 lines for signal density.
    TRIMMED=$(echo "$PUSH_STDERR" | head -n 3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    WARNING="origin 'push --dry-run' failed: ${TRIMMED:-unknown reason}"
    PUSH_OK="false"
  fi
fi

# --- Touch session marker (if provided) regardless of warn/clean ---
if [[ -n "$SESSION_MARKER" ]]; then
  mkdir -p "$(dirname "$SESSION_MARKER")" 2>/dev/null || true
  : > "$SESSION_MARKER" || true
fi

# --- Emit outcome ---
if [[ $JSON_MODE -eq 1 ]]; then
  emit_json "true" "$ROLE" "" "$PUSH_OK" "$WARNING"
else
  if [[ -n "$WARNING" ]]; then
    echo "[preflight] warning (role=maintainer): $WARNING" >&2
    echo "[preflight] Your /evolve or retro-aggregate edits will commit locally, but the federation will not pick them up until push succeeds." >&2
  else
    echo "[preflight] role=maintainer — origin push --dry-run OK" >&2
  fi
fi

exit 0
