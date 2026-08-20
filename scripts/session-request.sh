#!/usr/bin/env bash
# session-request.sh — Enqueue a session spawn request into _sessions/requests/pending/
#
# Usage:
#   lore session request --type <spec|implement|chat|worker> \
#     (--target <i> | --prefer-dir <p> | --prefer-cwd | --anywhere) [options]
#
# Options:
#   --type <t>         Required. Session type: spec | implement | chat | worker.
#   --slug <s>         Work-item slug the request targets. An unscoped chat gets
#                      a durable chat-<request-suffix> session slug automatically.
#                      REQUIRED for --type worker, and its shape is checked:
#                      a worker's slug is the derived <work-item-slug>--w<n> that is
#                      its session identity, and the suffix is what the journal,
#                      scoped watches, and the TUI parse to find the work item.
#   --target <name>    Placement stance: address the request to one instance (the
#                      named live instance alone may claim). A missing/stale
#                      registry row is refused; re-pin or use --anywhere rather
#                      than parking a request at a dead target. Every request MUST carry
#                      exactly one placement stance — --target, --prefer-dir,
#                      --prefer-cwd, or --anywhere; a stanceless request is refused.
#   --initiator <i>    Who initiated the request: agent | human (default: human).
#   --auto-close <b>   Override the TUI exit-ladder auto-close gate: true | false.
#                      Omitted (default) defers to --initiator (agent auto-closes,
#                      human holds open); true forces auto-close, false holds open.
#   --requested-by <w> Who enqueued it (default: $LORE_SESSION_INSTANCE, else $USER).
#   --context <t|file> Task content handed to prompt composition — the brief alone,
#                      with no guidance floor of your own. Value is read from a file
#                      when it names one, else treated as literal text. A JSON object
#                      is stored verbatim as extra_context; any other text is wrapped
#                      as {"dispatch_guidance": <text>}. For --type worker this verb
#                      renders the canonical guidance block itself and prepends it to
#                      the brief, so nothing upstream has to remember to.
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
#   --worktree-identity <json|file>
#                      Versioned session-worktree identity to carry unchanged to
#                      the claiming TUI. A file is read when the value names one;
#                      otherwise the value is parsed as JSON. When omitted for a
#                      fresh request, the claiming TUI allocates and captures a
#                      session-owned worktree before reaching the launch boundary.
#   --worktree-id <id>  Manager-owned coordination worktree identifier, carried
#                      through to the claiming TUI unchanged. The allocation verb
#                      (`lore coordinate worktree`) owns the registry and hands
#                      back a verified tuple; this verb transports it, and the
#                      claiming TUI re-checks guard identity before spawn.
#   --execution-dir <p> Manager-resolved child working directory. This is hard
#                      placement, unlike the claim-timing-only --prefer-dir.
#   --prefer-dir <p>   Soft project-dir preference stored as prefer_project_dir: an
#                      instance whose project dir matches claims immediately; any
#                      other defers ~15s before it may claim. Resolved physically at
#                      write time (refused when it names no existing directory).
#                      Mutually exclusive with --prefer-cwd. Pair with --min-vintage
#                      when an old claiming TUI must not ignore this additive field.
#   --prefer-cwd       Like --prefer-dir but names the checkout the calling session
#                      was carved from — the common "route to my own checkout" case.
#                      Inside a session that is the source checkout recorded on the
#                      instance registry row, NOT $PWD: a session's working directory
#                      is a detached worktree under the knowledge store, which is no
#                      instance's project directory and so can never match one.
#                      Outside a session it is $PWD. Refused when a session cannot
#                      name its own checkout. Mutually exclusive with --prefer-dir.
#   --anywhere         Placement stance: any live instance may claim immediately.
#                      Writes no queue field — the explicit form of what an
#                      unstated placement used to mean, made deliberate.
#   --yes              Run autonomously: skip the session's confirmation gates
#                      (alias --no-confirm). This is the default for queue-spawned
#                      sessions, so omitting all three leaves it on.
#   --confirm          Run gated: keep every confirmation gate (each becomes a
#                      coordinator send window). Sets skip_confirm=false.
#   --kdir <path>      Knowledge-store override (test isolation).
#   --json             Emit a JSON result object instead of a human line.
#
# Derived placement (no flag): a request naming a work-item slug takes its hard
# placement from that item's declared source checkout, resolved physically here and
# stored as required_project_dir — only an instance whose project directory equals
# it may claim, however long the row waits. A slug naming no tracked work item
# derives nothing. Three refusals, each with its own repair:
#   the item declares nothing        -> run `lore work source-checkout <slug>`
#   the declaration names no dir     -> re-declare it from the right checkout
#   no live instance serves that dir -> start or re-point an instance there
#
# placement_stance records which axis actually governs and is always written, with
# the strongest axis in force winning (required_dir > targeted > preferred_dir):
#   required_dir   the work item's declaration governs (hard directory filter)
#   targeted       --target governs (hard instance filter)
#   preferred_dir  --prefer-dir/--prefer-cwd governs (claim-timing only)
#   any            nothing constrains placement
# A row without the token was written before the field existed and keeps the older,
# filterless semantics: an absent token is never a stance.
#
# required_target_ref carries the branch the dispatching session's worktree was
# created against, when there is a session to read it from. It never selects a
# checkout: the claiming side compares it against what the source clone actually
# has checked out and refuses on contradiction, before creating anything on disk.
#
# Prepare-and-return: writes one request file tmp+rename into requests/pending/ and
# emits a `requested` journal event through session-event-append.sh, then exits. It
# never spawns, waits, or touches the TUI. Field validation happens here at write
# time (non-zero exit naming the offending field); readers never re-validate. The
# `requested` event carries the whole placement stance — the token, both directory
# fields, the vintage floor, the requester, and whether an identity was pre-declared
# — because every terminal path deletes the pending row, leaving the journal as the
# only durable record of what was asked for.
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
WORKTREE_IDENTITY=""
WORKTREE_IDENTITY_PROVIDED=0
WORKTREE_ID=""
WORKTREE_ID_PROVIDED=0
EXECUTION_DIR=""
PREFER_DIR=""
PREFER_DIR_PROVIDED=0
PREFER_CWD_PROVIDED=0
ANYWHERE_PROVIDED=0
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
    --worktree-identity) WORKTREE_IDENTITY="$2"; WORKTREE_IDENTITY_PROVIDED=1; shift 2 ;;
    --worktree-id) WORKTREE_ID="$2"; WORKTREE_ID_PROVIDED=1; shift 2 ;;
    --execution-dir) EXECUTION_DIR="$2"; shift 2 ;;
    --prefer-dir) PREFER_DIR="$2"; PREFER_DIR_PROVIDED=1; shift 2 ;;
    --prefer-cwd) PREFER_CWD_PROVIDED=1; shift ;;
    --anywhere) ANYWHERE_PROVIDED=1; shift ;;
    --yes|--no-confirm) SKIP_CONFIRM="true"; shift ;;
    --confirm) SKIP_CONFIRM="false"; shift ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,129p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-request.sh --type <spec|implement|chat|worker> (--target <name> | --prefer-dir <path> | --prefer-cwd | --anywhere) [--slug <s>] [--initiator <agent|human>] [--auto-close <true|false>] [--requested-by <who>] [--context <text|file>] [--route <role=model>]... [--min-vintage <ts|commit-ish>] [--track <short|full>] [--model <id>] [--framework <claude-code|codex|opencode>] [--worktree-identity <json|file>] [--worktree-id <id> --execution-dir <path>] [--yes|--no-confirm|--confirm] [--kdir <path>] [--json]" >&2
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

