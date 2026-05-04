#!/usr/bin/env bash
# export-obsidian.sh — One-way export of the lore knowledge store into an
# Obsidian-flavor vault. Stateless full re-export; mode-flag driven.
#
# Modes:
#   --init <vault-path>           Write user-config + vault marker, seed
#                                 .obsidian/graph.json (first write only),
#                                 then run --full
#   [<vault-path>] --full         Authoritative reconciliation (whole tree, includes deletes)
#                                 [--allow-collisions]   (deprecated no-op; D6)
#   --file <source-path>          Per-file projection into the configured vault
#   --work-hubs                   Regenerate hub notes only into the configured vault
#   --help, -h                    Print usage
#
# Vault config:    ~/.lore/config/obsidian.json (`schema_version`, `vault_path`, `repo_path`)
# Vault marker:    <vault>/.lore-obsidian-mirror.json
#                  (`schema_version`, `initialized_at`, `repo_path`, `mirror_ignore`)
#
# Filtering mechanisms — orthogonal, do not conflate (D5):
#   `mirror_ignore` (in the vault marker) is an EXPORT-PIPELINE-LEVEL opt-out:
#   matching source paths are not mirrored into the vault at all. It governs
#   what gets written.
#   `<vault>/.obsidian/graph.json` "search" filter (seeded once at --init; D3)
#   is GRAPH-VIEW-LEVEL: matching files ARE mirrored but are not drawn in the
#   graph view. It governs what is rendered.
#   Both are reserved for future per-deployment customization; collapsing them
#   would lose the early-vs-late distinction.
#
# This is the sole engine — capture/work/renormalize trigger sites all call here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

LORE_DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
CONFIG_FILE="$LORE_DATA_DIR/config/obsidian.json"
MARKER_BASENAME=".lore-obsidian-mirror.json"
SCHEMA_VERSION=1

usage() {
  cat >&2 <<EOF
export-obsidian.sh — mirror lore knowledge store into an Obsidian vault

Usage:
  export-obsidian.sh --init <vault-path>
      Write ~/.lore/config/obsidian.json and the vault marker, then run --full.

  export-obsidian.sh [<vault-path>] --full [--allow-collisions]
      Authoritative whole-tree reconciliation. <vault-path> overrides the
      configured vault for one-off exports. --allow-collisions is a
      deprecated no-op kept for one release; passing it prints a stderr
      notice and is otherwise ignored.

  export-obsidian.sh --file <source-path>
      Per-file projection. Reads vault from config; exits 0 silently if
      the mirror is not configured (designed for hook-fired use).

  export-obsidian.sh --work-hubs
      Regenerate the work + archive hub notes only. Reads vault from config;
      exits 0 silently if the mirror is not configured.

  export-obsidian.sh --help
      Show this help.

Vault config: $CONFIG_FILE
Vault marker: <vault>/$MARKER_BASENAME
EOF
}

die_user() {
  echo "Error: $*" >&2
  exit 1
}

# --- arg parse ---
# ALLOW_COLLISIONS is initialized to 0 unconditionally so `set -u` never sees
# an unbound reference even when --allow-collisions isn't passed.
MODE=""
INIT_PATH=""
FILE_ARG=""
EXPLICIT_VAULT=""
ALLOW_COLLISIONS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --init)
      [[ -n "${2:-}" ]] || die_user "--init requires <vault-path>"
      MODE="init"
      INIT_PATH="$2"
      shift 2
      ;;
    --full)
      MODE="full"
      shift
      ;;
    --file)
      [[ -n "${2:-}" ]] || die_user "--file requires <source-path>"
      MODE="file"
      FILE_ARG="$2"
      shift 2
      ;;
    --work-hubs)
      MODE="work-hubs"
      shift
      ;;
    --allow-collisions)
      # D6: deprecated no-op. Folder-path translation (D1) makes vault-path
      # collisions impossible by construction, so the collision check should
      # never fire and the flag has nothing to override. Accepted for one
      # release with a stderr deprecation notice; remove later.
      echo "[export-obsidian] --allow-collisions is now a no-op (folder-path links eliminate the collision class); flag will be removed in a future release" >&2
      ALLOW_COLLISIONS=1
      shift
      ;;
    -*)
      echo "Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$EXPLICIT_VAULT" ]]; then
        echo "Error: unexpected positional argument '$1' (vault path already set to '$EXPLICIT_VAULT')" >&2
        exit 1
      fi
      EXPLICIT_VAULT="$1"
      shift
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Error: a mode flag is required (--init, --full, --file, or --work-hubs)" >&2
  usage
  exit 1
fi

# --- KDIR ---
KDIR="$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null || true)"
if [[ -z "$KDIR" ]]; then
  die_user "could not resolve knowledge directory (not in a lore-aware repo?)"
