#!/usr/bin/env bash
# arc-open.sh — open a coordination arc: create _work/_arcs/<slug>/, instantiate
# the ledger from the coordinate skill's template, and record the arc through
# arc-write-meta.sh.
#
# Usage: bash arc-open.sh --title <t> --anchor <a> [--project <p>] [--slug <s>]
#
# The slug is derived from the title. A slug that collides with an existing arc
# is refused, and so is one the length cap would clip — both name a slug nobody
# chose, in a substrate whose point is that names are findable. --slug is the
# way to choose one deliberately.
#
# Opening an arc also arms the standing eye, as the last thing it does. Arming
# by hand was friction nobody paid reliably: the watcher is what makes a park
# visible, and a coordinator who forgets it coordinates blind. The ledger is the
# moment the board starts mattering, so that is where the eye goes on.
#
# What that arming is, exactly: the same install and the same registry write
# `lore coordinate arm --install` performs, scoped to this arc — invoked through
# that verb rather than reimplemented, so its refusals (a dead owner handle, a
# harness that cannot host the hook) apply here too and the two surfaces cannot
# drift. `lore arc close` already switches off a watcher scoped solely to the
# closing arc, so open and close are symmetric without close changing at all.
#
# Nothing in the arming can fail the open. An arc is a record the coordinator
# asked for; watcher hygiene does not get a veto over it. Every outcome the
# block reports goes to stderr, clear of the --json contract on stdout, and
# every path that does not arm prints the command that would.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc open --title <title> --anchor <intent> [--project <name>] [--slug <slug>]

Opens a coordination arc as its own directory under _work/_arcs/, holding the
record, the ledger, and whatever documents the arc accumulates.

Opening an arc arms the standing board watcher as its final act, scoped to the
new arc, into the harness settings file. `lore arc close` switches it off again.
An eye that is already armed is left exactly as it is.

Options:
  --title <title>    What the arc is about. The slug is derived from it.
  --anchor <intent>  The intent statement, stored verbatim.
  --project <name>   Optional project label. Arcs are not contained by projects;
                     the label is there to filter and to display.
  --slug <slug>      Name the arc directly instead of deriving the name.
  --no-watcher       Open the arc without arming the standing eye. For a seat
                     that genuinely wants no watcher; `lore coordinate arm` can
                     arm one later.
  --owner-pid <pid>  The long-lived harness process that owns the seat, when arc
                     open cannot identify it from this process's ancestry.
  --owner-tmux <n>   tmux session name of the owner, as the same handle.
  --tmux-server <n>  tmux server socket for --owner-tmux (default: lore-tui).
  --json             Emit the new record as JSON.
  --kdir <path>      Override the resolved knowledge dir (testing).
  --help, -h         Show this help.
EOF
}

TITLE=""
ANCHOR=""
PROJECT=""; HAS_PROJECT=0
SLUG_OVERRIDE=""
JSON_MODE=0
KDIR_OVERRIDE=""
NO_WATCHER=0
OWNER_PID=""
OWNER_TMUX=""
TMUX_SERVER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 ;;
    --anchor) ANCHOR="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; HAS_PROJECT=1; shift 2 ;;
    --slug) SLUG_OVERRIDE="${2:-}"; shift 2 ;;
    --no-watcher) NO_WATCHER=1; shift ;;
    --owner-pid) OWNER_PID="${2:-}"; shift 2 ;;
    --owner-tmux) OWNER_TMUX="${2:-}"; shift 2 ;;
    --tmux-server) TMUX_SERVER="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown option '$1'"; fi
      echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "'$1' is unexpected — arc open takes no positional arguments"; fi
      echo "[arc] Error: '$1' is unexpected — arc open takes no positional arguments, the slug comes from --title" >&2
      usage
      exit 1 ;;
  esac
done

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[arc] Error: $1" >&2
  exit 1
}