# The checkout the calling session belongs to, for --prefer-cwd. A session's
# working directory is a detached worktree under the knowledge store, which is no
# instance's project directory, so $PWD is only the right answer outside a session.
# The registry row records the source checkout the worktree was carved from; a
# session with no slug (a human-opened chat) still resolves through its instance's
# own project directory. Exit 1 = not inside a session, 2 = no registry row for
# this instance, 3 = the row names no checkout.
session_source_checkout() {
  local instance="${LORE_SESSION_INSTANCE:-}"
  local slug="${LORE_SESSION_SLUG:-}"
  local stype="${LORE_SESSION_TYPE:-}"
  local registry checkout=""
  [[ -n "$instance" ]] || return 1
  registry="$KNOWLEDGE_DIR/_sessions/instances/$instance.json"
  [[ -f "$registry" ]] || return 2
  if [[ -n "$slug" && -n "$stype" ]]; then
    checkout="$(jq -r --arg s "$slug" --arg t "$stype" \
      '[.sessions[]? | select(.slug == $s and .type == $t)
        | .worktree.captured.canonical_path // empty] | .[0] // ""' "$registry" 2>/dev/null || true)"
  fi
  [[ -n "$checkout" ]] || checkout="$(jq -r '.project_dir // empty' "$registry" 2>/dev/null || true)"
  [[ -n "$checkout" ]] || return 3
  printf '%s\n' "$checkout"
}

