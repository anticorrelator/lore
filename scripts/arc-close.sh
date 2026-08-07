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
  --json         Emit the updated record as JSON.
  --kdir <path>  Override the resolved knowledge dir (testing).
  --help, -h     Show this help.
EOF
}

SLUG=""
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
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
# The record arm leaves behind is how a closing seat finds a watcher it never
# armed itself — the seat that closes an arc is usually not the seat that opened
# it.
#
# What gets switched off is only what this arc can be held solely responsible
# for. A watcher scoped to other arcs or to individual items may still be
# somebody's live eye, so it is named, not disarmed: blinding a board in
# progress is the more expensive mistake, and the callout costs a line.
#
# Nothing here can fail the close. Closure is the coordinator's decision being
# recorded; watcher hygiene does not get a veto over it. Everything the block
# says goes to stderr, beside the missing-report warning above and clear of the
# --json contract on stdout.
ARMED_RECORD_FILE="$KNOWLEDGE_DIR/_coordination/armed-watchers.json"

if [[ -f "$ARMED_RECORD_FILE" ]]; then
  ARMED_MATCHES=$(python3 - "$ARMED_RECORD_FILE" "$SLUG" <<'PYEOF' || true
import json, sys

record_path, slug = sys.argv[1], sys.argv[2]
try:
    with open(record_path, encoding="utf-8") as f:
        records = json.load(f)
except (OSError, ValueError) as exc:
    print("[arc] Warning: could not read %s (%s) — any armed watcher for this "
          "arc is still armed; disarm it with 'lore coordinate disarm "
          "--settings <path>'" % (record_path, exc), file=sys.stderr)
    raise SystemExit(0)
if not isinstance(records, dict):
    print("[arc] Warning: %s is not an object; skipping the standing-eye check"
          % record_path, file=sys.stderr)
    raise SystemExit(0)

for key, rec in sorted(records.items()):
    if not isinstance(rec, dict):
        continue
    scopes = rec.get("scopes") or {}
    arcs = [a for a in (scopes.get("arcs") or []) if a]
    slugs = [s for s in (scopes.get("slugs") or []) if s]
    # Only a watcher this arc's scope names is this arc's business. A board-wide
    # eye names no arc, so closing one arc says nothing about whether it is
    # still wanted.
    if slug not in arcs:
        continue
    kind = "sole" if set(arcs) == {slug} and not slugs else "wide"
    scope = ", ".join(["arc:%s" % a for a in arcs] + ["slug:%s" % s for s in slugs])
    print("\t".join([kind, rec.get("settings_path") or key,
                     rec.get("framework") or "", scope]))
PYEOF
  )

  while IFS=$'\t' read -r EYE_KIND EYE_SETTINGS EYE_FRAMEWORK EYE_SCOPE; do
    [[ -n "$EYE_KIND" && -n "$EYE_SETTINGS" ]] || continue

    if [[ "$EYE_KIND" != "sole" ]]; then
      echo "[arc] Warning: an armed standing eye covers '$SLUG' and more (scope: $EYE_SCOPE) — it is left armed, because switching it off could blind a board somebody is still working. Disarm it deliberately once it is no longer wanted:" >&2
      echo "         lore coordinate disarm --settings $EYE_SETTINGS" >&2
      continue
    fi

    # The framework the arm recorded, not the one closing: the adapter that
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
    # put two voices on one outcome, and the second one would sometimes be wrong.
    if [[ $DISARM_RC -eq 0 ]]; then
      echo "[arc] Standing eye: '$SLUG' is the only scope on the watcher at $EYE_SETTINGS — disarming it." >&2
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
