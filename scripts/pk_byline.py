import datetime
import json
import re
from pathlib import Path


_ROLES = {
    "worker", "researcher", "lead", "reviewer", "advisor", "judge",
    "summarizer", "interactive", "coordinator", "classifier", "curator",
    "implement-lead", "spec-lead", "worker-mechanical", "worker-judgment-dense",
    "spec-researcher", "spec-worker", "implement-worker",
}


def _metadata(text):
    blocks = re.findall(r"<!--(.*?)-->", text, re.DOTALL)
    if not blocks:
        return {}
    remaining = blocks[-1].strip()
    fields = {}
    while remaining:
        key, sep, rest = remaining.partition(":")
        if not sep:
            break
        rest = rest.lstrip()
        if rest.startswith(("[", "{")):
            try:
                value, end = json.JSONDecoder().raw_decode(rest)
                remaining = rest[end:].lstrip().removeprefix("|").lstrip()
            except ValueError:
                break
        else:
            value, _, remaining = rest.partition("|")
            value = value.strip()
        fields[key.strip()] = value
    return fields


class Bylines:
    def __init__(self, knowledge_dir):
        self.root = Path(knowledge_dir)
        self._titles = None

    def _title(self, slug):
        if self._titles is None:
            self._titles = {}
            try:
                index = json.loads((self.root / "_work/_index.json").read_text())
                for item in index.get("plans", []):
                    if isinstance(item, dict) and item.get("slug") and item.get("title"):
                        self._titles[item["slug"]] = " ".join(item["title"].split())
            except (OSError, ValueError, TypeError, AttributeError):
                pass
        return self._titles.get(slug, "") if isinstance(slug, str) else ""

    def _line(self, verb, role, work, date):
        role = role if isinstance(role, str) and role in _ROLES else ""
        title = self._title(work)
        if not role and not title:
            return ""
        line = verb
        if role:
            label = role.replace("-", " ")
            article = "an" if label[0] in "aeiou" else "a"
            line += f" by {article} {label}"
        if title:
            line += f' during "{title}"'
        try:
            day = datetime.date.fromisoformat(date[:10])
            age = (datetime.datetime.now(datetime.timezone.utc).date() - day).days
            if age == 0:
                line += ", today"
            elif age == 1:
                line += ", 1 day ago"
            elif age > 1:
                line += f", {age} days ago"
            else:
                line += f", on {day.isoformat()}"
        except (ValueError, TypeError):
            pass
        return line

    def lines(self, entry):
        if entry.get("source_type", "knowledge") != "knowledge":
            return ""
        try:
            meta = _metadata((self.root / entry["file_path"]).read_text(encoding="utf-8"))
        except (OSError, UnicodeError, KeyError):
            return ""
        lines = [self._line("captured", meta.get("capturer_role") or meta.get("producer_role"),
                            meta.get("work_item"), meta.get("learned"))]
        corrections = meta.get("corrections", [])
        if isinstance(corrections, list) and corrections and isinstance(corrections[-1], dict):
            correction = corrections[-1]
            lines.append(self._line("corrected", correction.get("reported_by"),
                                    correction.get("work_item"), correction.get("date")))
        return "\n".join(line for line in lines if line)

    def block(self, entry, indent=""):
        return "".join(indent + line + "\n" for line in self.lines(entry).splitlines())

    def budget(self, data):
        full, demoted = [], []
        used = 0
        for entry in data.get("full", []):
            entry = dict(entry)
            entry["content"] = self.insert(entry.get("content", ""), entry)
            size = len(entry["content"])
            if used + size <= data.get("budget_total", 0):
                full.append(entry)
                used += size
            else:
                demoted.append({key: value for key, value in entry.items() if key != "content"})
        return dict(data, full=full, titles_only=demoted + data.get("titles_only", []), budget_used=used)

    def insert(self, content, entry):
        byline = self.block(entry)
        if not byline:
            return content
        return re.sub(r"^(#{1,6} .+)(\n|$)", lambda m: m[1] + "\n" + byline,
                      content, count=1, flags=re.MULTILINE)


if __name__ == "__main__":
    import sys

    root, path = sys.argv[1:3]
    content = Path(path).read_text(encoding="utf-8")
    print(Bylines(root).insert(content, {"file_path": path}), end="")
