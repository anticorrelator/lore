#!/usr/bin/env python3
"""pk_work_search: the work search that search-work.sh and `lore search --type all` print.

    pk_work_search.py search [--all] [--json] -- <knowledge_dir> <query>
    pk_work_search.py all -- <query> <pk_cli.py search argv...>
    pk_work_search.py header -- <knowledge_dir> <query>
    pk_work_search.py arcs [--json] -- <knowledge_dir> <query>

`search` is search-work.sh's output once it has found the store and its _work/
directory. `all` is `lore search --type all` in text mode: the knowledge search,
a blank line, then the work search, all in one process so the searches share
one index check. `header` and `arcs` serve search-work.sh's grep fallback,
which runs when python3 has no sqlite3, so nothing here imports pk_cli until a
search needs it.
"""

import argparse
import contextlib
import io
import json
import os
import re
import subprocess
import sys


def header(knowledge_dir: str, query: str) -> bytes:
    """The search title, then the work-index lines that name the query.

    The index lines come from `grep -i`, as they always have: the query is a
    grep pattern here, unlike everywhere else in this search. The index section
    runs ahead of the FTS results because FTS indexes prose documents only, so
    _meta.json fields like project are findable solely through the index.
    """
    out = [b'=== Work Search: "' + os.fsencode(query) + b'" ===\n\n']
    index_path = os.path.join(knowledge_dir, "_work", "_index.json")
    if os.path.isfile(index_path):
        out.append(b"--- Index matches ---\n")
        grep = subprocess.run(["grep", "-i", query, index_path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        fields = re.compile(rb'"(title|tags|slug|project)"')
        matches = [line for line in grep.stdout.split(b"\n") if fields.search(line)]
        if matches:
            out.extend(b"  " + line + b"\n" for line in matches)
        else:
            out.append(b"  (no title/tag matches)\n")
        out.append(b"\n")
    return b"".join(out)


def arc_hits(knowledge_dir: str, query: str) -> list[dict]:
    """Arc records whose title, anchor, project, or a document line contains query.

    Arc records sit at _work/_arcs/, which every work-item walk prunes along
    with the other underscore-prefixed substrates, so they get their own scan.
    Hits carry kind "arc" and work-item hits carry kind "work-item": an arc very
    often shares a slug with the work item it grew out of, so results are
    deduplicated on the pair and never on the slug alone.
    """
    arcs_dir = os.path.join(knowledge_dir, "_work", "_arcs")
    query = query.lower()

    results = []
    if query and os.path.isdir(arcs_dir):
        for name in sorted(os.listdir(arcs_dir)):
            arc_dir = os.path.join(arcs_dir, name)
            if name.startswith("_") or name.startswith(".") or not os.path.isdir(arc_dir):
                continue

            record = {}
            meta_path = os.path.join(arc_dir, "_meta.json")
            if os.path.isfile(meta_path):
                try:
                    with open(meta_path) as handle:
                        loaded = json.load(handle)
                    if isinstance(loaded, dict):
                        record = loaded
                except ValueError:
                    pass

            excerpt = ""
            hit_path = os.path.join("_work", "_arcs", name)
            for field in ("title", "anchor", "project"):
                value = record.get(field)
                if isinstance(value, str) and query in value.lower():
                    excerpt = "%s: %s" % (field, value.strip())
                    break

            if not excerpt:
                for doc in sorted(os.listdir(arc_dir)):
                    if not doc.endswith(".md"):
                        continue
                    doc_path = os.path.join(arc_dir, doc)
                    if not os.path.isfile(doc_path):
                        continue
                    try:
                        with open(doc_path, errors="replace") as handle:
                            for line in handle:
                                if query in line.lower():
                                    excerpt = line.strip()
                                    hit_path = os.path.join("_work", "_arcs", name, doc)
                                    break
                    except OSError:
                        continue
                    if excerpt:
                        break

            if excerpt:
                results.append({
                    "kind": "arc",
                    "slug": record.get("slug") or name,
                    "title": record.get("title") or name,
                    "excerpt": excerpt,
                    "status": record.get("status") or "unrecorded",
                    "path": hit_path,
                })
    return results


def arc_section(rows: list[dict]) -> str:
    lines = ["--- Arc matches ---"]
    if not rows:
        lines.append("  (no matches in arcs)")
    else:
        for row in rows:
            lines.append("")
            lines.append("  [arc] %s (%s) — %s" % (row["slug"], row["status"], row["title"]))
            lines.append("    %s" % row["path"])
            lines.append("    %s" % row["excerpt"])
    lines.append("")
    return "\n".join(lines) + "\n"


def _captured_search(searcher, argv: list[str]) -> str:
    """What `pk_cli.py <argv>` prints, as `$(... 2>/dev/null || true)` captures it:
    stderr and any failure dropped, trailing newlines stripped."""
    import pk_cli

    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        try:
            pk_cli.cmd_search(pk_cli.build_parser().parse_args(argv), searcher)
        except (Exception, SystemExit):
            pass
    return out.getvalue().rstrip("\n")


def _work_searches(searcher, knowledge_dir: str, query: str, json_mode: bool) -> tuple[str, str]:
    """(active, active-plus-archived) output of the two work searches."""
    argv = ["search", knowledge_dir, query, "--limit", "10", "--type", "work"]
    if json_mode:
        argv.append("--json")
    with searcher.single_index_check():
        active = _captured_search(searcher, argv)
        archived = _captured_search(searcher, argv + ["--include-archived"])
    return active, archived


def _archived_only_slug_count(active: str, archived: str) -> int:
    active_slugs = set()
    archived_slugs = set()
    for line in active.splitlines():
        m = re.search(r"_work/([^/]+)/", line)
        if m:
            active_slugs.add(m.group(1))
    for line in archived.splitlines():
        m = re.search(r"_work/_archive/([^/]+)/", line)
        if m:
            archived_slugs.add(m.group(1))
    return len(archived_slugs - active_slugs)


def search_text(searcher, knowledge_dir: str, query: str, show_all: bool) -> str:
    """Everything after the header: ranked work results, archived ones or a hint, arcs."""
    active, archived = _work_searches(searcher, knowledge_dir, query, json_mode=False)
    lines = ["--- Ranked results (FTS5) ---", active or "(no active matches)", ""]
    if show_all:
        if archived and archived != active:
            lines += ["--- Archived results (FTS5) ---", archived, ""]
        else:
            lines += ["(no additional archived matches)", ""]
    else:
        hint_count = _archived_only_slug_count(active, archived)
        if hint_count > 0:
            lines += [f"Also found: {hint_count} archived match(es) — use --all to show", ""]
    return (
        "\n".join(lines) + "\n"
        + arc_section(arc_hits(knowledge_dir, query))
        + "=== End Work Search ===\n"
    )


def search_json(searcher, knowledge_dir: str, query: str) -> str:
    """Active hits, then archived hits whose slug no active hit has, then arcs."""
    active_raw, archived_raw = _work_searches(searcher, knowledge_dir, query, json_mode=True)
    active = json.loads(active_raw) if active_raw else []
    archived_all = json.loads(archived_raw) if archived_raw else []

    active_slugs = set()
    results = []
    for r in active:
        r["status"] = "active"
        parts = r.get("file_path", "").replace("_work/", "").split("/")
        slug = parts[0] if parts else ""
        r["kind"] = "work-item"
        r["slug"] = slug
        active_slugs.add(slug)
        results.append(r)

    for r in archived_all:
        parts = r.get("file_path", "").replace("_work/_archive/", "").replace("_work/", "").split("/")
        slug = parts[0] if parts else ""
        if slug not in active_slugs:
            r["status"] = "archived"
            r["kind"] = "work-item"
            r["slug"] = slug
            results.append(r)

    results.extend(arc_hits(knowledge_dir, query))
    return json.dumps(results)


def _write(data: bytes | str) -> None:
    sys.stdout.flush()
    sys.stdout.buffer.write(data if isinstance(data, bytes) else data.encode())
    sys.stdout.buffer.flush()


def search_all(query: str, search_argv: list[str]) -> int:
    """`pk_cli.py <search_argv>`, a blank line, then `search-work.sh <query>`."""
    import pk_cli
    from pk_search import Searcher

    args = pk_cli.build_parser().parse_args(search_argv)
    searcher = Searcher(args.knowledge_dir)
    with searcher.single_index_check():
        pk_cli.cmd_search(args, searcher)
        print("")
        # search-work.sh's own refusals, which it makes before printing anything.
        if not query:
            print("Usage: search-work.sh <query> [directory] [--json]")
            return 1
        if not os.path.isdir(os.path.join(args.knowledge_dir, "_work")):
            print("No work directory found. Run `/work create <name>` to create a work item.")
            return 1
        _write(header(args.knowledge_dir, query))
        _write(search_text(searcher, args.knowledge_dir, query, show_all=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="pk_work_search")
    sub = parser.add_subparsers(dest="command", required=True)
    p_search = sub.add_parser("search")
    p_search.add_argument("--all", action="store_true")
    p_search.add_argument("--json", action="store_true")
    p_all = sub.add_parser("all")
    p_all.add_argument("query")
    p_all.add_argument("search_argv", nargs=argparse.REMAINDER)
    p_header = sub.add_parser("header")
    p_arcs = sub.add_parser("arcs")
    p_arcs.add_argument("--json", action="store_true")
    for p in (p_search, p_header, p_arcs):
        p.add_argument("knowledge_dir")
        p.add_argument("query")
    args = parser.parse_args()

    if args.command == "all":
        return search_all(args.query, args.search_argv)
    if args.command == "header":
        _write(header(args.knowledge_dir, args.query))
    elif args.command == "arcs":
        rows = arc_hits(args.knowledge_dir, args.query)
        _write(json.dumps(rows) + "\n" if args.json else arc_section(rows))
    else:
        from pk_search import Searcher

        searcher = Searcher(args.knowledge_dir)
        if args.json:
            _write(search_json(searcher, args.knowledge_dir, args.query) + "\n")
        else:
            _write(header(args.knowledge_dir, args.query))
            _write(search_text(searcher, args.knowledge_dir, args.query, args.all))
    return 0


if __name__ == "__main__":
    sys.exit(main())
