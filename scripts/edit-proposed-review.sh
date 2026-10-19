#!/usr/bin/env bash
# edit-proposed-review.sh — change a follow-up's proposed review before it is posted
#
# Usage:
#   bash edit-proposed-review.sh <id> <target> [--select|--deselect] [--body <text>|--body-file <path>] [--json]
#   bash edit-proposed-review.sh <id> --event <COMMENT|APPROVE|REQUEST_CHANGES> [--json]
#
# Targets (one per call):
#   --comment <n>     comments[n] of proposed-comments.json (0-based, as `view --json` lists them)
#   --general         the general review body (review_body / review_body_selected)
#   --all-comments    every inline comment (selection only)
#   --finding <n>     findings[n] of lens-findings.json (selection only)
#   --all-findings    every lens finding (selection only)
#
# --event may be given alone or beside a target. The file is rewritten
# atomically (temp file + rename) and every field this script does not change
# is kept as it was, unknown ones included. --json prints the follow-up's
# proposed_comments and lens_findings as they now stand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore followup edit-review <id> <target> [--select|--deselect] [--body <text>|--body-file <path>] [--json]
  lore followup edit-review <id> --event <COMMENT|APPROVE|REQUEST_CHANGES> [--json]

Change a follow-up's proposed review before posting it with `lore followup post-review`.

Targets (one per call):
  --comment <n>     Inline comment n (0-based position in proposed_comments.comments)
  --general         The general review body
  --all-comments    Every inline comment (selection only)
  --finding <n>     Lens finding n (0-based position in lens_findings.findings; selection only)
  --all-findings    Every lens finding (selection only)

Changes:
  --select          Mark the target selected
  --deselect        Mark the target not selected
  --body <text>     Replace the text of a comment or the general body
  --body-file <p>   Read the replacement text from a file ('-' for stdin)
  --event <e>       Set the review event: COMMENT, APPROVE or REQUEST_CHANGES

Options:
  --json            Print {id, proposed_comments, lens_findings} after the change
  --help, -h        Show this help
EOF
}

ID=""
TARGET=""
INDEX=""
SELECTION=""
BODY=""
HAS_BODY=false
EVENT=""
JSON_OUTPUT=false

fail() {
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "$1"
  fi
  echo "[followup] Error: $1" >&2
  exit 1
}

set_target() {
  [[ -z "$TARGET" ]] || { echo "[followup] Error: one target per call" >&2; usage; exit 2; }
  TARGET="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --comment|--finding)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "[followup] Error: $1 needs a position (0, 1, …)" >&2; exit 2; }
      set_target "${1#--}"; INDEX="$2"; shift 2 ;;
    --general) set_target general; shift ;;
    --all-comments) set_target all-comments; shift ;;
    --all-findings) set_target all-findings; shift ;;
    --select|--deselect)
      [[ -z "$SELECTION" ]] || { echo "[followup] Error: --select and --deselect are exclusive" >&2; exit 2; }
      SELECTION="${1#--}"; shift ;;
    --body)
      [[ $# -ge 2 ]] || { echo "[followup] Error: --body needs text" >&2; exit 2; }
      BODY="$2"; HAS_BODY=true; shift 2 ;;
    --body-file)
      [[ $# -ge 2 && -n "$2" ]] || { echo "[followup] Error: --body-file needs a path" >&2; exit 2; }
      if [[ "$2" == "-" ]]; then BODY="$(cat)"; else BODY="$(cat "$2")"; fi
      HAS_BODY=true; shift 2 ;;
    --event)
      [[ $# -ge 2 ]] || { echo "[followup] Error: --event needs a value" >&2; exit 2; }
      case "$2" in
        COMMENT|APPROVE|REQUEST_CHANGES) EVENT="$2" ;;
        *) echo "[followup] Error: --event must be COMMENT, APPROVE or REQUEST_CHANGES" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "[followup] Error: unknown option '$1'" >&2; usage; exit 2 ;;
    *)
      [[ -z "$ID" ]] || { echo "[followup] Error: unexpected argument '$1'" >&2; usage; exit 2; }
      ID="$1"; shift ;;
  esac
done

[[ -n "$ID" ]] || { echo "[followup] Error: missing follow-up id" >&2; usage; exit 2; }
if [[ -z "$TARGET" && -z "$EVENT" ]]; then
  echo "[followup] Error: nothing to change; name a target or --event" >&2; usage; exit 2
fi
if [[ -n "$TARGET" && -z "$SELECTION" && "$HAS_BODY" != true ]]; then
  echo "[followup] Error: --$TARGET needs --select, --deselect or --body" >&2; exit 2
fi
if [[ -z "$TARGET" && ( -n "$SELECTION" || "$HAS_BODY" == true ) ]]; then
  echo "[followup] Error: --select, --deselect and --body need a target" >&2; exit 2
fi
if [[ "$HAS_BODY" == true && "$TARGET" != comment && "$TARGET" != general ]]; then
  echo "[followup] Error: --body applies to --comment or --general only" >&2; exit 2
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir) || fail "Could not resolve knowledge directory"
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"
ITEM_DIR=$(resolve_followup_dir "$ID" 2>/dev/null) || fail "Follow-up not found: $ID"