fi

# --- Mode dispatch ---
case "$MODE" in
  init)
    # Write config + marker, then run --full against the freshly-initialized vault.
    if [[ ! -d "$INIT_PATH" ]]; then
      mkdir -p "$INIT_PATH"
    fi
    VAULT_ABS="$(cd "$INIT_PATH" && pwd)"
    REPO_ABS="$KDIR"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    NOW="$(timestamp_iso)"
    python3 - "$CONFIG_FILE" "$VAULT_ABS" "$REPO_ABS" "$SCHEMA_VERSION" <<'PY'
import json, sys
config_file, vault_path, repo_path, schema_version = sys.argv[1:5]
data = {
    "schema_version": int(schema_version),
    "vault_path": vault_path,
    "repo_path": repo_path,
}
with open(config_file, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
    MARKER_FILE="$VAULT_ABS/$MARKER_BASENAME"
    python3 - "$MARKER_FILE" "$REPO_ABS" "$NOW" "$SCHEMA_VERSION" <<'PY'
import json, sys
marker_file, repo_path, ts, schema_version = sys.argv[1:5]
data = {
    "schema_version": int(schema_version),
    "initialized_at": ts,
    "repo_path": repo_path,
    "mirror_ignore": [],
}
with open(marker_file, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
    # Seed .obsidian/graph.json on first init only (D3) — never touch an
    # existing graph.json so user customizations made inside Obsidian persist.
    OBSIDIAN_DIR="$VAULT_ABS/.obsidian"
    GRAPH_FILE="$OBSIDIAN_DIR/graph.json"
    if [[ ! -e "$GRAPH_FILE" ]]; then
      mkdir -p "$OBSIDIAN_DIR"
      python3 - "$GRAPH_FILE" <<'PY'
import json, sys
graph_file = sys.argv[1]
data = {
    "search": "-path:\"_work/\" -path:\"_threads/\"",
}
with open(graph_file, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
      echo "[export-obsidian] seeded:           $GRAPH_FILE"
    fi
    echo "[export-obsidian] initialized vault: $VAULT_ABS"
    echo "[export-obsidian] config:           $CONFIG_FILE"
    echo "[export-obsidian] marker:           $MARKER_FILE"
    # Fall through to full export against this vault.
    EXPLICIT_VAULT="$VAULT_ABS"
    MODE="full"
    ;;
esac

# --- Resolve vault for non-init modes ---
# Returns: empty string when no config and no explicit; else absolute vault path.
resolve_vault() {
  if [[ -n "$EXPLICIT_VAULT" ]]; then
    echo "$EXPLICIT_VAULT"
    return 0
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    python3 - "$CONFIG_FILE" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    p = d.get("vault_path")
    if isinstance(p, str) and p:
        print(p)
except Exception:
    pass
PY
    return 0
  fi
  echo ""
}

VAULT="$(resolve_vault)"

case "$MODE" in
  file|work-hubs)
    # Hook-scoped modes exit 0 silently when no vault is configured.
    if [[ -z "$VAULT" ]]; then
      exit 0
    fi
    ;;
  full)
    if [[ -z "$VAULT" ]]; then
      die_user "no vault configured — run \`lore export-obsidian --init <vault-path>\` first, or pass an explicit <vault-path>"
    fi
    ;;
esac

# Marker check (only needed when we will write or delete).
require_marker() {
  local vault="$1"
  local marker="$vault/$MARKER_BASENAME"
  if [[ ! -f "$marker" ]]; then
    die_user "vault not initialized — run \`lore export-obsidian --init $vault\` first (no marker at $marker)"
  fi
  local marker_repo
  marker_repo=$(python3 - "$marker" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    p = d.get("repo_path")
    if isinstance(p, str):
        print(p)
except Exception:
    pass
PY
  )
  if [[ -z "$marker_repo" ]]; then
    die_user "vault marker is malformed (no repo_path): $marker"
  fi
  if [[ "$marker_repo" != "$KDIR" ]]; then
    die_user "vault belongs to a different repo (marker repo_path=$marker_repo, current=$KDIR); refusing to write"
  fi
}

case "$MODE" in
  full|file|work-hubs)
    require_marker "$VAULT"
    ;;
esac

# --- Run the engine ---
# All translation, synthesis, deletion reconciliation, and collision detection
# live in a single Python pass. Bash supplies args; Python does the work.
export LORE_KDIR="$KDIR"
export LORE_VAULT="$VAULT"
export LORE_MODE="$MODE"
export LORE_FILE_ARG="$FILE_ARG"
export LORE_MARKER_BASENAME="$MARKER_BASENAME"

