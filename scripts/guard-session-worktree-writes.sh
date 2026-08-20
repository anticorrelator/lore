#!/usr/bin/env bash
# guard-session-worktree-writes.sh — PreToolUse hook (matcher Edit|Write)
#
# Enforces a session-scoped write allowlist for a TUI-hosted harness session: it
# may write inside its own checkout, inside the knowledge store outside the two
# managed-checkout namespaces, and inside the system temporary directory. Any
# other target — another session's worktree, a coordinated writer's tree, another
# clone, or a path belonging to no checkout at all — is refused at the tool call
# and journaled.
#
# Input:  PreToolUse JSON on stdin (tool_name, tool_input.file_path, cwd, session_id)
# Output: {"decision":"block","reason":"..."} or {"decision":"approve"} on stdout.
#         A PreToolUse hook is read as approving when it says nothing, so every
#         refusal path prints its blocking JSON before doing anything that can
#         fail. Diagnostics and journal failures go to stderr and can never turn
#         a refusal into an approval.
#
# Policy inputs come from the environment the TUI spawn path exports, never from
# the payload: LORE_SESSION_INSTANCE (hosted identity), LORE_SESSION_WORKTREE
# (the containment boundary), LORE_SESSION_STORE_ROOT (the knowledge store). A
# process with no hosted identity is an operator's own terminal and is approved
# without classification, so a human editing sibling checkouts never trips this.
# The payload's reported working directory is used only as the base for a
# relative target: it describes the call being judged rather than supplying the
# rule to judge it by.
#
# Refusal reasons are a closed set:
#   outside-session-allowlist     a classified target resolved outside every allowed root
#   containment-context-missing   hosted identity present, usable policy context absent

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

approve() {
  printf '{"decision":"approve"}\n'
  exit 0
}

# Print the refusal first, then journal. An append that fails leaves the write
# refused and the failure on stderr; it never re-opens the tool call.
block() {
  local message="$1"
  # Composed with shell builtins only. Everything else in this script shells out
  # to python3, and a refusal that cannot print is read as an approval — so the
  # one line that must always be emitted depends on nothing external.
  message="${message//\\/\\\\}"
  message="${message//\"/\\\"}"
  printf '{"decision":"block","reason":"%s"}\n' "$message"
}

journal_refusal() {
  local reason="$1" links_json="$2"
  local row
  row=$(python3 - "$reason" "$links_json" <<'PY'
import json, os, sys
row = {
    "event": "worktree_write_refused",
    "actor_instance": os.environ.get("LORE_SESSION_INSTANCE", ""),
    "reason": sys.argv[1],
    "links": json.loads(sys.argv[2]),
}
for key, var in (("slug", "LORE_SESSION_SLUG"), ("session_type", "LORE_SESSION_TYPE")):
    value = os.environ.get(var, "")
    if value:
        row[key] = value
print(json.dumps(row))
PY
  ) || { echo "[worktree-fence] could not compose the refusal row" >&2; return 1; }
  if ! printf '%s' "$row" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$STORE_ROOT" >/dev/null 2>&1; then
    echo "[worktree-fence] refusal journaled nowhere: session-event-append.sh rejected the row" >&2
    return 1
  fi
  return 0
}

INPUT=$(cat)

# --- Hosted gate: no session identity means this is not a hosted session ---
if [[ -z "${LORE_SESSION_INSTANCE:-}" ]]; then
  approve
fi

# --- The store root is both a policy input and the only journal destination ---
STORE_ROOT="${LORE_SESSION_STORE_ROOT:-}"
if [[ -z "$STORE_ROOT" || ! -d "$STORE_ROOT" ]]; then
  block "Refused: this session declares hosted identity but no usable LORE_SESSION_STORE_ROOT, so its write allowlist cannot be evaluated. Relaunch the session from the lore TUI so the spawn path declares LORE_SESSION_WORKTREE and LORE_SESSION_STORE_ROOT."
  echo "[worktree-fence] refusal not journaled: LORE_SESSION_STORE_ROOT is unset or not a directory" >&2
  exit 0
fi

