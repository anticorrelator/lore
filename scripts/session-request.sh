#!/usr/bin/env bash
# session-request.sh — Enqueue a session spawn request into _sessions/requests/pending/
#
# Usage:
#   lore session request --type <spec|implement|chat|worker> [options]
#
# Options:
#   --type <t>         Required. Session type: spec | implement | chat | worker.
#   --slug <s>         Work-item slug the request targets (default: null / no work
#                      item). REQUIRED for --type worker: a worker's slug is the
#                      derived <work-item-slug>--w<n> that is its session identity.
#   --target <name>    Instance name to address the request to (default: null / any instance).
#   --initiator <i>    Who initiated the request: agent | human (default: human).
#   --auto-close <b>   Override the TUI exit-ladder auto-close gate: true | false.
#                      Omitted (default) defers to --initiator (agent auto-closes,
#                      human holds open); true forces auto-close, false holds open.
#   --requested-by <w> Who enqueued it (default: $LORE_SESSION_INSTANCE, else $USER).
#   --context <t|file> Dispatch guidance handed to prompt composition. Value is read
#                      from a file when it names one, else treated as literal text. A
#                      JSON object is stored verbatim as extra_context; any other text
#                      is wrapped as {"dispatch_guidance": <text>}.
#   --route role=model Per-dispatch routing override (repeatable). The claiming TUI
#                      exports it as LORE_MODEL_<ROLE> into the spawned session, riding
#                      the resolver's top-precedence env layer. role MUST be in the
#                      adapters/roles.json closed set (unknown roles are refused).
#   --min-vintage <v>  Minimum build vintage the claiming instance must meet: a
#                      request never targets an instance whose build is older. Value
#                      is an ISO-8601 UTC timestamp (2026-07-05T12:00:00Z) OR a git
#                      commit-ish resolved to its committer-date here at enqueue time.
#                      Filtered read-side like --target; an instance of unknown
#                      vintage is never rejected (additive degradation).
#   --track <t>        Spec depth selector: short | full. Valid ONLY with --type
#                      spec (rejected otherwise). `short` maps to the session's
#                      short-track (/spec short); `full` is the default and stores
#                      nothing (omit-when-empty).
#   --model <id>       Lead-model override for the session (the top-level agent is
#                      the session lead). Composed into the spawn as the harness's
#                      --model flag. The id is opaque — validated only for
#                      non-emptiness here, never against a model list (the candidate
#                      set is coordinator policy, not schema).
#   --framework <id>   Framework override for the spawned session: claude-code |
#                      codex | opencode. Validated against adapters/capabilities.json
#                      and stored only when present. Pair with --min-vintage when an
#                      old claiming TUI must not ignore this additive field.
#   --prefer-dir <p>   Soft project-dir preference stored as prefer_project_dir: an
#                      instance whose project dir matches claims immediately; any
#                      other defers ~15s before it may claim. Resolved physically at
#                      write time (refused when it names no existing directory).
#                      Mutually exclusive with --prefer-cwd. Pair with --min-vintage
#                      when an old claiming TUI must not ignore this additive field.
#   --prefer-cwd       Like --prefer-dir but captures the caller's $PWD — the common
#                      "route to my own checkout" case. Mutually exclusive with
#                      --prefer-dir.
#   --yes              Run autonomously: skip the session's confirmation gates
#                      (alias --no-confirm). This is the default for queue-spawned
#                      sessions, so omitting all three leaves it on.
#   --confirm          Run gated: keep every confirmation gate (each becomes a
#                      coordinator send window). Sets skip_confirm=false.
#   --kdir <path>      Knowledge-store override (test isolation).
#   --json             Emit a JSON result object instead of a human line.
#
# Prepare-and-return: writes one request file tmp+rename into requests/pending/ and
# emits a `requested` journal event through session-event-append.sh, then exits. It
# never spawns, waits, or touches the TUI. Field validation happens here at write
# time (non-zero exit naming the offending field); readers never re-validate.
#
# Exit codes: 0 success; 1 error/refused. Codes 2 and 3 are reserved (unused here)
# to keep the session verb family compatible with the composed-terminal-verb
# exit-code namespace. No child exit code is propagated verbatim.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TYPE=""
SLUG=""
TARGET=""
INITIATOR="human"
AUTO_CLOSE=""
REQUESTED_BY=""
CONTEXT=""
KDIR_OVERRIDE=""
JSON_MODE=0
ROUTE_SPECS=()
MIN_VINTAGE=""
TRACK=""
MODEL=""
MODEL_PROVIDED=0
FRAMEWORK=""
FRAMEWORK_PROVIDED=0
PREFER_DIR=""
PREFER_DIR_PROVIDED=0
PREFER_CWD_PROVIDED=0
SKIP_CONFIRM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --initiator) INITIATOR="$2"; shift 2 ;;
    --auto-close) AUTO_CLOSE="$2"; shift 2 ;;
    --requested-by) REQUESTED_BY="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --route) ROUTE_SPECS+=("$2"); shift 2 ;;
    --min-vintage) MIN_VINTAGE="$2"; shift 2 ;;
    --track) TRACK="$2"; shift 2 ;;
    --model) MODEL="$2"; MODEL_PROVIDED=1; shift 2 ;;
    --framework) FRAMEWORK="$2"; FRAMEWORK_PROVIDED=1; shift 2 ;;
    --prefer-dir) PREFER_DIR="$2"; PREFER_DIR_PROVIDED=1; shift 2 ;;
    --prefer-cwd) PREFER_CWD_PROVIDED=1; shift ;;
    --yes|--no-confirm) SKIP_CONFIRM="true"; shift ;;
    --confirm) SKIP_CONFIRM="false"; shift ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,66p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-request.sh --type <spec|implement|chat|worker> [--slug <s>] [--target <name>] [--initiator <agent|human>] [--auto-close <true|false>] [--requested-by <who>] [--context <text|file>] [--route <role=model>]... [--min-vintage <ts|commit-ish>] [--track <short|full>] [--model <id>] [--framework <claude-code|codex|opencode>] [--prefer-dir <path>|--prefer-cwd] [--yes|--no-confirm|--confirm] [--kdir <path>] [--json]" >&2
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

