import argparse
import datetime
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

from pk_byline import _metadata
from pk_search import CATEGORY_DIRS, DB_FILENAME, IndexLockBusy, IndexWriteLock, Searcher


VERSION = "1"
DESIGN = re.compile(r"^(?:\d+[.)]?\s+)?(?:strategy|design\b|intent anchor\b|rationale\b)", re.I)
DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:Z|[+-]\d{2}:\d{2})?)?)?")
PATH = re.compile(r"(?<![\w:/])(?:[\w.*@+-]+/)+[\w.*@+-]+(?:/)?|(?<=`)[\w-]+\.[\w]+(?=[:`])")


def file_key(value):
    return re.sub(r":\d+(?:[-:]\d+)*$", "", value.strip().strip("` ")).removeprefix("./").rstrip("/")


def related_files(value):
    if isinstance(value, str):
        value = value.split(",")
    return [file_key(v) for v in value if isinstance(v, str) and v.strip()] if isinstance(value, list) else []


def subsystem_metadata(root):
    names, links = set(), set()
    for category in sorted(CATEGORY_DIRS):
        for path in sorted((root / category).rglob("*.md")):
            try:
                meta = _metadata(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError):
                continue
            name = meta.get("subsystem")
            if not isinstance(name, str) or not name.strip():
                continue
            name = name.strip().casefold()
            names.add(name)
            links.update((f, name) for f in related_files(meta.get("related_files")))
    return names, links


def sections(text, plan=False):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    stack, body, fence = [], [], None

    def section():
        content = "".join(body).strip()
        if content and (not plan or any(DESIGN.match(h) for _, h in stack)):
            return {"heading": " / ".join(h for _, h in stack) or "(ungrouped)",
                    "content": content}

    for line in text.splitlines(keepends=True):
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            token = marker[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            body.append(line)
            continue
        heading = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line) if fence is None else None
        if heading:
            result = section()
            if result:
                yield result
            body = []
            level, title = len(heading[1]), heading[2]
            while stack and stack[-1][0] >= level:
                stack.pop()
            stack.append((level, title))
        else:
            body.append(line)
    result = section()
    if result:
        yield result