ITEM_DIR="$ITEM_DIR" TARGET="$TARGET" INDEX="$INDEX" SELECTION="$SELECTION" \
  BODY="$BODY" HAS_BODY="$HAS_BODY" EVENT="$EVENT" FOLLOWUP_ID="$ID" JSON_OUTPUT="$JSON_OUTPUT" \
  python3 - <<'PYEOF'
import json, os, sys, tempfile

item_dir = os.environ["ITEM_DIR"]
target = os.environ["TARGET"]
index = int(os.environ["INDEX"]) if os.environ["INDEX"] else None
selection = os.environ["SELECTION"]
has_body = os.environ["HAS_BODY"] == "true"
body = os.environ["BODY"]
event = os.environ["EVENT"]
json_output = os.environ["JSON_OUTPUT"] == "true"

comments_path = os.path.join(item_dir, "proposed-comments.json")
findings_path = os.path.join(item_dir, "lens-findings.json")


def fail(message):
    if json_output:
        print(json.dumps({"error": message}))
    else:
        print(f"[followup] Error: {message}", file=sys.stderr)
    sys.exit(1)


def load(path, name):
    if not os.path.isfile(path):
        fail(f"this follow-up has no {name}")
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        fail(f"malformed {name}: {e}")


def save(path, value):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".edit-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def pick(items, what):
    if index is None or index >= len(items):
        fail(f"no {what} at position {index}; it has {len(items)}")
    item = items[index]
    if not isinstance(item, dict):
        fail(f"{what} {index} is not an object")
    return item


selected = {"select": True, "deselect": False}.get(selection)

if target in ("comment", "general", "all-comments") or event:
    review = load(comments_path, "proposed review")
    # The legacy sidecar is a bare list of comments: no general body, no event.
    is_wrapped = isinstance(review, dict)
    comments = review.get("comments") if is_wrapped else review
    if not isinstance(comments, list):
        fail("proposed review has no comments list")
    if (target == "general" or event) and not is_wrapped:
        fail("this proposed review predates the general body and event; recreate it to set them")
    if target == "comment":
        comment = pick(comments, "comment")
        if selected is not None:
            comment["selected"] = selected
        if has_body:
            comment["body"] = body
    elif target == "all-comments":
        for comment in comments:
            if isinstance(comment, dict):
                comment["selected"] = selected
    elif target == "general":
        if selected is not None:
            review["review_body_selected"] = selected
        if has_body:
            review["review_body"] = body
    if event:
        review["review_event"] = event
    save(comments_path, review)

if target in ("finding", "all-findings"):
    lens = load(findings_path, "lens findings")
    findings = lens.get("findings") if isinstance(lens, dict) else None
    if not isinstance(findings, list):
        fail("lens findings have no findings list")
    if target == "finding":
        pick(findings, "finding")["selected"] = selected
    else:
        for finding in findings:
            if isinstance(finding, dict):
                finding["selected"] = selected
    save(findings_path, lens)


def read_json(path):
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f)


if json_output:
    print(json.dumps({
        "id": os.environ["FOLLOWUP_ID"],
        "proposed_comments": read_json(comments_path),
        "lens_findings": read_json(findings_path),
    }))
else:
    print(f"[followup] Updated {os.environ['FOLLOWUP_ID']}")
PYEOF