# The branch the calling session's worktree was created against. This never
# selects a checkout — it travels to the claiming side, which compares it against
# what the source clone actually has checked out and refuses on contradiction — so
# an unidentifiable session yields nothing rather than a refusal.
session_source_target_ref() {
  local instance="${LORE_SESSION_INSTANCE:-}"
  local slug="${LORE_SESSION_SLUG:-}"
  local stype="${LORE_SESSION_TYPE:-}"
  local registry
  [[ -n "$instance" && -n "$slug" && -n "$stype" ]] || return 0
  registry="$KNOWLEDGE_DIR/_sessions/instances/$instance.json"
  [[ -f "$registry" ]] || return 0
  jq -r --arg s "$slug" --arg t "$stype" \
    '[.sessions[]? | select(.slug == $s and .type == $t)
      | .worktree.target_ref // empty] | .[0] // ""' "$registry" 2>/dev/null || true
}

# --- Validate required fields at write time (sole-writer discipline) ---
case "$TYPE" in
  spec|implement|chat|worker) ;;
  "") fail "missing required field: --type (one of spec, implement, chat, worker)" ;;
  *) fail "invalid --type: '$TYPE' (must be one of spec, implement, chat, worker)" ;;
esac

# A worker session's slug is its identity — the derived <work-item-slug>--w<n>
# the claiming TUI keys panels, tmux names, and journal rows on. Unlike spec (which
# may run with no work item and thus a null slug), a worker with no slug has no
# session identity, so require one at enqueue. Unscoped chat identity is minted
# after REQUEST_ID is known below; worker derivation remains caller-owned.
if [[ "$TYPE" == "worker" && -z "$SLUG" ]]; then
  fail "--slug is required for --type worker (the derived slug is the session identity)"
fi

