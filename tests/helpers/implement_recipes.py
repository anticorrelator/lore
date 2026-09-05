#!/usr/bin/env python3
"""Execute the implement skill's published recipes in an isolated store."""

import argparse
import copy
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
        if "<!-- implement-recipe:" in line and not marker:
            raise ValueError(f"invalid recipe marker at {n + 1}")
        if marker:
            if pending:
                raise ValueError("recipe marker has no body: " + pending)
            pending = marker.group(1)
            line = line[marker.end():]
        fence = re.match(r"\s*(`{3,}|~{3,})(.*)\s*$", line)
        inline = re.fullmatch(r"\s*`([^`\n]+)`\s*", line) if pending else None
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
    current, current_bodies = inventory(Path(document["source_path"]))
    if current["source_sha256"] != document["source_sha256"]:
        raise AssertionError("recipe source changed after inventory")
    if current_bodies != bodies:
        raise AssertionError("execution bodies differ from source inventory")
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
        common = {"PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TMP", "TEMP", "TZ",
                  "SYSTEMROOT", "COMSPEC", "PATHEXT"}
        self.env = {k: v for k, v in os.environ.items() if k in common}
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
        (self.code / ".gitignore").write_text("execution-count\n")
        self.call(["git", "add", "tracked", ".gitignore"])
        self.call(["git", "commit", "-qm", "Initial fixture source"])
        self.sequence = 0

    def data(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value, indent=2) + "\n")
        return path

    def create_item(self, slug="recipes"):
        self.lore("work", "create", "--title", "Recipe behavior", "--slug", slug,
                  "--intent-anchor", "Preserve execution and dispatch history.")
        item = self.store / "_work" / slug
        assert (item / "_meta.json").is_file()
        assert item.is_relative_to(self.root)
        hosts = self.store / "_sessions/instances"
        hosts.mkdir(parents=True, exist_ok=True)
        (hosts / "fixture.json").write_text(json.dumps({"name": "fixture", "project_dir": str(self.code)}))
        self.lore("work", "source-checkout", slug, "--from-instance", "fixture")
        return item

    def write_plan(self, item, *, consultation=False):
        tasks = []
        for number in (1, 2):
            criterion = {"id": "observe", "intent": "Observe actual execution in the assigned root.",
                         "argv": [sys.executable, "-c",
                                  "from pathlib import Path; p=Path('execution-count'); "
                                  "p.write_text(str(int(p.read_text())+1) if p.exists() else '1'); "
                                  "print('executed in', Path.cwd())"],
                         "cwd": ".", "timeout": 10, "expected_exit": 0}
            required = "**Consultations required:**\n- storage\n" if consultation and number == 1 else ""
            depends = "**Depends on:** Task 1\n" if number == 2 else ""
            tasks.append(f"""### Task {number}: Observe history {number}
**Deliverable:** Inspectable execution history {number}.
**Files:** `tracked`
{depends}{required}**Close criteria:**
```json
{json.dumps([criterion])}
```
- [ ] Observe history {number} [class: mechanical]
""")
        (item / "plan.md").write_text("""# Recipe behavior
## Intent Anchor
Preserve execution and dispatch history.

**Scope delta:** none

## Tasks
**Merge rationale:** The second observation reads the first one's history.

""" + "\n".join(tasks))
        return self.data("decisions.json", {
            "anchor_coverage": {"disposition": "covered", "by": "fixture-seat", "note": "Both observations preserve inspectable history."},
            "review_requirement": {"disposition": "not-required", "by": "fixture-seat", "note": "Isolated command fixture."},
            "dispatch_decision": {"disposition": "proceed", "by": "fixture-seat", "note": "Exercise declared recipes.",
                                  "task_ids": ["task-1", "task-2"], "prior_review_refs": []}})

    def report_input(self, bindings, reference, *, consultation=None, claim_id=None):
        manifest = json.loads(Path(reference["manifest_path"]).read_text())
        producer = manifest["producer"]
        text = f"""Report-schema: 1
Report-id: {bindings['report_id']}
Work-item: {bindings['work_item']}
Task: Observe history 1
Producer-role: worker
Dispatch-path: harness-subagent
Harness: {producer['framework']}
Status: completed
Template-version: {producer['template_version']}
Position-dispatch-manifest: {reference['manifest_path']}
Position-dispatch-sha256: {reference['manifest_sha256']}
Packet-id: {bindings['packet_id']}
Revision-id: {bindings['revision_id']}
Dispatch-attempt-id: {bindings['dispatch_attempt_id']}

**Artifacts:**
- path: {self.code / 'tracked'}
  kind: source
  writer: fixture
  identity: {self.call(['git', 'rev-parse', 'HEAD']).stdout.decode().strip()}
**Changes:**
- tracked: Retains observable source.
**Checks:**
- The fixture inspects dispatch bytes and recorded writer output.
**Skills used:**
None
**Observations:**
- claim: "None"
**Tier 2 evidence:**
{('- ' + claim_id) if claim_id else 'none'}
**Convention handling:**
none in scope
**Surfaced concerns:**
None
**Blockers:**
none
"""
        if consultation:
            text += "**Consultations:**\n" + yaml.safe_dump([consultation], sort_keys=False)
        path = self.root / (bindings["report_id"] + ".input.md")
        path.write_text(text)
        return path

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