python3 - <<'PY_ENGINE'
"""
Obsidian export engine.

Modes:
  full        Walk source tree, produce vault tree, reconcile (write + delete).
  file        Per-file projection of one source path into the vault.
  work-hubs   Regenerate hub notes only.

Inputs from env:
  LORE_KDIR, LORE_VAULT, LORE_MODE, LORE_FILE_ARG, LORE_MARKER_BASENAME

Per the plan's D-decisions (D1, D5, D6, D7, D8, D9, D10, D11, D12).
"""
import json
import os
import re
import sys
from pathlib import Path

KDIR = Path(os.environ["LORE_KDIR"]).resolve()
VAULT = Path(os.environ["LORE_VAULT"]).resolve()
MODE = os.environ["LORE_MODE"]
FILE_ARG = os.environ.get("LORE_FILE_ARG", "")
MARKER_BASENAME = os.environ["LORE_MARKER_BASENAME"]

# Top-level source directories to mirror as knowledge categories.
# Anything starting with "_" is reserved (work, threads, internal); we do
# explicit handling for _work and _threads, and skip the rest.
EXCLUDED_KNOWLEDGE_DIRS = {
    "_batch-runs", "_calibration", "_edge_synopses", "_followups", "_inbox",
    "_meta", "_meta_bak", "_renormalize", "_scorecards", "_threads",
    "_work-queue", "_work",
}
# Files in $KDIR root that aren't knowledge entries.
EXCLUDED_KNOWLEDGE_ROOT_FILES = {
    "_branch_cache.json", "_capture_log.csv", "_evaluated_ranges.json",
    "_followup_index.json", "_index.db", "_inbox.md", "_manifest.json",
    "_self_test_results.md", "config.json",
}

# Source sidecar bases consumed for the consolidated work file (D2).
# Order matches the H2 section order in the emitted vault file:
# plan → notes → execution-log → evidence. Missing source files produce no
# section (no empty H2 header).
WORK_SECTION_ORDER = [
    ("plan", "Plan"),
    ("notes", "Notes"),
    ("execution-log", "Execution log"),
    ("evidence", "Evidence"),
]


# --- HTML footer extraction (D8) ----------------------------------------

LEARNED_COMMENT_RE = re.compile(r"<!--\s*(learned:.*?)-->", re.DOTALL)


def parse_footer_meta(body: str) -> dict:
    """
    Find the canonical `<!-- learned: ... -->` comment (the one led by
    `learned:`), parse its `key: value | key: value` payload into a dict.
    Returns {} if no learned-led comment is found.

    Handles double-comment case where `<!-- source: renormalize-backlinks -->`
    sits before the canonical comment.
    """
    m = LEARNED_COMMENT_RE.search(body)
    if not m:
        return {}
    payload = m.group(1).strip()
    fields = {}
    for piece in payload.split("|"):
        piece = piece.strip()
        if not piece:
            continue
        if ":" not in piece:
            continue
        key, _, value = piece.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def strip_footer_and_backlinks(body: str) -> str:
    """
    Strip trailing footer comments and `See also:` lines from the body so
    the vault note shows only narrative text (links are preserved as a
    body section by `convert_links` callers).
    """
    lines = body.splitlines()
    # Remove all trailing HTML-comment lines plus any `See also:` lines that
    # immediately precede them (renormalize-backlinks pattern).
    while lines:
        last = lines[-1].strip()
        if not last:
            lines.pop()
            continue
        if last.startswith("<!--") and last.endswith("-->"):
            lines.pop()
            continue
        if last.startswith("See also:"):
            lines.pop()
            continue
        break
    return "\n".join(lines).rstrip() + "\n"


# --- frontmatter (D8) ---------------------------------------------------

# Fields that should always be encoded as YAML lists when present.
LIST_FIELDS = {"scale", "branches"}
# Comma-separated free-form fields (kept as scalar string in v1 unless
# explicitly LIST_FIELDS).
COMMA_FIELDS = {"related_files", "source_artifact_ids"}


def yaml_scalar(value):
    """
    Quote a YAML scalar conservatively: simple strings unquoted unless they
    contain reserved chars, then double-quoted with `\\` and `"` escaped.
    """
    if value is None:
        return '""'
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    s = str(value)
    if s == "":
        return '""'
    needs_quote = bool(re.search(r'[:#\[\]\{\}&\*!|>\'"%@`,]', s)) or s.strip() != s or s.lower() in {"yes", "no", "true", "false", "null", "~"}
    if not needs_quote:
        return s
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def yaml_list(items):
    return "[" + ", ".join(yaml_scalar(x) for x in items) + "]"