# The `--w<n>` suffix is not decoration: three sole-writer consumers parse it and
# each degrades silently when it is absent. session-event-append.sh derives
# links.work_item from this shape, so a mis-shaped worker slug leaves every
# lifecycle row of that session unattributed — and the scope predicate in lib.sh
# matches worker rows only through links.work_item, so a watch scoped to the item
# never sees the worker at all. The TUI groups workers under their base item from
# the same parse. None of those failures announce themselves.
#
# A refusal rather than a warning: the value is fully determined at enqueue, and
# the cost of getting it wrong is invisible downstream loss.
#
# The base must be a slugify() output, which collapses every `--` run to a single
# `-`; that is what makes the suffix an unambiguous marker rather than a guess.
if [[ "$TYPE" == "worker" ]] && ! [[ "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*--w[0-9]+$ ]]; then
  fail "invalid --slug for --type worker: '$SLUG' (expected the derived <work-item-slug>--w<n> form, e.g. my-work-item--w1).
  The '--w<n>' suffix is how the journal stamps links.work_item, how a scoped watch
  finds this session's rows, and how the TUI groups it under its work item. A slug
  without it enqueues cleanly and then goes missing from all three, with no error.
  Pass the work item's own slug with the worker number appended."
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

# Managed placement is a tuple the allocation verb produced and this verb
# transports. `lore coordinate worktree` owns the registry, validates the tuple
# it hands back, and the claiming TUI re-checks guard identity immediately
# before spawn — so re-deriving those conditions here was a second check on a
# value nobody else had touched in between. The only thing done to the identity
# is the parse the row emit needs: read it from a file when the value names one,
# otherwise from the literal. The field stays omit-when-empty; an omitted
# identity is allocated by the claiming TUI before launch.
WORKTREE_IDENTITY_JSON=""
if [[ $WORKTREE_IDENTITY_PROVIDED -eq 1 ]]; then
  [[ -n "$WORKTREE_IDENTITY" ]] || fail "empty --worktree-identity (an identity JSON object or file is required)"
  if [[ -f "$WORKTREE_IDENTITY" ]]; then
    WORKTREE_IDENTITY_JSON="$(jq -c '.' "$WORKTREE_IDENTITY" 2>/dev/null)" || fail "invalid --worktree-identity file: '$WORKTREE_IDENTITY' (expected JSON)"
  else
    WORKTREE_IDENTITY_JSON="$(printf '%s' "$WORKTREE_IDENTITY" | jq -c '.' 2>/dev/null)" || fail "invalid --worktree-identity (expected a JSON object or readable file)"
  fi
fi

# prefer_project_dir is a soft routing preference: a matching instance claims
# immediately, a non-matching one defers a grace window before it may claim (the
# read-side timing lives in the claiming TUI; nothing here is a hard filter). The
# value is resolved physically at write time — cd + pwd -P collapses symlinks
# (macOS /tmp → /private/tmp, worktree links) so the byte-equality match the
# reader performs holds from both bash and Go. An unresolvable path is refused
# naming the field; the reader never re-validates. --prefer-dir and --prefer-cwd
# name the same field and are mutually exclusive.
# Placement stance is a required declaration: every request states where it may
# run — --target (hard pin), --prefer-dir/--prefer-cwd (soft preference), or
# --anywhere (the deliberate opt-out). --anywhere satisfies this check and writes
# NO queue field: the row is byte-identical to the old untargeted form, so old
# claiming TUIs are unaffected. Why an error and not a default: the soft-preference
# mechanism shipped 2026-07-13, yet 0 of 110 historical claims carried
# prefer_project_dir — placement was silently unstated, and a missing declaration
# must be an error, never a routed-to-anywhere default.
if [[ $ANYWHERE_PROVIDED -eq 1 ]] && [[ -n "$TARGET" || $PREFER_DIR_PROVIDED -eq 1 || $PREFER_CWD_PROVIDED -eq 1 ]]; then
  fail "--anywhere contradicts an explicit placement (--target, --prefer-dir, or --prefer-cwd); pass exactly one stance"
fi
if [[ $ANYWHERE_PROVIDED -eq 0 && -z "$TARGET" && $PREFER_DIR_PROVIDED -eq 0 && $PREFER_CWD_PROVIDED -eq 0 ]]; then
  fail "missing placement stance: pass exactly one of --target <instance>, --prefer-dir <path>, --prefer-cwd, or --anywhere"
fi

PREFER_PROJECT_DIR_JSON=""
PREFER_RESOLVED=""
if [[ $PREFER_DIR_PROVIDED -eq 1 && $PREFER_CWD_PROVIDED -eq 1 ]]; then
  fail "--prefer-dir and --prefer-cwd are mutually exclusive (both set prefer_project_dir)"
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

# Worker-session enqueue is an actual launch boundary: the claiming TUI runs the
# brief verbatim as the session's whole prompt, so the standing-defaults floor has
# to be inside it. Render it here rather than instructing every caller to prepend
# it — this is the last step before the row is durable, which is the latest moment
# at which "invocation-fresh" is still true, and a floor nobody has to remember
# cannot be forgotten. A brief that already carries a block is left as composed:
# one floor per prompt, whoever rendered it.
#
# Worker-scoped on purpose. For spec/implement/chat the claiming TUI splices
# extra_context into a slash-command argument (`/spec <slug> -- <ctx>`), where a
# multi-line block does not belong; those launches meet the floor through the
# harness's own admission gate instead.
if [[ "$TYPE" == "worker" ]]; then
  [[ "$EXTRA_JSON" != "null" ]] || \
    fail "--context is required for --type worker (the composed brief is the session's whole prompt)"
  WORKER_PROMPT="$(printf '%s' "$EXTRA_JSON" | jq -r '.dispatch_guidance // empty')"
  [[ -n "$WORKER_PROMPT" ]] || \
    fail "worker --context must provide a non-empty dispatch_guidance string"
  if [[ "$WORKER_PROMPT" != *"lore-dispatch-guidance:v1:"* ]]; then
    # shellcheck disable=SC2119
    GUIDANCE_BLOCK="$(render_dispatch_guidance)" || \
      fail "could not render the canonical dispatch-guidance block; nothing was enqueued"
    EXTRA_JSON="$(printf '%s' "$EXTRA_JSON" \
      | jq -c --arg block "$GUIDANCE_BLOCK" --arg brief "$WORKER_PROMPT" \
        '. + {dispatch_guidance: ($block + "\n" + $brief)}')"
  fi
fi

# Nullable target becomes explicit JSON null when unset. Slug is resolved after
# REQUEST_ID is minted below because unscoped chats derive their identity from it.
TARGET_JSON="null"
[[ -n "$TARGET" ]] && TARGET_JSON="$(jq -n --arg t "$TARGET" '$t')"

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

INSTANCES_DIR="$KNOWLEDGE_DIR/_sessions/instances"

# --prefer-cwd reads the instance registry to find the calling session's checkout,
# so the preference cannot resolve until the knowledge directory is known.
if [[ $PREFER_CWD_PROVIDED -eq 1 ]]; then
  if PREFER_CWD_SOURCE="$(session_source_checkout)"; then
    PREFER_DIR="$PREFER_CWD_SOURCE"
  else
    case $? in
      1) PREFER_DIR="$PWD" ;;
      2) fail "refusing --prefer-cwd: no registry row for session instance '${LORE_SESSION_INSTANCE:-}'.
