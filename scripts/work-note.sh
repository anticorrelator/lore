#!/usr/bin/env bash
# work-note.sh — Append a timestamped session-log entry to a work item's notes.md.
#
# Usage: bash work-note.sh <slug> [--text <body>]
#   Body source: --text <body>, or stdin when --text is omitted (multi-line
#   heredoc-friendly). The body is written verbatim under a pinned
#   `## YYYY-MM-DDTHH:MM` heading — the same session-entry format create-work.sh
#   seeds notes.md with. The body's own sub-structure (Focus/Progress/Next,
#   free prose, whatever) is the caller's business; this verb only stamps the
#   heading and appends.
#
#   The slug is resolved active→archive via resolve_work_item_dir (lib.sh); an
#   unknown slug is a hard error. This is the mechanical CLI primitive behind
#   the `/work update` skill flow — it does no session summarization and asks
#   for no review, so agents/workers can append a note without hand-editing the
#   file or burning a round-trip on the nonexistent `lore work update`.
#
# Exit: 0 written | 1 error (missing/unknown slug, empty body, bad flag).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: lore work note <slug> [--text <body>]

Append a '## YYYY-MM-DDTHH:MM' session-log entry to a work item's notes.md.
Body comes from --text, or from stdin when --text is omitted (heredoc-friendly).
Exit: 0 written | 1 error (missing/unknown slug, empty body, bad flag).
EOF
}

SLUG=""
TEXT=""
TEXT_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --text)
      [[ $# -ge 2 ]] || { echo "[work note] Error: --text requires a value." >&2; exit 1; }
      TEXT="$2"
      TEXT_SET=1
      shift 2
      ;;
    --)
      shift
      ;;
    -*)
      echo "[work note] Error: unknown flag '$1'." >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
        shift
      else
        echo "[work note] Error: unexpected extra argument '$1'." >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "[work note] Error: missing required <slug> argument." >&2
  usage
  exit 1
fi

# Body: --text value, else stdin (multi-line heredoc-friendly).
if [[ $TEXT_SET -eq 1 ]]; then
  BODY="$TEXT"
else
  BODY="$(cat)"
fi

# An entry with a heading and no content is noise — refuse a whitespace-only body.
if [[ -z "${BODY//[$' \t\r\n']/}" ]]; then
  echo "[work note] Error: refusing to append an empty note to '$SLUG'." >&2
  exit 1
fi

KNOWLEDGE_DIR="$(resolve_knowledge_dir)"

# Resolve the owning directory (active→archive) via the shared lib.sh helper.
# The notes.md artifact hint prefers a dir that already holds the log; a slug
# that resolves to neither an active nor an archived item leaves the helper
# returning non-zero → unknown-slug exit 1.
if ! ITEM_DIR="$(resolve_work_item_dir "$KNOWLEDGE_DIR" "$SLUG" notes.md)"; then
  echo "[work note] Error: no work item found for slug '$SLUG' (checked active and _archive under $KNOWLEDGE_DIR/_work)." >&2
  exit 1
fi

NOTES_FILE="$ITEM_DIR/notes.md"

# notes.md is created by create-work.sh; if it is somehow absent, seed the
# pinned header so the append lands in a well-formed file rather than a bare
# fragment.
if [[ ! -f "$NOTES_FILE" ]]; then
  {
    printf '# Session Notes: %s\n\n' "$(basename "$ITEM_DIR")"
    printf '<!-- Append session entries below. Entry format: ## YYYY-MM-DDTHH:MM followed by **Focus:**, **Progress:**, **Next:** fields. -->\n'
  } > "$NOTES_FILE"
fi

# Heading uses the pinned notes.md entry format: minute-precision UTC, no
# seconds/Z (matches create-work.sh's notes.md heading, NOT lib.sh timestamp_iso
# which carries seconds + Z for _meta.json fields).
HEADING_TS="$(date -u +%Y-%m-%dT%H:%M)"

{
  printf '\n## %s\n' "$HEADING_TS"
  printf '%s\n' "$BODY"
} >> "$NOTES_FILE"

echo "[work note] Appended entry ($HEADING_TS) to $NOTES_FILE"