def normalize_related_files(raw: str) -> list:
    """
    Split comma-separated related_files; strip absolute paths to basenames
    (D8: absolute paths in `related_files` stripped to repo-relative basenames).
    Repo-relative paths are kept verbatim.
    """
    out = []
    for piece in raw.split(","):
        p = piece.strip()
        if not p:
            continue
        if p.startswith("/"):
            # Strip absolute prefix down to a repo-relative shape if possible.
            try:
                rel = os.path.relpath(p, str(KDIR))
                if not rel.startswith(".."):
                    out.append(rel)
                    continue
            except ValueError:
                pass
            out.append(os.path.basename(p))
        else:
            out.append(p)
    return out


def render_frontmatter(meta: dict, extra: dict | None = None) -> str:
    """
    Render a YAML frontmatter block. `meta` keys come from the HTML footer
    or work _meta.json; `extra` overlays vault-only fields (e.g. lore_managed).
    """
    fields = dict(meta)
    if extra:
        fields.update(extra)
    if not fields:
        return ""
    lines = ["---"]
    for key, value in fields.items():
        if key in LIST_FIELDS:
            if isinstance(value, list):
                items = value
            else:
                items = [v.strip() for v in str(value).split(",") if v.strip()]
            lines.append(f"{key}: {yaml_list(items)}")
        elif key in COMMA_FIELDS:
            if isinstance(value, list):
                items = value
            else:
                items = [v.strip() for v in str(value).split(",") if v.strip()]
            if not items:
                continue
            lines.append(f"{key}: {yaml_list(items)}")
        elif isinstance(value, list):
            lines.append(f"{key}: {yaml_list(value)}")
        elif isinstance(value, bool):
            lines.append(f"{key}: {'true' if value else 'false'}")
        else:
            lines.append(f"{key}: {yaml_scalar(value)}")
    lines.append("---")
    lines.append("")
    return "\n".join(lines) + "\n"


# --- link translation (D1) ----------------------------------------------

# Folder-path translation rules (D1, reverses prior D9 basename strip):
#   `[[knowledge:conventions/cli/foo]]`   -> `[[conventions/cli/foo]]`
#   `[[knowledge:gotchas/hooks/bar#H]]`   -> `[[gotchas/hooks/bar#H]]`
#   `[[work:slug]]`                       -> `[[_work/slug]]`
#                                            (or `[[_work/_archive/slug]]` if known archived)
#   `[[plan:slug]]`                       -> `[[_work/slug]]`  (legacy alias)
#   `[[thread:topic]]`                    -> `[[_threads/topic/topic]]`
#   `[[type:target]]` for unknown type    : pass through unchanged
#   `[[name|display]]`                    : pass through unchanged
#   bare `[[name]]`                       : pass through unchanged

WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
TRANSLATE_PREFIXES = ("knowledge:", "work:", "plan:", "thread:")


def _archived_slugs() -> set[str]:
    """Slugs known to live under `_work/_archive/` in the source tree."""
    archive_dir = KDIR / "_work" / "_archive"
    if not archive_dir.exists():
        return set()
    return {
        entry.name
        for entry in archive_dir.iterdir()
        if entry.is_dir() and not entry.name.startswith("_")
    }


_ARCHIVED_CACHE: set[str] | None = None


def archived_slugs() -> set[str]:
    global _ARCHIVED_CACHE
    if _ARCHIVED_CACHE is None:
        _ARCHIVED_CACHE = _archived_slugs()
    return _ARCHIVED_CACHE


def translate_wikilink_inner(inner: str) -> str:
    """
    Convert one [[...]] inner token. Returns the new inner token.
    """
    # Display alias: pass through unchanged.
    if "|" in inner:
        return inner
    # Untyped: pass through.
    if ":" not in inner:
        return inner
    prefix, _, target = inner.partition(":")
    prefix_full = prefix + ":"
    if prefix_full not in TRANSLATE_PREFIXES:
        # Unknown scheme — pass through (e.g. [[type:target]]).
        return inner
    # Split off heading fragment (re-attached after rewriting the path).
    heading = ""
    if "#" in target:
        target, _, heading = target.partition("#")
    target = target.rstrip("/")
    if prefix_full == "knowledge:":
        rewritten = target
    elif prefix_full in ("work:", "plan:"):
        # plan: is a legacy alias for work: (D1).
        slug = os.path.basename(target)
        if slug in archived_slugs():
            rewritten = f"_work/_archive/{slug}"
        else:
            rewritten = f"_work/{slug}"
    elif prefix_full == "thread:":
        topic = os.path.basename(target)
        rewritten = f"_threads/{topic}/{topic}"
    else:
        rewritten = target
    if heading:
        return f"{rewritten}#{heading}"
    return rewritten


def convert_links(text: str) -> str:
    return WIKILINK_RE.sub(lambda m: f"[[{translate_wikilink_inner(m.group(1))}]]", text)


# --- knowledge entry conversion -----------------------------------------

