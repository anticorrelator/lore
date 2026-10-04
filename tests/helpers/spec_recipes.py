#!/usr/bin/env python3
"""Execute the spec skill's exact recipes through isolated, real writers."""

import argparse
import copy
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "vendor"))  # lore's vendored PyYAML
import yaml  # noqa: E402

from implement_recipes import Fixture, assert_coverage, capture_prepared_launch, digest, inventory


RECIPE_FILES = ("skills/spec/SKILL.md", "skills/spec/commissioning.md")
PROSE_FILES = RECIPE_FILES + ("skills/spec/templates/plan.md", "docs/position-report-contracts.md")
ROLES = ("lead", "worker", "worker-mechanical", "worker-judgment-dense", "researcher", "reviewer", "advisor", "default")


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def tree_hashes(root):
    return {str(p.relative_to(root)): digest(p.read_bytes()) for p in root.rglob("*") if p.is_file()}


def rejects(operation, message):
    try:
        operation()
    except (AssertionError, ValueError) as exc:
        assert message in str(exc), str(exc)
    else:
        raise AssertionError("negative control passed: " + message)


def extraction_controls(root):
    root.mkdir(parents=True, exist_ok=True)
    source = root / "spec.md"
    original = ("Recipe inputs: none\n<!-- spec-recipe: first -->\n"
                "```bash\nprintf '%s\\n' 'literal $HOME; `value`'\n```\n"
                "Recipe inputs: none\n<!-- spec-recipe: inline -->\n`true`\n"
                '```json\n{"state":"example"}\n```\n'
                '```yaml\nstate: example\n```\n').encode()
    source.write_bytes(original)
    document, bodies = inventory(source, "spec")
    assert set(document) == {"schema_version", "source_path", "source_sha256", "recipes", "declarative_examples"}
    assert document["schema_version"] == 1
    assert bodies["first"] == b"printf '%s\\n' 'literal $HOME; `value`'\n"
    assert bodies["inline"] == b"true"
    assert all(row["validation"] == "parsed" for row in document["declarative_examples"])
    rejects(lambda: inventory(source), "unmarked executable")
    rejects(lambda: assert_coverage(document, bodies, "spec"), "unexercised")
    covered = copy.deepcopy(document)
    # This synthetic row tests the coverage checker, not recipe execution.
    for row in covered["recipes"]:
        row["executions"] = [{"body_sha256": row["body_sha256"]}]
    assert_coverage(covered, bodies, "spec")
    changed = copy.deepcopy(covered)
    changed["recipes"][0]["executions"][0]["body_sha256"] = "0" * 64
    rejects(lambda: assert_coverage(changed, bodies, "spec"), "changed recipes")
    source.write_bytes(original + b"Recipe inputs: none\n<!-- spec-recipe: added -->\n`true`\n")
    added, added_bodies = inventory(source, "spec")
    for row in added["recipes"]:
        if row["id"] in bodies:
            row["executions"] = [{"body_sha256": row["body_sha256"]}]
    rejects(lambda: assert_coverage(added, added_bodies, "spec"), "unexercised")
    source.write_bytes(original.replace(b"literal", b"changed"))
    rejects(lambda: assert_coverage(covered, bodies, "spec"), "source changed")
    for extra, reason in [
        ("```python\nprint('unmarked')\n```\n", "unmarked executable"),
        ("<!-- spec-recipe: BAD -->\n`true`\n", "invalid recipe marker"),
        ("<!-- spec-recipe: data -->\n```json\n{}\n```\n", "declarative fence"),
        ("<!-- spec-recipe: orphan -->\n", "has no body"),
        ("Recipe inputs: none\n<!-- spec-recipe: first -->\n`true`\n", "duplicate recipe"),
        ("<!-- spec-recipe: unknown -->\n```ruby\nputs 'x'\n```\n", "declarative fence"),
        ("```bash\ntrue\n", "unterminated fence"),
        ("```json\nnot json\n```\n", "Expecting value"),
    ]:
        source.write_bytes(original + extra.encode())
        rejects(lambda: inventory(source, "spec"), reason)
    source.write_text("<!-- spec-recipe: missing-input -->\n`true`\n")
    rejects(lambda: inventory(source, "spec"), "missing Recipe inputs")
    source.write_bytes(original)
    rejects(lambda: inventory(source, "bad namespace"), "invalid recipe namespace")

    second = root / "commissioning.md"
    second_original = b"Recipe inputs: none\n<!-- spec-recipe: second -->\n`true`\n"
    second.write_bytes(second_original)
    combined, combined_bodies = inventory([source, second], "spec")
    assert set(combined) == set(document) and combined["source_path"] == [str(source), str(second)]
    assert {row["id"]: row["source_path"] for row in combined["recipes"]} == {
        "first": str(source), "inline": str(source), "second": str(second)}
    rejects(lambda: assert_coverage(combined, combined_bodies, "spec"), "unexercised")
    covered = copy.deepcopy(combined)
    for row in covered["recipes"]:
        row["executions"] = [{"body_sha256": row["body_sha256"]}]
    assert_coverage(covered, combined_bodies, "spec")
    second.write_bytes(second_original + b"Recipe inputs: none\n<!-- spec-recipe: added -->\n`true`\n")
    added, added_bodies = inventory([source, second], "spec")
    for row in added["recipes"]:
        if row["id"] in combined_bodies:
            row["executions"] = [{"body_sha256": row["body_sha256"]}]
    rejects(lambda: assert_coverage(added, added_bodies, "spec"), "unexercised")
    rejects(lambda: assert_coverage(covered, combined_bodies, "spec"), "source changed")
    second.write_bytes(b"Recipe inputs: none\n<!-- spec-recipe: first -->\n`true`\n")
    rejects(lambda: inventory([source, second], "spec"), "duplicate recipe")
    second.write_bytes(second_original)
    rejects(lambda: inventory([], "spec"), "no recipe sources")

    empty = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--scenario", "not-a-scenario", "--root", str(root / "empty")], capture_output=True)
    assert empty.returncode == 2 and b"invalid choice" in empty.stderr
    assert not (root / "empty").exists()
    print("One spec namespace spans both prose files at schema 1 and rejects missing coverage, drift, cross-file duplicates and malformed recipes; empty scenario selection refuses")


def compose_source(repo, destination, prose_ref=None):
    """Retain the tested scripts and exact committed prose as separate inputs."""
    destination.mkdir(parents=True)
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=repo).decode().split("\0")
    for name in filter(None, names):
        source = repo / name
        if source.is_file():
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    prose_commit = subprocess.check_output(["git", "rev-parse", prose_ref or "HEAD"], cwd=repo).decode().strip()
    for name in PROSE_FILES:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if prose_ref:
            target.write_bytes(subprocess.check_output(["git", "show", f"{prose_commit}:{name}"], cwd=repo))
        else:
            shutil.copy2(repo / name, target)
    record = {"fixture_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo).decode().strip(),
              "prose_commit": prose_commit, "prose_override": bool(prose_ref),
              "files": {str(p.relative_to(destination)): digest(p.read_bytes())
                        for p in destination.rglob("*") if p.is_file()}}
    (destination.parent / "source-identity.json").write_text(json.dumps(record, indent=2) + "\n")
    return destination


