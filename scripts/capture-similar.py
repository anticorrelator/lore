#!/usr/bin/env python3
"""capture-similar: report existing knowledge entries similar to one capture just filed.

Scores the filed entry against every other knowledge entry by TF-IDF cosine
similarity — the metric `lore analyze merge-candidates` reports, over the same
stored vectors, with HTML comments (the metadata footer) left out of the text on
both sides — and prints one line per entry at or above the threshold, most
similar first:

    [capture] similar entry: <category/relative/path.md> (similarity 0.NN)

Entries filed since the search index last ran have no stored vector yet; they are
weighed from their current text in the same vector space, so a capture made a
minute ago still counts. Only live entries are named — a path that no longer
exists, or an entry whose status default search withholds (retired, superseded,
historical, resolved, expired), is not a near-duplicate worth reading.

When the check cannot run, exactly one line is printed instead:

    [capture] similarity check skipped: <reason>

An absent check must never read as "no similar entries". The exit status is 0
either way: the entry is already filed and nothing here may fail the capture.

--json prints {"similar": [{"path": ..., "similarity": ...}, ...]} on success
and {"similar": null, "skipped": "<reason>"} when the check could not run.

Usage:
    capture-similar.py --kdir <store> --entry <path> [--threshold N] [--limit N] [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pk_concordance import (  # noqa: E402
    SIMILAR_ENTRY_THRESHOLD,
    Concordance,
    sparse_cosine_similarity,
)
from pk_markdown import MarkdownParser  # noqa: E402
from pk_search import (  # noqa: E402
    CATEGORY_DIRS,
    DB_FILENAME,
    DEFAULT_STATUS_FILTER,
    SKIP_DIRS,
    SKIP_FILES,
    IndexLockBusy,
    IndexWriteLock,
)

DEFAULT_THRESHOLD = SIMILAR_ENTRY_THRESHOLD
DEFAULT_LIMIT = 3
LOCK_WAIT_SECS = 0.5


class Skipped(Exception):
    """The check could not run; the message is the reason printed."""


def knowledge_entry_files(kdir: str) -> dict[str, str]:
    """Map store-relative path -> absolute path for every knowledge entry on disk."""
    found: dict[str, str] = {}
    for category in sorted(CATEGORY_DIRS):
        top = os.path.join(kdir, category)
        if not os.path.isdir(top):
            continue
        for root, dirs, files in os.walk(top):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                if name.endswith(".md") and name not in SKIP_FILES:
                    path = os.path.join(root, name)
                    found[os.path.relpath(path, kdir)] = path
    return found


def store_relative(path: str, kdir: str, real_kdir: str) -> str | None:
    """Path relative to the store, or None when it lies outside it.

    The index records the absolute path it was built with, and the store may be
    reached here through a different spelling of the same directory; resolving
    symlinks settles that, and only paths that do not already match pay for it.
    """
    if path.startswith(kdir + os.sep):
        return path[len(kdir) + 1:]
    real = os.path.realpath(path)
    if real.startswith(real_kdir + os.sep):
        return real[len(real_kdir) + 1:]
    return None


def is_live(path: str) -> bool:
    try:
        with open(path, encoding="utf-8") as f:
            status = MarkdownParser._extract_metadata(f.read())["entry_status"]
    except (OSError, UnicodeDecodeError):
        return False
    return not status or status in DEFAULT_STATUS_FILTER


def read_vector_space(kdir: str, db_path: str):
    """Stored vectors and a matching vectorizer, read without an index write in between.

    Indexing commits entries and their vectors in separate transactions, so a
    read between the two would pair a new vocabulary with old vectors. Holding
    the write lock rules that out.
    """
    concordance = Concordance(db_path)
    try:
        with IndexWriteLock(kdir, wait_secs=LOCK_WAIT_SECS):
            if not concordance.vectors_exclude_comments():
                raise Skipped("the search index's vectors predate footer-free similarity; the next index update rebuilds them")
            return concordance.latest_vectors(), concordance.text_vectorizer()
    except IndexLockBusy:
        raise Skipped("the search index is being rebuilt")


def find_similar(kdir: str, entry_path: str, threshold: float, limit: int) -> list[dict]:
    kdir = os.path.abspath(kdir)
    db_path = os.path.join(kdir, DB_FILENAME)
    if not os.path.exists(db_path):
        raise Skipped("no search index in this store yet")

    parsed = MarkdownParser.parse_entry_file(entry_path)
    if not parsed:
        raise Skipped("the filed entry could not be read back")
    entry_rel = os.path.relpath(os.path.abspath(entry_path), kdir)

    on_disk = knowledge_entry_files(kdir)
    stored, vectorize = read_vector_space(kdir, db_path)
    if not stored:
        raise Skipped("the search index holds no entry vectors")

    real_kdir = os.path.realpath(kdir)
    candidates: dict[str, dict[int, float]] = {}
    for (file_path, _heading), vec in stored.items():
        rel = store_relative(file_path, kdir, real_kdir)
        if rel is not None and rel in on_disk:
            candidates[rel] = vec
    if not candidates:
        raise Skipped("the search index describes entries this store no longer has")

    for rel, path in on_disk.items():
        if rel not in candidates and rel != entry_rel:
            unindexed = MarkdownParser.parse_entry_file(path)
            if unindexed:
                candidates[rel] = vectorize(unindexed[0]["content"])
    candidates.pop(entry_rel, None)

    query = vectorize(parsed[0]["content"])
    scored = []
    for rel, vec in candidates.items():
        similarity = sparse_cosine_similarity(query, vec)
        if similarity >= threshold:
            scored.append({"path": rel, "similarity": round(similarity, 2)})
    scored.sort(key=lambda s: (-s["similarity"], s["path"]))
    return [s for s in scored if is_live(on_disk[s["path"]])][:limit]


def report_skip(reason: str, as_json: bool) -> int:
    reason = " ".join(reason.split()) or "unknown error"
    if as_json:
        print(json.dumps({"similar": None, "skipped": reason}))
    else:
        print(f"[capture] similarity check skipped: {reason}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Report knowledge entries similar to a just-filed capture.")
    parser.add_argument("--kdir", required=True)
    parser.add_argument("--entry", required=True)
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        similar = find_similar(args.kdir, args.entry, args.threshold, args.limit)
    except Skipped as e:
        return report_skip(str(e), args.json)
    except Exception as e:
        return report_skip(f"{type(e).__name__}: {e}", args.json)

    if args.json:
        print(json.dumps({"similar": similar}))
    else:
        for s in similar:
            print(f"[capture] similar entry: {s['path']} (similarity {s['similarity']:.2f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