def is_knowledge_entry(path: Path) -> bool:
    """True for category .md files (excluding category index files)."""
    if path.suffix != ".md":
        return False
    if path.name == "index.md":
        return False
    if path.name.startswith("_"):
        return False
    return True


def category_index_target(source_idx: Path) -> Path:
    """index.md -> <dirname>.md (D5)."""
    parent = source_idx.parent
    rel = parent.relative_to(KDIR)
    return VAULT / rel / f"{parent.name}.md"


def knowledge_entry_target(source: Path) -> Path:
    rel = source.relative_to(KDIR)
    return VAULT / rel


def convert_knowledge_entry(source_path: Path) -> str:
    body = source_path.read_text(encoding="utf-8", errors="replace")
    meta = parse_footer_meta(body)
    # Normalize related_files (D8: abs path strip).
    if "related_files" in meta:
        meta["related_files"] = normalize_related_files(meta["related_files"])
    if "source_artifact_ids" in meta:
        meta["source_artifact_ids"] = [s.strip() for s in meta["source_artifact_ids"].split(",") if s.strip()]
    if "scale" in meta:
        # Multi-value scale becomes a YAML list.
        meta["scale"] = [s.strip() for s in str(meta["scale"]).split(",") if s.strip()]

    cleaned = strip_footer_and_backlinks(body)
    cleaned = convert_links(cleaned)
    fm = render_frontmatter(meta, extra={"lore_managed": True})
    return fm + cleaned


def convert_category_index(source_idx: Path) -> str:
    """Pass through, but translate links and add lore_managed frontmatter."""
    body = source_idx.read_text(encoding="utf-8", errors="replace")
    body = convert_links(body)
    fm = render_frontmatter({}, extra={"lore_managed": True})
    return fm + body


def synthesize_folder_note(category_dir: Path) -> str:
    """
    For categories with no index.md, list all entries in the directory (D5).
    Emits folder-path wikilinks (D1) so links resolve uniquely under the
    full-path translation rule.
    """
    rel = category_dir.relative_to(KDIR)
    rel_str = rel.as_posix()
    title = category_dir.name
    lines = [f"# {title}", ""]
    lines.append(f"_Synthesized index for `{rel}`. Mirror-owned; user edits will be overwritten._")
    lines.append("")
    entries = []
    for child in sorted(category_dir.iterdir()):
        if child.is_dir():
            sub_rel = child.relative_to(KDIR).as_posix()
            entries.append(f"- [[{sub_rel}/{child.name}]] (subcategory)")
        elif is_knowledge_entry(child):
            entry_rel = child.relative_to(KDIR).with_suffix("").as_posix()
            entries.append(f"- [[{entry_rel}]]")
    if entries:
        lines.append("## Entries")
        lines.append("")
        lines.extend(entries)
    body = "\n".join(lines) + "\n"
    fm = render_frontmatter({}, extra={"lore_managed": True, "synthesized": True})
    return fm + body


# --- work item conversion (D2) ------------------------------------------

def parse_work_meta(work_dir: Path) -> dict:
    meta_file = work_dir / "_meta.json"
    if not meta_file.exists():
        return {}
    try:
        return json.loads(meta_file.read_text(encoding="utf-8"))
    except Exception:
        return {}


def build_consolidated_work(work_dir: Path, archive: bool) -> str:
    """
    Render one work item as a single Markdown file (D2): YAML frontmatter
    hoisted from `_meta.json`, an H1 title, then H2 sections for each
    present sidecar in plan → notes → execution-log → evidence order.
    Missing sidecars produce no header.
    """
    meta = parse_work_meta(work_dir)
    slug = meta.get("slug", work_dir.name)
    title = meta.get("title", slug)
    fm_fields = {
        "lore_managed": True,
        "title": title,
        "slug": slug,
        "status": meta.get("status", ""),
        "branches": meta.get("branches", []),
        "tags": meta.get("tags", []),
        "created": meta.get("created", ""),
        "updated": meta.get("updated", ""),
    }
    if archive:
        fm_fields["archived"] = True
    fm = render_frontmatter({}, extra=fm_fields)
    lines = [f"# {title}", ""]
    for base, heading in WORK_SECTION_ORDER:
        src = work_dir / f"{base}.md"
        if not src.exists():
            continue
        body = src.read_text(encoding="utf-8", errors="replace")
        body = convert_links(body).rstrip("\n")
        lines.append(f"## {heading}")
        lines.append("")
        lines.append(body)
        lines.append("")
    return fm + "\n".join(lines).rstrip("\n") + "\n"