This session cannot name its own checkout, and its working directory is a session
worktree that matches no instance. Pass --prefer-dir <checkout>, or --anywhere." ;;
      *) fail "refusing --prefer-cwd: the registry row for '${LORE_SESSION_INSTANCE:-}' records
no source checkout for this session. Pass --prefer-dir <checkout>, or --anywhere." ;;
    esac
  fi
  PREFER_DIR_PROVIDED=1
fi
if [[ $PREFER_DIR_PROVIDED -eq 1 ]]; then
  [[ -n "$PREFER_DIR" ]] || fail "empty --prefer-dir (a directory path is required when --prefer-dir is given)"
  PREFER_RESOLVED="$(resolve_physical_dir "$PREFER_DIR" || true)"
  [[ -n "$PREFER_RESOLVED" ]] || fail "invalid --prefer-dir: '$PREFER_DIR' (prefer_project_dir must resolve to an existing directory)"
  PREFER_PROJECT_DIR_JSON="$(jq -n --arg d "$PREFER_RESOLVED" '$d')"
fi

# A hard target is useful only while its registry row is live. Reuse the pin
# preflight's shared mtime-TTL rule: silently rewriting this to --anywhere would
# change placement stance, while accepting it would create a request no live
# instance can claim. Soft/anywhere stances remain deliberately untouched.
if [[ -n "$TARGET" ]]; then
  if ! TARGET_AGE="$(session_instance_age_seconds "$INSTANCES_DIR" "$TARGET")"; then
    fail "refusing --target '$TARGET': its registry row is absent (age unavailable; live window ${SESSION_INSTANCE_LIVENESS_TTL_SECONDS}s).
Re-pin the project to a live instance and retry, or choose --anywhere explicitly."
  fi
  if (( TARGET_AGE > SESSION_INSTANCE_LIVENESS_TTL_SECONDS )); then
    fail "refusing --target '$TARGET': its registry row is ${TARGET_AGE}s old (live window ${SESSION_INSTANCE_LIVENESS_TTL_SECONDS}s).
