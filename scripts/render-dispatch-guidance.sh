#!/usr/bin/env bash
# render-dispatch-guidance.sh — Render the canonical prompt floor prepended to
# every sanctioned subagent dispatch. Routed as `lore dispatch guidance`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat >&2 <<'EOF'
Usage: lore dispatch guidance

Render the invocation-fresh schema-v1 dispatch-guidance block on stdout.
The block is prompt content: prepend it verbatim before task-specific context.
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: lore dispatch guidance accepts no arguments" >&2
      usage
      exit 1
      ;;
  esac
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
External-Vocabulary: In pull requests, issues, comments, and every other colleague-visible deliverable, describe only what shipped and its effect. Do not expose internal process: no harness session links, session trailers, generated-attribution lines, agent/worker/skill language, or Lore tooling references.
Standing-Defaults:
$DEFAULTS
<!-- lore-dispatch-guidance:v1:end -->
EOF
