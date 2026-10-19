#!/usr/bin/env bash
# adapters/codex/hooks.sh — Codex hook adapter (T27).
#
# Implements the hook adapter contract documented in
# adapters/hooks/README.md (T24) for Codex CLI 0.124.0+ native hooks.
# Codex exposes SessionStart, Stop, PreToolUse, PostToolUse, and
# PermissionRequest natively; PreCompact and TaskCompleted-blocking
# remain capability gaps and are routed through the orchestration
# adapter / SessionStart bookend per the hook ↔ orchestration
# cross-reference in adapters/hooks/README.md.
#
# Subcommands:
#   install    Inject the lore hook entries into ~/.codex/config.toml,
#              preserving any non-lore content the user has there.
#              Lore-managed entries are bracketed by sentinel comments
#              so a future install can strip and rewrite them without
#              touching user-authored hooks elsewhere in the file.
#   uninstall  Strip every lore-managed hook entry, leaving user
#              content intact.
#   smoke      Print, for the active framework (must be codex), every
#              Lore lifecycle event paired with its support level and
#              the native Codex hook (or fallback path) it routes
#              through. Honors adapters/hooks/README.md checklist
#              item 5.
#
# Wire format reference: ~/.codex/config.toml defines hooks as matcher
# groups holding command handlers (Codex 0.162.1, probed 2026-10-19):
#
#   [[hooks.PreToolUse]]
#   matcher = "Write"
#
#   [[hooks.PreToolUse.hooks]]
#   type = "command"
#   command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/guard-work-writes.sh"
#
# The older flat form, `[[hooks.<Event>]]` with `command = …` on the group,
# defines no hook on 0.162.1 and Codex reports nothing about it. Codex runs a
# config hook only after the person trusts it (startup "Hooks need review" or
# /hooks), and asks again whenever a hook's command or position changes.
#
# Codex blocks a tool on exit 2 with a reason on stderr, or on
# `permissionDecision: "deny"` JSON; PermissionRequest answers with
# `behavior: allow|deny`. The hook commands written here are the same
# Lore handler scripts the claude-code adapter invokes; the adapter
# does NOT translate per-handler protocols (e.g. PreToolUse JSON
# stdout) — handlers that depend on Claude-Code-specific signaling
# may run as advisory `notify`-shaped commands on Codex. That is the
# `partial`/`fallback` part of the capability cells, and the
# orchestration adapter compensates for the genuine gaps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LORE_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=/dev/null
source "$LORE_REPO_DIR/scripts/lib.sh"

TARGET_FRAMEWORK=""

parse_adapter_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --framework)
        [[ $# -lt 2 ]] && { echo "Error: --framework requires a value" >&2; return 1; }
        TARGET_FRAMEWORK="$2"
        shift 2
        ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done
}

# Sentinel markers bracketing the lore-managed block inside config.toml.
# Idempotent install/uninstall keys on these literals: any text between
# them (inclusive) is rewritten as a unit, anything outside is preserved
# verbatim including user comments and table layout.
LORE_BEGIN_MARKER="# >>> lore hooks (managed) — do not edit between markers"
LORE_END_MARKER="# <<< lore hooks (managed)"

# Ensure the active framework is codex; install callers pass --framework and
# runtime callers resolve from Codex markers or LORE_FRAMEWORK.
require_codex() {
  local active
  active="${TARGET_FRAMEWORK:-}"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework 2>/dev/null) || active=""
  fi
  if [[ "$active" != "codex" ]]; then
    echo "Error: adapters/codex/hooks.sh requires active framework=codex (got '$active')" >&2
    echo "       pass --framework codex or set LORE_FRAMEWORK=codex for this process" >&2
    return 1
  fi
}

resolve_settings_path() {
  local settings_path
  if ! settings_path=$(resolve_harness_install_path settings "${TARGET_FRAMEWORK:-}" 2>/dev/null); then
    echo "Error: resolve_harness_install_path settings failed for codex" >&2
    return 1
  fi
  if [[ "$settings_path" == "unsupported" ]]; then
    echo "Error: install_paths.settings is 'unsupported' for codex (capabilities.json contract violation)" >&2
    return 1
  fi
  echo "$settings_path"
}