def work_targets(work_dir: Path, archive: bool) -> list[tuple[Path, str]]:
    """
    Return [(target_path, content)] for one work item — a single consolidated
    file under `_work/<slug>.md` (or `_work/_archive/<slug>.md`) per D2.
    """
    rel_parent = "_work/_archive" if archive else "_work"
    slug = work_dir.name
    target = VAULT / rel_parent / f"{slug}.md"
    return [(target, build_consolidated_work(work_dir, archive))]


def synthesize_work_hub() -> tuple[Path, str]:
    """`<vault>/_work.md` lists active work items (folder-path links per D1)."""
    work_dir = KDIR / "_work"
    actives = []
    if work_dir.exists():
        for child in sorted(work_dir.iterdir()):
            if not child.is_dir():
                continue
            if child.name.startswith("_"):
                continue
            meta = parse_work_meta(child)
            actives.append((child.name, meta.get("title", child.name), meta.get("status", "")))
    fm = render_frontmatter({}, extra={"lore_managed": True, "synthesized": True})
    lines = ["# Active Work", ""]
    if actives:
        for slug, title, status in actives:
            status_suffix = f" — {status}" if status else ""
            lines.append(f"- [[_work/{slug}]] {title}{status_suffix}")
    else:
        lines.append("_No active work items._")
    return VAULT / "_work.md", fm + "\n".join(lines) + "\n"


def synthesize_archive_hubs() -> list[tuple[Path, str]]:
    """
    `<vault>/_work/_archive/_archive.md` (top hub) + per-year sub-hubs (D6).
    Folder-path links per D1.
    """
    archive_dir = KDIR / "_work" / "_archive"
    by_year: dict[str, list[tuple[str, str]]] = {}
    if archive_dir.exists():
        for child in sorted(archive_dir.iterdir()):
            if not child.is_dir():
                continue
            meta = parse_work_meta(child)
            created = meta.get("created", "") or ""
            year = created[:4] if len(created) >= 4 and created[:4].isdigit() else "unknown"
            by_year.setdefault(year, []).append((child.name, meta.get("title", child.name)))

    out = []
    for year, items in sorted(by_year.items()):
        items.sort(key=lambda x: x[0])
        fm = render_frontmatter({}, extra={"lore_managed": True, "synthesized": True, "year": year})
        lines = [f"# Archive {year}", "", f"_{len(items)} archived work items in {year}._", ""]
        for slug, title in items:
            lines.append(f"- [[_work/_archive/{slug}]] {title}")
        out.append((VAULT / "_work" / "_archive" / f"{year}.md", fm + "\n".join(lines) + "\n"))

    fm = render_frontmatter({}, extra={"lore_managed": True, "synthesized": True})
    lines = ["# Archive", "", "_Per-year hubs:_", ""]
    for year in sorted(by_year.keys()):
        lines.append(f"- [[_work/_archive/{year}]] ({len(by_year[year])} items)")
    out.append((VAULT / "_work" / "_archive" / "_archive.md", fm + "\n".join(lines) + "\n"))
    return out


# --- thread conversion --------------------------------------------------

def thread_targets(thread_dir: Path) -> list[tuple[Path, str]]:
    topic = thread_dir.name
    meta_file = thread_dir / "_meta.json"
    meta = {}
    if meta_file.exists():
        try:
            meta = json.loads(meta_file.read_text(encoding="utf-8"))
        except Exception:
            meta = {}
    out = []
    fm_fields = {
        "lore_managed": True,
        "synthesized": True,
        "topic": meta.get("topic", topic),
        "tier": meta.get("tier", ""),
        "created": meta.get("created", ""),
        "updated": meta.get("updated", ""),
        "sessions": meta.get("sessions", 0),
    }
    fm = render_frontmatter({}, extra=fm_fields)
    title = meta.get("topic", topic)
    bodies = sorted(p for p in thread_dir.iterdir() if p.is_file() and p.suffix == ".md")
    body_lines = [f"# {title}", "", f"_Thread: `{topic}`. Mirror-owned synthesized index._", ""]
    if bodies:
        body_lines.append("## Entries")
        body_lines.append("")
        for b in bodies:
            # Folder-path link (D1): `_threads/<topic>/<entry>`.
            body_lines.append(f"- [[_threads/{topic}/{b.stem}]]")
    folder_note = VAULT / "_threads" / topic / f"{topic}.md"
    out.append((folder_note, fm + "\n".join(body_lines) + "\n"))
    for b in bodies:
        target = VAULT / "_threads" / topic / b.name
        out.append((target, convert_links(b.read_text(encoding="utf-8", errors="replace"))))
    return out


# --- whole-tree planning ------------------------------------------------

