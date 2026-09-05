#!/usr/bin/env bash
# render-dispatch-guidance.sh — Outside a project, the hook emits nothing.
# Inside a project, --short supplies unmarked prompts; full blocks remain
# available for marked prompts, which the hook validates strictly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat >&2 <<'EOF'
Usage: lore dispatch guidance [--short] [--packet <id>]

Render the invocation-fresh schema-v1 dispatch-guidance block on stdout.
Prepend the output verbatim before task-specific context.
With --short, render only the external vocabulary boundary and defaults pointer.
EOF
}

SHORT=false
PACKET_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --packet)
      PACKET_ID="${2:?--packet requires an id}"
      shift 2
      ;;
    --short)
      SHORT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unexpected argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

EXTERNAL_VOCABULARY='External-Vocabulary: In pull requests, issues, comments, and every other colleague-visible deliverable, describe only what shipped and its effect. Do not expose internal process: no harness session links, session trailers, generated-attribution lines, agent/worker/skill language, or Lore tooling references.'

PACKET_LINE=""
if [[ -n "$PACKET_ID" ]]; then
  source "$SCRIPT_DIR/lib.sh"
  PACKET_LINE=$(python3 "$SCRIPT_DIR/packet_builder.py" --kdir "$(resolve_knowledge_dir)" pointer "$PACKET_ID")
fi

if [[ "$SHORT" == true ]]; then
  printf '%s\n' "$EXTERNAL_VOCABULARY" 'For the standing defaults in force, run `lore dispatch guidance`.'
  [[ -z "$PACKET_LINE" ]] || printf '%s\n' "$PACKET_LINE"
  exit 0
fi

DEFAULTS="$("$SCRIPT_DIR/render-standing-defaults.sh")"
DEFAULTS_DIGEST=$(printf '%s\n' "$DEFAULTS" | python3 -c '
import hashlib, re, sys
text = sys.stdin.read()
text = re.sub(
    r"\A=== Standing defaults in force \(rendered [^)]+\) ===",
    "=== Standing defaults in force (rendered <invocation>) ===",
    text,
    count=1,
)
print(hashlib.sha256(text.encode("utf-8")).hexdigest())
')

cat <<EOF
<!-- lore-dispatch-guidance:v1:begin -->
Schema-Version: 1
Defaults-Digest: sha256:$DEFAULTS_DIGEST
Binding: Treat this invocation-fresh guidance as binding for this dispatch. It informs execution but does not select or rewrite the model, role, concurrency, or report contract.
$EXTERNAL_VOCABULARY
Standing-Defaults:
$DEFAULTS
<!-- lore-dispatch-guidance:v1:end -->
EOF

[[ -z "$PACKET_LINE" ]] || printf '%s\n' "$PACKET_LINE"