Re-pin the project to a live instance and retry, or choose --anywhere explicitly."
  fi
fi

# --- Derive hard placement from the work item's declared source checkout ---
# Placement is not a flag here: a request that names a work item takes its checkout
# from the item, and each of the three ways that can fail gets its own repair. A
# slug naming no tracked work item derives nothing — an unscoped chat and an ad-hoc
# slug have no declaration to read.
REQUIRED_PROJECT_DIR_JSON=""
REQUIRED_RESOLVED=""
WORK_META=""
WORK_ITEM_SLUG=""
if [[ -n "$SLUG" ]]; then
  # A worker's slug is <work-item-slug>--w<n>; the declaration lives on the item.
  WORK_ITEM_SLUG="$SLUG"
  if [[ "$WORK_ITEM_SLUG" =~ ^(.+)--w[0-9]+$ ]]; then
    WORK_ITEM_SLUG="${BASH_REMATCH[1]}"
  fi
  for candidate in "$KNOWLEDGE_DIR/_work/$WORK_ITEM_SLUG/_meta.json" \
                   "$KNOWLEDGE_DIR/_work/_archive/$WORK_ITEM_SLUG/_meta.json"; do
    if [[ -f "$candidate" ]]; then
      WORK_META="$candidate"
      break
    fi
  done
fi

if [[ -n "$WORK_META" ]]; then
  DECLARED_CHECKOUT="$(jq -r '.source_checkout // empty' "$WORK_META" 2>/dev/null || true)"
  if [[ -z "$DECLARED_CHECKOUT" ]]; then
    fail "refusing --slug '$SLUG': work item '$WORK_ITEM_SLUG' declares no source checkout, so
this request cannot say which clone it belongs in. Seed the declaration with:
  lore work source-checkout $WORK_ITEM_SLUG
Run that from a session hosted by an instance in the checkout this work belongs to."
  fi
  REQUIRED_RESOLVED="$(resolve_physical_dir "$DECLARED_CHECKOUT" || true)"
  if [[ -z "$REQUIRED_RESOLVED" ]]; then
    fail "refusing --slug '$SLUG': work item '$WORK_ITEM_SLUG' declares source checkout
'$DECLARED_CHECKOUT', which is not an existing directory. The clone was moved or
removed. Re-declare it with:
  lore work source-checkout $WORK_ITEM_SLUG"
  fi

  # An unsatisfiable hard filter has to be refused here, before the row is durable.
  # Each instance's claim loop can only decline for itself and nothing aggregates
  # "every instance declined", so a row no instance can claim is never reported as
  # unclaimable — it waits out the request TTL, and the sweep that enforces that TTL
  # is TUI-hosted, so a store with no live instance never runs one. A pinned target
  # narrows the check to that instance, since nothing else could claim the row.
  LIVE_DIRS="$(live_instance_project_dirs "$INSTANCES_DIR" || true)"
  SERVED=0
  LIVE_CHECKOUTS=""
  while IFS= read -r live_dir; do
    [[ -n "$live_dir" ]] || continue
    LIVE_CHECKOUTS="${LIVE_CHECKOUTS}  $live_dir
"
    [[ "$live_dir" == "$REQUIRED_RESOLVED" ]] && SERVED=1
  done <<< "$LIVE_DIRS"
  [[ -n "$LIVE_CHECKOUTS" ]] || LIVE_CHECKOUTS="  (no live instance publishes a project directory in this store)
"

  if [[ -n "$TARGET" ]]; then
    TARGET_DIR="$(jq -r '.project_dir // empty' "$INSTANCES_DIR/$TARGET.json" 2>/dev/null || true)"
    TARGET_RESOLVED=""
    [[ -n "$TARGET_DIR" ]] && TARGET_RESOLVED="$(resolve_physical_dir "$TARGET_DIR" || printf '%s' "$TARGET_DIR")"
    if [[ "$TARGET_RESOLVED" != "$REQUIRED_RESOLVED" ]]; then
      fail "refusing --target '$TARGET' for --slug '$SLUG': work item '$WORK_ITEM_SLUG' belongs to