class SpecFixture(Fixture):
    def __init__(self, repo, root):
        super().__init__(repo, root, [repo / name for name in RECIPE_FILES], "spec")
        self.values = dict(SCRIPTS_DIR=repo / "scripts", KNOWLEDGE_DIR=self.store, SLUG="recipes")
        assert Path(shutil.which("lore", path=self.env["PATH"])).resolve() == repo / "cli/lore"
        self.settings_path = self.root / "data/config/settings.json"
        self.write_settings({"version": 2, "tui_launch_framework": "codex",
                             "routes": {role: "codex/gpt-6-astra" for role in ROLES},
                             "harnesses": {"codex": {"args": [], "native_models": {"default": "gpt-6-astra"}}},
                             "coordination": {"max_concurrency": 2}})
        self.timings = []
        self.connections = []

    def settings(self):
        return json.loads(self.settings_path.read_text())

    def write_settings(self, settings):
        self.settings_path.write_text(json.dumps(settings))

    def connection(self, name, *, producer, consumer, value, actor, revision=None, attempt=None):
        self.connections.append(dict(name=name, producer=producer, consumer=consumer, value=str(value),
                                     actor=actor, revision=revision, attempt=attempt))
        self.data("handoff-trace.json", self.connections)

    def measure(self, runner, name, scenario, inputs, start):
        row = runner.rows[name]
        extension = "py" if row["language"] in {"python", "python3"} else "sh"
        script = self.root / "outputs" / f"{self.sequence:03d}-{name}.{extension}"
        argv = [sys.executable, str(script)] if extension == "py" else ["bash", "-eu", str(script)]
        execution = row["executions"][-1] if row["executions"] else {}
        self.timings.append({"recipe": name, "scenario": scenario, "cwd": str(self.code), "argv": argv,
                             "inputs": {key: str(value) for key, value in inputs.items()},
                             "environment": {key: value for key, value in self.env.items() if key in
                                             {"PATH", "HOME", "LORE_ROOT", "LORE_DATA_DIR", "LORE_KNOWLEDGE_DIR",
                                              "LORE_FRAMEWORK", "GOTOOLCHAIN", "GOMODCACHE", "GOCACHE", "LORE_TEST_GO"}},
                             "elapsed_seconds": time.monotonic() - start, **execution})
        (self.root / "recipe-timings.json").write_text(json.dumps(self.timings, indent=2) + "\n")

    def recipe(self, name, scenario, expected=0, **values):
        assert set(values) <= set(self.rows[name]["inputs"]), (name, "undeclared supplied inputs", set(values) - set(self.rows[name]["inputs"]))
        self.values.update(values)
        inputs = {key: self.values[key] for key in self.rows[name]["inputs"]}
        start = time.monotonic()
        try:
            return self.run(name, inputs, scenario, expected)
        finally:
            self.measure(self, name, scenario, inputs, start)

    def finish(self, required):
        missing = set(required) - {row["id"] for row in self.document["recipes"] if row["executions"]}
        assert not missing, "scenario did not execute required recipes: " + ", ".join(sorted(missing))
        self.save()
        print(json.dumps({"inventory": str(self.root / "inventory.json"), "executed": sorted(required)}))

    def investigator_report(self, bindings, reference, assertions=None, *, key_files=None, **sections):
        manifest = json.loads(Path(reference["manifest_path"]).read_text())
        headers = {"Template-version": manifest["producer"]["template_version"],
                   "Position-dispatch-manifest": reference["manifest_path"],
                   "Position-dispatch-sha256": reference["manifest_sha256"],
                   "Report-id": bindings["report_id"], "Packet-id": bindings["packet_id"],
                   "Dispatch-attempt-id": bindings["dispatch_attempt_id"]}
        if bindings["revision_id"]:
            headers["Revision-id"] = bindings["revision_id"]
        contents = {"Question": "Which committed bytes ground this investigation?",
                    "Findings": "The tracked file contains observable source.",
                    "Key files": yaml.safe_dump(key_files if key_files is not None else [str(self.code / "tracked")]),
                    "Implications": "Keep the committed source and report identities available to the designer.",
                    "Assertions": yaml.safe_dump(assertions or []), "Observations": "None",
                    "Worker leads": "None", "Unknowns": "Live model receipt is outside this fixture."}
        contents.update(sections)
        text = "".join(f"{key}: {value}\n" for key, value in headers.items())
        text += "".join(f"**{key}:**\n{value.rstrip()}\n" for key, value in contents.items())
        source = self.root / (bindings["report_id"] + ".input.md")
        source.write_text(text)
        return source

    def claim(self, name, *, producer, task_id, bindings=None, reference=None, source=None, revision=None, **extra):
        sys.path.insert(0, str(self.repo / "scripts"))
        from snippet_normalize import hash_normalized
        source = source or self.code / "tracked"
        snippet = source.read_text().splitlines()[0]
        row = {"claim_id": name, "tier": "task-evidence", "claim": "The tracked source contains the observed first line.",
               "producer_role": producer, "protocol_slot": "spec", "task_id": task_id,
               "scale": "implementation", "file": str(source), "line_range": "1-1", "exact_snippet": snippet,
               "normalized_snippet_hash": hash_normalized(snippet), "falsifier": "The committed first line differs.",
               "why_this_work_needs_it": "Check collection against committed source.",
               "captured_at_sha": revision or self.call(["git", "rev-parse", "HEAD"]).stdout.decode().strip(),
               "change_context": {"summary": "Fixture source", "changed_files": [str(source)], "diff_ref": None},
               "significance": "low", **extra}
        if bindings is not None:
            row.update(report_id=bindings["report_id"], dispatch_attempt_id=bindings["dispatch_attempt_id"],
                       position_dispatch={key: reference[key] for key in ("manifest_path", "manifest_sha256")})
        return row


def source_checkout(f, item):
    instances = f.store / "_sessions/instances"
    instances.mkdir(parents=True, exist_ok=True)
    (instances / "fixture.json").write_text(json.dumps({"name": "fixture", "project_dir": str(f.code)}))
    f.lore("work", "source-checkout", item.name, "--from-instance", "fixture")


def authored_plan(f, item, *, concrete=False, retrieval="v2"):
    text = """# Recipe behavior
## Goal
Keep investigation and plan history available to the next reader.
## Narrative
The investigation supplies source facts. The design explains how to preserve them.
## Intent Anchor
Preserve execution and dispatch history.

**Scope delta:** none
**Tempting narrower implementation:** Publish tasks without the investigation history.
## Investigations
### Source history
**Question:** Which bytes ground this plan?
**Findings:** The tracked file contains observable source.
**Key files:** tracked
**Implications:** Keep immutable identities available.
**Observations:** None
## Design Decisions
### D1: Preserve history
**Decision:** Retain source and report identity.
**Rationale:** A later reader can recover the basis of the design.
**Alternatives considered:** An unbound summary loses that basis.
**Applies to:** Task 1.
"""
    if concrete:
        criterion = [{"id": "observe", "intent": "The committed source remains readable.",
                      "argv": [sys.executable, "-c", "from pathlib import Path; assert Path('tracked').read_text() == 'observable source\\n'"],
                      "cwd": ".", "timeout": 10, "expected_exit": 0}]
        directive = ""
        if retrieval == "v2":
            directive = "**Retrieval directive:**\n```yaml\n" + yaml.safe_dump({"retrieval_directive": {
                "version": 2, "topics": [{"role": "focal", "topic": "source history", "seeds": ["tracked"],
                                          "scale_set": ["implementation"], "limit": 8}], "hop_budget": 1}}, sort_keys=False) + "```\n"
        elif retrieval == "legacy":
            directive = "**Retrieval directive:**\n- seeds: tracked\n- scale_set: implementation\n- hop_budget: 1\n"
        text += """## Tasks
**Merge rationale:** One source history boundary owns this change.
### Task 1: Preserve source history
**Deliverable:** Inspectable source history.
**Files:** `tracked`
**Scope:**
- Output contract: The committed source remains inspectable.
**Close criteria:**
```json
""" + json.dumps(criterion) + "\n```\n" + directive + "- [ ] Implement source history in `tracked` [class: mechanical]\n"
    text += "\n## Open Questions\n- None\n"
    (item / "plan.md").write_text(text)
    return text


def synthesized_packet(f, recipe, *, role, **values):
    result = json.loads(f.recipe(recipe, "build fresh " + role + " packet", **values).stdout)
    packet_id = result["packet_id"]
    packet = json.loads(f.lore("packet", "show", packet_id, "--json").stdout)
    assert packet["recipient_role"] == role and packet["delivery_stage"] == "assembled"
    dispositions = f.data(packet_id + "-synthesis.json", {"dropped": [], "added": []})
    f.recipe("packet-synthesis", "record explicit keep-all applicability before binding " + role,
             PACKET_ID=packet_id, SYNTHESIS_FILE=dispositions)
    latest = json.loads(f.lore("packet", "show", packet_id, "--json").stdout)
    assert latest["delivery_stage"] == "synthesized" and latest["synthesis"]["by"] == "spec-lead"
    assert latest["content"] == packet["content"]
    delivered = f.data(packet_id + "-delivery.json", latest)
    return packet_id, delivered


