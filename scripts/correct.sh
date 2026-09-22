#!/usr/bin/env bash
# correct.sh — `lore correct`: resolve a knowledge entry the code contradicts.
#
# The name an agent reaches for at the moment it finds an entry wrong. It is a
# front door, not a second writer: every invocation becomes
# `verify-append.sh <entry> contradicted --resolution corrected|disputed`, so
# the entry edit, the trust-ledger event, and retry convergence are exactly
# the ones `lore verify` produces.
#
# What it adds over calling verify directly:
#   - the disposition is implied (contradicted);
#   - --resolution defaults to corrected, and --dispute selects disputed;
#   - --source defaults to interactive, the seat with no position brief to
#     name one. A dispatched position passes its own --source.
#
# Every other flag passes through unchanged; see `lore verify --help`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: lore correct <knowledge-path> \
           --file <absolute-path> --line-range <N-M> --exact-snippet <verbatim> \
           --rationale <why the code falsifies the entry> \
           --claim-text <the entry assertion> --falsifier <what would disprove your reading> \
           # correct the entry (default):
           --superseded-text <entry text being replaced> \
           --replacement-text <what it becomes> \
           --confidence <high|medium|low> \
           --evidence-scope <single-callsite|multi-callsite|systemic> \
           --claim-scale <implementation|subsystem|architecture|abstract> \
           # or leave a dated marker instead:
           --dispute --dispute-note <what you saw and why you did not correct> \
           [--source <role>]        # default: interactive
           [--work-item <slug>]     # optional
           [--json] [...any other `lore verify` flag]

Resolve an entry the code in front of you contradicts. By default the entry is
rewritten (superseded-text -> replacement-text); with --dispute a dated marker
is left for the next reader whose context can settle it. Both record a
grounded contradiction on the trust ledger.

Exit 3 means the evidence cannot carry a correction (confidence below high,
or single-callsite evidence against a claim above implementation scale):
nothing was written; re-run with --dispute.

This is `lore verify <entry> contradicted --resolution ...` under a name you
can find. To record that an entry held, use `lore verify <entry> held`.
EOF
}

ENTRY=""
SOURCE_SET=0
RESOLUTION=""
PASS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dispute) RESOLUTION="disputed"; shift ;;
    --resolution)
      [[ $# -ge 2 ]] || { echo "[correct] Error: --resolution needs a value" >&2; exit 1; }
      RESOLUTION="$2"; shift 2 ;;
    --source)
      [[ $# -ge 2 ]] || { echo "[correct] Error: --source needs a value" >&2; exit 1; }
      SOURCE_SET=1; PASS+=("$1" "$2"); shift 2 ;;
    --json) PASS+=("$1"); shift ;;
    --*)
      [[ $# -ge 2 ]] || { echo "[correct] Error: $1 needs a value" >&2; exit 1; }
      PASS+=("$1" "$2"); shift 2 ;;
    *)
      if [[ -z "$ENTRY" ]]; then
        ENTRY="$1"; shift
      else
        echo "[correct] Error: unexpected argument '$1' (the disposition is implied; to record a held entry use 'lore verify <entry> held')" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$ENTRY" ]]; then
  echo "[correct] Error: <knowledge-path> is required" >&2
  usage
  exit 1
fi

[[ $SOURCE_SET -eq 1 ]] || PASS+=(--source interactive)
PASS+=(--resolution "${RESOLUTION:-corrected}")

exec bash "$SCRIPT_DIR/verify-append.sh" "$ENTRY" contradicted "${PASS[@]}"