def extraction_controls(root):
    """Coverage must reject drift even when a previous inventory passed."""
    source = root / "extraction.md"
    original = (b"Recipe inputs: none\n<!-- implement-recipe: first -->\n"
                b"```bash\nprintf '%s\\n' 'literal $HOME; `value`'\n```\n"
                b"Recipe inputs: none\n<!-- implement-recipe: inline -->\n`true`\n"
                b'```json\n{"state":"example"}\n```\n')
    source.write_bytes(original)
    document, bodies = inventory(source)
    assert bodies["first"] == b"printf '%s\\n' 'literal $HOME; `value`'\n"
    assert bodies["inline"] == b"true"
    assert document["declarative_examples"][0]["validation"] == "parsed"

    def rejects(operation, message):
        try:
            operation()
        except (AssertionError, ValueError) as exc:
            assert message in str(exc), str(exc)
        else:
            raise AssertionError("negative control passed: " + message)

    rejects(lambda: assert_coverage(document, bodies), "unexercised")
    # Synthetic coverage here tests the checker itself, never scenario evidence.
    covered = copy.deepcopy(document)
    for row in covered["recipes"]:
        row["executions"] = [{"body_sha256": row["body_sha256"]}]
    assert_coverage(covered, bodies)
    source.write_bytes(original + b"Recipe inputs: none\n<!-- implement-recipe: added -->\n```sh\ntrue\n```\n")
    added, added_bodies = inventory(source)
    for row in added["recipes"]:
        if row["id"] in bodies:
            row["executions"] = [{"body_sha256": row["body_sha256"]}]
    rejects(lambda: assert_coverage(added, added_bodies), "unexercised")
    rejects(lambda: assert_coverage(covered, bodies), "source changed")
    source.write_bytes(original.replace(b"literal", b"changed"))
    rejects(lambda: assert_coverage(covered, bodies), "source changed")
    for extra, reason in [
        (b"```python\nprint('unmarked')\n```\n", "unmarked executable"),
        (b"<!-- implement-recipe: BAD -->\n`true`\n", "invalid recipe marker"),
        (b"<!-- implement-recipe: data -->\n```json\n{}\n```\n", "declarative fence"),
        (b"<!-- implement-recipe: orphan -->\n", "has no body"),
        (b"Recipe inputs: none\n<!-- implement-recipe: first -->\n`true`\n", "duplicate recipe"),
        (b"```bash\ntrue\n", "unterminated fence"),
        (b"```json\nnot json\n```\n", "Expecting value"),
    ]:
        source.write_bytes(original + extra)
        rejects(lambda: inventory(source), reason)
    source.write_bytes(original)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "skills/implement/SKILL.md")
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    if args.self_test:
        if args.root is None:
            parser.error("--self-test requires --root")
        extraction_controls(args.root)
        print("Recipe extraction and coverage negative controls passed")
        return
    document, _ = inventory(args.source.resolve())
    rendered = json.dumps(document, indent=2) + "\n"
    if args.inventory:
        args.inventory.write_text(rendered)
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
