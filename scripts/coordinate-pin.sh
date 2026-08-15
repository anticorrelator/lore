#!/usr/bin/env bash
# coordinate-pin.sh — sole writer of the coordination pin sidecar
#   _work/_projects/<project-slug>/_coordination.json (schema v1):
#     {"schema_version": 1, "pin": {"instance", "pinned_at", "pinned_by"}}
#   The pin key is omitted entirely when no pin is set; pinned_by omits when
#   empty. Liveness is never stored — the read form derives live/dead by joining
#   pin.instance against the session registry's mtime TTL.
#
# Usage:
#   lore coordinate pin <project> <instance> [--pinned-by <actor>]   # set pin
#   lore coordinate pin <project> --clear                            # clear pin
#   lore coordinate pin <project> [--json]                           # read pin
#   lore coordinate pin <project> --preflight                        # gate a dispatch
#
# Writes go through mktemp + atomic rename. The project home must already exist;
# a missing home is refused and never created (that is describe-project.sh's job).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore coordinate pin <project> <instance> [--pinned-by <actor>]   set the pin
  lore coordinate pin <project> --clear                            clear the pin
  lore coordinate pin <project> [--json]                           read the pin
  lore coordinate pin <project> --preflight                        gate a dispatch

Options:
  --pinned-by <actor>  Actor recorded on a set (default: $LORE_SESSION_INSTANCE,
                       else $USER). Omitted from the sidecar when empty.
  --clear              Remove the pin key, leaving a valid pin-less sidecar.
  --json               Read form emits a JSON projection instead of text.
  --preflight          Read form refuses instead of reporting. Not combinable
                       with --json (see below).
  --kdir <path>        Override the resolved knowledge dir (testing).
  --help, -h           Show this help.

Preflight, and why it refuses:
  The plain read form answers "what is the pin?", and "nothing" or "dead" are
  legitimate answers to that question — so it always exits 0. Preflight asks a
  different question: "is this project safe to dispatch against right now?" It
  prints nothing but the bare instance name on stdout, so the answer drops
  straight into a dispatch:

    lore coordinate <verb> --target "$(lore coordinate pin myproject --preflight)"

  A dead or missing pin stops the command substitution there, with a diagnostic
  on stderr, instead of surfacing fifteen minutes later as a session that was
  launched at nothing. That is the whole point of the mode: nothing here warns
  and continues. Because the caller reads stdout, --preflight and --json are
  mutually exclusive — a JSON object is not an instance name.

  Exit codes (preflight only; every other form of this verb uses 0 and 1):
    0  the pin is set and its instance is live — the name is on stdout
    3  a pin is set but its instance is dead (its registry row has not been
       touched inside the liveness TTL). Re-pin to a live instance, or clear
       the pin if this project should dispatch unpinned.
    4  no pin is set for this project. Set one, or dispatch without a target.

  Liveness is derived on every read and never stored, so a pin that was live a
  minute ago can be exit 3 now. That is the mode working, not a stale record.
EOF
}

PROJECT=""
INSTANCE=""
PINNED_BY=""
HAS_PINNED_BY=0
CLEAR=0
JSON_MODE=0
PREFLIGHT=0
KDIR_OVERRIDE=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear) CLEAR=1; shift ;;
    --pinned-by) PINNED_BY="${2:-}"; HAS_PINNED_BY=1; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --preflight) PREFLIGHT=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "[coordinate] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
  echo "[coordinate] Error: missing required argument: project" >&2
  usage
  exit 1