[[ -n "$TITLE" ]] || fail "--title is required"
[[ -n "$ANCHOR" ]] || fail "--anchor is required"
if [[ $HAS_PROJECT -eq 1 && -z "$PROJECT" ]]; then
  fail "--project cannot be empty"
fi

if [[ -n "$SLUG_OVERRIDE" ]]; then
  SLUG="$SLUG_OVERRIDE"
  if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    fail "'$SLUG' is not a valid arc slug — use lowercase letters, digits, and hyphens"
  fi
else
  SLUG="$(slugify "$TITLE")"
  [[ -n "$SLUG" ]] || fail "no slug could be derived from '$TITLE' — pass --slug"
  # slugify clips at MAX_SLUG_LENGTH; recomputing without the cap is how a
  # clipped slug is told apart from one the title actually produced.
  UNCLIPPED="$(MAX_SLUG_LENGTH=500; slugify "$TITLE")"
  if [[ "$SLUG" != "$UNCLIPPED" ]]; then
    fail "the title clips to '$SLUG' — pass --slug with a name you have chosen"
  fi
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

ARCS_DIR="$KNOWLEDGE_DIR/_work/_arcs"
RECORD_DIR="$ARCS_DIR/$SLUG"

if [[ -e "$RECORD_DIR" ]]; then
  EXISTING_TITLE=""
  if [[ -f "$RECORD_DIR/_meta.json" ]]; then
    EXISTING_TITLE="$(json_field "title" "$RECORD_DIR/_meta.json")"
  fi
  fail "an arc named '$SLUG' already exists (${EXISTING_TITLE:-untitled}) — pick a more specific topic, or pass --slug to name this one yourself"
fi

TEMPLATE="$LORE_REPO_DIR/skills/coordinate/templates/coordination.md"
[[ -f "$TEMPLATE" ]] || fail "the coordination ledger template is missing at $TEMPLATE"

mkdir -p "$RECORD_DIR"
CREATED_DIR="$RECORD_DIR"

cleanup_on_failure() {
  if [[ -n "$CREATED_DIR" && -d "$CREATED_DIR" ]]; then
    rm -rf "$CREATED_DIR"
  fi
}

if ! ARC_TITLE="$TITLE" ARC_ANCHOR="$ANCHOR" python3 - "$TEMPLATE" "$RECORD_DIR/coordination.md" <<'PYEOF'
import os
import sys

template_path, dest_path = sys.argv[1], sys.argv[2]
title = os.environ["ARC_TITLE"]
anchor = os.environ["ARC_ANCHOR"]

with open(template_path) as handle:
    lines = handle.read().splitlines()

for index, line in enumerate(lines):
    if line.startswith("# Coordination Ledger"):
        lines[index] = "# Coordination Ledger — " + title
    elif line.startswith("**Feature under coordination:**"):
        lines[index] = "**Feature under coordination:** " + anchor

with open(dest_path, "w") as handle:
    handle.write("\n".join(lines) + "\n")
PYEOF
then
  cleanup_on_failure
  fail "the ledger could not be instantiated from $TEMPLATE"
fi

WRITE_ARGS=(--kdir "$KNOWLEDGE_DIR" --slug "$SLUG" --op open --title "$TITLE" --anchor "$ANCHOR")
if [[ $HAS_PROJECT -eq 1 ]]; then
  WRITE_ARGS+=(--project "$PROJECT")
fi

if ! ENVELOPE=$("$SCRIPT_DIR/arc-write-meta.sh" "${WRITE_ARGS[@]}"); then
  cleanup_on_failure
  exit 1
fi

RELATIVE_PATH="_work/_arcs/$SLUG"

# --- The standing eye goes on with the ledger ---------------------------------

eye() { echo "[arc] $1" >&2; }