# Render the lore-managed TOML block. Hook commands point at the stable
# ~/.lore/scripts/<name> install symlink per checklist item 6. The
# SessionStart handlers are listed in the claude-code adapter's order:
# doctor -> auto-reindex -> mine-retrieval-misses -> load-knowledge ->
# load-work -> load-threads -> extract-session-digest. Codex launches the
# matching handlers of one event concurrently, so the order is for readers.
# (mine-retrieval-misses self-skips on codex: the transcript provider is
# partial, and the miner gates on provider status like the digest.) Lore no longer ships a Stop hook (the prior
# stop-novelty-check.py was retired 2026-05-06, and check-plan-persistence.py
# was retired 2026-05-26 — see _meta/effectiveness-journal.jsonl and the
# heuristic-vs-definite-hook entry under conventions/). PreToolUse with
# matcher=Write covers guard-work-writes.
# PreCompact and SessionEnd are not native Codex events; PreCompact
# falls back to a SessionStart bookend (pre-compact.sh on every session
# start) and SessionEnd is derived from Stop (skipped here — Stop hook
# already runs the same work).
#
# Every command carries the LORE_FRAMEWORK=codex prefix. framework.json holds a
# single framework string (last install wins), so on a multi-harness install
# every hook that resolved through it would route to whichever harness installed
# last. lib.sh::resolve_active_framework reads LORE_FRAMEWORK ahead of
# framework.json, so the prefix is what pins these hooks to codex's own
# capability profile. TUI launch preference is not process truth either, so a
# later install for another harness cannot redirect these commands.
render_lore_block() {
  cat <<'TOML'
# >>> lore hooks (managed) — do not edit between markers
# Lore rewrites the hook groups it wrote between this marker and `<<< lore
# hooks (managed)`; any other table here (Codex appends its own settings
# just above the end marker) is moved above this marker on reinstall. To
# customize a hook, add your own [[hooks.<Event>]] group outside the
# markers — Codex runs every matching group. To opt out entirely, run
# `bash adapters/codex/hooks.sh uninstall` (or re-run install.sh with
# --framework=<other>).

[[hooks.SessionStart]]

[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/doctor.sh --quiet"

[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/auto-reindex.sh"

[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex python3 ~/.lore/scripts/mine-retrieval-misses.py"

[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/load-knowledge.sh"

[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/load-work.sh"

[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/load-threads.sh"

[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex python3 ~/.lore/scripts/extract-session-digest.py"

# pre_compact fallback: Codex has no native PreCompact event, so the
# pre-compact reminder runs at SessionStart as a bookend. See
# adapters/hooks/README.md "Per-Harness Mapping" for the fallback.
[[hooks.SessionStart.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/pre-compact.sh"

[[hooks.PreToolUse]]
# `matcher` is a string matched against the tool name; Codex also matches
# apply_patch file edits on `Write` (the payload still says apply_patch).
# The `{ tool = "Write" }` inline-table form fails config load on 0.124+.
matcher = "Write"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/guard-work-writes.sh"

[[hooks.PreToolUse]]
# Current Codex maps the spawn_agent local function onto the Agent matcher.
# The hook payload retains tool_name=spawn_agent and tool_input.message;
# validate-dispatch-guidance.sh accepts only that probe-backed exact shape.
matcher = "Agent"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "LORE_FRAMEWORK=codex bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook codex"
# <<< lore hooks (managed)
TOML
}

# Rewrite config.toml without lore's managed block, keeping every table in
# it that lore did not write. Codex and the ChatGPT app add new tables at the
# end of the document but before its trailing comment, which is lore's end
# marker, so their settings ([desktop], [mcp_servers.*], [tui], hook trust
# under [hooks.state.*]) land inside the markers. A unit lore wrote is a
# [[hooks.<Event>]] group, with its [[hooks.<Event>.hooks]] handlers, whose
# every `command` runs a script under ~/.lore/scripts/ — true of every form
# this adapter has rendered, flat or nested. Any other table, with the
# comments just above it, stays where the block was. With a block argument
# (install) the fresh block is appended at the end; without one (uninstall)
# nothing is. The file is left untouched if the result would not parse as
# TOML where the original did (checked when python3 has tomllib).
rewrite_settings() {
  local settings_path="$1" lore_block="${2:-}"
  python3 - "$settings_path" "$LORE_BEGIN_MARKER" "$LORE_END_MARKER" "$lore_block" <<'PYEOF'
import os, re, shutil, sys, tempfile

settings_path, begin, end, lore_block = sys.argv[1:5]
LORE_SCRIPTS = "~/.lore/scripts/"
HEADER = re.compile(r"\s*\[")
ARRAY_HEADER = re.compile(r"\s*\[\[\s*([^\[\]]+?)\s*\]\]")
GROUP = re.compile(r"hooks\.[A-Za-z]+")
COMMAND = re.compile(r"\s*command\s*=")


def escaped(line, j):
    k = j
    while k > 0 and line[k - 1] == "\\":
        k -= 1
    return (j - k) % 2 == 1


TOP = (None, 0)


def scan(line, state):
    """(open multi-line string delimiter, open bracket depth) after `line`.

    A line starts a table header or a comment only at TOP: outside any
    multi-line string and any array or inline table spanning lines."""
    delim, depth = state
    i, n = 0, len(line)
    while i < n:
        if delim:
            j = line.find(delim, i)
            while delim == '"""' and j > 0 and escaped(line, j):
                j = line.find(delim, j + 1)
            if j < 0:
                return (delim, depth)
            j += 3
            # A closing delimiter may carry up to two content quotes before it.
            for _ in range(2):
                if j < n and line[j] == delim[0]:
                    j += 1
            i, delim = j, None
            continue
        c = line[i]
        if c == "#":
            break
        if line.startswith('"""', i) or line.startswith("'''", i):
            delim = line[i:i + 3]
            i += 3
        elif c == '"':
            i += 1
            while i < n and line[i] != '"':
                i += 2 if line[i] == "\\" else 1
            i += 1
        elif c == "'":
            j = line.find("'", i + 1)
            i = n if j < 0 else j + 1
        else:
            if c in "[{":
                depth += 1
            elif c in "]}":
                depth = max(0, depth - 1)
            i += 1
    return (delim, depth)


def is_comment_or_blank(line):
    s = line.strip()
    return not s or s.startswith("#")


def kept_from_region(region):
    """Lines of the managed region that lore did not write, in order."""
    lead = []      # key lines before any header: they belong to the table above
    items = []     # {"header", "lines", "commands"}
    pending = []   # comments/blank lines waiting for the next header
    state = TOP
    for line in region:
        opened = state
        state = scan(line, state)
        if opened == TOP and HEADER.match(line):
            items.append({"header": line.strip(), "lines": pending + [line], "commands": []})
            pending = []
        elif opened == TOP and is_comment_or_blank(line):
            pending.append(line)
        elif items:
            items[-1]["lines"].extend(pending + [line])
            pending = []
            if opened == TOP and COMMAND.match(line):
                items[-1]["commands"].append(line)
        else:
            # Comments before the first header are lore's own preamble.
            lead.append(line)
            pending = []
    if items:
        items[-1]["lines"].extend(pending)

    units = []
    for item in items:
        m = ARRAY_HEADER.match(item["header"])
        path = re.sub(r"\s+", "", m.group(1)) if m else None
        if units and path and units[-1]["group"] and path == units[-1]["group"] + ".hooks":
            units[-1]["items"].append(item)
            continue
        group = path if path and GROUP.fullmatch(path) else None
        units.append({"group": group, "items": [item]})

    kept = list(lead)
    for unit in units:
        commands = [c for item in unit["items"] for c in item["commands"]]
        if unit["group"] and commands and all(LORE_SCRIPTS in c for c in commands):
            continue
        lines = [line for item in unit["items"] for line in item["lines"]]
        while lines and not lines[0].strip():
            lines.pop(0)
        while lines and not lines[-1].strip():
            lines.pop()
        if kept and kept[-1].strip():
            kept.append("\n")
        kept.extend(lines)
    if kept and not kept[-1].endswith("\n"):
        kept[-1] += "\n"
    return kept


with open(settings_path, "r") as f:
    text = f.read()

out = []
region = None
state = TOP
for line in text.splitlines(keepends=True):
    stripped = line.rstrip("\n").rstrip("\r")
    if region is None:
        opened = state
        state = scan(line, state)
        if opened == TOP and stripped == begin:
            region = []
            state = TOP
        else:
            out.append(line)
    elif stripped == end:
        kept = kept_from_region(region)
        if kept and out and out[-1].strip():
            if not out[-1].endswith("\n"):
                out[-1] += "\n"
            out.append("\n")
        out.extend(kept)
        region = None
    else:
        region.append(line)
if region is not None:
    # An unterminated block: keep what lore did not write up to the end.
    out.extend(kept_from_region(region))

preserved = "".join(out).rstrip()
if lore_block:
    new_text = (preserved + "\n\n" if preserved else "") + lore_block.rstrip() + "\n"
else:
    new_text = preserved + ("\n" if out else "")

try:
    import tomllib
except ImportError:
    tomllib = None
if tomllib is not None:
    try:
        tomllib.loads(text)
        parsed_before = True
    except tomllib.TOMLDecodeError:
        parsed_before = False
    if parsed_before:
        try:
            tomllib.loads(new_text)
        except tomllib.TOMLDecodeError as exc:
            sys.exit(f"Error: rewriting {settings_path} would leave invalid TOML ({exc}); file left unchanged")

# Replace the file a symlinked config.toml points at, not the link itself.
target = os.path.realpath(settings_path)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".config.toml.")
with os.fdopen(fd, "w") as f:
    f.write(new_text)
shutil.copymode(target, tmp)
os.replace(tmp, target)
PYEOF
}

# --- Subcommand: install ---
# Inject the lore-managed block into config.toml. Idempotent: lore's hook
# groups in the existing managed block are replaced, tables lore did not
# write there move above the fresh block, and everything outside the
# markers is preserved. New file is created if config.toml does not exist
# yet.
cmd_install() {
  require_codex
  local settings_path
  settings_path=$(resolve_settings_path)
  mkdir -p "$(dirname "$settings_path")"

  local lore_block
  lore_block=$(render_lore_block)

  if [[ ! -f "$settings_path" ]]; then
    {
      echo "# Codex configuration — lore hooks injected by"
      echo "# adapters/codex/hooks.sh install."
      echo
      echo "$lore_block"
    } > "$settings_path"
    emit_degraded_notices
    return 0
  fi

  # Strip any existing lore-managed block, then append the fresh one.
  rewrite_settings "$settings_path" "$lore_block"

  emit_degraded_notices
}

# Surface degraded status (adapters/hooks/README.md checklist item 4).
# Codex has no native PreCompact event and no native subagent-completion
# blocking event; lore covers them via SessionStart bookend and the
# orchestration adapter's lead-side validator respectively. Emit one
# line per fallback event so operators see exactly what is degraded.
emit_degraded_notices() {
  echo "[lore] degraded: pre_compact via SessionStart bookend (~/.lore/scripts/pre-compact.sh) (capability=fallback)" >&2
  echo "[lore] degraded: task_completed via lead-side validator in orchestration adapter (capability=fallback)" >&2
}

# --- Subcommand: uninstall ---
# Strip lore's hook groups and the sentinel markers. User content above and
# below the markers, and any table inside them that lore did not write, is
# preserved. If config.toml does not exist, this is a no-op.
cmd_uninstall() {
  require_codex
  local settings_path
  settings_path=$(resolve_settings_path)
  if [[ ! -f "$settings_path" ]]; then
    return 0
  fi

  rewrite_settings "$settings_path"
}

# --- Subcommand: smoke ---
# Print Lore lifecycle event -> support level + native Codex hook
# (or fallback mechanism) for the active framework. Mirrors the
# claude-code adapter's output shape so tests/frameworks/hooks.bats
# can assert structurally without per-adapter format branches.
cmd_smoke() {
  require_codex
  local settings_path
  settings_path=$(resolve_settings_path 2>/dev/null) || settings_path="<unresolved>"

  echo "[codex hook adapter smoke]"
  echo "  active framework: codex"
  echo "  settings path:    $settings_path"
  echo
  echo "  Lore event           Support   Native hook (codex)"
  echo "  -------------------- --------- ----------------------------------------"
  printf '  %-20s %-9s %s\n' session_start      full      "SessionStart hook (~/.lore/scripts/{doctor,auto-reindex,load-knowledge,load-work,load-threads,extract-session-digest})"
  printf '  %-20s %-9s %s\n' user_prompt        full      "(no native UserPromptSubmit; PreToolUse matcher=Write covers lore writes)"
  printf '  %-20s %-9s %s\n' pre_tool           full      "PreToolUse hooks (Write guard; Agent/spawn_agent -> validate-dispatch-guidance.sh)"
  printf '  %-20s %-9s %s\n' post_tool          full      "(currently unused by lore; PostToolUse hook surface available)"
  printf '  %-20s %-9s %s\n' permission_request full      "PermissionRequest hook (decision.behavior=allow|deny JSON-stdout, or exit 2 to deny)"
  printf '  %-20s %-9s %s\n' pre_compact        fallback  "(no native PreCompact; SessionStart bookend -> pre-compact.sh)"
  printf '  %-20s %-9s %s\n' stop               full      "(no lore Stop hook; ephemeral builtin plans are not auto-persisted)"
  printf '  %-20s %-9s %s\n' session_end        full      "(no native SessionEnd; Stop hook covers both turn-stop and clear)"
  printf '  %-20s %-9s %s\n' task_completed     fallback  "(no native blocking event; lead-side validator via orchestration adapter, T31/T32)"
}

# --- Dispatch ---
cmd="${1:-}"
case "$cmd" in
  install)   shift; parse_adapter_args "$@"; cmd_install ;;
  uninstall) shift; parse_adapter_args "$@"; cmd_uninstall ;;
  smoke)     shift; parse_adapter_args "$@"; cmd_smoke ;;
  -h|--help|"")
    cat <<EOF >&2
Usage: $(basename "$0") <subcommand> [--framework codex]

Subcommands:
  install    Inject lore hooks into the active framework's config.toml.
  uninstall  Remove every lore-managed hook entry, preserving user content.
  smoke      Print Lore lifecycle event -> native hook mapping for
             the active framework (codex only).

Refer to adapters/hooks/README.md for the full hook adapter contract.
EOF
    [[ -z "$cmd" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$cmd' (allowed: install, uninstall, smoke)" >&2
    exit 1
    ;;
esac