def wave_manifest():
    return {"schema_version": 1, "track": "full", "investigations": [
        {"id": "source", "kind": "lead-authored", "question": "Which source bytes must remain inspectable?",
         "complexity": "moderate", "prefetch": []},
        {"id": "history", "kind": "lead-authored", "question": "Which report identities must the plan retain?",
         "complexity": "simple", "prefetch": [{"query": "source history", "scale_set": ["subsystem", "implementation"]}]}]}


def declare_sessions(f, document, bindings_dir, model, *, scenario):
    draft = f.data("investigations-draft.json", document)
    declared = f.root / "investigations.json"
    f.recipe("declare-dispatch", scenario, INVESTIGATIONS_DRAFT=draft, BINDINGS_DIR=bindings_dir,
             TARGET_FRAMEWORK="codex", MODEL=model, INVESTIGATIONS_JSON=declared)
    return declared


def bind_investigation(f, inv, bindings_dir, report_id, scenario, execution_root=""):
    packet_id, _ = synthesized_packet(f, "investigator-packet", role="investigator", INVESTIGATION_ID=inv["id"],
                                      QUERY=inv["question"], SCALE_SET="implementation")
    f.recipe("investigator-bindings", scenario, PACKET_ID=packet_id, INVESTIGATION_ID=inv["id"], QUESTION=inv["question"],
             COMPLEXITY=inv["complexity"], REPORT_ID=report_id, EXECUTION_ROOT=execution_root,
             BINDINGS_FILE=bindings_dir / (inv["id"] + ".json"))
    return packet_id


def directive_context(f, dispatch_file, name, scenario, label=None):
    context_file = f.root / ((label or name) + "-context.json")
    reference_file = f.root / ((label or name) + "-directive-reference.json")
    summary = json.loads(f.recipe("directive-context", scenario, DISPATCH_JSON=dispatch_file, INVESTIGATION_ID=name,
                                  CONTEXT_FILE=context_file, REFERENCE_FILE=reference_file).stdout)
    return summary, context_file, reference_file


def host_launch(f, context_file, *, framework="codex", root=None):
    # This invokes the host's real preparation writer; it starts no model process.
    return json.loads(f.call([sys.executable, str(f.repo / "scripts/position-bind.py"), "launch", "--framework", framework,
                             "--slug", "recipes--w1", "--execution-root", str(root or f.code), "--kdir", str(f.store)],
                            input=context_file.read_bytes()).stdout)


def host_reference(f, context_file, *, framework="codex", root=None):
    root = root or f.code
    launched = host_launch(f, context_file, framework=framework, root=root)
    result = f.recipe("session-reference", "read the independent prepared reference after host publication",
                      CONTEXT_FILE=context_file)
    reference_file = context_file.with_name(context_file.stem + "-session-reference.json")
    reference_file.write_bytes(result.stdout)
    collected = json.loads(result.stdout)
    assert collected["reference"] == launched["reference"]
    assert collected["bindings"]["execution_root"] == str(root)
    assert collected["delivery_proven"] is False
    assert Path(collected["reference"]["payload_path"]).read_text() == launched["payload"]
    return collected, reference_file


def enqueue(f, context_file, session_route, *, fixed=False):
    # The declared fixture host remains live while these serial steps execute.
    (f.store / "_sessions/instances/fixture.json").touch()
    result = f.recipe("request-session", "enqueue " + ("fixed" if fixed else "ordinary") + " prepared session",
                      SESSION_SLUG="recipes--w1", SESSION_ROUTE=json.dumps(session_route), CONTEXT_FILE=context_file,
                      TARGET_INSTANCE="", MIN_VINTAGE="", WORKTREE_ID="fixture-worktree" if fixed else "",
                      EXECUTION_DIR=str(f.code) if fixed else "")
    queued = json.loads((f.store / json.loads(result.stdout)["path"]).read_text())
    assert queued["framework"] == session_route["framework"] and queued["model"] == session_route["model"]
    assert queued["extra_context"] == json.loads(context_file.read_text())
    assert queued["placement_stance"] == "required_dir" and queued["required_project_dir"] == str(f.code)
    if fixed:
        assert queued["execution_dir"] == str(f.code) and queued["worktree_id"] == "fixture-worktree"
    else:
        assert not {"execution_dir", "worktree_id"} & queued.keys()
    return queued


def refuse_missing_placement(f, context_file):
    original = f.bodies["request-session"]
    lines = original.splitlines(keepends=True)
    placement = [line for line in lines if b'args+=(--target "$TARGET_INSTANCE")' in line]
    assert len(placement) == 1 and b'args+=(--anywhere)' in placement[0]
    changed = original.replace(placement[0], b"")
    script = f.root / "negative-missing-placement.sh"
    script.write_bytes(changed)
    declared = {key: str(f.values[key]) for key in f.rows["request-session"]["inputs"]}
    declared["CONTEXT_FILE"] = str(context_file)
    before = tree_hashes(f.store / "_sessions/requests")
    result = subprocess.run(["bash", "-eu", str(script)], cwd=f.code, env={**f.env, **declared}, capture_output=True)
    assert result.returncode == 1, result.stderr
    assert b"placement stance" in result.stdout + result.stderr, (result.stdout, result.stderr)
    assert tree_hashes(f.store / "_sessions/requests") == before
    output = f.root / "negative-missing-placement.output"
    output.write_bytes(result.stdout + result.stderr)
    f.data("negative-missing-placement.json", {"source_sha256": digest(original), "mutated_sha256": digest(changed),
           "mutation": "Remove the explicit target/anywhere stance from the authored recipe.",
           "inputs": declared, "exit_code": result.returncode, "output": str(output)})


def collect_report(f, collected, reference_file, name):
    b, reference = collected["bindings"], collected["reference"]
    source = f.investigator_report(b, reference)
    f.recipe("land-report", "land returned report " + name, REPORT_ID=b["report_id"], REPORT_BODY_FILE=source)
    f.recipe("check-identity", "check the independently held reference " + name, REPORT_PATH=b["report_path"],
             REFERENCE_FILE=reference_file)
    f.recipe("typed-completion", "type the report before accepting its findings " + name, TASK_ID="")
    return Path(b["report_path"])


def collect_report_with_assertion(f, collected, reference_file, name):
    b, reference = collected["bindings"], collected["reference"]
    f.recipe("typed-completion", "typing cannot complete an unlanded report", expected=2,
             REFERENCE_FILE=reference_file, TASK_ID="")
    producer_version = collected["producer"]["template_version"]
    claim = f.claim("claim-" + name, producer="researcher", task_id=name, bindings=b, reference=reference,
                    template_version=producer_version)
    hashed = f.recipe("snippet-hash", "canonical normalizer grounds the collected assertion",
                      SNIPPET=claim["exact_snippet"]).stdout.decode().strip()
    assert hashed == claim["normalized_snippet_hash"]
    f.recipe("append-tier2", "the seat appends the investigator's assertion under researcher attribution",
             ROW_FILE=f.data(name + "-claim.json", claim))
    source = f.investigator_report(b, reference, [claim])
    source.write_bytes(source.read_bytes() + b"\n\n\n")
    f.recipe("land-report", "land the complete report before checking identity",
             REPORT_ID=b["report_id"], REPORT_BODY_FILE=source)
    report = Path(b["report_path"])
    assert report.read_bytes() == source.read_bytes().rstrip(b"\n") + b"\n"
    assert report.read_bytes() != source.read_bytes()
    f.recipe("check-identity", "compare headers with the independently held reference",
             REPORT_PATH=report, REFERENCE_FILE=reference_file)
    claim_rows = rows(f.store / "_work/recipes/task-claims.jsonl")
    f.recipe("typed-completion", "landed assertions match their canonical rows", TASK_ID="")
    assert rows(f.store / "_work/recipes/task-claims.jsonl") == claim_rows
    assert {row["producer_role"] for row in claim_rows} == {"researcher"}
    f.recipe("land-report", "retry cannot overwrite the original report", expected=4)
    assert report.read_bytes() == source.read_bytes().rstrip(b"\n") + b"\n"
    item = f.store / "_work/recipes"
    lead_version = digest((f.repo / "skills/spec/SKILL.md").read_bytes())[:12]
    f.recipe("log-worker-leads", "worker leads preserve producer, filer and attempt reference",
             INVESTIGATION_ID=name, REPORT_ID=b["report_id"], WORKER_LEADS="Inspect tracked:1 when implementing source history.",
             PRODUCER_TEMPLATE_VERSION=producer_version, LEAD_TEMPLATE_VERSION=lead_version,
             MANIFEST_PATH=reference["manifest_path"], MANIFEST_SHA256=reference["manifest_sha256"])
    log = (item / "execution-log.md").read_text()
    assert "Inspect tracked:1" in log and b["report_id"] in log
    f.recipe("log-worker-leads", "an empty worker-leads block writes nothing", WORKER_LEADS="None",
             MANIFEST_PATH="", MANIFEST_SHA256="")
    return report