# --- Classify the call: one pass over the payload and the declared roots ---
# Emits shell assignments (VERDICT, REASON, TOOL_NAME, TARGET_PATH, WORKTREE_PATH,
# HARNESS_SESSION_ID). Canonicalization goes through os.path.realpath, which
# resolves symlinks in existing ancestors and tolerates a missing leaf — the BSD
# realpath on this platform rejects the -m that would be its shell equivalent.
CLASSIFIER=$(cat <<'PY'
import json, os, shlex, sys

store_root = sys.argv[1]


def canonical(path):
    return os.path.realpath(path)


def emit(**fields):
    for key, value in fields.items():
        print("%s=%s" % (key, shlex.quote(value)))
    sys.exit(0)


try:
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        raise ValueError("payload is not an object")
except Exception:
    emit(VERDICT="unparsed")

tool_name = payload.get("tool_name")
tool_name = tool_name if isinstance(tool_name, str) and tool_name else ""
if not tool_name:
    emit(VERDICT="unparsed")

harness_session_id = payload.get("session_id")
harness_session_id = harness_session_id if isinstance(harness_session_id, str) else ""

tool_input = payload.get("tool_input")
if not isinstance(tool_input, dict):
    emit(VERDICT="context-missing", DETAIL="the payload carries no tool_input object",
         TOOL_NAME=tool_name, HARNESS_SESSION_ID=harness_session_id)

if "file_path" not in tool_input:
    # Nothing to fence: this tool call names no target.
    emit(VERDICT="approve", TOOL_NAME=tool_name)

raw_target = tool_input.get("file_path")
if not isinstance(raw_target, str) or not raw_target:
    emit(VERDICT="context-missing", DETAIL="tool_input.file_path is present but not a usable path",
         TOOL_NAME=tool_name, HARNESS_SESSION_ID=harness_session_id)

# Resolve the boundary and the target independently, so a row for a degraded
# context still names whichever of the two was established.
declared_worktree = os.environ.get("LORE_SESSION_WORKTREE", "")
worktree_root = canonical(declared_worktree) if declared_worktree and os.path.isdir(declared_worktree) else ""

base = payload.get("cwd")
if os.path.isabs(raw_target):
    target = canonical(raw_target)
elif isinstance(base, str) and base:
    target = canonical(os.path.join(base, raw_target))
else:
    target = ""

if not target:
    emit(VERDICT="context-missing",
         DETAIL="the target path is relative and the payload reports no working directory",
         TOOL_NAME=tool_name, WORKTREE_PATH=worktree_root,
         HARNESS_SESSION_ID=harness_session_id)
if not worktree_root:
    emit(VERDICT="context-missing",
         DETAIL="LORE_SESSION_WORKTREE is unset or does not name a directory",
         TOOL_NAME=tool_name, TARGET_PATH=target,
         HARNESS_SESSION_ID=harness_session_id)


def within(root):
    return root and (target == root or target.startswith(root.rstrip("/") + os.sep))


store = canonical(store_root)
managed_namespaces = [
    os.path.join(store, "_sessions", "worktrees"),
    os.path.join(store, "_coordination", "worktrees", "trees"),
]
temp_roots = {canonical(os.environ.get("TMPDIR") or "/tmp"), canonical("/tmp")}

refused = dict(VERDICT="refuse", TOOL_NAME=tool_name, TARGET_PATH=target,
               WORKTREE_PATH=worktree_root, HARNESS_SESSION_ID=harness_session_id)
allowed = dict(VERDICT="approve", TOOL_NAME=tool_name)

# Ordered: the session's own checkout lives under the store's session-worktree
# namespace, so it has to be allowed before that namespace is denied — and both
# managed namespaces live under the store, so they have to be denied before the
# rest of the store is allowed.
if within(worktree_root):
    emit(**allowed)
if any(within(ns) for ns in managed_namespaces):
    emit(**refused)
if within(store):
    emit(**allowed)
if any(within(root) for root in temp_roots):
    emit(**allowed)
emit(**refused)
PY
)
CLASSIFICATION=$(printf '%s' "$INPUT" | python3 -c "$CLASSIFIER" "$STORE_ROOT")

if [[ -z "$CLASSIFICATION" ]]; then
  block "Refused: the write fence could not classify this tool call. Report this as a lore hook failure."
  echo "[worktree-fence] refusal not journaled: classification produced no verdict" >&2
  exit 0
fi

VERDICT=""; REASON=""; DETAIL=""; TOOL_NAME=""; TARGET_PATH=""; WORKTREE_PATH=""; HARNESS_SESSION_ID=""
eval "$CLASSIFICATION"

case "$VERDICT" in
  approve)
    approve
    ;;
  unparsed)
    block "Refused: the write fence could not read this tool call's payload, so its target cannot be classified. Report this as a lore hook failure."
    echo "[worktree-fence] refusal not journaled: the payload named no tool, so no legible refusal row exists" >&2
    exit 0
    ;;
  context-missing)
    block "Refused: this session declares hosted identity but the write fence has no usable containment context ($DETAIL). Relaunch the session from the lore TUI so the spawn path declares LORE_SESSION_WORKTREE and LORE_SESSION_STORE_ROOT."
    LINKS=$(python3 -c '
import json, sys
links = {"tool_name": sys.argv[1]}
for key, value in (("target_path", sys.argv[2]), ("worktree_path", sys.argv[3]), ("harness_session_id", sys.argv[4])):
    if value:
        links[key] = value
print(json.dumps(links))' "$TOOL_NAME" "$TARGET_PATH" "$WORKTREE_PATH" "$HARNESS_SESSION_ID")
    journal_refusal "containment-context-missing" "$LINKS" || true
    exit 0
    ;;
  refuse)
    block "Refused: $TOOL_NAME targets $TARGET_PATH, which is outside this session's write allowlist. This session may write inside its own checkout ($WORKTREE_PATH), inside the knowledge store outside the managed-checkout namespaces, and inside the system temporary directory. Editing another checkout or another session's worktree is what this fence exists to stop — make the change in your own checkout."
    LINKS=$(python3 -c '
import json, sys
links = {"target_path": sys.argv[1], "worktree_path": sys.argv[2], "tool_name": sys.argv[3]}
if sys.argv[4]:
    links["harness_session_id"] = sys.argv[4]
print(json.dumps(links))' "$TARGET_PATH" "$WORKTREE_PATH" "$TOOL_NAME" "$HARNESS_SESSION_ID")
    journal_refusal "outside-session-allowlist" "$LINKS" || true
    exit 0
    ;;
  *)
    block "Refused: the write fence returned an unrecognized verdict. Report this as a lore hook failure."
    echo "[worktree-fence] refusal not journaled: unrecognized verdict '$VERDICT'" >&2
    exit 0
    ;;
esac