'$REQUIRED_RESOLVED', which that instance does not serve. Live checkouts:
${LIVE_CHECKOUTS}Target an instance in that checkout, or drop --target and let the
declaration place the request."
    fi
  elif [[ $SERVED -eq 0 ]]; then
    fail "refusing --slug '$SLUG': work item '$WORK_ITEM_SLUG' belongs to '$REQUIRED_RESOLVED',
and no live instance serves that checkout. Live checkouts:
${LIVE_CHECKOUTS}Start an instance in that checkout, or re-declare the item with:
  lore work source-checkout $WORK_ITEM_SLUG"
  fi

  REQUIRED_PROJECT_DIR_JSON="$(jq -n --arg d "$REQUIRED_RESOLVED" '$d')"
fi

# placement_stance names the axis that actually governs, so no reader has to infer
# a stance from which fields happen to be absent. The declaration outranks the
# caller's flags: it is the narrowest hard filter and it is derived rather than
# passed, so --anywhere means "I add no placement of my own", not "ignore the
# item's".
if [[ -n "$REQUIRED_PROJECT_DIR_JSON" ]]; then
  PLACEMENT_STANCE="required_dir"
elif [[ -n "$TARGET" ]]; then
  PLACEMENT_STANCE="targeted"
elif [[ $PREFER_DIR_PROVIDED -eq 1 ]]; then
  PLACEMENT_STANCE="preferred_dir"
else
  PLACEMENT_STANCE="any"
fi
# The claim side gates the hard filter on the token being present, so a token
# outside the closed set would let a declaring row through unfiltered. No shared
# enum helper exists; the set is checked here, where it is written.
case "$PLACEMENT_STANCE" in
  required_dir|targeted|preferred_dir|any) ;;
  *) fail "internal error: placement_stance '$PLACEMENT_STANCE' is outside the closed set (required_dir, targeted, preferred_dir, any)" ;;
esac

# The declared branch is verification-only: it travels to the claiming side, which
# compares it against what the source clone has checked out. It is read from the
# dispatching session and is absent when there is no session to read.
REQUIRED_TARGET_REF="$(session_source_target_ref)"

PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
mkdir -p "$PENDING_DIR"

RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REQUEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
REQUESTED_AT="$(timestamp_iso)"

# An unscoped chat still needs a durable session identity: every live-session
# verb, registry join, and scoped journal reader addresses by slug. The request
# id is already the spawn's durable identity, and its random suffix is compact,
# deterministic, and stable across claim retries. Explicit chat slugs (for chats
# attached to a work item/follow-up) stay byte-identical.
if [[ "$TYPE" == "chat" && -z "$SLUG" ]]; then
  SLUG="chat-${REQUEST_ID##*-}"
fi
SLUG_JSON="null"
[[ -n "$SLUG" ]] && SLUG_JSON="$(jq -n --arg s "$SLUG" '$s')"

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