def exercise_synthesis(f):
    item = f.create_item()
    assert set(f.rows["packet-synthesis"]["inputs"]) == {"PACKET_ID", "SYNTHESIS_FILE"}
    entries = []
    tokens = ("KEEP-BODY-CONTENT-5921", "DROP-BODY-CONTENT-5921")
    for label, token in zip(("retained", "unneeded"), tokens):
        before = knowledge_entries(f)
        f.lore("capture", "--insight", "Source history synthesis " + label + " fixture convention.",
               "--example", token + "\n### Nested example heading\n" + token + "-TAIL",
               "--category", "conventions", "--scale", "implementation", "--producer-role", "spec-lead", "--work-item", "recipes")
        created = knowledge_entries(f) - before
        assert len(created) == 1
        entries.append(created.pop())
    inv = {"id": "synthesis", "kind": "lead-authored", "question": "Which source history conventions apply?",
           "complexity": "simple", "prefetch": []}
    packet = json.loads(f.recipe("investigator-packet", "assemble candidate source history before applicability",
                                INVESTIGATION_ID=inv["id"], QUERY="source history synthesis", SCALE_SET="implementation").stdout)
    packet_id = packet["packet_id"]
    candidate = json.loads(f.lore("packet", "show", packet_id, "--json").stdout)
    assert candidate["delivery_stage"] == "assembled"
    paths = [str(p.relative_to(f.store)) for p in entries]
    assert set(paths) <= {e["path"] for e in candidate["delivered_entries"]}
    assert all(token in candidate["content"] for token in tokens)
    candidate_file = f.data("candidate-packet.json", candidate)
    bindings_dir = f.root / "synthesis-bindings"
    bindings_dir.mkdir()
    f.recipe("investigator-bindings", "bind the candidate identity before testing its delivery stage",
             PACKET_ID=packet_id, INVESTIGATION_ID=inv["id"], QUESTION=inv["question"],
             COMPLEXITY=inv["complexity"], REPORT_ID="synthesis-report", EXECUTION_ROOT="",
             BINDINGS_FILE=bindings_dir / (inv["id"] + ".json"))
    document = {"schema_version": 1, "track": "full", "investigations": [inv]}
    declare_sessions(f, document, bindings_dir, "gpt-6-astra", scenario="declare the candidate packet as a session route")
    failed = f.recipe("spec-open", "open refuses a supplied candidate set", expected=1)
    assert b"synthesi" in (failed.stdout + failed.stderr).lower(), failed.stderr
    assert not (item / "spec-dispatch.json").exists() and not (item / "position-dispatch").exists()
    before = knowledge_entries(f)
    f.lore("capture", "--insight", "An independent delivery boundary fixture convention.", "--example", "ADDED-BODY-CONTENT-5921",
           "--category", "conventions", "--scale", "implementation", "--producer-role", "spec-lead", "--work-item", "recipes")
    created = knowledge_entries(f) - before
    assert len(created) == 1
    added = str(created.pop().relative_to(f.store))
    spec = f.data("synthesis-dispositions.json", {
        "dropped": [{"path": paths[1], "reason": "This question needs only the retained source-history convention."}],
        "added": [{"path": added, "reason": "Delivery identity is needed and was absent from the candidate set."}]})
    f.recipe("packet-synthesis", "curate rendered delivery through the native writer before handoff", PACKET_ID=packet_id, SYNTHESIS_FILE=spec)
    latest = json.loads(f.lore("packet", "show", packet_id, "--json").stdout)
    assert latest["delivery_stage"] == "synthesized"
    assert latest["synthesis"]["dropped"] == json.loads(spec.read_text())["dropped"]
    assert latest["synthesis"]["added"] == json.loads(spec.read_text())["added"]
    assert paths[1] not in {e["path"] for e in latest["delivered_entries"]}
    assert tokens[0] in latest["content"] and "ADDED-BODY-CONTENT-5921" in latest["content"]
    assert tokens[1] not in latest["content"] and tokens[1] + "-TAIL" not in latest["content"]
    rendered = f.recipe("seat-packet-show", "the receiver renders the latest synthesized row", PACKET_ID=packet_id).stdout.decode()
    assert tokens[0] in rendered and "ADDED-BODY-CONTENT-5921" in rendered and tokens[1] not in rendered
    history = [row for row in rows(f.store / "_packets/packets.jsonl") if row["packet_id"] == packet_id]
    assert [row["delivery_stage"] for row in history] == ["assembled", "synthesized"]
    assert history[0] == json.loads(candidate_file.read_text())
    work = json.loads(f.recipe("work-show", "projection retains one latest summary per packet identity").stdout)
    summaries = [row for row in work["evidence"]["packet_summary"] if row["packet_id"] == packet_id]
    assert len(summaries) == 1 and summaries[0]["delivery_stage"] == "synthesized"
    assert summaries[0]["synthesis"] == {"by": latest["synthesis"]["by"],
        **{key: len(latest["synthesis"][key]) for key in ("kept", "dropped", "added")}}
    assert summaries[0]["superseded_rows"] == 1
    opened = json.loads(f.recipe("spec-open", "the synthesized packet opens").stdout)
    dispatch_file = f.data("synthesis-dispatch.json", opened)
    payload = opened["directives"][0]["payload"]
    assert payload["bindings"]["packet_id"] == packet_id
    _, context_file, _ = directive_context(f, dispatch_file, inv["id"], "retain the admitted session context")
    enqueue(f, context_file, payload["session_route"])
    selected, reference_file = host_reference(f, context_file)
    collect_report(f, selected, reference_file, "synthesized")
    assert selected["bindings"]["packet_id"] == packet_id and selected["delivery_proven"] is False
    f.finish({"investigator-packet", "packet-synthesis", "investigator-bindings", "declare-dispatch", "spec-open",
              "directive-context", "seat-packet-show", "work-show", "request-session", "session-reference", "land-report",
              "check-identity", "typed-completion"})