def _schema(conn):
    conn.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS work_history USING fts5(
        heading, content, title, file_path UNINDEXED, slug UNINDEXED,
        date UNINDEXED, status UNINDEXED, tokenize='porter unicode61')""")
    conn.execute("""CREATE TABLE IF NOT EXISTS work_history_sources (
        file_path TEXT PRIMARY KEY, fingerprint TEXT NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS work_history_keys (
        section_id INTEGER, kind TEXT, value TEXT,
        PRIMARY KEY(section_id, kind, value))""")
    conn.execute("CREATE INDEX IF NOT EXISTS work_history_lookup ON work_history_keys(kind, value)")
    conn.execute("""CREATE TABLE IF NOT EXISTS work_history_subsystems (
        file_path TEXT, subsystem TEXT, PRIMARY KEY(file_path, subsystem))""")


def rebuild(knowledge_dir):
    root = Path(knowledge_dir).resolve()
    names, links = subsystem_metadata(root)
    registry = json.dumps([VERSION, sorted(names), sorted(links)])
    patterns = {name: re.compile(r"(?<!\w)" + re.escape(name) + r"(?!\w)", re.I) for name in names}
    indexed, removed = 0, 0
    with IndexWriteLock(str(root)):
        conn = sqlite3.connect(root / DB_FILENAME)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("BEGIN IMMEDIATE")
            _schema(conn)
            previous = dict(conn.execute("SELECT file_path, fingerprint FROM work_history_sources"))
            seen = set()
            for directory, status in ((root / "_work", "active"), (root / "_work/_archive", "archived")):
                if not directory.is_dir():
                    continue
                for item in sorted(directory.iterdir()):
                    if not item.is_dir() or item.name.startswith("_"):
                        continue
                    try:
                        raw_meta = (item / "_meta.json").read_text(encoding="utf-8")
                        meta = json.loads(raw_meta)
                        if not isinstance(meta, dict):
                            continue
                    except (OSError, ValueError):
                        continue
                    for path in sorted(item.iterdir()):
                        if not path.is_file() or not (path.name in {"plan.md", "notes.md", "design.md"}
                                                     or re.fullmatch(r"rationale.*\.md", path.name)):
                            continue
                        try:
                            text = path.read_text(encoding="utf-8")
                            mtime = path.stat().st_mtime
                        except (OSError, UnicodeError):
                            continue
                        relative = path.relative_to(root).as_posix()
                        seen.add(relative)
                        fingerprint = hashlib.sha256((registry + raw_meta + text).encode()).hexdigest()
                        if previous.get(relative) == fingerprint:
                            continue
                        _remove(conn, relative)
                        fallback_date = str(meta.get("updated") or meta.get("updated_at") or meta.get("created")
                                            or meta.get("created_at") or datetime.datetime.fromtimestamp(
                                                mtime, datetime.timezone.utc).isoformat())
                        for section in sections(text, plan=path.name == "plan.md"):
                            dates = DATE.findall(section["heading"])
                            date = dates[-1] if dates else fallback_date
                            cursor = conn.execute(
                                "INSERT INTO work_history VALUES (?, ?, ?, ?, ?, ?, ?)",
                                (section["heading"], section["content"], str(meta.get("title") or item.name),
                                 relative, item.name, date, status))
                            content = section["heading"] + "\n" + section["content"]
                            files = {file_key(m[0]) for m in PATH.finditer(content)}
                            subsystems = {name for name, pattern in patterns.items() if pattern.search(content)}
                            keys = [(cursor.lastrowid, "file", f) for f in files]
                            keys += [(cursor.lastrowid, "subsystem", s) for s in subsystems]
                            conn.executemany("INSERT OR IGNORE INTO work_history_keys VALUES (?, ?, ?)", keys)
                        conn.execute("INSERT INTO work_history_sources VALUES (?, ?)", (relative, fingerprint))
                        indexed += 1
            for relative in previous.keys() - seen:
                _remove(conn, relative)
                removed += 1
            conn.execute("DELETE FROM work_history_subsystems")
            conn.executemany("INSERT INTO work_history_subsystems VALUES (?, ?)", sorted(links))
            conn.commit()
        finally:
            conn.close()
    return {"files_indexed": indexed, "files_removed": removed}


def _remove(conn, relative):
    conn.execute("DELETE FROM work_history_keys WHERE section_id IN (SELECT rowid FROM work_history WHERE file_path = ?)", (relative,))
    conn.execute("DELETE FROM work_history WHERE file_path = ?", (relative,))
    conn.execute("DELETE FROM work_history_sources WHERE file_path = ?", (relative,))


def _file_matches(left, right):
    return left == right or left.endswith("/" + right) or right.endswith("/" + left)


def lookup(knowledge_dir, *, location=None, topic=None, limit=5):
    db = Path(knowledge_dir).resolve() / DB_FILENAME
    if not db.exists() or limit <= 0:
        return []
    try:
        conn = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("BEGIN")
            if location is not None:
                target = file_key(location)
                subsystems = {row[1] for row in conn.execute("SELECT file_path, subsystem FROM work_history_subsystems")
                              if _file_matches(row[0], target)}
                ids = {row[0] for row in conn.execute("SELECT section_id, kind, value FROM work_history_keys")
                       if (row[1] == "file" and _file_matches(row[2], target))
                       or (row[1] == "subsystem" and row[2] in subsystems)}
                if not ids:
                    return []
                condition = "rowid IN (" + ",".join("?" for _ in ids) + ")"
                params = list(ids)
            else:
                query = Searcher._prepare_query(topic or "")
                if not query:
                    return []
                condition, params = "work_history MATCH ?", [query]
            rows = conn.execute("SELECT rowid, * FROM work_history WHERE " + condition +
                                " ORDER BY date DESC, file_path, rowid DESC LIMIT ?", [*params, limit]).fetchall()
            return [dict(row, source_type="work-history", pointer=f"[[work:{row['slug']}]]") for row in rows]
        finally:
            conn.close()
    except sqlite3.DatabaseError:
        return []


def render(records):
    if not records:
        return ""
    lines = ["", "### From the record", ""]
    for record in records:
        lines += [f"#### {record['title']} — {record['date']} ({record['status']})",
                  f"{record['pointer']} — {record['file_path'].rsplit('/', 1)[-1]} > {record['heading']}", "",
                  record["content"][:2000] + ("…" if len(record["content"]) > 2000 else ""), ""]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("knowledge_dir")
    args = parser.parse_args()
    try:
        print(json.dumps(rebuild(args.knowledge_dir)))
    except (OSError, sqlite3.DatabaseError, IndexLockBusy) as error:
        sys.exit(f"[work history] {error}; run lore work heal to retry.")