# worktree_identity follows omit-when-empty for rolling schema compatibility.
# When present, preserve the whole versioned identity object byte-for-byte in
# meaning; intermediate request projections must not reconstruct a partial row.
if [[ -n "$WORKTREE_IDENTITY_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson wi "$WORKTREE_IDENTITY_JSON" '. + {worktree_identity: $wi}')"
fi

# worktree_id/execution_dir are hard placement and therefore travel together.
# prefer_project_dir remains a separate, soft claim-timing hint.
if [[ $WORKTREE_ID_PROVIDED -eq 1 ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --arg id "$WORKTREE_ID" --arg dir "$EXECUTION_DIR" '. + {worktree_id: $id, execution_dir: $dir}')"
fi

# prefer_project_dir follows omit-when-empty: added only when --prefer-dir or
# --prefer-cwd carried a resolved value, so an absent preference stays absent (the
# Go decoder reads a nil *string → every instance is immediately eligible).
if [[ -n "$PREFER_PROJECT_DIR_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson pd "$PREFER_PROJECT_DIR_JSON" '. + {prefer_project_dir: $pd}')"
fi

# required_project_dir is the hard directory filter derived from the work item: an
# instance whose project dir differs may never claim, however long the row waits.
# Omit-when-empty like every other placement field.
if [[ -n "$REQUIRED_PROJECT_DIR_JSON" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --argjson rd "$REQUIRED_PROJECT_DIR_JSON" '. + {required_project_dir: $rd}')"
fi

# placement_stance is always written, and its presence is what tells a reader the
# row came from a writer that knows about required_project_dir at all. Rows written
# before this field keep the older, filterless semantics, so the hard filter must
# turn on the token being present rather than on the directory being absent.
ROW="$(printf '%s' "$ROW" | jq -c --arg ps "$PLACEMENT_STANCE" '. + {placement_stance: $ps}')"

# required_target_ref is checked, never matched on: the claiming side compares it
# against the source checkout's actual branch inside worktree creation and refuses
# before anything is created on disk. Omit-when-empty.
if [[ -n "$REQUIRED_TARGET_REF" ]]; then
  ROW="$(printf '%s' "$ROW" | jq -c --arg tr "$REQUIRED_TARGET_REF" '. + {required_target_ref: $tr}')"
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
# Built after the durable pending row lands. The pending file is deleted on every
# terminal path, so this row is the only durable record of what was asked for — it
# therefore carries the whole placement stance, not just the fields that happened to
# be set. The stance token, the requester, and the identity-declared flag are always
# present so that no absence has to be read as a stance. target_instance/slug and
# the directory fields follow omit-when-empty; actor_instance is absent (an enqueue
# via the CLI is not a TUI).
IDENTITY_DECLARED_JSON=false
[[ $WORKTREE_IDENTITY_PROVIDED -eq 1 ]] && IDENTITY_DECLARED_JSON=true
EVENT_ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg session_type "$TYPE" \
  --arg initiator "$INITIATOR" \
  --arg requested_by "$REQUESTED_BY" \
  --arg placement_stance "$PLACEMENT_STANCE" \
  --argjson identity_declared "$IDENTITY_DECLARED_JSON" \
  --argjson slug "$SLUG_JSON" \
  --argjson target "$TARGET_JSON" \
  --arg worktree_id "$WORKTREE_ID" \
  --arg execution_dir "$EXECUTION_DIR" \
  --arg required_dir "$REQUIRED_RESOLVED" \
  --arg required_ref "$REQUIRED_TARGET_REF" \
  --arg prefer_dir "$PREFER_RESOLVED" \
  --arg min_vintage "${MIN_VINTAGE_RESOLVED:-}" \
  '{event: "requested", request_id: $request_id, session_type: $session_type, initiator: $initiator,
    requested_by: $requested_by, placement_stance: $placement_stance,
    worktree_identity_declared: $identity_declared}
   + (if $slug != null then {slug: $slug} else {} end)
   + (if $target != null then {target_instance: $target} else {} end)
   + (if $required_dir != "" then {required_project_dir: $required_dir} else {} end)
   + (if $required_ref != "" then {required_target_ref: $required_ref} else {} end)
   + (if $prefer_dir != "" then {prefer_project_dir: $prefer_dir} else {} end)
   + (if $min_vintage != "" then {min_vintage: $min_vintage} else {} end)
   + (if $worktree_id != "" then {worktree_id: $worktree_id, execution_dir: $execution_dir} else {} end)')"

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
    --arg worktree_id "$WORKTREE_ID" \
    --arg execution_dir "$EXECUTION_DIR" \
    --arg path "$RELPATH" \
    --arg placement_stance "$PLACEMENT_STANCE" \
    --arg required_dir "$REQUIRED_RESOLVED" \
    '{request_id: $request_id, type: $type, slug: $slug, target_instance: $target, path: $path,
      placement_stance: $placement_stance, enqueued: true}
     + (if $required_dir != "" then {required_project_dir: $required_dir} else {} end)
     + (if $worktree_id != "" then {worktree_id: $worktree_id, execution_dir: $execution_dir} else {} end)')"
  json_output "$RESULT"
fi

echo "[session] Enqueued $TYPE request $REQUEST_ID → $RELPATH"
