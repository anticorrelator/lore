"""pk_resolve: Backlink resolver and file path resolution for lore knowledge stores.

Extracted from pk_search.py. Provides:
    Resolver — resolve [[backlink]] syntax to content
    resolve_read_path — resolve a file argument to an absolute path
    BACKLINK_RE — compiled regex for [[type:target#heading]] syntax

Used by: pk_search.py (LinkChecker, CLI), staleness-scan.py
"""

import os
import re
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants (shared with pk_search.py)
# ---------------------------------------------------------------------------

CATEGORY_DIRS = {"abstractions", "architecture", "conventions", "gotchas", "principles", "workflows", "domains"}
SKIP_FILES = {"_inbox.md", "_index.md", "_meta.md", "_meta.json", "_index.json", "_self_test_results.md", "_manifest.json"}

# Backlink patterns:
#   [[knowledge:file#heading]]  -> extract section from knowledge file
#   [[knowledge:file]]          -> return full knowledge file
#   [[work:slug]]               -> return plan.md + notes.md for work item
#   [[work:slug#heading]]       -> extract section from plan.md
#   [[plan:slug]]               -> deprecated alias for [[work:slug]]
#   [[plan:slug#heading]]       -> deprecated alias for [[work:slug#heading]]
#   [[thread:slug]]             -> return all entries from thread directory (or monolithic file)
#   [[thread:slug#date]]        -> return specific entry file (e.g. [[thread:how-we-work#2026-02-06-s6]])

BACKLINK_RE = re.compile(
    r"\[\[(?P<type>knowledge|work|plan|thread):(?P<target>[^\]#]+)(?:#(?P<heading>[^\]]+))?\]\]"
)


# ---------------------------------------------------------------------------
# Filename <-> heading conversion (duplicated from Indexer for independence)
# ---------------------------------------------------------------------------

def filename_to_heading(fname: str) -> str:
    """Reconstruct a thread entry heading from its filename.

    2026-02-06.md           -> 2026-02-06
    2026-02-06-s6.md        -> 2026-02-06 (Session 6)
    2026-02-07-s14-continued.md -> 2026-02-07 (Session 14, continued)
    2026-02-07-s14-2.md     -> 2026-02-07 (Session 14)
    """
    base = fname.replace(".md", "")
    date = base[:10]
    rest = base[10:]

    if not rest:
        return date

    rest = rest.lstrip("-")
    m = re.match(r"^s(\d+)(-.*)?$", rest)
    if m:
        session_num = m.group(1)
        suffix = m.group(2) or ""
        if not suffix:
            return f"{date} (Session {session_num})"
        elif re.match(r"^-\d+$", suffix):
            # Disambiguation suffix
            return f"{date} (Session {session_num})"
        else:
            qualifier = suffix.lstrip("-").replace("-", " ")
            return f"{date} (Session {session_num}, {qualifier})"

    return date


# ---------------------------------------------------------------------------
# Backlink Resolver
# ---------------------------------------------------------------------------