command -v jq &>/dev/null || fail "jq is required but not found on PATH"

# --- Validate required fields at write time (sole-writer discipline) ---
case "$TYPE" in
  spec|implement|chat|worker) ;;
  "") fail "missing required field: --type (one of spec, implement, chat, worker)" ;;
  *) fail "invalid --type: '$TYPE' (must be one of spec, implement, chat, worker)" ;;
esac

# A worker session's slug is its identity — the derived <work-item-slug>--w<n>
# the claiming TUI keys panels, tmux names, and journal rows on. Unlike spec/chat
# (which may run with no work item and thus a null slug), a worker with no slug
# has no session identity, so require one at enqueue.
if [[ "$TYPE" == "worker" && -z "$SLUG" ]]; then
  fail "--slug is required for --type worker (the derived slug is the session identity)"
fi

case "$INITIATOR" in
  agent|human) ;;
  *) fail "invalid --initiator: '$INITIATOR' (must be one of agent, human)" ;;
esac

# auto_close is a nullable bool: absent (omit-when-empty) defers to the initiator
# gate; true/false force the exit-ladder outcome. Emitted with --argjson so the
# Go decoder receives a real JSON boolean, never a quoted string.
case "$AUTO_CLOSE" in
  "") AUTO_CLOSE_JSON="" ;;
  true|false) AUTO_CLOSE_JSON="$AUTO_CLOSE" ;;
  *) fail "invalid --auto-close: '$AUTO_CLOSE' (must be true or false)" ;;
esac

# track selects spec depth and maps to the session's ShortMode, which only
# affects the /spec prompt — so --track is refused on a non-spec request at write
# time (a reader never re-checks). `short` is stored; `full` is the default and
# stays absent (omit-when-empty, so the stored field is present only when it
# changes behavior). Any other value is refused naming the field.
TRACK_JSON=""
case "$TRACK" in
  "") ;;
  short|full)
    [[ "$TYPE" == "spec" ]] || fail "--track is valid only for --type spec (got --type '$TYPE')"
    [[ "$TRACK" == "short" ]] && TRACK_JSON="$(jq -n --arg t "$TRACK" '$t')"
    ;;
  *) fail "invalid --track: '$TRACK' (must be short or full)" ;;
esac

# model is an opaque lead-model id: the only write-time check is non-emptiness
# when the flag is given (an explicit --model with no value is a mistake). The id
# is NOT validated against any list — the candidate set is coordinator policy, not
# schema. Absent stays absent (omit-when-empty).
if [[ $MODEL_PROVIDED -eq 1 && -z "$MODEL" ]]; then
  fail "empty --model (a lead-model id is required when --model is given)"
