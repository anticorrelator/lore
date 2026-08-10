#!/usr/bin/env bash
# arc-close.sh — record the closure of a coordination arc.
#
# Usage: bash arc-close.sh <slug> [--json]
#
# Closure is the coordinator's decision, so it is recorded rather than inferred
# from what is on disk. A missing report.md is called out loudly and does not
# stop the close.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc close <slug> [--json]

Records the arc as closed and stamps its closure time. Closing an already-closed
arc leaves the recorded closure time alone.

Options:
  --json             Emit the updated record as JSON.
  --settings <path>  The settings file to read for a standing eye scoped to this
                     arc. Defaults to the active harness's settings file, which
                     is where `lore arc open` arms one.
  --kdir <path>      Override the resolved knowledge dir (testing).
  --help, -h         Show this help.
EOF
}

SLUG=""
JSON_MODE=0
KDIR_OVERRIDE=""
SETTINGS_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --settings) SETTINGS_OVERRIDE="${2:-}"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown option '$1'"; fi
      echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *)
      if [[ -n "$SLUG" ]]; then
        echo "[arc] Error: unexpected argument '$1'" >&2; usage; exit 1
      fi
      SLUG="$1"; shift ;;
  esac
done

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[arc] Error: $1" >&2
  exit 1
}

[[ -n "$SLUG" ]] || fail "a slug is required"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

RECORD_DIR="$KNOWLEDGE_DIR/_work/_arcs/$SLUG"
[[ -f "$RECORD_DIR/_meta.json" ]] || fail "no arc named '$SLUG'"

# An archived arc is refused by the writer below; warning about its report first
# would put a to-do note in front of a refusal.
CURRENT_STATUS="$(json_field "status" "$RECORD_DIR/_meta.json")"
if [[ "$CURRENT_STATUS" != "archived" && ! -f "$RECORD_DIR/report.md" ]]; then
  echo "[arc] Warning: arc '$SLUG' is closing without a report — write $RECORD_DIR/report.md so the arc's residue is readable by whoever comes next" >&2
fi

ENVELOPE=$("$SCRIPT_DIR/arc-write-meta.sh" --kdir "$KNOWLEDGE_DIR" --slug "$SLUG" --op close) || exit 1

# --- The standing eye outlives the arc unless something switches it off -------
#
# `lore coordinate arm --install` installs a Stop-hook watcher that re-fires at
# every turn boundary. Nothing else in the closure path removes it, so an armed
# eye survives its arc and keeps waking a seat about a board nobody is working.
#
# The entry itself says what it watches: `coordinate arm` writes the scope flags
# and the LORE_FRAMEWORK prefix into the command line verbatim, so the settings
# file is both the authority on what is armed and the record of what it covers.
# The seat that closes an arc is usually not the seat that armed it, and it does
# not have to be — it reads the entry.
#
# What gets switched off is only what this arc can be held solely responsible
# for. A watcher naming other arcs too may still be somebody's live eye, so it is
# named, not disarmed: blinding a board in progress is the more expensive
# mistake, and the callout costs a line.
#
# Nothing here can fail the close. Closure is the coordinator's decision being
# recorded; watcher hygiene does not get a veto over it. Everything the block
# says goes to stderr, beside the missing-report warning above and clear of the
# --json contract on stdout.
EYE_SETTINGS_FILE="$SETTINGS_OVERRIDE"
if [[ -z "$EYE_SETTINGS_FILE" ]]; then
  CLOSE_FRAMEWORK="$(resolve_active_framework 2>/dev/null)" || CLOSE_FRAMEWORK=""
  if [[ -n "$CLOSE_FRAMEWORK" ]]; then
    EYE_SETTINGS_FILE="$(resolve_harness_install_path settings "$CLOSE_FRAMEWORK" 2>/dev/null)" || EYE_SETTINGS_FILE=""
    [[ "$EYE_SETTINGS_FILE" == "unsupported" ]] && EYE_SETTINGS_FILE=""
  fi
fi