fi
PROJECT="${POSITIONAL[0]}"
[[ ${#POSITIONAL[@]} -ge 2 ]] && INSTANCE="${POSITIONAL[1]}"
if [[ ${#POSITIONAL[@]} -gt 2 ]]; then
  echo "[coordinate] Error: unexpected argument '${POSITIONAL[2]}'" >&2
  usage
  exit 1
fi

# Mode selection: --clear and an instance argument are mutually exclusive; a
# lone project reads.
if [[ $CLEAR -eq 1 && -n "$INSTANCE" ]]; then
  echo "[coordinate] Error: --clear takes no <instance> argument" >&2
  exit 1
fi
if [[ $CLEAR -eq 0 && -n "$INSTANCE" ]]; then
  MODE="set"
elif [[ $CLEAR -eq 1 ]]; then
  MODE="clear"
else
  MODE="read"
fi

if [[ $PREFLIGHT -eq 1 ]]; then
  if [[ "$MODE" != "read" ]]; then
    echo "[coordinate] Error: --preflight reads a pin; it cannot be combined with a set or --clear" >&2
    exit 1
  fi
  if [[ $JSON_MODE -eq 1 ]]; then
    echo "[coordinate] Error: --preflight and --json are mutually exclusive — preflight's stdout is the bare instance name, for a caller substituting it into a dispatch" >&2
    exit 1
  fi
fi

INPUT_PROJECT="$PROJECT"
SLUG=$(slugify "$PROJECT")
if [[ -z "$SLUG" ]]; then
  echo "[coordinate] Error: project label '$INPUT_PROJECT' produced an empty slug" >&2
  exit 1
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || die "knowledge store not found at: $KNOWLEDGE_DIR"

WORK_DIR="$KNOWLEDGE_DIR/_work"
INSTANCES_DIR="$KNOWLEDGE_DIR/_sessions/instances"

# resolve_home resolves the owning project home immediately before a write and
# refuses (never creates) a missing home — home creation belongs to
# describe-project.sh. Re-run right before each write; never carry the path
# across a gap.
resolve_home() {
  local home="$WORK_DIR/_projects/$SLUG"
  if [[ ! -d "$home" ]]; then
    echo "[coordinate] Error: project '$SLUG' has no home at $home — describe it first" >&2
    return 1
  fi
  echo "$home"
}

atomic_write() {
  # atomic_write <dir> <dest-path> <content>
  local dir="$1" dest="$2" content="$3" tmp
  tmp="$(mktemp "$dir/.tmp._coordination.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$dest"
}

# pin_live <instance> — 0 (live) when the registry row's mtime is within the
# TTL, 1 otherwise. Derived only; no liveness is ever persisted.
pin_live() {
  session_instance_live "$INSTANCES_DIR" "$1"
}

case "$MODE" in
  set)
    if [[ "$INSTANCE" == */* || -z "$INSTANCE" ]]; then
      echo "[coordinate] Error: invalid instance name '$INSTANCE'" >&2
      exit 1
    fi
    if [[ $HAS_PINNED_BY -eq 0 ]]; then
      PINNED_BY="${LORE_SESSION_INSTANCE:-${USER:-}}"
    fi
    HOME_DIR=$(resolve_home) || exit 1
    PINNED_AT=$(timestamp_iso)
    CONTENT=$(python3 - "$INSTANCE" "$PINNED_AT" "$PINNED_BY" <<'PYEOF'
import json, sys

instance, pinned_at, pinned_by = sys.argv[1:4]
pin = {"instance": instance, "pinned_at": pinned_at}
if pinned_by:
    pin["pinned_by"] = pinned_by
print(json.dumps({"schema_version": 1, "pin": pin}, separators=(",", ":")))
PYEOF
)
    atomic_write "$HOME_DIR" "$HOME_DIR/_coordination.json" "$CONTENT"
    echo "[coordinate] pinned '$SLUG' -> $INSTANCE"
    ;;

  clear)
    HOME_DIR=$(resolve_home) || exit 1
    SIDECAR="$HOME_DIR/_coordination.json"
    if [[ ! -f "$SIDECAR" ]]; then
      echo "[coordinate] no pin set for '$SLUG'"
      exit 0
    fi
    # Drop the pin key while preserving schema validity; the sole writer only
    # ever emits schema_version + pin, so the cleared form is the bare schema.
    CONTENT=$(python3 - "$SIDECAR" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}
version = data.get("schema_version", 1)
print(json.dumps({"schema_version": version}, separators=(",", ":")))
PYEOF
)
    atomic_write "$HOME_DIR" "$SIDECAR" "$CONTENT"
    echo "[coordinate] cleared pin for '$SLUG'"
    ;;

  read)
    SIDECAR="$WORK_DIR/_projects/$SLUG/_coordination.json"
    PIN_INSTANCE=""
    PIN_AT=""
    PIN_BY=""
    if [[ -f "$SIDECAR" ]]; then
      # Read the three pin fields on tab-separated lines; a pin-less or missing
      # sidecar yields empties.
      IFS=$'\t' read -r PIN_INSTANCE PIN_AT PIN_BY < <(python3 - "$SIDECAR" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}
pin = data.get("pin") or {}
print("\t".join([
    str(pin.get("instance", "") or ""),
    str(pin.get("pinned_at", "") or ""),
    str(pin.get("pinned_by", "") or ""),
]))
PYEOF
)
    fi

    LIVE=""
    if [[ -n "$PIN_INSTANCE" ]]; then
      if pin_live "$PIN_INSTANCE"; then LIVE="live"; else LIVE="dead"; fi
    fi

    # Preflight terminates the read here: stdout carries the instance name and
    # nothing else, and the two refusals name both corrections rather than
    # leaving the caller to re-read the sidecar to find out which one applies.
    if [[ $PREFLIGHT -eq 1 ]]; then
      if [[ -z "$PIN_INSTANCE" ]]; then
        echo "[coordinate] Error: project '$SLUG' has no pin, so there is no instance to dispatch against." >&2
        echo "             Pin one deliberately:  lore coordinate pin $SLUG <instance>" >&2
        echo "             Or dispatch without a target if this project does not need a sticky seat." >&2
        exit 4
      fi
      if [[ "$LIVE" != "live" ]]; then
        echo "[coordinate] Error: project '$SLUG' is pinned to '$PIN_INSTANCE', which is not live." >&2
        echo "             Its registry row at $INSTANCES_DIR/$PIN_INSTANCE.json has not been touched" >&2
        echo "             within the ${SESSION_INSTANCE_LIVENESS_TTL_SECONDS}s liveness window (or is gone entirely)." >&2
        echo "             Re-pin to a live instance:  lore coordinate pin $SLUG <instance>" >&2
        echo "             Or clear the pin:           lore coordinate pin $SLUG --clear" >&2
        exit 3
      fi
      printf '%s\n' "$PIN_INSTANCE"
      exit 0
    fi

    if [[ $JSON_MODE -eq 1 ]]; then
      python3 - "$SLUG" "$PIN_INSTANCE" "$PIN_AT" "$PIN_BY" "$LIVE" <<'PYEOF'
import json, sys

slug, instance, pinned_at, pinned_by, live = sys.argv[1:6]
if not instance:
    print(json.dumps({"project": slug, "pinned": False}, separators=(",", ":")))
else:
    out = {
        "project": slug,
        "pinned": True,
        "instance": instance,
        "pinned_at": pinned_at,
        "live": live == "live",
    }
    if pinned_by:
        out["pinned_by"] = pinned_by
    print(json.dumps(out, separators=(",", ":")))
PYEOF
    else
      if [[ -z "$PIN_INSTANCE" ]]; then
        echo "project: $SLUG"
        echo "pin: (none)"
      else
        echo "project: $SLUG"
        echo "pin: $PIN_INSTANCE ($LIVE)"
        echo "pinned_at: $PIN_AT"
        [[ -n "$PIN_BY" ]] && echo "pinned_by: $PIN_BY"
      fi
    fi
    ;;
esac