class Resolver:
    """Resolve [[backlink]] syntax to content."""

    def __init__(self, knowledge_dir: str):
        self.knowledge_dir = os.path.abspath(knowledge_dir)
        self._script_dir = os.path.dirname(os.path.abspath(__file__))

    def _get_extract_section(self):
        """Import extract_section from the same directory."""
        sys.path.insert(0, self._script_dir)
        try:
            from extract_section import extract_section
            return extract_section
        finally:
            sys.path.pop(0)

    def resolve(self, backlink: str) -> dict:
        """Resolve a single backlink to its content.

        Args:
            backlink: A backlink string like '[[knowledge:architecture#Section-Level Retrieval]]'

        Returns:
            dict with keys: backlink, resolved (bool), source_type, target, heading, content, error
        """
        match = BACKLINK_RE.search(backlink)
        if not match:
            return {
                "backlink": backlink,
                "resolved": False,
                "error": f"Invalid backlink syntax: {backlink}",
            }

        source_type = match.group("type")
        target = match.group("target").strip()
        heading = match.group("heading")
        if heading:
            heading = heading.strip()

        file_path, is_archived = self._resolve_path(source_type, target)
        if not file_path:
            return {
                "backlink": backlink,
                "resolved": False,
                "source_type": source_type,
                "target": target,
                "heading": heading,
                "error": f"Target not found: {source_type}:{target}",
            }

        # v2 thread directory: resolve entries from directory
        if source_type == "thread" and os.path.isdir(file_path):
            content = self._resolve_thread_dir(file_path, heading)
            if content is None:
                return {
                    "backlink": backlink,
                    "resolved": False,
                    "source_type": source_type,
                    "target": target,
                    "heading": heading,
                    "error": f"Entry '{heading}' not found in thread {target}",
                }
        # Knowledge category directory: list entries or find by H1
        elif source_type == "knowledge" and os.path.isdir(file_path):
            content = self._resolve_category_dir(file_path, heading)
            if content is None:
                return {
                    "backlink": backlink,
                    "resolved": False,
                    "source_type": source_type,
                    "target": target,
                    "heading": heading,
                    "error": f"Entry '{heading}' not found in category {target}",
                }
        elif heading:
            extract_section = self._get_extract_section()
            content = extract_section(file_path, heading)
            if content is None:
                return {
                    "backlink": backlink,
                    "resolved": False,
                    "source_type": source_type,
                    "target": target,
                    "heading": heading,
                    "error": f"Heading '{heading}' not found in {target}",
                }
        else:
            try:
                content = Path(file_path).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as e:
                return {
                    "backlink": backlink,
                    "resolved": False,
                    "source_type": source_type,
                    "target": target,
                    "error": str(e),
                }

        result = {
            "backlink": backlink,
            "resolved": True,
            "source_type": source_type,
            "target": target,
            "heading": heading,
            "content": content.strip(),
        }
        if is_archived:
            result["archived"] = True
        return result

    def _resolve_thread_dir(self, thread_dir: str, heading: str | None) -> str | None:
        """Resolve content from a v2 thread directory.

        Without heading: concatenate all entries (newest first) with ## headings.
        With heading: find the matching entry file by reconstructing headings from filenames.

        Returns content string, or None if heading specified but not found.
        """
        entry_files = sorted(
            [f for f in os.listdir(thread_dir) if f.endswith(".md")],
            reverse=True,
        )

        if not entry_files:
            return "" if heading is None else None

        if heading is None:
            # No heading: concatenate all entries with reconstructed ## headings
            parts = []
            for fname in entry_files:
                fpath = os.path.join(thread_dir, fname)
                try:
                    body = Path(fpath).read_text(encoding="utf-8").strip()
                except (OSError, UnicodeDecodeError):
                    continue
                entry_heading = filename_to_heading(fname)
                parts.append(f"## {entry_heading}\n{body}")
            return "\n\n".join(parts)
        else:
            # Heading specified: find matching entry file
            for fname in entry_files:
                entry_heading = filename_to_heading(fname)
                if entry_heading == heading:
                    fpath = os.path.join(thread_dir, fname)
                    try:
                        return Path(fpath).read_text(encoding="utf-8").strip()
                    except (OSError, UnicodeDecodeError):
                        return None

            # Also try matching against the filename stem directly
            for fname in entry_files:
                stem = fname.replace(".md", "")
                if stem == heading:
                    fpath = os.path.join(thread_dir, fname)
                    try:
                        return Path(fpath).read_text(encoding="utf-8").strip()
                    except (OSError, UnicodeDecodeError):
                        return None

            return None

    def _resolve_category_dir(self, category_dir: str, heading: str | None) -> str | None:
        """Resolve content from a knowledge category directory.

        Without heading: list all entry H1 titles.
        With heading: find the entry file whose H1 matches and return its content.

        Returns content string, or None if heading specified but not found.
        """
        entry_files = sorted(
            [f for f in os.listdir(category_dir) if f.endswith(".md") and f not in SKIP_FILES],
        )

        if not entry_files:
            return "" if heading is None else None

        if heading is None:
            # No heading: list all entry titles
            titles = []
            for fname in entry_files:
                fpath = os.path.join(category_dir, fname)
                try:
                    with open(fpath, encoding="utf-8") as f:
                        first_line = f.readline().strip()
                except (OSError, UnicodeDecodeError):
                    continue
                if first_line.startswith("# "):
                    titles.append(f"- {first_line[2:]}")
                else:
                    titles.append(f"- {fname.replace('.md', '')}")
            return "\n".join(titles)
        else:
            # Heading specified: find entry whose H1 matches
            for fname in entry_files:
                fpath = os.path.join(category_dir, fname)
                try:
                    content = Path(fpath).read_text(encoding="utf-8")
                except (OSError, UnicodeDecodeError):
                    continue
                first_line = content.split("\n", 1)[0].strip()
                if first_line.startswith("# ") and first_line[2:].strip() == heading:
                    return content.strip()
            return None

    def resolve_batch(self, backlinks: list[str]) -> list[dict]:
        """Resolve multiple backlinks. Returns list of resolve results."""
        return [self.resolve(bl) for bl in backlinks]

    def _resolve_path(self, source_type: str, target: str) -> tuple[str | None, bool]:
        """Convert source_type + target to an absolute file path.

        Returns:
            Tuple of (file_path, is_archived). is_archived is True when a work item
            was found in _work/_archive/ rather than _work/.

        Note: source_type "plan" is a deprecated alias for "work" — both resolve
        against _work/ and _work/_archive/.
        """
        if source_type == "knowledge":
            # If target is a bare category name (e.g. "gotchas"), return the
            # category directory itself so resolve() can list/search entries.
            if target in CATEGORY_DIRS:
                cat_dir = os.path.join(self.knowledge_dir, target)
                if os.path.isdir(cat_dir):
                    return cat_dir, False

            # If target contains a path separator (e.g. "architecture/service-mesh"),
            # try it directly as a category/slug path
            if "/" in target:
                for candidate in (
                    os.path.join(self.knowledge_dir, f"{target}.md"),
                    os.path.join(self.knowledge_dir, target),
                ):
                    if os.path.isfile(candidate):
                        return candidate, False

            # Search category directories for a matching entry file
            for cat_dir in sorted(CATEGORY_DIRS):
                candidate = os.path.join(self.knowledge_dir, cat_dir, f"{target}.md")
                if os.path.isfile(candidate):
                    return candidate, False

            # Legacy fallback: root-level files and domains/
            for candidate in (
                os.path.join(self.knowledge_dir, f"{target}.md"),
                os.path.join(self.knowledge_dir, f"{target}"),
                os.path.join(self.knowledge_dir, "domains", f"{target}.md"),
            ):
                if os.path.isfile(candidate):
                    return candidate, False

        elif source_type in ("work", "plan"):
            # "plan" is a deprecated alias for "work" — both resolve to _work/
            # Check active work items first
            work_item_dir = os.path.join(self.knowledge_dir, "_work", target)
            if os.path.isdir(work_item_dir):
                for fname in ("plan.md", "notes.md"):
                    candidate = os.path.join(work_item_dir, fname)
                    if os.path.isfile(candidate):
                        return candidate, False
            # Fall back to archived work items
            archive_dir = os.path.join(self.knowledge_dir, "_work", "_archive", target)
            if os.path.isdir(archive_dir):
                for fname in ("plan.md", "notes.md"):
                    candidate = os.path.join(archive_dir, fname)
                    if os.path.isfile(candidate):
                        return candidate, True

        elif source_type == "thread":
            # v2: directory per thread
            thread_dir = os.path.join(self.knowledge_dir, "_threads", target)
            if os.path.isdir(thread_dir):
                return thread_dir, False
            # v1 fallback: monolithic file
            candidate = os.path.join(self.knowledge_dir, "_threads", f"{target}.md")
            if os.path.isfile(candidate):
                return candidate, False

        return None, False