def plan_full_targets() -> list[tuple[Path, str]]:
    """Compute every (target_path, content) pair for a full export."""
    targets: list[tuple[Path, str]] = []

    # Knowledge categories.
    for child in sorted(KDIR.iterdir()):
        if child.name in EXCLUDED_KNOWLEDGE_DIRS:
            continue
        if child.is_file():
            # Top-level knowledge files in a flat category at root are rare;
            # skip the canonical excluded list.
            if child.name in EXCLUDED_KNOWLEDGE_ROOT_FILES:
                continue
            if child.suffix == ".md" and child.name != "MEMORY.md":
                # Flat root entries: treat as direct knowledge entries at root.
                rel = child.relative_to(KDIR)
                targets.append((VAULT / rel, convert_knowledge_entry(child)))
            continue
        if not child.is_dir():
            continue
        targets.extend(walk_category(child))

    # Work hub + items.
    targets.append(synthesize_work_hub())
    work_dir = KDIR / "_work"
    if work_dir.exists():
        for entry in sorted(work_dir.iterdir()):
            if not entry.is_dir():
                continue
            if entry.name == "_archive":
                continue
            if entry.name.startswith("_"):
                continue
            targets.extend(work_targets(entry, archive=False))

    # Archive hubs + archive items.
    targets.extend(synthesize_archive_hubs())
    archive_dir = KDIR / "_work" / "_archive"
    if archive_dir.exists():
        for entry in sorted(archive_dir.iterdir()):
            if not entry.is_dir():
                continue
            targets.extend(work_targets(entry, archive=True))

    # Threads. Skip both `_`-prefixed (reserved/internal) and `.`-prefixed
    # (hidden, conventionally non-content; D4 — drops the dead-storage
    # `.pre-migration-backup/` directory).
    threads_dir = KDIR / "_threads"
    if threads_dir.exists():
        for entry in sorted(threads_dir.iterdir()):
            if not entry.is_dir():
                continue
            if entry.name.startswith("_"):
                continue
            if entry.name.startswith("."):
                continue
            targets.extend(thread_targets(entry))

    return targets


def walk_category(cat_dir: Path) -> list[tuple[Path, str]]:
    """Recurse a knowledge category. Index handling per D5."""
    out: list[tuple[Path, str]] = []
    has_index = (cat_dir / "index.md").exists()
    for child in sorted(cat_dir.iterdir()):
        if child.is_dir():
            out.extend(walk_category(child))
            continue
        if child.name == "index.md":
            target = category_index_target(child)
            out.append((target, convert_category_index(child)))
            continue
        if not is_knowledge_entry(child):
            continue
        target = knowledge_entry_target(child)
        out.append((target, convert_knowledge_entry(child)))
    if not has_index:
        # Synthesize folder note (D5).
        target = VAULT / cat_dir.relative_to(KDIR) / f"{cat_dir.name}.md"
        out.append((target, synthesize_folder_note(cat_dir)))
    return out


# --- collision detection (D6 — defensive trap) --------------------------

def detect_collisions(targets: list[tuple[Path, str]]) -> dict[Path, int]:
    """
    Detect distinct (target, content) pairs that share the same target path —
    i.e. two synthesized writes pointing at the same vault file. Under D1's
    folder-path translation, two source paths cannot resolve to the same
    vault path by construction; if this fires, the path-construction logic
    has a bug. Returns {path: count} for paths assigned more than once.
    """
    counts: dict[Path, int] = {}
    for target, _ in targets:
        counts[target.resolve()] = counts.get(target.resolve(), 0) + 1
    return {p: n for p, n in counts.items() if n > 1}


# --- write + reconcile --------------------------------------------------