def exercise_entry(f):
    r = f.recipe
    r("resolve-paths", "resolve only the selected checkout and isolated store")
    r("lore-defaults", "read isolated standing defaults")
    before = tree_hashes(f.store)
    started = json.loads(r("spec-start", "unresolved standalone entry creates no item or packet",
                          INPUT="new-fixture-capability", TRACK="short", MODEL_OVERRIDE="gpt-6-astra-high").stdout)
    assert started["resolved"] is False and started["track"] == "short"
    assert started["effective_lead_route"]["model"] == "gpt-6-astra"
    assert started["effective_lead_route"]["options"]["effort"] == "high"
    assert tree_hashes(f.store) == before
    r("seat-packet-build", "a packet cannot precede work creation", expected=2,
      TOPIC="source history", SCALE_SET="implementation")
    assert not (f.store / "_packets/packets.jsonl").exists()
    r("work-create", "create the resolved standalone item before its seat packet", TITLE="Recipe behavior",
      INTENT_ANCHOR="Preserve execution and dispatch history.")
    item = f.store / "_work/recipes"
    source_checkout(f, item)
    packet_id, brief = synthesized_packet(f, "seat-packet-build", role="coordinator",
                                         TOPIC="source history", SCALE_SET="implementation")
    prior_packets = (f.store / "_packets/packets.jsonl").read_bytes()
    r("seat-packet-show", "commissioned entry reads its supplied seat packet", PACKET_ID=packet_id)
    assert (f.store / "_packets/packets.jsonl").read_bytes() == prior_packets
    r("work-show", "resume reads existing work evidence")
    for state, plan in [("none", None), ("incomplete", "# Recipe behavior\n"),
                        ("investigations-only", "# Recipe behavior\n## Investigations\nRecorded finding.\n"),
                        ("follow-up-needed", "# Recipe behavior\n## Open Questions\n- Which source remains?\n")]:
        path = item / "plan.md"
        if plan is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(plan)
        actual = json.loads(r("spec-start", "typed continuation state: " + state,
                              INPUT="recipes", TRACK="full", MODEL_OVERRIDE="").stdout)
        assert actual["resolved"] and actual["plan_state"] == state and actual["track"] == "full"
    authored_plan(f, item, concrete=True)
    actual = json.loads(r("spec-start", "completed synthesis resumes without a new investigation").stdout)
    assert actual["plan_state"] == "synthesis-complete"
    assert actual["intent_anchor"] == "Preserve execution and dispatch history."
    with (item / "plan.md").open("a") as stream:
        stream.write("\n## Strategy\nRetain every prior report verbatim.\n")
    assert json.loads(r("spec-start", "existing strategy remains available on resume").stdout)["strategy_present"]
    r("knowledge-search", "the seat's reading explicitly declares its retrieval scale", TOPIC="source history", SCALE_SET="implementation", LIMIT=5)
    norm_inputs = [
        ("conventions", "Source history fixtures retain the committed first line. INCLUDED-NORM-CONTENT-8271"),
        ("preferences", "Visual layout fixtures use a compact margin. EXCLUDED-NORM-CONTENT-8271"),
    ]
    norm_paths = []
    for category, insight in norm_inputs:
        before = knowledge_entries(f)
        f.lore("capture", "--insight", insight, "--category", category, "--scale", "implementation",
               "--producer-role", "spec-lead", "--work-item", "recipes")
        added = knowledge_entries(f) - before
        assert len(added) == 1
        norm_paths.append(added.pop())
    discovery = json.loads(r("spec-discover", "retain complete candidate coverage separately from applicability").stdout)
    discovered_paths = {row["path"] for row in discovery["candidates"]}
    assert {str(p.relative_to(f.store)) for p in norm_paths} <= discovered_paths
    complete_discovery = f.data("complete-discovery.json", discovery)
    full_manifest = f.data("full-permissive-norms.json", [str(p.relative_to(f.store)) for p in norm_paths])
    # These are explicit authored applicability judgments, not search ranking.
    applicability = f.data("norm-applicability.json", {
        "kept": [{"path": str(norm_paths[0].relative_to(f.store)), "reason": "The task preserves committed source history."}],
        "dropped": [{"path": str(norm_paths[1].relative_to(f.store)), "reason": "The task changes no visual layout."}], "added": []})
    delivery = f.root / "knowledge-context.md"
    delivery.write_text(norm_paths[0].read_text())
    assert "INCLUDED-NORM-CONTENT-8271" in delivery.read_text()
    assert "EXCLUDED-NORM-CONTENT-8271" not in delivery.read_text()
    assert "EXCLUDED-NORM-CONTENT-8271" in norm_paths[1].read_text()
    assert json.loads(complete_discovery.read_text()) == discovery
    assert len(json.loads(full_manifest.read_text())) == 2 and json.loads(applicability.read_text())["dropped"]
    assert discovery["provenance"]["applicability_decided"] is False
    assert len(discovery["coverage"]) >= 9
    assert any(row["status"] == "missing" for row in discovery["coverage"])
    assert all(not ({"matched", "binding", "applicability"} & row.keys()) for row in discovery["candidates"])
    f.lore("work", "archive", "recipes")
    archived = json.loads(r("spec-start", "archived entry is reported for an explicit restore decision").stdout)
    assert archived["archived"] is True
    assert (f.store / "_work/_archive/recipes").is_dir() and not item.exists()
    f.finish({"resolve-paths", "lore-defaults", "spec-start", "work-create", "seat-packet-build", "packet-synthesis",
              "seat-packet-show", "work-show", "knowledge-search", "spec-discover"})


def exercise_full(f):
    item = f.create_item()
    authored_plan(f, item)
    document = wave_manifest()
    assert {inv["kind"] for inv in document["investigations"]} == {"lead-authored"}
    bindings_dir = f.root / "wave-bindings"
    bindings_dir.mkdir()
    for inv in document["investigations"]:
        bind_investigation(f, inv, bindings_dir, "full-" + inv["id"], "declare ordinary full-wave placement for " + inv["id"])
    settings = f.settings()
    settings["harnesses"]["claude-code"] = {"args": [], "native_models": {"default": "opus"}}
    settings["routes"]["ceremony_overlays"] = {"spec": {"researcher": "codex/gpt-6-research"}}
    f.write_settings(settings)
    f.env["LORE_FRAMEWORK"] = "claude-code"
    model = f.recipe("resolve-role-model", "resolve target Codex while the active lead is Claude",
                     ROLE="researcher", CEREMONY="spec", TARGET_FRAMEWORK="codex").stdout.decode().strip()
    assert model == "gpt-6-research", model
    declared = declare_sessions(f, document, bindings_dir, model, scenario="full mode explicitly selects ordinary sessions")
    shaped = json.loads(declared.read_text())
    assert all(inv["dispatch"]["route"] == "session" and inv["dispatch"]["bindings"]["execution_root"] is None
               for inv in shaped["investigations"])
    assert all(inv["dispatch"]["model"] == model for inv in shaped["investigations"])
    f.recipe("declare-dispatch", "negative input substitutes the incompatible active-framework model", MODEL="claude-code/opus")
    refused = f.recipe("spec-open", "the active Claude model is not a target Codex binding", expected=1)
    assert b"model" in (refused.stdout + refused.stderr).lower()
    assert not (item / "spec-dispatch.json").exists()
    f.recipe("declare-dispatch", "carry the resolver's emitted binding unchanged", MODEL=model)
    opened = json.loads(f.recipe("spec-open", "prepare a wave of seat-authored questions").stdout)
    assert opened["status"] == "created" and len(opened["directives"]) == len(document["investigations"])
    frozen = (item / "spec-dispatch.json").read_bytes()
    assert json.loads(f.recipe("spec-open", "unchanged full preparation is reused").stdout)["status"] == "reused"
    assert (item / "spec-dispatch.json").read_bytes() == frozen
    dispatch_file = f.data("dispatch.json", opened)
    reports = []
    for index, directive in enumerate(opened["directives"]):
        payload = directive["payload"]
        name = payload["investigation_id"]
        assert payload["publication_state"] == "pending-execution-root"
        assert payload["prompt"] is None and payload["position_dispatch"] is None
        summary, context_file, pending = directive_context(f, dispatch_file, name, "retain admitted full-wave context " + name)
        assert summary["publication_state"] == "pending-execution-root" and json.loads(pending.read_text()) is None
        f.recipe("session-reference", "an unlaunched preparation has no published reference", expected=1, CONTEXT_FILE=context_file)
        queued = enqueue(f, context_file, payload["session_route"])
        assert queued["model"] == payload["session_route"]["model"]
        if index == 0:
            refuse_missing_placement(f, context_file)
        f.connection("target model", producer="resolve-role-model", consumer="declare-dispatch -> spec-open -> request-session",
                     value=model, actor="spec-lead", attempt=payload["bindings"]["dispatch_attempt_id"])
        selected, reference_file = host_reference(f, context_file)
        assert selected["bindings"]["report_id"] == payload["bindings"]["report_id"]
        f.connection("held reference", producer="session-reference", consumer="check-identity and typed-completion",
                     value=reference_file, actor="spec-lead", attempt=payload["bindings"]["dispatch_attempt_id"])
        if index == 0:
            reports.append(collect_report_with_assertion(f, selected, reference_file, name))
        else:
            reports.append(collect_report(f, selected, reference_file, name))
    assert len(reports) == len(document["investigations"]) and all(p.is_file() for p in reports)
    assert json.loads(f.recipe("spec-open", "collection does not rewrite full-wave preparation").stdout)["directives"] == opened["directives"]
    assert (item / "spec-dispatch.json").read_bytes() == frozen
    old_reports = {str(p): p.read_bytes() for p in reports}
    old_bundles = tree_hashes(item / "position-dispatch")
    followup = document["investigations"][-1]
    followup["question"] += " Which prior source fact needs a targeted follow-up?"
    bind_investigation(f, followup, bindings_dir, "full-" + followup["id"] + "-followup",
                       "targeted follow-up receives a fresh report and attempt")
    f.data("investigations-draft.json", document)
    f.recipe("declare-dispatch", "declare the changed question with its new identities")
    refused = f.recipe("spec-open", "a changed wave cannot reuse already-published session attempts", expected=1)
    assert b"published session differs from admitted content" in refused.stderr
    assert (item / "spec-dispatch.json").read_bytes() == frozen
    for inv in document["investigations"][:-1]:
        bind_investigation(f, inv, bindings_dir, "full-" + inv["id"] + "-followup",
                           "the retained question also gets a fresh wave attempt at a fixed root", execution_root=f.code)
    f.recipe("declare-dispatch", "declare fresh attempts for the complete follow-up wave")
    retried = json.loads(f.recipe("spec-open", "prepare the follow-up wave without relabeling prior reports").stdout)
    dispatch_file.write_text(json.dumps(retried))
    for previous, directive in zip(opened["directives"], retried["directives"]):
        newer = directive["payload"]
        assert newer["bindings"]["dispatch_attempt_id"] != previous["payload"]["bindings"]["dispatch_attempt_id"]
        name = newer["investigation_id"]
        fixed = newer["bindings"]["execution_root"] is not None
        summary, context_file, held = directive_context(f, dispatch_file, name, "read the freshly prepared continuation context",
                                                        label=name + "-followup")
        enqueue(f, context_file, newer["session_route"], fixed=fixed)
        if fixed:
            assert summary["publication_state"] == "prepared"
            launched = host_launch(f, context_file)
            assert launched["reference"] == json.loads(held.read_text())["reference"]
            collect_report(f, {"bindings": newer["bindings"], "reference": launched["reference"]}, held, name + "-followup")
        else:
            selected, reference_file = host_reference(f, context_file)
            collect_report(f, selected, reference_file, name + "-followup")
    assert all(Path(path).read_bytes() == raw for path, raw in old_reports.items())
    current_bundles = tree_hashes(item / "position-dispatch")
    assert all(current_bundles[path] == value for path, value in old_bundles.items())
    f.finish({"investigator-packet", "packet-synthesis", "investigator-bindings", "resolve-role-model", "declare-dispatch",
              "spec-open", "directive-context", "request-session", "session-reference", "snippet-hash", "append-tier2",
              "land-report", "check-identity", "typed-completion", "log-worker-leads"})