# ---------------------------------------------------------------------------
# File path resolution (for CLI read command)
# ---------------------------------------------------------------------------

def resolve_read_path(knowledge_dir: str, file_arg: str, source_type: str | None = None) -> str | None:
    """Resolve a file argument to an absolute path within the knowledge dir.

    Handles:
    - domains/topic -> $KDIR/domains/topic.md
    - _threads/slug or thread slug with --type thread -> $KDIR/_threads/slug/ (v2) or $KDIR/_threads/slug.md (v1)
    - plain name -> $KDIR/name.md
    - Already absolute paths
    """
    # If it's already an absolute path and exists
    if os.path.isabs(file_arg) and os.path.isfile(file_arg):
        return file_arg

    # Strip .md extension if provided (we'll add it back)
    base = file_arg
    if base.endswith(".md"):
        base = base[:-3]

    # Thread source type
    if source_type == "thread":
        # v2: try directory first
        candidate_dir = os.path.join(knowledge_dir, "_threads", base)
        if os.path.isdir(candidate_dir):
            return candidate_dir
        # v1: try monolithic file
        candidate = os.path.join(knowledge_dir, "_threads", f"{base}.md")
        if os.path.isfile(candidate):
            return candidate
        # Try stripping _threads/ prefix if user included it
        if base.startswith("_threads/"):
            stripped = base[len("_threads/"):]
            candidate_dir = os.path.join(knowledge_dir, "_threads", stripped)
            if os.path.isdir(candidate_dir):
                return candidate_dir
            candidate = os.path.join(knowledge_dir, f"{base}.md")
            if os.path.isfile(candidate):
                return candidate

    # Try candidates in order
    candidates = []

    # If file_arg already has a path prefix (e.g. architecture/service-mesh)
    if "/" in base:
        candidates.append(os.path.join(knowledge_dir, f"{base}.md"))
        candidates.append(os.path.join(knowledge_dir, base))

    # Search category directories for entry files
    for cat_dir in sorted(CATEGORY_DIRS):
        candidates.append(os.path.join(knowledge_dir, cat_dir, f"{base}.md"))

    # Legacy: root-level and domains/
    candidates.extend([
        os.path.join(knowledge_dir, f"{base}.md"),
        os.path.join(knowledge_dir, base) if not base.endswith(".md") else None,
        os.path.join(knowledge_dir, "domains", f"{base}.md"),
        os.path.join(knowledge_dir, "_threads", f"{base}.md"),
    ])

    for c in candidates:
        if c and os.path.isfile(c):
            return c

    return None