fi

# framework is an optional closed-set override for the claiming TUI's launch
# framework. Validate from the existing adapter capability registry at write time
# so stale/invalid request rows never enter the queue.
FRAMEWORK_JSON=""
if [[ $FRAMEWORK_PROVIDED -eq 1 ]]; then
  [[ -n "$FRAMEWORK" ]] || fail "empty --framework (a framework id is required when --framework is given)"
  CAPABILITIES_FILE="$LORE_LIB_DIR/../adapters/capabilities.json"
  [[ -f "$CAPABILITIES_FILE" ]] || fail "framework registry not found at: $CAPABILITIES_FILE (cannot validate --framework)"
  if ! jq -e --arg fw "$FRAMEWORK" '.frameworks | has($fw)' "$CAPABILITIES_FILE" >/dev/null 2>&1; then
    VALID_FRAMEWORKS="$(jq -r '.frameworks | keys | join(", ")' "$CAPABILITIES_FILE")"
    fail "invalid --framework: '$FRAMEWORK' (must be one of $VALID_FRAMEWORKS)"
  fi
  FRAMEWORK_JSON="$(jq -n --arg fw "$FRAMEWORK" '$fw')"
fi

# prefer_project_dir is a soft routing preference: a matching instance claims
# immediately, a non-matching one defers a grace window before it may claim (the
# read-side timing lives in the claiming TUI; nothing here is a hard filter). The
# value is resolved physically at write time — cd + pwd -P collapses symlinks
# (macOS /tmp → /private/tmp, worktree links) so the byte-equality match the
# reader performs holds from both bash and Go. An unresolvable path is refused
# naming the field; the reader never re-validates. --prefer-dir and --prefer-cwd
# name the same field and are mutually exclusive.
PREFER_PROJECT_DIR_JSON=""
if [[ $PREFER_DIR_PROVIDED -eq 1 && $PREFER_CWD_PROVIDED -eq 1 ]]; then
  fail "--prefer-dir and --prefer-cwd are mutually exclusive (both set prefer_project_dir)"
fi
if [[ $PREFER_CWD_PROVIDED -eq 1 ]]; then
  PREFER_DIR="$PWD"
  PREFER_DIR_PROVIDED=1
fi
if [[ $PREFER_DIR_PROVIDED -eq 1 ]]; then
  [[ -n "$PREFER_DIR" ]] || fail "empty --prefer-dir (a directory path is required when --prefer-dir is given)"
  PREFER_RESOLVED="$(cd "$PREFER_DIR" 2>/dev/null && pwd -P || true)"
  [[ -n "$PREFER_RESOLVED" ]] || fail "invalid --prefer-dir: '$PREFER_DIR' (prefer_project_dir must resolve to an existing directory)"
  PREFER_PROJECT_DIR_JSON="$(jq -n --arg d "$PREFER_RESOLVED" '$d')"
fi

# skip_confirm is a nullable bool: absent (omit-when-empty) defers to the
# queue-spawn default (autonomous — the historical always-skip behavior); true
# (--yes/--no-confirm) forces autonomous, false (--confirm) forces gated. Emitted
# with --argjson so the Go decoder reads a real JSON boolean.
SKIP_CONFIRM_JSON="$SKIP_CONFIRM"