# The harness process a seat runs as. The owner handle has to name something that
# outlives this command, and nothing in arc open's own ancestry qualifies until
# the harness itself: `lore` execs straight through to this script, so $PPID is
# the shell that ran it and dies when it returns — precisely the handle
# `coordinate arm` refuses. So the chain is walked by name until the harness
# turns up, and when it does not, the arc still opens and the arming is reported
# as the seat's to do.
harness_process_name() {
  case "$1" in
    claude-code) echo "claude" ;;
    codex) echo "codex" ;;
    opencode) echo "opencode" ;;
    *) return 1 ;;
  esac
}

owner_pid_from_ancestry() {
  local want="$1" pid="$PPID" depth=0 parent comm line
  [[ -n "$want" ]] || return 1
  command -v ps >/dev/null 2>&1 || return 1
  while [[ "$pid" -gt 1 && $depth -lt 12 ]]; do
    line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || return 1
    [[ -n "$line" ]] || return 1
    parent=""; comm=""
    read -r parent comm <<<"$line"
    [[ -n "$parent" ]] || return 1
    if [[ -n "$comm" && "$(basename "$comm")" == "$want" ]]; then
      printf '%s' "$pid"
      return 0
    fi
    pid="$parent"
    depth=$(( depth + 1 ))
  done
  return 1
}

