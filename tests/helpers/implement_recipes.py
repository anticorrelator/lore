#!/usr/bin/env python3
"""Execute the implement skill's published recipes in an isolated store."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import yaml


EXECUTABLE = {"bash", "sh", "shell", "python", "python3"}
MARKER = re.compile(r"<!-- implement-recipe: ([a-z0-9]+(?:-[a-z0-9]+)*) -->")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inventory(source):
    raw = source.read_bytes()
    lines = raw.decode().splitlines(keepends=True)
    recipes, examples, bodies = [], [], {}
    pending = None
    inputs = None
    n = 0
    while n < len(lines):
        line = lines[n]
        declaration = re.search(r"Recipe inputs:\s*(.*)", line)
        if declaration:
            value = declaration.group(1).strip().strip("*").strip().rstrip(".")
            inputs = [] if value.lower() == "none" else re.findall(r"\b[A-Z][A-Z0-9_]*\b", value)
            if not inputs and value.lower() != "none":
                raise ValueError(f"unreadable input declaration at {n + 1}")
        marker = MARKER.search(line)
        if marker:
            if pending:
                raise ValueError("recipe marker has no body: " + pending)
            pending = marker.group(1)
            line = line[marker.end():]
        fence = re.match(r"\s*(`{3,}|~{3,})(.*)\s*$", line)
        inline = re.match(r"\s*`([^`\n]+)`", line) if marker else None
        if fence:
            delimiter, info = fence.groups()
            language = info.strip().split()[0] if info.strip() else "text"
            start = n + 1
            n += 1
            body = []
            while n < len(lines) and not re.fullmatch(r"\s*" + re.escape(delimiter[0]) + "{" + str(len(delimiter)) + r",}\s*", lines[n]):
                body.append(lines[n])
                n += 1
            if n == len(lines):
                raise ValueError(f"unterminated fence at {start}")
            body = "".join(body).encode()
            end = n + 1
            kind = "fence"
        elif inline:
            language, body, start, end, kind = "bash", inline.group(1).encode(), n + 1, n + 1, "inline"
        else:
            if pending and line.strip():
                raise ValueError(f"recipe marker must immediately precede its body: {pending}")
            n += 1
            continue
        row = dict(language=language, line_start=start, line_end=end, body_sha256=digest(body))
        if language in EXECUTABLE:
            if pending is None:
                raise ValueError(f"unmarked executable fence at {start}")
            if pending in bodies:
                raise ValueError("duplicate recipe id: " + pending)
            if inputs is None:
                raise ValueError("missing Recipe inputs declaration: " + pending)
            row.update(id=pending, kind=kind, inputs=inputs, executions=[])
            bodies[pending] = body
            recipes.append(row)
            pending, inputs = None, None
        else:
            if pending:
                raise ValueError("executable marker on declarative fence: " + pending)
            if language == "json":
                json.loads(body)
            elif language in {"yaml", "yml"}:
                yaml.safe_load(body)
            row["validation"] = "parsed" if language in {"json", "yaml", "yml"} else "declarative-text"
            examples.append(row)
        n += 1
    if pending:
        raise ValueError("recipe marker has no body: " + pending)
    if not recipes:
        raise ValueError("skill contains no executable recipes")
    return dict(schema_version=1, source_path=str(source), source_sha256=digest(raw),
                recipes=recipes, declarative_examples=examples), bodies


def assert_coverage(document, bodies):
    missing = []
    for row in document["recipes"]:
        if not row["executions"] or any(e["body_sha256"] != digest(bodies[row["id"]]) for e in row["executions"]):
            missing.append(row["id"])
    if missing:
        raise AssertionError("unexercised or changed recipes: " + ", ".join(missing))


class Fixture:
    def __init__(self, repo, root, source):
        self.repo, self.root = repo.resolve(), root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.document, self.bodies = inventory(source)
        self.rows = {r["id"]: r for r in self.document["recipes"]}
        self.home, self.store, self.code = [self.root / n for n in ("home", "knowledge", "code")]
        for path in (self.home, self.store, self.code, self.root / "outputs"):
            path.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LORE_", "CLAUDE_", "CODEX_", "GIT_"))}
        self.env.update(HOME=str(self.home), LORE_DATA_DIR=str(self.root / "data"),
                        LORE_KNOWLEDGE_DIR=str(self.store), LORE_FRAMEWORK="codex",
                        XDG_CONFIG_HOME=str(self.root / "config"), XDG_DATA_HOME=str(self.root / "data"),
                        XDG_CACHE_HOME=str(self.root / "cache"),
                        PATH=str(self.repo / "cli") + os.pathsep + self.env["PATH"])
        (self.root / "data/config").mkdir(parents=True)
        (self.root / "data/config/settings.json").write_text(json.dumps({"version": 1,
            "coordination": {"max_concurrency": 2}, "harnesses": {"codex": {"roles": {
                role: "gpt-6-astra" for role in ("lead", "worker", "advisor", "reviewer", "researcher", "default")}}}}))
        (self.home / ".lore").mkdir()
        (self.home / ".lore/scripts").symlink_to(self.repo / "scripts")
        self.call(["git", "init", "-q"])
        self.call(["git", "config", "user.name", "Fixture"])
        self.call(["git", "config", "user.email", "fixture@example.test"])
        (self.code / "tracked").write_text("observable source\n")
        self.call(["git", "add", "tracked"])
        self.call(["git", "commit", "-qm", "Initial fixture source"])
        self.sequence = 0

    def call(self, argv, expected=0, **kwargs):
        proc = subprocess.run(argv, cwd=self.code, env=self.env, capture_output=True, **kwargs)
        assert proc.returncode == expected, (argv, proc.returncode, proc.stdout.decode(errors="replace"), proc.stderr.decode(errors="replace"))
        return proc

    def lore(self, *args, **kwargs):
        return self.call([str(self.repo / "cli/lore"), *args], **kwargs)

    def run(self, name, inputs, scenario, expected=0, stdin=None):
        row = self.rows[name]
        assert set(inputs) == set(row["inputs"]), (name, "declared inputs differ", row["inputs"], list(inputs))
        env = dict(self.env, **{k: str(v) for k, v in inputs.items()})
        self.sequence += 1
        extension = "py" if row["language"] in {"python", "python3"} else "sh"
        script = self.root / "outputs" / f"{self.sequence:03d}-{name}.{extension}"
        script.write_bytes(self.bodies[name])
        argv = [sys.executable, str(script)] if extension == "py" else ["bash", "-eu", str(script)]
        proc = subprocess.run(argv, cwd=self.code, env=env, capture_output=True, input=stdin)
        output = script.with_suffix(".output")
        output.write_bytes(proc.stdout + b"\n--- stderr ---\n" + proc.stderr)
        row["executions"].append(dict(scenario=scenario, exit_code=proc.returncode,
            output_path=str(output), body_sha256=digest(script.read_bytes())))
        self.save()
        assert proc.returncode == expected, (name, scenario, proc.returncode, output.read_text(errors="replace"))
        return proc

    def save(self):
        (self.root / "inventory.json").write_text(json.dumps(self.document, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--inventory", type=Path)
    args = parser.parse_args()
    document, _ = inventory(args.source.resolve())
    rendered = json.dumps(document, indent=2) + "\n"
    if args.inventory:
        args.inventory.write_text(rendered)
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