def exercise_native(f):
    item = f.create_item()
    document = wave_manifest()
    document["investigations"][-1]["question"] += " " + "distinct prepared input " * 1200 + "λ final sentinel"
    settings = f.settings()
    settings["routes"]["researcher"] = "codex/gpt-6-astra-high"
    f.write_settings(settings)
    model = f.recipe("resolve-role-model", "resolve the native model and effort before declaration", ROLE="researcher",
                     CEREMONY="spec", TARGET_FRAMEWORK="codex").stdout.decode().strip()
    assert model == "gpt-6-astra", model
    draft = f.data("native-draft.json", document)
    declared = f.root / "native-investigations.json"
    f.recipe("declare-dispatch", "native opt-in leaves the existing open default intact", INVESTIGATIONS_DRAFT=draft,
             BINDINGS_DIR="", TARGET_FRAMEWORK="codex", MODEL=model, INVESTIGATIONS_JSON=declared)
    assert json.loads(declared.read_text()) == document
    opened = json.loads(f.recipe("spec-open", "prepare native input without invoking a live tool").stdout)
    for directive in opened["directives"]:
        packet_id = directive["payload"]["bindings"]["packet_id"]
        bound_packet = json.loads(f.lore("packet", "show", packet_id, "--json").stdout)
        assert bound_packet["delivery_stage"] == "assembled" and bound_packet["synthesis_waiver"]
    payload = opened["directives"][-1]["payload"]
    ref = payload["position_dispatch"]
    native = json.loads(f.recipe("native-input", "retain exact native model, effort and prompt fields",
                                MANIFEST_PATH=ref["manifest_path"], MANIFEST_SHA256=ref["manifest_sha256"], AGENTS_SCOPE="").stdout)
    assert native["tool_input"]["message"] == payload["prompt"] == Path(ref["payload_path"]).read_text()
    assert native["tool_input"]["model"] == "gpt-6-astra" and native["tool_input"]["reasoning_effort"] == "high"
    assert "λ final sentinel" in native["tool_input"]["message"][20000:]
    offered = tuple(native["tool_input"])
    capture_prepared_launch(native, f.root / "native-captured.json", offered_fields=offered)
    try:
        capture_prepared_launch(native, f.root / "refused-native.json", offered_fields=("message",))
    except ValueError as exc:
        assert "does not offer" in str(exc)
    else:
        raise AssertionError("missing native tool fields were admitted")
    assert not (f.root / "refused-native.json").exists()
    f.env["LORE_FRAMEWORK"] = "claude-code"
    settings["tui_launch_framework"] = "claude-code"
    settings["routes"]["researcher"] = "claude-code/opus"
    settings["harnesses"]["claude-code"] = {"args": [], "native_models": {"default": "opus"}}
    f.write_settings(settings)
    claude = json.loads(f.recipe("spec-open", "prepare native Claude selection with actual readiness requirements").stdout)
    ref = claude["directives"][-1]["payload"]["position_dispatch"]
    f.recipe("native-input", "Claude refuses before its native definition is registered", expected=1,
             MANIFEST_PATH=ref["manifest_path"], MANIFEST_SHA256=ref["manifest_sha256"], AGENTS_SCOPE="")
    scope = f.code / ".claude/agents"
    scope.mkdir(parents=True)
    selected = json.loads(f.recipe("native-input", "register the exact retained Claude definition", AGENTS_SCOPE=scope).stdout)
    name = selected["tool_input"]["subagent_type"]
    assert (scope / (name + ".md")).read_bytes() == (Path(ref["manifest_path"]).parent / "selection.md").read_bytes()
    capture_prepared_launch(selected, f.root / "claude-captured.json", offered_agents=(name,))
    try:
        capture_prepared_launch(selected, f.root / "claude-refused.json", offered_agents=())
    except ValueError as exc:
        assert "live selection inventory" in str(exc)
    else:
        raise AssertionError("missing live native selection was admitted")
    before = (item / "spec-dispatch.json").read_bytes()
    f.env["LORE_FRAMEWORK"] = "opencode"
    settings["tui_launch_framework"] = "opencode"
    settings["routes"]["researcher"] = "opencode/anthropic/opus"
    settings["harnesses"]["opencode"] = {"args": [], "native_models": {"default": "anthropic/opus"}}
    f.write_settings(settings)
    failed = f.recipe("spec-open", "unsupported native route refuses without replacing prior preparation", expected=1)
    assert b"unsupported" in (failed.stdout + failed.stderr).lower() or b"unavailable" in (failed.stdout + failed.stderr).lower()
    assert (item / "spec-dispatch.json").read_bytes() == before
    f.finish({"resolve-role-model", "declare-dispatch", "spec-open", "native-input"})