# routing_overrides is a role→model object built from repeatable --route flags.
# Each role MUST be in the adapters/roles.json closed set — the same rejection
# the resolver applies (resolve_model_for_role), enforced here at write time so a
# reader never re-validates. The registry must exist to enforce the closed set:
# a missing one is a refusal, not a silent pass. Empty (no --route) stays absent
# (omit-when-empty), leaving every role to resolve against settings as before.
ROUTING_JSON=""
if [[ ${#ROUTE_SPECS[@]} -gt 0 ]]; then
  ROLES_FILE="$LORE_LIB_DIR/../adapters/roles.json"
  [[ -f "$ROLES_FILE" ]] || fail "role registry not found at: $ROLES_FILE (cannot validate --route roles)"
  ROUTING_JSON="{}"
  for spec in "${ROUTE_SPECS[@]}"; do
    [[ "$spec" == *=* ]] || fail "invalid --route: '$spec' (expected role=model)"
    route_role="${spec%%=*}"
    route_model="${spec#*=}"
    [[ -n "$route_role" ]] || fail "invalid --route: '$spec' (empty role)"
    [[ -n "$route_model" ]] || fail "invalid --route: '$spec' (empty model)"
    if ! jq -e --arg r "$route_role" '.roles[] | select(.id == $r)' "$ROLES_FILE" >/dev/null 2>&1; then
      fail "unknown role '$route_role' in --route (not in $ROLES_FILE)"
    fi
    ROUTING_JSON="$(printf '%s' "$ROUTING_JSON" | jq -c --arg r "$route_role" --arg m "$route_model" '. + {($r): $m}')"
  done
fi

# min_vintage is an optional minimum build vintage, stored as a comparable ISO
# timestamp so the read-side filter never shells out to git. An ISO-8601 UTC value
# is stored verbatim; anything else is resolved as a git commit-ish to its
# committer-date (UTC) against the lore source repo where these scripts live —
# one-time at enqueue, mirroring the other write-time resolutions here. An
# unresolvable value is refused (naming the field), never silently dropped.
MIN_VINTAGE_JSON=""
if [[ -n "$MIN_VINTAGE" ]]; then
  if [[ "$MIN_VINTAGE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    MIN_VINTAGE_RESOLVED="$MIN_VINTAGE"
  else
    MIN_VINTAGE_RESOLVED="$(TZ=UTC git -C "$SCRIPT_DIR" show -s \
      --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format='%cd' "$MIN_VINTAGE" 2>/dev/null || true)"
    [[ -n "$MIN_VINTAGE_RESOLVED" ]] || fail "invalid --min-vintage: '$MIN_VINTAGE' (expected an ISO-8601 UTC timestamp like 2026-07-05T12:00:00Z or a resolvable git commit-ish)"
  fi
  MIN_VINTAGE_JSON="$(jq -n --arg v "$MIN_VINTAGE_RESOLVED" '$v')"
fi

if [[ $FRAMEWORK_PROVIDED -eq 1 && -z "$MIN_VINTAGE" ]]; then
  echo "[session] advisory: --framework was provided without --min-vintage; old claiming TUIs may ignore the framework field" >&2
fi

if [[ -n "$PREFER_PROJECT_DIR_JSON" && -z "$MIN_VINTAGE" ]]; then
  echo "[session] advisory: --prefer-dir/--prefer-cwd was provided without --min-vintage; old claiming TUIs may ignore the prefer_project_dir field and claim immediately" >&2
fi

if [[ -z "$REQUESTED_BY" ]]; then
  REQUESTED_BY="${LORE_SESSION_INSTANCE:-${USER:-unknown}}"
fi

# --- Resolve extra_context (object verbatim, else wrapped guidance) ---
EXTRA_JSON="null"
if [[ -n "$CONTEXT" ]]; then
  CONTENT="$CONTEXT"
  if [[ -f "$CONTEXT" ]]; then
    CONTENT="$(cat "$CONTEXT")"
  fi
  if printf '%s' "$CONTENT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    EXTRA_JSON="$(printf '%s' "$CONTENT" | jq -c '.')"
  else
    EXTRA_JSON="$(jq -n --arg g "$CONTENT" '{dispatch_guidance: $g}')"
  fi
fi

# Nullable string fields become explicit JSON null when unset.
SLUG_JSON="null"
[[ -n "$SLUG" ]] && SLUG_JSON="$(jq -n --arg s "$SLUG" '$s')"
TARGET_JSON="null"
[[ -n "$TARGET" ]] && TARGET_JSON="$(jq -n --arg t "$TARGET" '$t')"

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
mkdir -p "$PENDING_DIR"

RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REQUEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
REQUESTED_AT="$(timestamp_iso)"

# attempts MUST be a JSON number (--argjson), never a quoted string, so the Go
# decoder accepts it (docs/session-substrate.md, Type discipline).
ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg type "$TYPE" \
  --argjson slug "$SLUG_JSON" \
  --argjson target "$TARGET_JSON" \
  --arg initiator "$INITIATOR" \
  --arg requested_by "$REQUESTED_BY" \
  --arg requested_at "$REQUESTED_AT" \
  --argjson attempts 0 \
  --argjson extra "$EXTRA_JSON" \
  '{request_id: $request_id, type: $type, slug: $slug, target_instance: $target, initiator: $initiator, requested_by: $requested_by, requested_at: $requested_at, attempts: $attempts, extra_context: $extra, last_error: null, last_attempt_at: null}')"

# auto_close follows omit-when-empty: added only when the flag forced a value,
# so an absent override stays absent (the Go decoder reads a nil *bool).
if [[ -n "$AUTO_CLOSE_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson ac "$AUTO_CLOSE_JSON" '. + {auto_close: $ac}')"
fi

# routing_overrides follows omit-when-empty: added only when --route was passed,
# so an absent map stays absent (the Go decoder reads a nil map).
if [[ -n "$ROUTING_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson ro "$ROUTING_JSON" '. + {routing_overrides: $ro}')"
fi

# min_vintage follows omit-when-empty: added only when --min-vintage was passed,
# so an absent requirement stays absent (the Go decoder reads a nil *string).
if [[ -n "$MIN_VINTAGE_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson mv "$MIN_VINTAGE_JSON" '. + {min_vintage: $mv}')"
fi

# track follows omit-when-empty: added only for the non-default `short` value, so
# a full-track (or absent) request stays absent (the Go decoder reads a nil
# *string → ShortMode false).
if [[ -n "$TRACK_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson tr "$TRACK_JSON" '. + {track: $tr}')"
fi

# model follows omit-when-empty: added only when --model carried a value, so an
# absent override stays absent (the Go decoder reads a nil *string).
if [[ -n "$MODEL" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --arg md "$MODEL" '. + {model: $md}')"
fi

# framework follows omit-when-empty: added only when --framework carried a value,
# so an absent override keeps the claiming TUI's launch-framework fallback.
if [[ -n "$FRAMEWORK_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson fw "$FRAMEWORK_JSON" '. + {framework: $fw}')"
fi

# prefer_project_dir follows omit-when-empty: added only when --prefer-dir or
# --prefer-cwd carried a resolved value, so an absent preference stays absent (the
# Go decoder reads a nil *string → every instance is immediately eligible).
if [[ -n "$PREFER_PROJECT_DIR_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson pd "$PREFER_PROJECT_DIR_JSON" '. + {prefer_project_dir: $pd}')"
fi

# skip_confirm follows omit-when-empty: added only when --yes/--no-confirm or
# --confirm forced a value, so an absent request stays absent (the Go decoder
# reads a nil *bool → the queue-spawn autonomy default). Emitted with --argjson so
# it lands as a real JSON boolean.
if [[ -n "$SKIP_CONFIRM_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson sc "$SKIP_CONFIRM_JSON" '. + {skip_confirm: $sc}')"
fi

# Enqueue = tmp-write + atomic rename-in. The tmp name is hidden and lacks the
# .json suffix, so a concurrent reader globbing *.json never sees a torn row.
TMP="$(mktemp "$PENDING_DIR/.tmp.${REQUEST_ID}.XXXXXX")"
printf '%s\n' "$ROW" > "$TMP"
DEST="$PENDING_DIR/${REQUEST_ID}.json"
mv "$TMP" "$DEST"

# --- Emit the `requested` event through the sole journal writer ---
# Built after the durable pending row lands. target_instance/slug follow
# omit-when-empty; actor_instance is absent (an enqueue via the CLI is not a TUI).
EVENT_ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg session_type "$TYPE" \
  --arg initiator "$INITIATOR" \
  --argjson slug "$SLUG_JSON" \
  --argjson target "$TARGET_JSON" \
  '{event: "requested", request_id: $request_id, session_type: $session_type, initiator: $initiator}
   + (if $slug != null then {slug: $slug} else {} end)
   + (if $target != null then {target_instance: $target} else {} end)')"

if ! printf '%s' "$EVENT_ROW" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
  # The pending row is durable (the source of truth for liveness); a lost
  # history row is tolerated by the journal contract. Surface, do not fail.
  echo "[session] warning: requested event append failed for $REQUEST_ID (pending row is durable)" >&2
fi

RELPATH="${DEST#"$KNOWLEDGE_DIR"/}"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT="$(jq -n \
    --arg request_id "$REQUEST_ID" \
    --arg type "$TYPE" \
    --argjson slug "$SLUG_JSON" \
    --argjson target "$TARGET_JSON" \
    --arg path "$RELPATH" \
    '{request_id: $request_id, type: $type, slug: $slug, target_instance: $target, path: $path, enqueued: true}')"
  json_output "$RESULT"
fi

echo "[session] Enqueued $TYPE request $REQUEST_ID → $RELPATH"