if [[ -n "$EYE_SETTINGS_FILE" && -f "$EYE_SETTINGS_FILE" ]]; then
  ARMED_MATCHES=$(python3 - "$EYE_SETTINGS_FILE" "$SLUG" <<'PYEOF' || true
import json, re, shlex, sys

settings_path, slug = sys.argv[1], sys.argv[2]
try:
    with open(settings_path, encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError) as exc:
    print("[arc] Warning: could not read %s (%s) — any armed watcher for this "
          "arc is still armed; disarm it with 'lore coordinate disarm "
          "--settings <path>'" % (settings_path, exc), file=sys.stderr)
    raise SystemExit(0)
if not isinstance(settings, dict):
    print("[arc] Warning: %s is not an object; skipping the standing-eye check"
          % settings_path, file=sys.stderr)
    raise SystemExit(0)

for entry in (settings.get("hooks") or {}).get("Stop") or []:
    for hook in entry.get("hooks") or []:
        command = hook.get("command") or ""
        if "coordinate-arm.sh" not in command:
            continue
        try:
            argv = shlex.split(command)
        except ValueError:
            continue
        # The scope the entry was armed with, read back off its own command line.
        arcs, framework = [], ""
        for i, tok in enumerate(argv):
            if tok == "--arc" and i + 1 < len(argv):
                arcs.append(argv[i + 1])
            elif tok.startswith("LORE_FRAMEWORK="):
                framework = tok[len("LORE_FRAMEWORK="):]
        # Only a watcher this arc's scope names is this arc's business. A
        # board-wide eye names no arc, so closing one arc says nothing about
        # whether it is still wanted.
        if slug not in arcs:
            continue
        kind = "sole" if set(arcs) == {slug} else "wide"
        scope = ", ".join("arc:%s" % a for a in arcs)
        print("\t".join([kind, settings_path, framework, scope]))
PYEOF
  )

  while IFS=$'\t' read -r EYE_KIND EYE_SETTINGS EYE_FRAMEWORK EYE_SCOPE; do
    [[ -n "$EYE_KIND" && -n "$EYE_SETTINGS" ]] || continue

    if [[ "$EYE_KIND" != "sole" ]]; then
      echo "[arc] Warning: an armed standing eye covers '$SLUG' and more (scope: $EYE_SCOPE) — it is left armed, because switching it off could blind a board somebody is still working. Disarm it deliberately once it is no longer wanted:" >&2
      echo "         lore coordinate disarm --settings $EYE_SETTINGS" >&2
      continue
    fi

    # The framework the entry names, not the one closing: the adapter that
    # installed the entry is the only one that can recognize and remove it.
    DISARM_RC=0
    DISARM_OUT=""
    if [[ -n "$EYE_FRAMEWORK" ]]; then
      DISARM_OUT=$(LORE_FRAMEWORK="$EYE_FRAMEWORK" bash "$SCRIPT_DIR/coordinate-arm.sh" \
        disarm --settings "$EYE_SETTINGS" --kdir "$KNOWLEDGE_DIR" 2>&1) || DISARM_RC=$?
    else
      DISARM_OUT=$(bash "$SCRIPT_DIR/coordinate-arm.sh" \
        disarm --settings "$EYE_SETTINGS" --kdir "$KNOWLEDGE_DIR" 2>&1) || DISARM_RC=$?
    fi

    # What the disarm found is the disarm surface's to report — an entry
    # removed, or a settings file that is already gone. Saying it here too would
    # put two voices on one outcome, and the second one would sometimes be
    # wrong: this line used to announce "— disarming it." on every rc=0, which
    # printed directly above the disarm's own "nothing to disarm". So it states
    # the attribution, which is this script's to make, and hands the outcome to
    # the surface that measured it.
    if [[ $DISARM_RC -eq 0 ]]; then
      echo "[arc] Standing eye: '$SLUG' is the only scope on the watcher at $EYE_SETTINGS, so this close ran disarm on it:" >&2
    else
      echo "[arc] Warning: could not disarm the standing eye at $EYE_SETTINGS (exit $DISARM_RC) — '$SLUG' is closed regardless, but the watcher is still armed. Run it by hand:" >&2
      echo "         lore coordinate disarm --settings $EYE_SETTINGS" >&2
    fi
    if [[ -n "$DISARM_OUT" ]]; then
      printf '%s\n' "$DISARM_OUT" >&2
    fi
  done <<< "$ARMED_MATCHES"
fi

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["record"], indent=2))
'
  exit 0
fi

printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
record = json.load(sys.stdin)["record"]
print("[arc] Closed: %s (%s)" % (record["slug"], record.get("title") or "untitled"))
print("  closed_at: %s" % (record.get("closed_at") or "unrecorded"))
'