def exercise_documented_report(f):
    f.create_item()
    documentation = (f.repo / "docs/position-report-contracts.md").read_text()
    paragraph, example = documentation.split("A report that passes typed completion, in outline.", 1)[1].split("```", 2)[:2]
    commit = re.search(r"commit `([0-9a-f]{40})`", paragraph).group(1)
    expected_hash = re.search(r"file sha256 `([0-9a-f]{64})`", paragraph).group(1)
    original = Path(__file__).resolve().parents[2]
    f.call(["git", "fetch", "--no-tags", str(original), commit])
    source = f.code / "scripts/coordinate-report.sh"
    source.parent.mkdir(exist_ok=True)
    source.write_bytes(f.call(["git", "show", commit + ":scripts/coordinate-report.sh"]).stdout)
    assert digest(source.read_bytes()) == expected_hash
    assertion = yaml.safe_load(example.split("**Assertions:**", 1)[1].split("**Observations:**", 1)[0])[0]
    start, end = map(int, assertion["line_range"].split("-"))
    assert assertion["exact_snippet"] in "\n".join(source.read_text().splitlines()[start - 1:end])
    cases = ("passing", "path-line")
    document = {"schema_version": 1, "track": "full", "investigations": [
        {"id": case, "kind": "lead-authored", "question": "Which writer lands compiled reports?", "complexity": "simple",
         "prefetch": []} for case in cases]}
    declared = f.data("documented-investigations.json", document)
    opened = json.loads(f.recipe("spec-open", "open the native default wave for the documented report",
                                INVESTIGATIONS_JSON=declared).stdout)
    dispatch_file = f.data("documented-dispatch.json", opened)
    for case in cases:
        _, _, reference_file = directive_context(f, dispatch_file, case, "hold the prepared reference for " + case)
        held = json.loads(reference_file.read_text())
        reference = held["reference"]
        directive = next(d for d in opened["directives"] if d["payload"]["investigation_id"] == case)
        bindings = directive["payload"]["bindings"]
        manifest = json.loads(Path(reference["manifest_path"]).read_text())
        claim = f.claim("documented-" + case, producer="researcher", task_id=case, bindings=bindings, reference=reference,
                        source=source, revision=commit)
        claim.update(assertion, file=str(source))
        f.recipe("append-tier2", "append the documented assertion against its actual committed coordinates",
                 ROW_FILE=f.data(case + "-claim.json", claim))
        report = example.replace("<12-hex version of the compiled brief>", manifest["producer"]["template_version"])
        report = report.replace("<absolute path of this attempt's manifest.json>", reference["manifest_path"])
        report = report.replace("<64 lowercase hex over that manifest>", reference["manifest_sha256"])
        report = report.replace("/checkout/", str(f.code) + "/")
        if case == "path-line":
            report = report.replace("- " + str(source), "- " + str(source) + ":52")
        report_file = f.root / (case + "-report.md")
        report_file.write_text(report + "\n\n\n")
        f.recipe("land-report", "land the exact documented outline with relocated identities", REPORT_ID=bindings["report_id"],
                 REPORT_BODY_FILE=report_file)
        landed = Path(bindings["report_path"])
        assert landed.read_bytes() == report.rstrip("\n").encode() + b"\n"
        f.recipe("check-identity", "the example retains its own compiled identity", REPORT_PATH=landed, REFERENCE_FILE=reference_file)
        checked = f.recipe("typed-completion", "type the documented example " + case, TASK_ID="", expected=0 if case == "passing" else 2)
        if case == "path-line":
            assert b"Key files" in checked.stdout + checked.stderr
        f.connection("documented report " + case, producer="docs/position-report-contracts.md", consumer="typed-completion",
                     value=landed, actor="investigator", attempt=bindings["dispatch_attempt_id"])
    f.finish({"spec-open", "directive-context", "append-tier2", "land-report", "check-identity", "typed-completion"})


def exercise_design(f):
    item = f.create_item()
    lead_version = digest((f.repo / "skills/spec/SKILL.md").read_bytes())[:12]
    claim = f.claim("seat-source", producer="spec-lead", task_id="spec-synthesis", template_version=lead_version)
    hashed = f.recipe("snippet-hash", "canonical normalizer grounds the seat's own assertion",
                      SNIPPET=claim["exact_snippet"]).stdout.decode().strip()
    assert hashed == claim["normalized_snippet_hash"]
    f.recipe("append-tier2", "the seat's reading lands under spec-lead attribution", ROW_FILE=f.data("seat-claim.json", claim))
    recorded = rows(item / "task-claims.jsonl")
    assert [row["producer_role"] for row in recorded if row["claim_id"] == claim["claim_id"]] == ["spec-lead"]
    rejected = dict(claim, claim_id="seat-unhashed", normalized_snippet_hash="0" * 64)
    f.recipe("append-tier2", "a row whose snippet hash disagrees stays rejected", expected=1,
             ROW_FILE=f.data("seat-unhashed.json", rejected))
    assert rows(item / "task-claims.jsonl") == recorded
    anchor = json.loads((item / "_meta.json").read_text())["intent_anchor"]
    abstract = ("# Recipe behavior\n## Goal\nKeep source history inspectable.\n"
                "## Narrative\nThe reading grounds this design.\n"
                "## Design Decisions\n### D1: Preserve history\n"
                "**Decision:** Retain source and report identity.\n"
                "**Rationale:** A later reader can recover the source-history basis.\n"
                "## Architecture Diagram\n```text\nsource -> report -> plan\n```\n")
    (item / "plan.md").write_text(abstract)
    refused = f.recipe("publish-revision", "an anchor-less abstract cannot publish", expected=1,
                       REASON="Attempt the incomplete abstract design.", AUTHOR_ROLE="spec-lead")
    assert b"anchor" in (refused.stdout + refused.stderr).lower()
    assert not (item / "revisions.jsonl").exists()
    abstract = abstract.replace("## Design Decisions", "## Intent Anchor\n" + anchor +
                                "\n\n**Scope delta:** none — anchor preserved unchanged\n## Design Decisions")
    (item / "plan.md").write_text(abstract)
    published = json.loads(f.recipe("publish-revision", "publish the abstract design before the first stop",
                                   REASON="Record the abstract design.", AUTHOR_ROLE="spec-lead").stdout)
    abstract_revision = published["revision_id"]
    assert (item / "revisions" / abstract_revision / "plan.md").read_bytes() == (item / "plan.md").read_bytes()
    assert not json.loads((item / "tasks.json").read_text()).get("tasks")
    again = json.loads(f.recipe("publish-revision", "identical bytes return the current revision").stdout)
    assert again["revision_id"] == abstract_revision
    note = f.root / "awaiting-design.md"
    note.write_text("Abstract design published as revision " + abstract_revision + "; awaiting the coordinator's read.\n")
    f.recipe("work-note", "a commissioned seat posts a note naming the revision", NOTE_FILE=note)
    assert abstract_revision in (item / "notes.md").read_text()
    f.connection("first stop", producer="publish-revision", consumer="work-note", value=abstract_revision,
                 actor="spec-lead", revision=abstract_revision)
    authored_plan(f, item, concrete=True)
    concrete_revision = json.loads(f.recipe("publish-revision", "concrete tasks publish the next revision").stdout)["revision_id"]
    assert concrete_revision != abstract_revision
    graph = json.loads((item / "tasks.json").read_text())
    assert len(graph["tasks"]) == 1 and graph["tasks"][0]["close_criteria"]
    history = f.lore("tradeoffs", "recipes", "--scale-set", "architecture").stdout.decode()
    assert "Preserve history" in history and "plan.md" in history
    f.finish({"snippet-hash", "append-tier2", "publish-revision", "work-note"})


