#!/usr/bin/env bash
# validate-dispatch-guidance.sh — Validate a composed dispatch prompt against
# the current schema-v1 guidance floor. In --hook mode, extract the exact
# evidence-backed prompt field and emit the harness's native deny shape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK_FRAMEWORK=""
PROMPT_FILE=""

usage() {
  cat >&2 <<'EOF'
Usage:
  validate-dispatch-guidance.sh [--prompt-file <path>]
  validate-dispatch-guidance.sh --hook <claude-code|codex>

Without --prompt-file, reads the composed prompt from stdin. Hook mode reads
the native PreToolUse JSON payload from stdin and blocks invalid launches.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt-file)
      [[ $# -ge 2 ]] || { echo "Error: --prompt-file requires a path" >&2; exit 1; }
      PROMPT_FILE="$2"
      shift 2
      ;;
    --hook)
      [[ $# -ge 2 ]] || { echo "Error: --hook requires a framework" >&2; exit 1; }
      HOOK_FRAMEWORK="$2"
      shift 2
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

if [[ -n "$HOOK_FRAMEWORK" && -n "$PROMPT_FILE" ]]; then
  echo "Error: --hook and --prompt-file are mutually exclusive" >&2
  exit 1
fi
case "$HOOK_FRAMEWORK" in
  ""|claude-code|codex) ;;
  *) echo "Error: unsupported hook framework '$HOOK_FRAMEWORK'" >&2; exit 1 ;;
esac

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
PROMPT_PATH="$TMP_DIR/prompt.txt"
MODEL_PATH="$TMP_DIR/model.txt"
DEFAULTS_PATH="$TMP_DIR/defaults.txt"
ERROR_PATH="$TMP_DIR/error.txt"

if [[ -n "$HOOK_FRAMEWORK" ]]; then
  PAYLOAD_PATH="$TMP_DIR/payload.json"
  tee "$PAYLOAD_PATH" >/dev/null
  if ! python3 - "$HOOK_FRAMEWORK" "$PAYLOAD_PATH" "$PROMPT_PATH" "$MODEL_PATH" >"$ERROR_PATH" 2>&1 <<'PY'; then
import json, sys

framework, payload_path, prompt_path, model_path = sys.argv[1:]
try:
    with open(payload_path, encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception as exc:
    raise SystemExit(f"malformed launch-hook payload: {exc}")

tool_name = payload.get("tool_name")
tool_input = payload.get("tool_input")
if not isinstance(tool_input, dict):
    raise SystemExit("launch-hook payload is missing object field tool_input")

if framework == "claude-code":
    if tool_name != "Agent":
        raise SystemExit(f"unsupported claude-code launch tool: {tool_name!r}")
    prompt = tool_input.get("prompt")
    model = tool_input.get("model")
else:
    if tool_name != "spawn_agent":
        raise SystemExit(f"unsupported codex launch tool: {tool_name!r}")
    prompt = tool_input.get("message")
    model = None

if not isinstance(prompt, str) or not prompt.strip():
    raise SystemExit("launch prompt is missing or empty")

with open(prompt_path, "w", encoding="utf-8") as fh:
    fh.write(prompt)
# A missing, empty, or non-string model field is an unstated model: the launch
# would inherit whatever tier the spawning session happens to run on.
with open(model_path, "w", encoding="utf-8") as fh:
    fh.write(model.strip() if isinstance(model, str) else "")
PY
    FAILURE_REASON=$(tr '\n' ' ' < "$ERROR_PATH" | sed 's/[[:space:]]*$//')
  fi
elif [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || { echo "Error: prompt file not found: $PROMPT_FILE" >&2; exit 1; }
  cp "$PROMPT_FILE" "$PROMPT_PATH"
else
  tee "$PROMPT_PATH" >/dev/null
fi

FAILURE_REASON="${FAILURE_REASON:-}"

# Injection path (claude-code hook mode only): a launch prompt that carries no
# trace of a guidance block is a non-protocol dispatch — the launching agent
# never had a delivery mechanism for the guidance floor. Render it fresh at
# this seam and inject it via updatedInput instead of teaching by denial.
# Any marker presence means a protocol seat attempted the form; those prompts
# fall through to strict validation so tampering and staleness still surface.
INJECT_GUIDANCE_PATH=""
if [[ "$HOOK_FRAMEWORK" == "claude-code" && -z "$FAILURE_REASON" ]] \
  && ! grep -qF 'lore-dispatch-guidance:v1:' "$PROMPT_PATH"; then
  GUIDANCE_PATH="$TMP_DIR/guidance.txt"
  if "$SCRIPT_DIR/render-dispatch-guidance.sh" > "$GUIDANCE_PATH" 2>"$ERROR_PATH"; then
    INJECT_GUIDANCE_PATH="$GUIDANCE_PATH"
  else
    FAILURE_REASON="guidance rendering failed at the admission gate: $(tr '\n' ' ' < "$ERROR_PATH" | sed 's/[[:space:]]*$//')"
  fi
fi

if [[ -z "$FAILURE_REASON" && -z "$INJECT_GUIDANCE_PATH" ]]; then
  "$SCRIPT_DIR/render-standing-defaults.sh" > "$DEFAULTS_PATH"
  if ! python3 - "$PROMPT_PATH" "$DEFAULTS_PATH" >"$ERROR_PATH" 2>&1 <<'PY'; then
import hashlib, re, sys

prompt_path, current_defaults_path = sys.argv[1:]
with open(prompt_path, encoding="utf-8") as fh:
    prompt = fh.read()
with open(current_defaults_path, encoding="utf-8") as fh:
    current_defaults = fh.read()

begin = "<!-- lore-dispatch-guidance:v1:begin -->"
end = "<!-- lore-dispatch-guidance:v1:end -->"
if prompt.count(begin) != 1 or prompt.count(end) != 1:
    raise SystemExit("prompt must contain exactly one complete schema-v1 guidance block")
start = prompt.index(begin)
finish = prompt.index(end, start) + len(end)
block = prompt[start:finish]

digest_match = re.search(r"(?m)^Defaults-Digest: sha256:([0-9a-f]{64})$", block)
if not digest_match or len(re.findall(r"(?m)^Defaults-Digest:", block)) != 1:
    raise SystemExit("guidance defaults digest is missing, duplicated, or malformed")

binding = "Binding: Treat this invocation-fresh guidance as binding for this dispatch. It informs execution but does not select or rewrite the model, role, concurrency, or report contract."
external = "External-Vocabulary: In pull requests, issues, comments, and every other colleague-visible deliverable, describe only what shipped and its effect. Do not expose internal process: no harness session links, session trailers, generated-attribution lines, agent/worker/skill language, or Lore tooling references."
if block.count(binding) != 1:
    raise SystemExit("guidance binding declaration is missing, duplicated, or altered")
if block.count(external) != 1:
    raise SystemExit("guidance external-vocabulary boundary is missing, duplicated, or altered")

standing_marker = "Standing-Defaults:\n"
if block.count(standing_marker) != 1:
    raise SystemExit("standing-defaults payload marker is missing or duplicated")
metadata = block.split(standing_marker, 1)[0].splitlines()
expected_metadata = [
    begin,
    "Schema-Version: 1",
    f"Defaults-Digest: sha256:{digest_match.group(1)}",
    binding,
    external,
]
if metadata != expected_metadata:
    raise SystemExit("guidance metadata fields are reordered, duplicated, or altered")
embedded = block.split(standing_marker, 1)[1]
if not embedded.endswith("\n" + end):
    raise SystemExit("guidance block is truncated or malformed")
embedded = embedded[: -(len(end) + 1)]

def stable(text: str) -> str:
    normalized, count = re.subn(
        r"\A=== Standing defaults in force \(rendered [^)]+\) ===",
        "=== Standing defaults in force (rendered <invocation>) ===",
        text,
        count=1,
    )
    if count != 1 or not normalized.rstrip().endswith("=== End standing defaults ==="):
        raise SystemExit("standing-defaults payload is missing its canonical header or footer")
    return normalized.rstrip("\n") + "\n"

embedded_digest = hashlib.sha256(stable(embedded).encode("utf-8")).hexdigest()
claimed_digest = digest_match.group(1)
if embedded_digest != claimed_digest:
    raise SystemExit("guidance defaults payload was altered after rendering")
current_digest = hashlib.sha256(stable(current_defaults).encode("utf-8")).hexdigest()
if current_digest != claimed_digest:
    raise SystemExit("guidance defaults digest is stale for the current settings or preferences")
PY
    FAILURE_REASON=$(tr '\n' ' ' < "$ERROR_PATH" | sed 's/[[:space:]]*$//')
  fi
fi

# Model floor (claude-code hook mode only): a launch that names no model
# inherits whatever tier the spawning session runs on, so a cheap fan-out
# dispatched from an expensive seat bills at that seat's tier and looks
# identical to a launch that chose it. Supply the settings-resolved default
# for this harness instead. A named model always passes through untouched —
# the gate fills a gap, it never overrides a stated choice. Resolution runs in
# a subshell so the library's globals stay out of the gate, and pins the
# harness to claude-code because that is the harness this hook mode gates.
INJECT_MODEL=""
if [[ "$HOOK_FRAMEWORK" == "claude-code" && -z "$FAILURE_REASON" && ! -s "$MODEL_PATH" ]]; then
  if ! INJECT_MODEL=$(LORE_FRAMEWORK=claude-code bash -c \
        'source "$1/lib.sh" && resolve_model_for_role default' _ "$SCRIPT_DIR" 2>"$ERROR_PATH") \
    || [[ -z "$INJECT_MODEL" ]]; then
    INJECT_MODEL=""
    FAILURE_REASON="the default launch model failed to resolve at the admission gate: $(tr '\n' ' ' < "$ERROR_PATH" | sed 's/[[:space:]]*$//')"
  fi
fi

if [[ -z "$FAILURE_REASON" ]]; then
  # One rewrite carries whatever this gate supplied. Nothing to supply means
  # no output at all, which is how the non-claude-code modes always exit.
  if [[ -n "$INJECT_GUIDANCE_PATH" || -n "$INJECT_MODEL" ]]; then
    python3 - "$PAYLOAD_PATH" "$INJECT_GUIDANCE_PATH" "$INJECT_MODEL" <<'PY'
import json, sys

payload_path, guidance_path, model = sys.argv[1:]
with open(payload_path, encoding="utf-8") as fh:
    payload = json.load(fh)

tool_input = dict(payload["tool_input"])
reasons = []

if guidance_path:
    with open(guidance_path, encoding="utf-8") as fh:
        guidance = fh.read()
    if not guidance.endswith("\n"):
        guidance += "\n"
    tool_input["prompt"] = guidance + tool_input["prompt"]
    reasons.append(
        "Dispatch guidance was absent from this launch prompt; a fresh "
        "schema-v1 guidance block was rendered and prepended at the "
        "admission gate."
    )

if model:
    tool_input["model"] = model
    reasons.append(
        "This launch named no model, so the settings-resolved default for "
        f"this harness ({model}) was supplied at the admission gate."
    )

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": " ".join(reasons),
    "updatedInput": tool_input,
}}, separators=(",", ":")))
PY
  fi
  exit 0
fi

CORRECTIVE="Run 'lore dispatch guidance' and prepend its complete output verbatim before the task-specific prompt."
if [[ "$HOOK_FRAMEWORK" == "claude-code" ]]; then
  python3 - "$FAILURE_REASON" "$CORRECTIVE" <<'PY'
import json, sys
reason = f"Dispatch guidance rejected: {sys.argv[1]}. {sys.argv[2]}"
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason,
}}, separators=(",", ":")))
PY
  exit 0
fi

echo "Dispatch guidance rejected: $FAILURE_REASON. $CORRECTIVE" >&2
exit 1