owner_tmux_session() {
  [[ -n "${TMUX:-}" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  local session
  session="$(tmux display-message -p '#S' 2>/dev/null)" || return 1
  [[ -n "$session" ]] || return 1
  printf '%s' "$session"
}

owner_tmux_server() {
  local socket="${TMUX%%,*}"
  [[ -n "$socket" ]] || return 1
  printf '%s' "$(basename "$socket")"
}

# What the settings file and the registry jointly say is already armed:
#   none        no lore watcher entry in the settings file
#   armed<TAB>  an entry the registry also knows about, with its recorded scope
#   entry-only  an entry nobody recorded — somebody installed it by hand
# Both halves matter. An entry with no record is still a live eye, so arming over
# it would replace a scope this command did not choose; the settings file carries
# exactly one lore watcher, and the adapter replaces on that marker.
watcher_state() {
  local settings="$1"
  python3 - "$settings" "$KNOWLEDGE_DIR/_coordination/armed-watchers.json" <<'PYEOF' 2>/dev/null
import json, os, sys

settings_path, record_path = sys.argv[1], sys.argv[2]
try:
    with open(settings_path, encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    print("none")
    raise SystemExit(0)

armed = [
    h for e in (settings.get("hooks") or {}).get("Stop") or []
    for h in e.get("hooks") or []
    if "coordinate-arm.sh" in (h.get("command") or "")
]
if not armed:
    print("none")
    raise SystemExit(0)

key = os.path.realpath(os.path.expanduser(settings_path))
records = {}
try:
    with open(record_path, encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        records = loaded
except (OSError, ValueError):
    pass

rec = records.get(key)
if not isinstance(rec, dict):
    print("entry-only")
    raise SystemExit(0)

scopes = rec.get("scopes") or {}
tokens = ["arc:%s" % a for a in scopes.get("arcs") or []]
tokens += ["slug:%s" % s for s in scopes.get("slugs") or []]
print("armed\t%s" % (", ".join(tokens) or "the whole board"))
PYEOF
}

arm_standing_eye() {
  local framework support settings state scope want_proc handle=() manual

  framework="$(resolve_active_framework 2>/dev/null)" || framework=""
  if [[ -z "$framework" ]]; then
    eye "the standing eye was not armed: no active harness could be resolved. Arm it with 'lore coordinate arm' once the harness is known."
    return 0
  fi

  support="$(framework_capability turn_boundary_rewake "$framework" 2>/dev/null)" || support="none"
  settings="$(resolve_harness_install_path settings "$framework" 2>/dev/null)" || settings=""

  if [[ "$support" != "full" ]]; then
    eye "the standing eye is manual on $framework (turn_boundary_rewake: $support) — there is no turn-boundary hook to host it, so nothing was installed. Run the watcher from the seat, re-running it after each wake:"
    eye "         lore coordinate arm --arc $SLUG --render"
    return 0
  fi

  if [[ -z "$settings" || "$settings" == "unsupported" ]]; then
    eye "the standing eye was not armed: $framework exposes no settings file to install it into. Arm it by hand with 'lore coordinate arm --arc $SLUG --install <settings.json>'."
    return 0
  fi

  state="$(watcher_state "$settings")" || state=""
  case "${state%%$'\t'*}" in
    armed)
      scope="${state#*$'\t'}"
      eye "a standing eye is already armed in $settings (scope: $scope) — left exactly as it is."
      if [[ "$scope" != *"arc:$SLUG"* && "$scope" != "the whole board" ]]; then
        eye "         it does not name '$SLUG'. To widen it, re-arm deliberately with every scope you want:"
        eye "         lore coordinate arm --arc $SLUG --arc <the others> --install $settings"
      fi
      return 0
      ;;
    entry-only)
      eye "$settings already carries a watcher entry that lore has no record of — left exactly as it is, because replacing it would drop a scope this command did not choose. Re-arm deliberately with 'lore coordinate arm' if it should cover '$SLUG'."
      return 0
      ;;
  esac

  if [[ -n "$OWNER_PID" ]]; then
    handle=(--owner-pid "$OWNER_PID")
  elif [[ -n "$OWNER_TMUX" ]]; then
    handle=(--owner-tmux "$OWNER_TMUX")
    if [[ -n "$TMUX_SERVER" ]]; then handle+=(--tmux-server "$TMUX_SERVER"); fi
  else
    want_proc="$(harness_process_name "$framework")" || want_proc=""
    if OWNER_PID="$(owner_pid_from_ancestry "$want_proc")"; then
      handle=(--owner-pid "$OWNER_PID")
    elif OWNER_TMUX="$(owner_tmux_session)"; then
      handle=(--owner-tmux "$OWNER_TMUX")
      TMUX_SERVER="$(owner_tmux_server)" || TMUX_SERVER=""
      if [[ -n "$TMUX_SERVER" ]]; then handle+=(--tmux-server "$TMUX_SERVER"); fi
    else
      eye "the standing eye was not armed: this process's ancestry names no ${want_proc:-harness} process and no tmux session, so there is no handle that outlives the seat. Arm it with the seat's own handle:"
      eye "         lore coordinate arm --owner-pid <the harness pid> --arc $SLUG --install $settings"
      return 0
    fi
  fi

  manual="lore coordinate arm ${handle[*]} --arc $SLUG --install $settings"
  local refusal=""
  if refusal="$("$SCRIPT_DIR/coordinate-arm.sh" "${handle[@]}" --arc "$SLUG" \
      --install "$settings" --kdir "$KNOWLEDGE_DIR" 2>&1)"; then
    eye "standing eye armed for '$SLUG' in $settings (owner: ${handle[*]}) — 'lore arc close' switches it off again."
  else
    # The refusal itself, not a pointer to it: re-running to find out why is a
    # second round trip for something already known here.
    eye "the standing eye was not armed — 'lore coordinate arm' refused:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "         $line" >&2
    done <<< "$refusal"
    eye "         arm it once the refusal is answered:"
    eye "         $manual"
  fi
  return 0
}

if [[ $NO_WATCHER -eq 0 ]]; then
  arm_standing_eye || true
else
  eye "standing eye not armed (--no-watcher). Arm one later with 'lore coordinate arm --arc $SLUG --install <settings.json>'."
fi

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
envelope = json.load(sys.stdin)
record = envelope["record"]
record["path"] = sys.argv[1]
print(json.dumps(record, indent=2))
' "$RELATIVE_PATH"
  exit 0
fi

echo "[arc] Opened: $SLUG ($TITLE)"
echo "  path:   $RELATIVE_PATH"
echo "  ledger: $RELATIVE_PATH/coordination.md"
if [[ $HAS_PROJECT -eq 1 ]]; then
  echo "  project: $PROJECT"
fi