def exercise_finalize(f):
    item = f.create_item()
    authored_plan(f, item, concrete=True)
    lead_version = digest((f.repo / "skills/spec/SKILL.md").read_bytes())[:12]
    f.recipe("prefetch", "task annotation declares a deliberate retrieval scale", TOPIC="source history", SCALE_SET="implementation")
    # Hosted registry rows are declared fixture inputs; events use the real writer.
    registry = f.store / "_sessions/instances/fixture.json"
    registry.write_text(json.dumps({"name": "fixture", "project_dir": str(f.code), "sessions": [
        {"slug": "recipes", "type": "spec", "request_id": "fixture-spawn-request"}]}))
    milestones = {"spec:design": "Design accepted", "spec:plan-ready": "Plan ready"}
    assert {"LORE_SESSION_INSTANCE", "LORE_SESSION_SLUG", "LORE_SESSION_TYPE"} <= set(f.rows["journal-step"]["inputs"])
    session_before = tree_hashes(f.store / "_sessions")
    unhosted = f.recipe("journal-step", "unhosted milestone invokes no session writer", STEP_ID="spec:design",
                        STEP_LABEL=milestones["spec:design"], LORE_SESSION_INSTANCE="", LORE_SESSION_SLUG="", LORE_SESSION_TYPE="")
    assert unhosted.stdout == b"" and unhosted.stderr == b""
    assert tree_hashes(f.store / "_sessions") == session_before
    for step, label in milestones.items():
        f.recipe("journal-step", "journal the durable " + step + " milestone", STEP_ID=step, STEP_LABEL=label,
                 LORE_SESSION_INSTANCE="fixture", LORE_SESSION_SLUG="recipes", LORE_SESSION_TYPE="spec")
        before = tree_hashes(f.store / "_sessions")
        f.recipe("journal-step", "identical milestone replay is idempotent")
        assert tree_hashes(f.store / "_sessions") == before
    events = rows(f.store / "_sessions/events.jsonl")
    assert [row["step_id"] for row in events if row["event"] == "step_completed"] == list(milestones)
    assert all(row["slug"] == "recipes" and row["session_type"] == "spec" for row in events if row["event"] == "step_completed")
    assert not any(row["event"] == "close_requested" for row in events)
    registry_bytes = registry.read_bytes()
    registry.unlink()
    warned = f.recipe("journal-step", "milestone failure warns without rolling back the plan", STEP_ID="spec:warning", STEP_LABEL="Warning fixture")
    assert b"Warning" in warned.stderr
    registry.write_bytes(registry_bytes)
    # Finalize inherits the host environment independently of journal-step's explicit inputs.
    f.env.update(LORE_SESSION_INSTANCE="fixture", LORE_SESSION_SLUG="recipes", LORE_SESSION_TYPE="spec")
    original = (item / "plan.md").read_text()
    (item / "plan.md").write_text(original.replace("Preserve execution and dispatch history.", "Narrowed fixture anchor."))
    session_before = tree_hashes(f.store / "_sessions")
    telemetry_before = rows(f.store / "_scorecards/rows.jsonl")
    failed = f.recipe("spec-finalize", "anchor refusal emits no success telemetry or terminus", expected=3, LEAD_TEMPLATE_VERSION=lead_version)
    assert b"anchor" in (failed.stdout + failed.stderr).lower()
    assert rows(f.store / "_scorecards/rows.jsonl") == telemetry_before
    assert tree_hashes(f.store / "_sessions") == session_before
    (item / "plan.md").write_text(original)
    f.recipe("spec-finalize", "successful finalization publishes the authored current revision")
    first_revision = json.loads((item / "tasks.json").read_text())["revision_id"]
    events = rows(f.store / "_sessions/events.jsonl")
    assert [row["event"] for row in events if row["event"] in ("step_completed", "close_requested")] == [
        "step_completed", "step_completed", "close_requested"]
    assert next(row for row in events if row["event"] == "close_requested")["reason"] == "protocol_terminus"
    assert rows(f.store / "_scorecards/rows.jsonl") != telemetry_before
    f.recipe("spec-finalize", "unchanged finalization retains the existing revision")
    assert json.loads((item / "tasks.json").read_text())["revision_id"] == first_revision
    authored_plan(f, item, concrete=True, retrieval="legacy")
    f.recipe("spec-finalize", "semantic edits publish another revision while retaining legacy retrieval declarations")
    assert json.loads((item / "tasks.json").read_text())["revision_id"] != first_revision
    assert (item / "revisions" / first_revision / "plan.md").read_text() == original
    f.finish({"prefetch", "journal-step", "spec-finalize"})


def knowledge_entries(f):
    return {p for p in f.store.rglob("*.md") if not p.relative_to(f.store).parts[0].startswith("_")}


def exercise_stewardship(f):
    f.create_item()
    version = digest((f.repo / "skills/spec/SKILL.md").read_bytes())[:12]
    # Hypotheses are authored fixture inputs; the same sanctioned capture writer creates them.
    f.lore("capture", "--insight", "The source history fixture may retain one stable first line.", "--scale", "implementation",
           "--kind", "hypothesis", "--kind-status", "untested", "--producer-role", "spec-lead", "--work-item", "recipes")
    hypothesis = next(p for p in knowledge_entries(f) if "may retain one stable" in p.read_text())
    f.recipe("claim-record", "record the observed test of an existing hypothesis", KNOWLEDGE_PATH=str(hypothesis.relative_to(f.store)),
             DIRECTION="supports", NOTE="The committed tracked file still contains the first line.", KIND_STATUS="")
    assert "corroborations" in hypothesis.read_text()
    f.recipe("claim-record", "settle only after the named test has been observed", DIRECTION="supports", KIND_STATUS="supported")
    assert "supported" in hypothesis.read_text()
    before = knowledge_entries(f)
    f.recipe("capture-theory", "persist a coherent subsystem account through the theory writer", SUBSYSTEM="fixture-source-history",
             INSIGHT="The fixture preserves source identity by retaining the committed file and naming its revision with each assertion.", TEMPLATE_VERSION=version)
    theories = knowledge_entries(f) - before
    assert len(theories) == 1 and "fixture-source-history" in next(iter(theories)).read_text()
    f.finish({"claim-record", "capture-theory"})


def merge_coverage(sources, paths, destination):
    document, bodies = inventory(sources, "spec")
    by_id = {row["id"]: row for row in document["recipes"]}
    assert paths, "empty coverage selection"
    for path in paths:
        observed = json.loads(path.read_text())
        assert observed["source_sha256"] == document["source_sha256"], "scenario source changed"
        assert {r["id"] for r in observed["recipes"]} == set(by_id), "scenario inventory differs"
        for row in observed["recipes"]:
            assert row["body_sha256"] == by_id[row["id"]]["body_sha256"], "scenario recipe changed"
            for execution in row["executions"]:
                assert Path(execution["output_path"]).is_file(), "execution output unavailable"
            by_id[row["id"]]["executions"].extend(row["executions"])
    assert_coverage(document, bodies, "spec")
    destination.write_text(json.dumps(document, indent=2) + "\n")


SCENARIOS = {"synthesis": exercise_synthesis, "entry": exercise_entry, "full": exercise_full, "native": exercise_native,
             "documented-report": exercise_documented_report, "design": exercise_design, "finalize": exercise_finalize,
             "stewardship": exercise_stewardship}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True, choices=("inventory", "coverage", *SCENARIOS))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--prose-ref")
    parser.add_argument("--source", type=Path, nargs="+")
    parser.add_argument("--inventories", type=Path, nargs="*")
    args = parser.parse_args()
    args.root = args.root.resolve()
    if args.scenario == "inventory":
        extraction_controls(args.root)
        test_file = Path(__file__).resolve().parents[2] / "tests/test_spec_recipes.bats"
        guard = ('selected=$(bats --count "$1" --filter "$2"); '
                 '[[ "$selected" -gt 0 ]] || { echo "empty Bats selection" >&2; exit 1; }; '
                 'exec bats "$1" --filter "$2"')
        argv = ["bash", "-c", guard, "empty-selection-control", str(test_file), "^no-such-spec-fixture$"]
        refused = subprocess.run(argv, capture_output=True)
        assert refused.returncode == 1 and b"empty Bats selection" in refused.stderr
        (args.root / "empty-bats-selection.json").write_text(json.dumps({"argv": argv, "exit_code": refused.returncode,
             "stdout": refused.stdout.decode(), "stderr": refused.stderr.decode()}, indent=2) + "\n")
        empty = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--scenario", "unknown", "--root", str(args.root / "empty-spec")], capture_output=True)
        assert empty.returncode == 2 and b"invalid choice" in empty.stderr
        assert not (args.root / "empty-spec").exists()
    elif args.scenario in SCENARIOS:
        implementation = compose_source(Path(__file__).resolve().parents[2], args.root / "source", args.prose_ref)
        SCENARIOS[args.scenario](SpecFixture(implementation, args.root / "case"))
    elif args.scenario == "coverage":
        assert args.source and len(args.source) == len(RECIPE_FILES), "coverage requires the exact spec sources"
        args.root.mkdir(parents=True, exist_ok=True)
        merge_coverage(args.source, args.inventories, args.root / "inventory.json")
        changed = args.root / ("changed-" + args.source[-1].name)
        changed.write_bytes(args.source[-1].read_bytes() + b"\nChanged current protocol input.\n")
        for sources, paths, reason in ((args.source[:-1] + [changed], args.inventories, "scenario source changed"),
                                       (args.source, [], "empty coverage selection")):
            try:
                merge_coverage(sources, paths, args.root / "negative-inventory.json")
            except AssertionError as exc:
                assert reason in str(exc), str(exc)
            else:
                raise AssertionError("aggregate admitted " + reason)
        assert not (args.root / "negative-inventory.json").exists()
        print("Current-source aggregate rejects changed protocol bytes and empty selection")


if __name__ == "__main__":
    main()