def write_target(target: Path, content: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    # Write only when bytes changed — preserves mtime for unchanged files
    # and keeps full-export idempotent at the byte level.
    new_bytes = content.encode("utf-8")
    if target.exists():
        try:
            old = target.read_bytes()
            if old == new_bytes:
                return
        except Exception:
            pass
    target.write_bytes(new_bytes)


def vault_owned_files() -> set[Path]:
    """
    Walk the vault and return every .md file that the mirror is allowed to
    delete (per D11): everything under VAULT except `.obsidian/`, the marker
    file, and any path matched by `mirror_ignore` patterns.
    """
    marker = VAULT / MARKER_BASENAME
    ignore_patterns: list[str] = []
    if marker.exists():
        try:
            data = json.loads(marker.read_text(encoding="utf-8"))
            ignore_patterns = data.get("mirror_ignore", []) or []
        except Exception:
            ignore_patterns = []

    owned: set[Path] = set()
    for root, dirs, files in os.walk(VAULT):
        root_p = Path(root)
        # Prune .obsidian.
        dirs[:] = [d for d in dirs if not (root_p == VAULT and d == ".obsidian")]
        for f in files:
            p = root_p / f
            if p == marker:
                continue
            if p.suffix != ".md":
                # v1: mirror only writes .md. Don't claim non-.md files.
                continue
            rel = p.relative_to(VAULT).as_posix()
            if any(re.fullmatch(pat, rel) for pat in ignore_patterns):
                continue
            owned.add(p.resolve())
    return owned


# --- mode entry points --------------------------------------------------

def run_full() -> int:
    targets = plan_full_targets()

    # Collision check (D6) — defensive trap. Folder-path translation makes
    # vault-path collisions impossible by construction, so this should never
    # fire; if it does, the path-construction logic has a bug. Warning-only;
    # never aborts.
    collisions = detect_collisions(targets)
    if collisions:
        print(
            "[export-obsidian] WARNING: vault path collisions detected (this should be impossible "
            "under folder-path links; please file a bug):",
            file=sys.stderr,
        )
        for i, (path, count) in enumerate(sorted(collisions.items()), 1):
            print(f"  {i}. {path} (assigned {count} times)", file=sys.stderr)

    # Write everything.
    written = set()
    for target, content in targets:
        write_target(target, content)
        written.add(target.resolve())

    # Reconcile deletes (D10): remove vault files no longer in source.
    owned = vault_owned_files()
    stale = owned - written
    for p in sorted(stale):
        try:
            p.unlink()
        except Exception as e:
            print(f"[export-obsidian] warn: could not delete {p}: {e}", file=sys.stderr)

    # Prune empty directories.
    for root, dirs, files in os.walk(VAULT, topdown=False):
        root_p = Path(root)
        if root_p == VAULT:
            continue
        if root_p.name == ".obsidian":
            continue
        try:
            if not any(root_p.iterdir()):
                root_p.rmdir()
        except Exception:
            pass

    return 0


def run_file() -> int:
    src = Path(FILE_ARG)
    if not src.is_absolute():
        src = (Path.cwd() / src).resolve()
    else:
        src = src.resolve()
    try:
        rel = src.relative_to(KDIR)
    except ValueError:
        print(f"[export-obsidian] source path {src} is outside knowledge dir {KDIR}; skipping", file=sys.stderr)
        return 0

    parts = rel.parts
    # Determine which mirror branch this file belongs to.
    if not src.exists():
        # Source removed: try to delete the parallel vault file.
        target_guess = VAULT / rel
        if target_guess.exists():
            try:
                target_guess.unlink()
            except Exception as e:
                print(f"[export-obsidian] warn: could not delete {target_guess}: {e}", file=sys.stderr)
        return 0

    if parts and parts[0] == "_work":
        # Work item file — re-emit the whole work-item folder (cheap).
        if len(parts) >= 3 and parts[1] == "_archive":
            slug = parts[2]
            wd = KDIR / "_work" / "_archive" / slug
            for target, content in work_targets(wd, archive=True):
                write_target(target, content)
        elif len(parts) >= 2:
            slug = parts[1]
            if slug.startswith("_"):
                return 0
            wd = KDIR / "_work" / slug
            for target, content in work_targets(wd, archive=False):
                write_target(target, content)
        return 0

    if parts and parts[0] == "_threads":
        if len(parts) >= 2:
            topic = parts[1]
            td = KDIR / "_threads" / topic
            for target, content in thread_targets(td):
                write_target(target, content)
        return 0

    if parts and parts[0] in EXCLUDED_KNOWLEDGE_DIRS:
        return 0

    if src.name == "index.md":
        target = category_index_target(src)
        write_target(target, convert_category_index(src))
        return 0

    if not is_knowledge_entry(src):
        return 0

    target = knowledge_entry_target(src)
    write_target(target, convert_knowledge_entry(src))
    return 0


def run_work_hubs() -> int:
    target, content = synthesize_work_hub()
    write_target(target, content)
    for target, content in synthesize_archive_hubs():
        write_target(target, content)
    # Hub-only: re-emit each consolidated work file (D2). The _work.md hub
    # links to `[[_work/<slug>]]` so the consolidated files must exist.
    work_dir = KDIR / "_work"
    if work_dir.exists():
        for entry in sorted(work_dir.iterdir()):
            if not entry.is_dir() or entry.name.startswith("_"):
                continue
            for target, content in work_targets(entry, archive=False):
                write_target(target, content)
    archive_dir = KDIR / "_work" / "_archive"
    if archive_dir.exists():
        for entry in sorted(archive_dir.iterdir()):
            if not entry.is_dir():
                continue
            for target, content in work_targets(entry, archive=True):
                write_target(target, content)
    return 0


def main() -> int:
    if MODE == "full":
        return run_full()
    if MODE == "file":
        return run_file()
    if MODE == "work-hubs":
        return run_work_hubs()
    print(f"[export-obsidian] unknown mode: {MODE}", file=sys.stderr)
    return 1


sys.exit(main())
PY_ENGINE
