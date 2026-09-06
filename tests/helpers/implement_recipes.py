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
import signal
import subprocess
import sys
import tempfile
import time

import yaml


EXECUTABLE = {"bash", "sh", "shell", "python", "python3"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inventory(source, namespace="implement"):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", namespace):
        raise ValueError("invalid recipe namespace: " + namespace)
    marker_prefix = "<!-- " + namespace + "-recipe:"
    marker_pattern = re.compile(re.escape(marker_prefix) + r" ([a-z0-9]+(?:-[a-z0-9]+)*) -->")
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
        marker = marker_pattern.search(line)
        if marker_prefix in line and not marker:
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


def assert_coverage(document, bodies, namespace="implement"):
    current, current_bodies = inventory(Path(document["source_path"]), namespace)
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


def capture_prepared_launch(prepared, destination, *, offered_fields=(), offered_agents=()):
    """A fake native surface checks prepared input; it proves no model receipt."""
    args = prepared["tool_input"]
    if prepared["readiness"]["kind"] == "native-tool-schema":
        if not set(args) <= set(offered_fields):
            raise ValueError("native tool does not offer the prepared fields")
    elif args["subagent_type"] not in offered_agents:
        raise ValueError("compiled definition is not in the live selection inventory")
    destination.write_text(json.dumps({"proof": "prepared-input only; no live model consumption", "tool": prepared["tool"], "arguments": args}, indent=2) + "\n")


def validate_declarative_examples(document, source):
    lines = source.read_text().splitlines(keepends=True)
    for row in document["declarative_examples"]:
        if row["language"] != "text":
            continue
        body = "".join(lines[row["line_start"]:row["line_end"] - 1])
        labels = [line.strip().split(":", 1)[0] for line in body.splitlines() if ":" in line]
        if "Test result" in labels:
            # These labels feed the execution-log reduction readers.
            required = {"Task", "Changes", "Skills", "Tier2-claims", "Observations", "Convention", "Investigation",
                        "Blockers", "Consultations", "Surfaced concerns", "Test result", "Spend"}
            assert set(labels) == required and len(labels) == len(required), labels
            row["validation"] = "validated-reduction-labels"
        elif "consultation-id" in labels:
            assert labels[:4] == ["consultation-id", "handler", "lead-acknowledged", "skill_template_version"], labels
            row["validation"] = "validated-consultation-reply-labels"
        else:
            raise AssertionError("unvalidated declarative text example at line " + str(row["line_start"]))


def isolated_go_environment(repo, case_root, env):
    env = dict(env)
    go = os.environ.get("LORE_TEST_GO") or shutil.which("go", path=env["PATH"])
    if not go:
        raise RuntimeError("Recipe fixtures require an installed Go toolchain; set LORE_TEST_GO")
    go = Path(go).resolve()
    probe_env = dict(env, GOTOOLCHAIN="local")
    version = subprocess.run([str(go), "env", "GOVERSION"], env=probe_env,
                             capture_output=True, text=True, check=True).stdout.strip()
    required = re.search(r"^go (\d+\.\d+(?:\.\d+)?)$", (repo / "tui/go.mod").read_text(), re.MULTILINE).group(1)
    def parts(value):
        match = re.fullmatch(r"(?:go)?(\d+)\.(\d+)(?:\.(\d+))?", value)
        return tuple(int(v or 0) for v in match.groups()) if match else ()
    if not parts(version) or parts(version) < parts(required):
        raise RuntimeError(f"Recipe fixtures need installed Go >= {required}, found {version}; set LORE_TEST_GO")
    go_cache = Path(tempfile.gettempdir()).resolve() / f"lore-implement-go-cache-{os.getuid()}"
    if go_cache.is_relative_to(case_root.resolve()):
        raise ValueError("Go caches must be outside the case root")
    for name in ("modules", "build"):
        (go_cache / name).mkdir(parents=True, exist_ok=True)
    env.update(PATH=str(go.parent) + os.pathsep + env["PATH"], GOTOOLCHAIN="local",
               GOMODCACHE=str(go_cache / "modules"), GOCACHE=str(go_cache / "build"))
    return env


class Fixture:
    def __init__(self, repo, root, source, namespace="implement"):
        self.repo, self.root = repo.resolve(), root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.document, self.bodies = inventory(source, namespace)
        if namespace == "implement":
            validate_declarative_examples(self.document, source)
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
        self.env = isolated_go_environment(self.repo, self.root, self.env)
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
        (self.code / ".gitignore").write_text("execution-count\nrecovery-count\n")
        self.call(["git", "add", "tracked", ".gitignore"])
        self.call(["git", "commit", "-qm", "Initial fixture source"])
        self.lore("init", "--force")
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

    def run(self, name, inputs, scenario, expected=0, stdin=None, interrupt_criterion=False):
        print(f"{name}: {scenario}", flush=True)
        row = self.rows[name]
        assert set(inputs) == set(row["inputs"]), (name, "declared inputs differ", row["inputs"], list(inputs))
        env = dict(self.env, **{k: str(v) for k, v in inputs.items()})
        self.sequence += 1
        extension = "py" if row["language"] in {"python", "python3"} else "sh"
        script = self.root / "outputs" / f"{self.sequence:03d}-{name}.{extension}"
        script.write_bytes(self.bodies[name])
        argv = [sys.executable, str(script)] if extension == "py" else ["bash", "-eu", str(script)]
        if interrupt_criterion:
            process = subprocess.Popen(argv, cwd=self.code, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            allocation_line = process.stderr.readline()
            allocation = json.loads(allocation_line)
            result_dir = self.store / "_work" / inputs["SLUG"] / "results" / allocation["result_id"]
            for _ in range(500):
                if (result_dir / "output-process.json").is_file() and (self.code / "recovery-count").is_file():
                    break
                time.sleep(.02)
            else:
                process.kill()
                raise AssertionError("criterion did not reach observable execution")
            child = json.loads((result_dir / "output-process.json").read_text())
            os.kill(child["supervisor_pid"], signal.SIGKILL)
            os.kill(child["pid"], signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=10)
            proc = subprocess.CompletedProcess(argv, process.returncode, stdout, allocation_line + stderr)
            assert proc.returncode != 0 and not (result_dir / "completion.json").exists()
        else:
            proc = subprocess.run(argv, cwd=self.code, env=env, capture_output=True, input=stdin)
        output = script.with_suffix(".output")
        output.write_bytes(proc.stdout + b"\n--- stderr ---\n" + proc.stderr)
        row["executions"].append(dict(scenario=scenario, exit_code=proc.returncode,
            output_path=str(output), body_sha256=digest(script.read_bytes())))
        self.save()
        assert expected is None or proc.returncode == expected, (name, scenario, proc.returncode, output.read_text(errors="replace"))
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


def exercise_recipes(repo, root, source):
    repo, root, source = repo.resolve(), root.resolve(), source.resolve()
    f = Fixture(repo, root, source)
    item = f.create_item()
    decisions = f.write_plan(item, consultation=True)
    v = dict(SLUG="recipes", INPUT="recipes", KNOWLEDGE_DIR=f.store,
             SCRIPTS_DIR=repo / "scripts", SKILL_FILE=source,
             LEAD_TEMPLATE_VERSION=digest(source.read_bytes())[:12],
             WORK_TITLE="Recipe behavior", TASK_IDS="", FALLBACK_SCALE_SET="implementation",
             ACTIVE_TASK_IDS="", TASK_ID="task-1", ROLE="worker", TARGET_FRAMEWORK="codex",
             POSITION="worker", EXECUTION_ROOT=f.code, REPORT_ID="native-first",
             TEAM_NAME="", LEAD_NAME="fixture-seat", PLACEMENT_NOTE="Use the assigned temporary root.",
             TIER2_EXTRACT_FILE="", REQUIRED_BINDINGS="task_id revision_id packet_id packet_pointer",
             NATIVE_MODEL="gpt-6-astra-high", AGENTS_SCOPE="", ROUTE="native",
             WORKER_MODEL="gpt-6-astra", TARGET_INSTANCE="", MIN_VINTAGE="", WORKTREE_ID="", EXECUTION_DIR="",
             TRANSCRIPT_FILE="", WOVEN_NORMS="", PROVIDER_STATUS="", SPAWNED_ADVISORS="")

    def run(name, scenario="published recipe", expected=0, interrupt_criterion=False, **updates):
        v.update(updates)
        if name == "request-session":
            (f.store / "_sessions/instances/fixture.json").touch()
        inputs = {key: v[key] for key in f.rows[name]["inputs"]}
        return f.run(name, inputs, scenario, expected, interrupt_criterion=interrupt_criterion)

    def obj(proc):
        return json.loads(proc.stdout)

    def paths(prefix):
        for name in ("bindings", "descriptor", "guidance", "wrapper", "prefix", "suffix", "context", "reference"):
            v[name.upper() + "_FILE"] = root / (prefix + "-" + name + (".json" if name in {"bindings", "descriptor", "wrapper", "context", "reference"} else ".txt"))

    def opened(scenario, **updates):
        data = obj(run("impl-open", scenario, **updates))
        v["DISPATCH_JSON"] = f.data(f"open-{f.sequence}.json", data)
        return data

    def prepare(prefix, route="native", framework="codex", root_path=None):
        paths(prefix)
        run("normalize-bindings", prefix, REPORT_ID=prefix, EXECUTION_ROOT=root_path if root_path is not None else f.code)
        b = json.loads(v["BINDINGS_FILE"].read_text())
        # The lead's judgment over the candidate set travels with the packet; an empty pair of lists is a recorded judgment too.
        synthesized = obj(run("synthesize-packet", prefix + " packet synthesized before binding", PACKET_ID=b["packet_id"],
                              SYNTHESIS_FILE=f.data(prefix + "-synthesis.json", {"dropped": [], "added": []})))
        assert synthesized["delivery_stage"] == "synthesized" and synthesized["packet_id"] == b["packet_id"]
        run("compile-position", prefix, POSITION="worker", TARGET_FRAMEWORK=framework)
        run("author-wrapper", prefix, ROUTE=route)
        return b

    def bind(scenario, **updates):
        ref = obj(run("bind-attempt", scenario, **updates))
        f.data(v["REFERENCE_FILE"].name, ref)
        v.update(MANIFEST_PATH=ref["manifest_path"], MANIFEST_SHA256=ref["manifest_sha256"])
        return ref

    resolved = dict(line.split("=", 1) for line in run("resolve-paths").stdout.decode().splitlines())
    assert Path(resolved["SCRIPTS_DIR"]).resolve() == repo / "scripts"
    assert Path(resolved["KNOWLEDGE_DIR"]).resolve() == f.store
    v["RUN_STARTED_AT"] = resolved["RUN_STARTED_AT"]
    assert b"Standing defaults" in run("lore-defaults").stdout
    run("plan-publish", "initial plan publication", REASON="Publish the authored fixture plan.")
    assert (item / "tasks.json").is_file(), "initial publication must persist task identity"
    run("plan-reconcile", "legacy revision adoption")
    v["REVISION_ID"] = json.loads((item / "tasks.json").read_text())["revision_id"]
    run("set-intent-anchor", INTENT_ANCHOR="Preserve execution and dispatch history.")
    run("plan-publish", REASON="Publish existing intent before review.")
    v["REVISION_ID"] = json.loads((item / "tasks.json").read_text())["revision_id"]
    run("plan-decision", DECISION_ID="initial-coverage", DECISIONS_FILE=decisions)
    started = obj(run("impl-start"))
    assert started["slug"] == "recipes" and started["position_descriptors"]["codex"]["worker"]["position"] == "worker"
    seat_packet = obj(run("seat-packet-build", "standalone seat after slug resolution", SLUG=started["slug"],
                          TOPIC="Preserve execution and dispatch history.", SCALE_SET="implementation"))
    packet_ledger = f.store / "_packets/packets.jsonl"
    seat_row = json.loads(packet_ledger.read_text().splitlines()[-1])
    assert seat_row["packet_id"] == seat_packet["packet_id"]
    assert seat_row["recipient_role"] == "coordinator" and seat_row["caller"] == "implement-lead"
    assert seat_row["work_item"] == started["slug"]
    assert seat_packet["packet_id"].encode() in run("seat-packet-show", "standalone seat reads assembled context",
                                                    PACKET_ID=seat_packet["packet_id"]).stdout
    # A commissioned run receives an existing packet from its caller.
    commissioned = obj(f.lore("packet", "build", "--work-item", "recipes", "--role", "coordinator", "--caller", "coordinator",
                              "--topic", "Inspect commissioned execution history.", "--scale-set", "implementation"))
    before_show = packet_ledger.read_bytes()
    assert commissioned["packet_id"] != seat_packet["packet_id"]
    assert commissioned["packet_id"].encode() in run("seat-packet-show", "commissioned seat reads supplied context",
                                                       PACKET_ID=commissioned["packet_id"]).stdout
    assert packet_ledger.read_bytes() == before_show, "reading a supplied packet must not publish another packet"
    v["WORKER_TEMPLATE_VERSION"] = started["template_versions"]["worker"]
    v["ADVISOR_TEMPLATE_VERSION"] = started["template_versions"]["advisor"]
    assert obj(run("work-show"))["slug"] == "recipes"
    run("gate-anchor", VERDICT="aligned", FIT="Both tasks preserve recorded history.", GAP="", SCOPE_DELTA="")
    assert b"framework=codex" in run("probe-operations").stdout
    assert b"gpt-6-astra" in run("resolve-role-model").stdout
    first = opened("initial task normalization")
    b = prepare("native-first")
    assert b["assignment"] == next(e for e in first["manifest"] if e.get("local_id") == "task-1")["description"]
    first_ref = bind("native Codex preparation")
    native = obj(run("native-input", "prepared-input proof only"))
    payload = Path(first_ref["payload_path"]).read_bytes()
    assert native["tool_input"]["message"].encode() == payload
    assert native["tool_input"]["model"] == "gpt-6-astra" and native["tool_input"]["reasoning_effort"] == "high"
    capture = root / "native-launch-capture.json"
    try:
        capture_prepared_launch(native, capture, offered_fields=("message",))
    except ValueError:
        assert not capture.exists()
    else:
        raise AssertionError("native readiness refusal did not stop launch")
    capture_prepared_launch(native, capture, offered_fields=("message", "model", "reasoning_effort"))
    assert json.loads(capture.read_text())["arguments"]["message"].encode() == payload
    f.data("native-prepared-input.json", {"proof": "prepared-input only; no live model consumption", **native})
    assert bind("identical retry reuses immutable reference") == first_ref
    original_manifest = Path(first_ref["manifest_path"]).read_bytes()
    original_binding = v["BINDINGS_FILE"].read_bytes()
    changed = dict(b, assignment=b["assignment"] + " changed")
    v["BINDINGS_FILE"].write_text(json.dumps(changed))
    run("bind-attempt", "changed retry refused", expected=1)
    assert Path(first_ref["manifest_path"]).read_bytes() == original_manifest
    v["BINDINGS_FILE"].write_bytes(original_binding)
    first_bindings, first_reference_file = b, v["REFERENCE_FILE"]

    opened("fresh retry packet")
    retry = prepare("session-retry", route="session", root_path="")
    assert all(retry[k] != b[k] for k in ("report_id", "dispatch_attempt_id", "packet_id"))
    v["SESSION_SLUG"] = "recipes--w1"
    run("prepare-session", "ordinary host-owned placement")
    context = json.loads(v["CONTEXT_FILE"].read_text())
    assert context["position_preparation"]["bindings"]["execution_root"] is None
    request_inputs = {key: v[key] for key in f.rows["request-session"]["inputs"]}
    queued = obj(run("request-session", "ordinary session admission"))
    assert queued
    run("session-reference", "ordinary reference unavailable before host publication", expected=1)
    launch = f.call([sys.executable, str(repo / "scripts/position-bind.py"), "launch", "--framework", "codex",
                     "--slug", v["SESSION_SLUG"], "--execution-root", str(f.code), "--kdir", str(f.store)],
                    input=json.dumps(context).encode())
    launched = obj(launch)
    session_ref = obj(run("session-reference", "independently collected host publication"))
    assert session_ref["reference"]["manifest_path"] == launched["reference"]["manifest_path"]
    assert Path(session_ref["reference"]["payload_path"]).read_text() == launched["payload"]
    f.data("ordinary-session-reference.json", session_ref)

    # This mutation is executed at admission, rather than inferred from prose.
    mutation = root / "missing-placement.md"
    body = f.bodies["request-session"]
    stance = b'if [[ -n "$TARGET_INSTANCE" ]]; then args+=(--target "$TARGET_INSTANCE"); else args+=(--anywhere); fi\n'
    assert stance in body
    mutation.write_bytes(source.read_bytes().replace(body, body.replace(stance, b"")))
    negative = Fixture(repo, root / "placement-negative", mutation)
    # Use the original valid preparation and isolated context so only placement changes.
    negative.env = f.env.copy()
    negative.code = f.code
    refusal = negative.run("request-session", request_inputs, "removed placement stance", expected=1)
    assert b"placement" in (refusal.stdout + refusal.stderr).lower() or b"anywhere" in refusal.stdout + refusal.stderr

    opened("fixed session attempt")
    fixed = prepare("fixed-session", route="session")
    fixed_ref = bind("fixed root binding", NATIVE_MODEL="")
    context_path = f.data("fixed-context.json", {"dispatch_guidance": Path(fixed_ref["payload_path"]).read_text(), "position_dispatch": fixed_ref})
    run("request-session", "seat-owned fixed session route is refused before enqueue", expected=1, CONTEXT_FILE=context_path, SESSION_SLUG="recipes--w2",
        TARGET_INSTANCE="fixture", WORKTREE_ID="fixed-fixture", EXECUTION_DIR=f.code)
    fixed_collected = obj(run("session-reference", "fixed independent reference"))
    assert fixed_collected["reference"] == fixed_ref
    v.update(WORKTREE_ID="", EXECUTION_DIR="", TARGET_INSTANCE="")

    opened("Claude native readiness")
    prepare("claude-native", framework="claude-code")
    claude_ref = bind("Claude compiled selection", NATIVE_MODEL="opus")
    run("native-input", "Claude definition not registered", AGENTS_SCOPE="", expected=1)
    scope = f.home / ".claude/agents"
    scope.mkdir(parents=True)
    selected = obj(run("native-input", "registered Claude prepared-input proof", AGENTS_SCOPE=scope))
    assert selected["tool_input"]["prompt"].encode() == Path(claude_ref["payload_path"]).read_bytes()
    assert (scope / (selected["tool_input"]["subagent_type"] + ".md")).is_file()
    assert selected["readiness"]["kind"] == "native-agent-inventory"
    capture = root / "claude-launch-capture.json"
    try:
        capture_prepared_launch(selected, capture)
    except ValueError:
        assert not capture.exists()
    else:
        raise AssertionError("unavailable compiled definition did not stop launch")
    capture_prepared_launch(selected, capture, offered_agents=(selected["tool_input"]["subagent_type"],))
    assert json.loads(capture.read_text())["arguments"] == selected["tool_input"]
    f.data("claude-prepared-input.json", {"proof": "prepared-input only; no live model consumption", **selected})
    opened("unsupported native target")
    prepare("opencode-native", framework="opencode")
    refusal = run("bind-attempt", "OpenCode native preparation refused", NATIVE_MODEL="anthropic/opus", expected=1)
    assert b"native" in refusal.stderr.lower()

    run("designer-packet", "required storage consultation", DOMAIN="storage", QUESTION="Where is the execution root?", SCALE_SET="implementation")
    packets = [json.loads(line) for line in (f.store / "_packets/packets.jsonl").read_text().splitlines()]
    v["PACKET_ID"] = packets[-1]["packet_id"]
    request = root / "consultation-request.md"
    request.write_text("## Consultation\nconsultation-id: storage-question\ndomain: storage\nreason: Verify root ownership.\nquestion: Where is the execution root?\ntask: task-1\n")
    paths("designer")
    run("designer-bindings", REQUEST_FILE=request, ADVISOR_NAME="storage-advisor", WORKER_NAME="task-1", EXECUTION_ROOT=f.code)
    designer_bindings = json.loads(v["BINDINGS_FILE"].read_text())
    assert designer_bindings["task_id"] is None and designer_bindings["mode"] == "consultation"
    request.write_text("## Consultation\ndomain: storage\n")
    run("designer-bindings", "missing consultation identity refused", expected=1)
    run("compile-position", "designer consultation compilation", POSITION="designer", TARGET_FRAMEWORK="codex")
    run("author-wrapper", "designer consultation wrapper", ROUTE="designer")
    run("synthesize-packet", "designer packet synthesized before binding",
        SYNTHESIS_FILE=f.data("designer-synthesis.json", {"dropped": [], "added": []}))
    designer_ref = bind("designer bound to its own packet", REQUIRED_BINDINGS="packet_id packet_pointer", NATIVE_MODEL="gpt-6-astra-high")
    designer_version = json.loads(Path(designer_ref["manifest_path"]).read_text())["producer"]["template_version"]
    reply = root / "reply.md"
    reply.write_text("consultation-id: wrong\nhandler: agent\n")
    run("check-reply", "reply identity refused", REPLY_FILE=reply, CONSULTATION_ID="storage-question",
        DESIGNER_TEMPLATE_VERSION=designer_version, expected=1)
    reply.write_text(f"consultation-id: storage-question\nhandler: agent\nadvisor_template_version: {designer_version}\nadvisor-acknowledged: true\n**Domain:** storage\n**Guidance:** Use the assigned root.\n**Key files:** tracked\n")
    run("check-reply", "acknowledged reply")
    run("consult-log", "empty answer refused", HANDLER="agent", ANSWER="", QUESTION="Where is the execution root?",
        ADVISOR_TEMPLATE_VERSION=designer_version, SKILL_TEMPLATE_VERSION="", expected=1)
    assert not (item / "consultation-transcript.jsonl").exists()
    run("consult-log", "compiled acknowledged consultation", ANSWER="Use the assigned execution root.")
    consultation = dict(consultation_id="storage-question", handler="agent", domain="storage",
                        advisor_template_version=designer_version, query_summary="Where is the execution root?",
                        advice_summary="Use the assigned root.", was_followed=True)
    transcript = item / "consultation-transcript.jsonl"
    assert json.loads(transcript.read_text().splitlines()[0])["consultation_id"] == "storage-question"
    for handler in ("lead", "skill"):
        run("consult-log", handler + " acknowledged consultation", HANDLER=handler,
            CONSULTATION_ID="optional-" + handler, DOMAIN="optional", SKILL_TEMPLATE_VERSION=v["LEAD_TEMPLATE_VERSION"])

    snippet_hash = run("snippet-hash", SNIPPET="observable source").stdout.decode().strip()
    worker_claim = {"claim_id": "observed-source", "tier": "task-evidence", "claim": "The assigned root contains observable source.",
        "producer_role": "worker", "protocol_slot": "Implementation", "task_id": "task-1", "scale": "implementation",
        "file": str(f.code / "tracked"), "line_range": "1-1", "exact_snippet": "observable source", "normalized_snippet_hash": snippet_hash,
        "falsifier": "The assigned root has no observable source line.", "why_this_work_needs_it": "Ground the report in the execution root.",
        "captured_at_sha": f.call(["git", "rev-parse", "HEAD"]).stdout.decode().strip(),
        "change_context": {"summary": "Inspect source in the assigned root.", "changed_files": [str(f.code / "tracked")]},
        "position_dispatch": {"manifest_path": first_ref["manifest_path"], "manifest_sha256": first_ref["manifest_sha256"]}}
    run("append-tier2", "compiled worker evidence", ROW_FILE=f.data("worker-claim.json", worker_claim))
    report_input = f.report_input(first_bindings, first_ref, consultation=consultation, claim_id="observed-source")
    v.update(REFERENCE_FILE=first_reference_file, REPORT_PATH=first_bindings["report_path"], REPORT_ID=first_bindings["report_id"],
             REVISION_ID=first_bindings["revision_id"], TASK_ID="task-1", REPORT_BODY_FILE=report_input)
    run("typed-completion", "report missing before landing", expected=2)
    run("land-report", "land before checks")
    landed = Path(v["REPORT_PATH"]).read_bytes()
    run("land-report", "report id cannot overwrite prior attempt", expected=4)
    assert Path(v["REPORT_PATH"]).read_bytes() == landed
    run("check-identity", "independent reference read")
    run("typed-completion", "compiled report completion")
    run("check-report", "required consultation transcript absent", TRANSCRIPT_FILE="", PROVIDER_STATUS="full",
        SPAWNED_ADVISORS="storage", expected=1)
    checks = obj(run("check-report", "required consultation acknowledged", TRANSCRIPT_FILE=transcript))
    assert checks["mechanical_pass"] is True
    assert run("provider-status").stdout.decode().strip() in {"full", "partial", "unavailable"}

    result = obj(run("criteria-run", "actual bound execution", CRITERION_ID="observe", EXECUTION_ROOT=f.code,
                     PACKET_ID=first_bindings["packet_id"], UNBOUND_REASON=""))
    rows = [json.loads(line) for line in (item / "results.jsonl").read_text().splitlines()]
    executed = rows[-1]
    assert executed["state"] == "pass" and (f.code / "execution-count").read_text() == "1"
    ledger = (item / "results.jsonl").read_bytes()
    run("criteria-recover", "recovery preserves completed execution", RESULT_ID=executed["result_id"])
    assert (item / "results.jsonl").read_bytes() == ledger and (f.code / "execution-count").read_text() == "1"
    prepared = obj(run("review-prepare", "frozen integration input", ATTEMPT_ID="integration-1"))
    review_output = root / "review.md"
    review_output.write_text("The recorded command ran in the assigned root, and the report cites the original attempt.\n")
    dispositions = f.data("review-dispositions.json", {"schema_version": 1, "outcome": "completed", "verdict": "PASS", "reason": None,
        "judgments": [{"purpose": "integration", "judgment": "consistent", "rationale": "The recorded execution supports the inspected source.", "result_ids": [executed["result_id"]]}], "dispositions": []})
    evaluator = f.data("evaluator.json", {"evaluator_locator": "fixture://seat", "evaluator_template_version": v["LEAD_TEMPLATE_VERSION"],
        "framework": "codex", "model": "fixture-seat", "final_round": 1})
    sealed = obj(run("review-seal", "seal actual result citation", OUTPUT_FILE=review_output, DISPOSITIONS_FILE=dispositions, EVALUATOR_FILE=evaluator))
    citations = json.loads((item / "reviews/integration-1/sealed/cited-results.json").read_text())
    assert citations["results"][0]["row"] == executed

    reduction = root / "worker-reduction.md"
    reduction.write_text("Task: Observe history 1 [class: mechanical]\nChanges: tracked: inspected source\nSkills: None\nTier2-claims: observed-source\nObservations: None\nConvention: none in scope\nInvestigation: None\nBlockers: none\nConsultations: none\nSurfaced concerns: None\nTest result: passed\n")
    worker_version = json.loads(Path(first_ref["manifest_path"]).read_text())["producer"]["template_version"]
    run("log-reduction", "compiled producer and filer remain distinct", REDUCTION_FILE=reduction, PRODUCER_TEMPLATE_VERSION=worker_version,
        MANIFEST_PATH=first_ref["manifest_path"], MANIFEST_SHA256=first_ref["manifest_sha256"], PRODUCER_ROLE="worker")
    attribution = [json.loads(line.split(": ", 1)[1]) for line in (item / "execution-log.md").read_text().splitlines()
                   if line.startswith("Producer-attribution: ")][-1]
    assert attribution["status"] == "resolved" and attribution["template_version"] == worker_version
    note = root / "acceptance.md"
    note.write_text(f"Accept task-1 against {executed['result_id']} and reviews/integration-1/sealed/seal.json; source and result were inspected before progress.\n")
    run("work-note", "authored acceptance before progress", NOTE_FILE=note)
    subject1 = json.loads((item / "tasks.json").read_text())["tasks"][0]["subject"]
    run("check-task", "accepted first task progress", TASK_SUBJECT=subject1)
    current_revision = json.loads((item / "tasks.json").read_text())["revision_id"]
    assert current_revision != first_bindings["revision_id"]
    resumed = obj(run("impl-start", "resume with prior claims"))
    assert resumed["prior_claims"]
    next_batch = obj(run("impl-next-batch", "subsequent ready task"))
    v.update(DISPATCH_JSON=f.data("next-batch.json", next_batch), TASK_ID="task-2", REVISION_ID=current_revision)
    paths("next-native")
    run("normalize-bindings", "subsequent normalization", REPORT_ID="next-native", EXECUTION_ROOT=f.code)
    next_binding = json.loads(v["BINDINGS_FILE"].read_text())
    assert next_binding["task_id"] == "task-2" and next_binding["revision_id"] == current_revision
    assert next_binding["packet_id"] != first_bindings["packet_id"]
    active = obj(run("impl-next-batch", "active task excluded", ACTIVE_TASK_IDS="task-2"))
    assert active["status"] == "all-blocked" and not active["batch"]
    opened("resume selected remainder", TASK_IDS="task-2")

    inline_claim = dict(worker_claim, claim_id="inline-source", producer_role="implement-lead", task_id="task-2")
    inline_claim.pop("position_dispatch")
    run("append-tier2", "truthful lead-inline evidence", ROW_FILE=f.data("inline-claim.json", inline_claim))
    inline_id = "inline-second"
    inline_report = root / "inline-report.md"
    inline_report.write_text(report_input.read_text().replace("Report-id: native-first", "Report-id: " + inline_id)
                             .replace("Producer-role: worker", "Producer-role: implement-lead")
                             .replace("Dispatch-path: harness-subagent", "Dispatch-path: lead-inline")
                             .replace(worker_version, v["LEAD_TEMPLATE_VERSION"])
                             .replace("Observe history 1", "Observe history 2")
                             .replace("- observed-source", "- inline-source"))
    # A local contribution has no worker dispatch reference to borrow.
    inline_report.write_text("\n".join(line for line in inline_report.read_text().splitlines()
                                      if not line.startswith(("Position-dispatch-", "Packet-id:", "Revision-id:", "Dispatch-attempt-id:"))) + "\n")
    run("land-report", "lead-inline report persistence", REPORT_ID=inline_id, REPORT_BODY_FILE=inline_report)
    inline_path = item / "worker-reports" / (inline_id + ".md")
    assert "Producer-role: implement-lead" in inline_path.read_text() and "Position-dispatch-manifest:" not in inline_path.read_text()
    run("check-report", "inline task uses current canonical task id", REPORT_PATH=inline_path, REVISION_ID=current_revision,
        TRANSCRIPT_FILE="", PROVIDER_STATUS="unavailable", SPAWNED_ADVISORS="")
    second_result = obj(run("criteria-run", "lead-inline execution with declared unbound reason", PACKET_ID="",
                            UNBOUND_REASON="The implement lead performs this task inline.", EXECUTION_ROOT=f.code))
    assert (f.code / "execution-count").read_text() == "2"
    inline_key = v["RUN_STARTED_AT"] + "/task-2"
    inline_reduction = root / "inline-reduction.md"
    inline_reduction.write_text("Report-key: " + inline_key + "\n" + reduction.read_text().replace("history 1", "history 2").replace("observed-source", "inline-source"))
    run("log-reduction", "inline producer is the lead", REDUCTION_FILE=inline_reduction, PRODUCER_TEMPLATE_VERSION=v["LEAD_TEMPLATE_VERSION"],
        MANIFEST_PATH="", MANIFEST_SHA256="", PRODUCER_ROLE="implement-lead")
    run("readback-report", "durable inline report and unique reduction", REPORT_KEY=inline_key)
    run("inline-commit", "selected task count refuses false completion", TASK_COUNT="2", expected=1)
    run("inline-commit", "all selected inline reports read back", TASK_COUNT="1")
    entry = root / "lead-entry.md"
    entry.write_text("Lead-invoked skill: fixture validation\nDomain: recipe behavior\nSkill template-version: " + v["LEAD_TEMPLATE_VERSION"] + "\n")
    run("lead-log", ENTRY_FILE=entry, TEMPLATE_VERSION=v["LEAD_TEMPLATE_VERSION"])
    run("followup-divergence", "unconvincing divergence creates nonblocking followup", TASK_SUBJECT="Observe history 2",
        CONTENT="The report needs a clearer explanation of the retained naming convention.")
    note.write_text("Accept task-2 after reading its durable inline report and actual command result.\n")
    run("work-note", "inline acceptance before progress", NOTE_FILE=note)
    subject2 = json.loads((item / "tasks.json").read_text())["tasks"][1]["subject"]
    run("check-task", TASK_SUBJECT=subject2)
    complete = obj(run("impl-next-batch", "all complete", ACTIVE_TASK_IDS=""))
    assert complete["status"] == "all-complete" and not complete["batch"]
    v["REVISION_ID"] = json.loads((item / "tasks.json").read_text())["revision_id"]
    run("review-prepare", "final revision retains historical execution citations", ATTEMPT_ID="integration-final")
    run("review-seal", "historical citation sealed without rewriting results")
    assert (item / "results.jsonl").read_text().count(executed["result_id"]) >= 1

    run("promote-batch", "empty accepted set is still recorded", CANDIDATES_FILE=f.data("empty-candidates.json", []),
        ADVISOR_TEMPLATE_VERSION=started["template_versions"]["advisor"])
    assert "0 accepted, 0 rejected" in (item / "execution-log.md").read_text()
    for kind in ("fact", "hypothesis", "question"):
        before = set(f.store.rglob("*.md"))
        run("capture-discovery", kind + " discovery", KIND=kind, SCALE="implementation", WHERE_LOOKED="tracked source and execution output",
            INSIGHT={"fact": "The isolated source contains the observable source line; falsified if tracked no longer contains it.",
                     "hypothesis": "The source marker survives repeated reads; test by reading tracked twice.",
                     "question": "Does the source marker retain its newline after a rewrite?"}[kind])
        added = set(f.store.rglob("*.md")) - before
        entries = [p for p in added if not any(part.startswith("_") for part in p.relative_to(f.store).parts)]
        assert entries, (kind, added)
        if kind == "hypothesis":
            hypothesis = entries[0]
    run("claim-record", "crossed test corroborates and settles", KNOWLEDGE_PATH=hypothesis, DIRECTION="supports",
        NOTE="Two reads of tracked returned the same bytes.", KIND_STATUS="supported")
    assert "supported" in hypothesis.read_text() and "corroborations" in hypothesis.read_text()

    note.write_text("Two of two tasks completed; two canonical claims; empty promotion evaluated. Capability remains partial pending the external delivery loop.\n")
    run("work-note", "closure context persisted", NOTE_FILE=note)
    empty_tasks = root / "checked-subjects.txt"
    empty_tasks.write_text("")
    run("impl-close", "partial capability verdict preserves parent and creates residue", VERDICT="partial", SUMMARY="Execution and report history are inspectable.",
        DIVERGENCE="The external delivery loop remains unexercised.", RESIDUE_TITLE="External delivery loop", RESIDUE_ANCHOR="Exercise the external delivery loop.",
        CHECK_TASKS_FILE=empty_tasks, TIER3_ACCEPTED="0", TIER3_REJECTED="0", expected=3)
    closure = json.loads((item / "_meta.json").read_text())["closure"]
    assert closure["verdict"] == "partial" and closure["residue_followup"]
    assert item.is_dir() and not (f.store / "_work/_archive/recipes").exists()
    run("impl-close", "authored full capability verdict archives before report", VERDICT="full", SUMMARY="The isolated command and report loop is complete.",
        DIVERGENCE="", RESIDUE_TITLE="", RESIDUE_ANCHOR="")
    archived = f.store / "_work/_archive/recipes"
    assert archived.is_dir() and not item.exists()
    bundle = json.loads((archived / "retro-bundle.json").read_text())
    assert len(bundle) == 10 and "task_attribution" in bundle
    assert (archived / "reviews/integration-final/sealed/cited-results.json").is_file()

    recovery_item = f.create_item("recovery")
    f.write_plan(recovery_item)
    recovery_plan = recovery_item / "plan.md"
    recovery_plan.write_text(recovery_plan.read_text().replace("execution-count", "recovery-count")
                             .replace("print('executed in', Path.cwd())", "print('executed in', Path.cwd()); import time; time.sleep(20)"))
    run("plan-publish", "publish interruptible criterion", SLUG="recovery", REASON="Observe interrupted execution recovery.")
    recovery_revision = json.loads((recovery_item / "tasks.json").read_text())["revision_id"]
    killed = run("criteria-run", "actual supervisor interruption", expected=None, interrupt_criterion=True,
                 TASK_ID="task-1", CRITERION_ID="observe", EXECUTION_ROOT=f.code, PACKET_ID="", REVISION_ID=recovery_revision,
                 UNBOUND_REASON="The isolated fixture interrupts this execution to exercise recovery.")
    allocated = json.loads(killed.stderr.splitlines()[0])
    run("criteria-recover", "unavailable recovery does not rerun command", RESULT_ID=allocated["result_id"], expected=2)
    recovered = json.loads((recovery_item / "results.jsonl").read_text().splitlines()[-1])
    assert recovered["state"] == "unavailable" and recovered["reason"] == "interrupted-without-durable-completion"
    assert (f.code / "recovery-count").read_text() == "1"

    allocation_item = f.create_item("allocation")
    allocation = obj(run("allocate-worktree", "real isolated seat allocation", SLUG="allocation", STREAM_ID="native", ATTEMPT_ID="native-1",
                          OWNER_ID="fixture-seat", SOURCE_DIR=f.code))
    assert Path(allocation["execution_dir"]).is_dir()
    assert Path(allocation["execution_dir"]).is_relative_to(root)
    assert allocation["owner"]["kind"] == "seat"

    f.save()
    assert_coverage(f.document, f.bodies)
    print(json.dumps({"inventory": str(root / "inventory.json"), "recipes": len(f.rows)}), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "skills/implement/SKILL.md")
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    if args.run:
        if args.root is None:
            parser.error("--run requires --root")
        exercise_recipes(Path(__file__).resolve().parents[2], args.root, args.source)
        return
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
