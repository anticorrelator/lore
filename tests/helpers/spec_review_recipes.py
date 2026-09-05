#!/usr/bin/env python3
"""Exercise published review recipes with declared evaluator fixture responses."""

import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys

import yaml

from implement_recipes import Fixture, assert_coverage, digest, inventory, isolated_go_environment


SOURCES = {
    "design": ("codex-design-review", "spec-design-review"),
    "plan": ("codex-plan-review", "spec-plan-review"),
}


def rejects(operation, message):
    try:
        operation()
    except (AssertionError, ValueError) as exc:
        assert message in str(exc), str(exc)
    else:
        raise AssertionError("negative control passed: " + message)


def extraction_controls(root):
    root.mkdir(parents=True, exist_ok=True)
    for namespace in ("spec", "spec-design-review", "spec-plan-review"):
        source = root / (namespace + ".md")
        original = (f"Recipe inputs: none\n<!-- {namespace}-recipe: first -->\n"
                    "```bash\nprintf '%s\\n' 'literal $HOME; `value`'\n```\n"
                    f"Recipe inputs: none\n<!-- {namespace}-recipe: inline -->\n`true`\n"
                    '```json\n{"state":"example"}\n```\n'
                    '```yaml\nstate: example\n```\n').encode()
        source.write_bytes(original)
        document, bodies = inventory(source, namespace)
        assert set(document) == {"schema_version", "source_path", "source_sha256", "recipes", "declarative_examples"}
        assert document["schema_version"] == 1
        assert bodies["first"] == b"printf '%s\\n' 'literal $HOME; `value`'\n"
        assert bodies["inline"] == b"true"
        assert all(row["validation"] == "parsed" for row in document["declarative_examples"])
        rejects(lambda: inventory(source), "unmarked executable")
        rejects(lambda: assert_coverage(document, bodies, namespace), "unexercised")
        covered = copy.deepcopy(document)
        # This synthetic row tests the coverage checker, not recipe execution.
        for row in covered["recipes"]:
            row["executions"] = [{"body_sha256": row["body_sha256"]}]
        assert_coverage(covered, bodies, namespace)
        changed = copy.deepcopy(covered)
        changed["recipes"][0]["executions"][0]["body_sha256"] = "0" * 64
        rejects(lambda: assert_coverage(changed, bodies, namespace), "changed recipes")
        source.write_bytes(original + f"Recipe inputs: none\n<!-- {namespace}-recipe: added -->\n`true`\n".encode())
        added, added_bodies = inventory(source, namespace)
        for row in added["recipes"]:
            if row["id"] in bodies:
                row["executions"] = [{"body_sha256": row["body_sha256"]}]
        rejects(lambda: assert_coverage(added, added_bodies, namespace), "unexercised")
        source.write_bytes(original.replace(b"literal", b"changed"))
        rejects(lambda: assert_coverage(covered, bodies, namespace), "source changed")
        for extra, reason in [
            ("```python\nprint('unmarked')\n```\n", "unmarked executable"),
            (f"<!-- {namespace}-recipe: BAD -->\n`true`\n", "invalid recipe marker"),
            (f"<!-- {namespace}-recipe: data -->\n```json\n{{}}\n```\n", "declarative fence"),
            (f"<!-- {namespace}-recipe: orphan -->\n", "has no body"),
            (f"Recipe inputs: none\n<!-- {namespace}-recipe: first -->\n`true`\n", "duplicate recipe"),
            (f"<!-- {namespace}-recipe: unknown -->\n```ruby\nputs 'x'\n```\n", "declarative fence"),
            ("```bash\ntrue\n", "unterminated fence"),
            ("```json\nnot json\n```\n", "Expecting value"),
        ]:
            source.write_bytes(original + extra.encode())
            rejects(lambda: inventory(source, namespace), reason)
        source.write_text(f"<!-- {namespace}-recipe: missing-input -->\n`true`\n")
        rejects(lambda: inventory(source, namespace), "missing Recipe inputs")
        source.write_bytes(original)
    rejects(lambda: inventory(source, "bad namespace"), "invalid recipe namespace")
    empty = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--scenario", "not-a-scenario", "--root", str(root / "empty")], capture_output=True)
    assert empty.returncode == 2 and b"invalid choice" in empty.stderr
    assert not (root / "empty").exists()
    print("All three namespaces retain schema 1 and reject missing coverage, drift and malformed recipes; empty scenario selection refuses")


class ReviewFixture(Fixture):
    def __init__(self, repo, root, source, namespace):
        frontmatter = source.read_text().split("---", 2)
        assert len(frontmatter) == 3 and not frontmatter[0].strip(), "missing YAML frontmatter"
        metadata = yaml.safe_load(frontmatter[1])
        assert metadata["name"] == source.parent.name and metadata["description"]
        super().__init__(repo, root, source, namespace)
        self.namespace = namespace
        settings = self.root / "data/config/settings.json"
        config = json.loads(settings.read_text())
        config["harnesses"]["codex"]["roles"]["advisor"] = "gpt-6-astra"
        config["harnesses"]["codex"]["ceremony_roles"] = {"spec": {"advisor": "gpt-6-astra-high"}}
        settings.write_text(json.dumps(config))
        self.model_input = self.root / "evaluator-input.txt"
        self.model_args = self.root / "evaluator-argv.json"
        self.model_response = self.root / "evaluator-response.txt"
        self.model_response.write_text("Explicit evaluator fixture response; no live model was run.\n")
        fake_bin = self.root / "fake-evaluator-bin"
        fake_bin.mkdir()
        fake = fake_bin / "codex"
        fake.write_text(f'''#!{sys.executable}
import json
from pathlib import Path
import sys
Path({str(self.model_input)!r}).write_bytes(sys.stdin.buffer.read())
Path({str(self.model_args)!r}).write_text(json.dumps({{"proof": "prepared-input only; no live model consumption", "argv": sys.argv[1:]}}))
sys.stdout.buffer.write(Path({str(self.model_response)!r}).read_bytes())
''')
        fake.chmod(0o755)
        self.env["PATH"] = str(self.repo / "cli") + os.pathsep + str(fake_bin) + os.pathsep + self.env["PATH"]
        assert Path(shutil.which("lore", path=self.env["PATH"])).resolve() == self.repo / "cli/lore"

    def finish(self):
        assert_coverage(self.document, self.bodies, self.namespace)
        self.save()
        print(json.dumps({"inventory": str(self.root / "inventory.json"),
                          "recipes": len(self.rows), "proof": "real writers; fixture evaluator response"}))


def review_plan(f, item, variant="tasks"):
    """Author fixture plans; revisions and prepared artifacts use real writers."""
    if variant == "tasks":
        f.write_plan(item)
        tasks = (item / "plan.md").read_text().split("## Tasks\n", 1)[1]
        tail = "## Tasks\n" + tasks
    elif variant == "legacy":
        tail = "## Phases\n### Phase 1: Preserve history\n- [ ] Keep historical records in `tracked` [class: mechanical]\n"
    else:
        tail = ""
    abstract = """# Recipe behavior
## Goal
Keep revision-bound review history legible.
## Intent Anchor
Preserve execution and dispatch history.

**Scope delta:** none
## Investigations
Evidence marker: prepared investigation.
### Key Assertions
The prepared snapshot is the evaluator input.
## Narrative
A reviewer reads a published draft and returns a judgment.
## Design Decisions
### D1: Retain history
The revision identifies the draft. The review identifies the judgment.
## Architecture Diagram
```text
reader -> snapshot
```
"""
    if variant == "fences":
        abstract += """## Context
````text
## Tasks
```bash
## Phases
```
````
~~~text
## Phases
~~~
## Non-Goals
Do not include future work.
"""
        f.write_plan(item)
        tail = "## Tasks\n" + (item / "plan.md").read_text().split("## Tasks\n", 1)[1]
    text = abstract + tail + "\n## Open Questions\nTrailing question marker: which history is being reviewed?\n"
    if tail:
        text += "## Related\nLater unrelated section marker.\n"
    (item / "plan.md").write_text(text)
    return text


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def tree_hashes(root):
    return {str(p.relative_to(root)): digest(p.read_bytes()) for p in root.rglob("*") if p.is_file()}


def install_sources(repo, root, source_root):
    root.mkdir(parents=True, exist_ok=True)
    target = compose_source(repo, root / "source", source_root)
    home, data = root / "home", root / "data"
    home.mkdir()
    data.mkdir()
    env = {key: value for key, value in os.environ.items()
           if key in {"PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TMP", "TEMP", "TZ"}}
    env.update(HOME=str(home), LORE_DATA_DIR=str(data), XDG_CONFIG_HOME=str(root / "config"),
               XDG_DATA_HOME=str(data), XDG_CACHE_HOME=str(root / "cache"))
    env = isolated_go_environment(repo, root, env)
    env["PATH"] = str(target / "cli") + os.pathsep + env["PATH"]
    assert Path(shutil.which("lore", path=env["PATH"])).resolve() == target / "cli/lore"
    proc = subprocess.run(["bash", str(target / "install.sh"), "--framework", "claude-code"],
                          cwd=target, env=env, capture_output=True)
    (root / "install.log").write_bytes(proc.stdout + proc.stderr)
    assert proc.returncode == 0, (root / "install.log").read_text()
    for skill, _ in SOURCES.values():
        installed = home / ".claude/skills" / skill
        assert installed.is_symlink()
        assert installed.resolve() == target / "skills" / skill
        assert (installed / "SKILL.md").read_bytes() == (source_root / "skills" / skill / "SKILL.md").read_bytes()
    print("Both canonical review skills installed through the existing installer in isolated HOME")


def compose_source(repo, target, source_root):
    target.mkdir(parents=True)
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=repo).decode().split("\0")
    for name in filter(None, files):
        source = repo / name
        if source.is_file():
            destination = target / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    for skill, _ in SOURCES.values():
        source = source_root / "skills" / skill / "SKILL.md"
        if source.exists():
            destination = target / "skills" / skill
            destination.mkdir(exist_ok=True)
            shutil.copy2(source, destination / "SKILL.md")
    return target


def unavailable_evaluator(f, item, run, prepare, v):
    """No evaluator output is recorded as absence, never a completed review."""
    v.update(REASON="Prepare an invocation whose evaluator is unavailable.", MODEL="gpt-6-astra-high")
    bound = prepare("no-evaluator")
    prefix = "design" if "design-slice" in f.rows else "plan"
    if prefix == "design":
        run("design-slice", "unavailable evaluator starts from the new prepared design")
    run(prefix + "-prompt-round-1", "unavailable evaluator receives the newly prepared input")
    f.model_response.write_text("")
    response = f.root / "no-evaluator-response.md"
    result = run("codex-submit", "empty evaluator response refuses before review normalization", expected=1, RESPONSE_FILE=response)
    assert b"no output" in result.stderr and response.read_bytes() == b""
    evidence_file = f.root / "no-evaluator-evidence.json"
    run("file-unavailable", "unavailable outcome requires an explicit reason", expected=1, REASON="", EVIDENCE_FILE=evidence_file)
    result = run("file-unavailable", "real schema-1 absence records skipped evaluator without a response", REASON="Fixture evaluator could not produce a response.", MODEL="")
    assert json.loads(result.stdout)["outcome"] == "skipped"
    evidence = json.loads(evidence_file.read_text())
    assert evidence["schema_version"] == 1
    assert evidence["final_round"] is None and evidence["disposition_ledger_sha256"] is None and evidence["model"] is None
    assert evidence["source_plan_sha256"] == digest(Path(bound["plan_file"]).read_bytes())
    assert not (Path(bound["prepared_dir"]) / "sealed").exists()
    result = run("file-outcome", "absence evidence cannot certify a completed review", expected=1, OUTCOME="completed", VERDICT="UNAVAILABLE", REASON="")
    assert b"null" in result.stdout + result.stderr
    assert not (item / "results.jsonl").exists()


def identity_controls(f, item, run, v):
    original = dict(v)
    result = run("read-prepared", "caller supplied wrong prepared directory refuses", expected=1, PREPARED_DIR=item)
    assert b"prepared path" in result.stderr
    v.update(original)
    wrong_ceremony = "spec-post-plan" if v["CEREMONY"] == "spec-design" else "spec-design"
    result = run("read-prepared", "caller supplied wrong ceremony refuses", expected=1, CEREMONY=wrong_ceremony)
    assert b"caller named" in result.stderr
    v.update(original)
    result = run("read-prepared", "caller supplied wrong revision refuses", expected=1, REVISION_ID="0" * 12)
    assert b"holds revision" in result.stderr
    v.update(original)


def all_accepted(f, item, skill, run, prepare, v):
    """Accepted edits without another evaluation keep the original reviewed identity."""
    prefix = "design" if skill == "codex-design-review" else "plan"
    v.update(REASON="Publish a new all-accepted fixture invocation.", OUTCOME="completed")
    bound = prepare("all-accept-r1")
    reviewed_revision = v["REVISION_ID"]
    reviewed_attempt = v["ATTEMPT_ID"]
    reviewed_prepared_path = v["PREPARED_PATH"]
    if prefix == "design":
        run("design-slice", "all-Accept invocation starts from prepared design")
    run(prefix + "-prompt-round-1", "all-Accept invocation evaluates original prepared bytes")
    f.model_response.write_text("Explicit all-Accept fixture response: " + ("CONCERNS" if prefix == "design" else "GATE FAILED") + "\n")
    run("codex-submit", "one actual captured evaluator submission before accepted edits", RESPONSE_FILE=f.root / "all-accept-response.md")
    first = {"round": 1, "attempt_id": reviewed_attempt, "revision_id": reviewed_revision,
             "verdict": "CONCERNS" if prefix == "design" else "GATE FAILED"}
    accepted = {"description": "Clarify the owning boundary", "disposition": "Accept", "rationale": "The boundary exists in the current source.", "applied": "Accepted-only edit marker."}
    if prefix == "design":
        first["proposals"] = [dict(accepted, number=1, type="Clarify", severity="Medium")]
    else:
        first["edits"] = [dict(accepted, criterion="Interface Clarity")]
        first["ratings"] = {name: "WEAK" if name == "Interface Clarity" else "ADEQUATE" for name in (
            "Objective and Scope", "Evidence and Uncertainty", "Interface Clarity", "Design Coherence", "Execution Readiness", "Validation and Traceability")}
    ledger = f.data("all-accept-ledger.json", {"schema_version": 1, "skill": skill, "rounds": [first]})
    v["LEDGER_FILE"] = ledger
    run(prefix + "-prompt-round-2", "all-Accept branch owes no response round", expected=1)
    live = item / "plan.md"
    live.write_text(live.read_text() + "\nAccepted-only edit marker.\n")
    published = json.loads(run("publish-revision", "seat publishes accepted edits after final evaluated round").stdout)
    assert published["revision_id"] != reviewed_revision
    assert not (item / "reviews/all-accept-unreviewed").exists()
    v.update(ATTEMPT_ID=reviewed_attempt, REVISION_ID=reviewed_revision, PREPARED_PATH=reviewed_prepared_path, PREPARED_DIR=str(Path(reviewed_prepared_path).parent),
             ROUND1_RESPONSE_FILE=v["RESPONSE_FILE"], ROUND2_RESPONSE_FILE="", REVIEW_OUTPUT=f.root / "all-accept-output.md",
             DISPOSITIONS_FILE=f.root / "all-accept-dispositions.json", OUTCOME="completed", REASON="",
             JUDGMENT="concerns", RATIONALE="The judgment concerns the original evaluated revision; accepted edits are unreviewed.",
             FINAL_ROUND=1, EVALUATOR_FILE=f.root / "all-accept-evaluator.json", SEAL_RESULT=f.root / "all-accept-seal.json",
             EVIDENCE_FILE=f.root / "all-accept-evidence.json", VERDICT=first["verdict"])
    run("compose-review-output", "one-round response is retained without a fabricated second response")
    run("compose-dispositions", "all-Accept verdict remains the original raw judgment")
    run("evaluator-manifest", "one-round evaluator identity remains one round")
    run("seal-review", "an unprepared edited revision cannot acquire a seal", expected=1, ATTEMPT_ID="all-accept-unreviewed")
    assert not (item / "reviews/all-accept-unreviewed").exists()
    run("seal-review", "all-Accept seals actual reviewed attempt with no new unread attempt", ATTEMPT_ID=reviewed_attempt)
    run("file-outcome", "accepted changes do not relabel the reviewed revision")
    evidence = json.loads(Path(v["EVIDENCE_FILE"]).read_text())
    assert evidence["revision_id"] == reviewed_revision
    assert evidence["final_round"] == 1
    assert not (item / "reviews/all-accept-unreviewed").exists()
    assert Path(bound["plan_file"]).read_text() not in ("", live.read_text())
    assert "Accepted-only edit marker." not in f.model_input.read_text()
    assert not (item / "results.jsonl").exists()


def exercise_design(repo, root, source_root):
    root.mkdir(parents=True)
    implementation = compose_source(repo, root / "source", source_root)
    skill, namespace = SOURCES["design"]
    f = ReviewFixture(implementation, root / "case", implementation / "skills" / skill / "SKILL.md", namespace)
    item = f.create_item()
    v = dict(INPUT="recipes", SLUG="recipes", SCRIPTS_DIR=implementation / "scripts", KNOWLEDGE_DIR=f.store,
             REASON="Publish the authored fixture draft.", AUTHOR_ROLE="spec-lead", MODEL="gpt-6-astra-high",
             DESIGN_FILE=f.root / "design.md", PROMPT_FILE=f.root / "prompt.md", RESPONSE_FILE=f.root / "response-1.md")

    def run(name, scenario, expected=0, **updates):
        v.update(updates)
        result = f.run(name, {key: v[key] for key in f.rows[name]["inputs"]}, scenario, expected)
        if name == "codex-submit" and result.returncode == 0:
            assert f.model_input.read_bytes() == Path(v["PROMPT_FILE"]).read_bytes()
            capture = json.loads(f.model_args.read_text())
            assert capture["argv"] == ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "-m", "gpt-6-astra", "-c", 'model_reasoning_effort="high"', "-"]
            assert Path(v["RESPONSE_FILE"]).read_bytes() == f.model_response.read_bytes()
            shutil.copy2(f.model_input, f.root / "outputs" / f"{f.sequence:03d}-captured-evaluator-input.txt")
            shutil.copy2(f.model_args, f.root / "outputs" / f"{f.sequence:03d}-captured-evaluator-argv.json")
        return result

    resolved = run("resolve-paths", "uses isolated store and this checkout's scripts").stdout.decode()
    assert "KNOWLEDGE_DIR=" + str(f.store) in resolved and "SCRIPTS_DIR=" + str(implementation / "scripts") in resolved
    assert run("resolve-item", "direct entry resolves existing work item").stdout.strip() == b"recipes"
    model = run("resolve-evaluator-model", "uses configured advisor model").stdout.decode().strip()
    assert model == "gpt-6-astra-high", model

    def prepare(attempt):
        published = json.loads(run("publish-revision", "publish before preparing evaluator input").stdout)
        v["REVISION_ID"] = published["revision_id"]
        prepared = json.loads(run("prepare-review", "prepare exact committed revision", ATTEMPT_ID=attempt).stdout)
        v["PREPARED_PATH"] = prepared["prepared_path"]
        v["PREPARED_DIR"] = str(Path(prepared["prepared_path"]).parent)
        v["CEREMONY"] = "spec-design"
        bound = json.loads(run("read-prepared", "commissioned read validates the supplied immutable identity").stdout)
        for key in ("plan_file", "tasks_file", "anchor_file"):
            v[key.upper()] = bound[key]
        assert Path(v["ANCHOR_FILE"]).read_text() == "Preserve execution and dispatch history."
        return bound

    for variant in ("abstract", "tasks", "legacy", "fences"):
        item = f.create_item("design-" + variant)
        v["SLUG"] = "design-" + variant
        original = review_plan(f, item, variant)
        bound = prepare("design-" + variant)
        prepared_tree = tree_hashes(Path(bound["prepared_dir"]))
        result = json.loads(run("design-slice", "structural design slice: " + variant).stdout)
        selected = Path(v["DESIGN_FILE"]).read_text()
        expected_boundary = {"abstract": None, "tasks": "Tasks", "legacy": "Phases", "fences": "Tasks"}[variant]
        assert result["boundary"] == expected_boundary, result
        if variant != "abstract":
            assert "Later unrelated section marker." not in selected
        assert "Trailing question marker" in selected
        assert "prepared investigation" in selected and "### Key Assertions" in selected
        assert "### Task 1:" not in selected and "### Phase 1:" not in selected
        if variant == "abstract":
            assert selected == original
        if variant == "fences":
            assert "## Tasks\n```bash\n## Phases" in selected
            assert "## Non-Goals" in selected
        run("design-prompt-round-1", "prompt carries original anchor and selected design: " + variant)
        prompt = Path(v["PROMPT_FILE"]).read_text()
        assert "<DESIGN>\n" + selected + "\n</DESIGN>" in prompt
        f.model_response.write_text("## Verdict\nCONCERNS\n\nFixture proposal: clarify the owning boundary.\n")
        run("codex-submit", "captures prepared input only: " + variant)
        assert tree_hashes(Path(bound["prepared_dir"])) == prepared_tree

    old_attempt, old_revision = v["ATTEMPT_ID"], v["REVISION_ID"]
    old_prepared = Path(bound["prepared_dir"])
    old_tree = tree_hashes(old_prepared)
    first = {"round": 1, "attempt_id": old_attempt, "revision_id": old_revision, "verdict": "CONCERNS", "proposals": [
        {"number": 1, "description": "Clarify ownership", "type": "Clarify", "severity": "Medium", "disposition": "Modify", "rationale": "Name the existing writer.", "applied": "Clarified boundary marker."},
        {"number": 2, "description": "Remove necessary history", "type": "Cut", "severity": "High", "disposition": "Reject", "rationale": "The original anchor requires history.", "applied": None}]}
    ledger = {"schema_version": 1, "skill": skill, "rounds": [first]}
    ledger_file = f.data("ledger-round-1.json", ledger)
    first_bytes = ledger_file.read_bytes()
    v.update(LEDGER_FILE=ledger_file, ROUND1_RESPONSE_FILE=v["RESPONSE_FILE"])
    live = item / "plan.md"
    live.write_text(live.read_text().replace("The revision identifies the draft.", "Clarified boundary marker. The revision identifies the draft."))
    prepare("design-fences-r2")
    assert v["REVISION_ID"] != old_revision
    assert tree_hashes(old_prepared) == old_tree
    run("design-slice", "round 2 selects fresh prepared input after accepted edits")
    run("design-prompt-round-2", "prior-round dispositions travel unchanged into fresh input")
    prompt = Path(v["PROMPT_FILE"]).read_text()
    assert "Clarified boundary marker." in prompt and "The original anchor requires history." in prompt
    f.model_response.write_text("## Verdict\nREWORK\n\nFixture response retains an unresolved concern.\n")
    run("codex-submit", "round 2 captures fresh prepared input", RESPONSE_FILE=f.root / "response-2.md")
    assert ledger_file.read_bytes() == first_bytes
    ledger["rounds"].append({"round": 2, "attempt_id": v["ATTEMPT_ID"], "revision_id": v["REVISION_ID"], "verdict": "REWORK", "proposals": []})
    v.update(LEDGER_FILE=f.data("ledger-final.json", ledger), ROUND2_RESPONSE_FILE=v["RESPONSE_FILE"],
             REVIEW_OUTPUT=f.root / "review-output.md", OUTCOME="needs-decision", REASON="The design concern remains unresolved.",
             JUDGMENT="needs-decision", RATIONALE="Design-stage judgment only; no task execution is certified.",
             DISPOSITIONS_FILE=f.root / "dispositions.json", FINAL_ROUND=2, EVALUATOR_FILE=f.root / "evaluator.json",
             SEAL_RESULT=f.root / "seal-result.json", EVIDENCE_FILE=f.root / "evidence.json", VERDICT="REWORK")
    run("compose-review-output", "raw responses and prior dispositions retained")
    run("compose-dispositions", "authored normalization preserves terminal raw verdict")
    dispositions = json.loads(Path(v["DISPOSITIONS_FILE"]).read_text())
    assert dispositions["verdict"] == "REWORK" and dispositions["judgments"][0]["result_ids"] == []
    assert len(dispositions["dispositions"]) == 2
    run("evaluator-manifest", "reviewer version is distinct from spec producer version")
    evaluator = json.loads(Path(v["EVALUATOR_FILE"]).read_text())
    assert evaluator["evaluator_template_version"] == digest((implementation / "skills" / skill / "SKILL.md").read_bytes())[:12]
    run("seal-review", "seal exactly the attempt round 2 evaluated")
    frozen = tree_hashes(item / "reviews" / v["ATTEMPT_ID"])
    outcome = json.loads(run("file-outcome", "unresolved decision remains explicit with unchanged verdict").stdout)
    assert outcome["outcome"] == "needs-decision"
    assert not (item / "results.jsonl").exists(), "review must not manufacture execution results"
    assert json.loads(run("file-outcome", "identical outcome replay is reused").stdout)["status"] == "reused"
    run("seal-review", "identical seal replay is reused")
    assert tree_hashes(item / "reviews" / v["ATTEMPT_ID"]) == frozen
    bad = run("file-outcome", "raw verdict mismatch refuses at outcome writer", expected=1, VERDICT="PASS")
    assert b"differs" in bad.stdout + bad.stderr
    v["VERDICT"] = "REWORK"
    run("read-prepared", "wrong revision refuses before reading input", expected=1, REVISION_ID="0" * 12)
    v["REVISION_ID"] = ledger["rounds"][-1]["revision_id"]
    prepared_json = item / "reviews" / v["ATTEMPT_ID"] / "prepared.json"
    original = prepared_json.read_bytes()
    altered = json.loads(original)
    altered["plan_path"] = "plan.md"
    prepared_json.write_text(json.dumps(altered))
    bad = run("read-prepared", "source outside the prepared revision refuses", expected=1)
    assert b"snapshot reference" in bad.stdout + bad.stderr
    prepared_json.write_bytes(original)
    f.lore("plan", "review", "prepare", v["SLUG"], "--attempt-id", "wrong-ceremony", "--ceremony", "spec-post-plan", "--revision", v["REVISION_ID"], "--purpose", "criterion-adequacy")
    run("read-prepared", "wrong ceremony refuses before evaluation", expected=1, ATTEMPT_ID="wrong-ceremony", PREPARED_DIR=item / "reviews/wrong-ceremony")
    run("read-prepared", "unavailable evidence refuses explicitly", expected=1, ATTEMPT_ID="unavailable", PREPARED_DIR=item / "reviews/unavailable")
    all_accepted(f, item, skill, run, prepare, v)
    identity_controls(f, item, run, v)
    unavailable_evaluator(f, item, run, prepare, v)
    f.finish()


def exercise_plan(repo, root, source_root):
    root.mkdir(parents=True)
    implementation = compose_source(repo, root / "source", source_root)
    skill, namespace = SOURCES["plan"]
    f = ReviewFixture(implementation, root / "case", implementation / "skills" / skill / "SKILL.md", namespace)
    item = f.create_item()
    original = review_plan(f, item)
    v = dict(INPUT="recipes", SLUG="recipes", SCRIPTS_DIR=implementation / "scripts", KNOWLEDGE_DIR=f.store,
             REASON="Publish the authored fixture draft.", AUTHOR_ROLE="spec-lead", MODEL="gpt-6-astra-high",
             PROMPT_FILE=f.root / "prompt.md", RESPONSE_FILE=f.root / "response-1.md", CEREMONY="spec-post-plan")

    def run(name, scenario, expected=0, **updates):
        v.update(updates)
        result = f.run(name, {key: v[key] for key in f.rows[name]["inputs"]}, scenario, expected)
        if name == "codex-submit" and result.returncode == 0:
            assert f.model_input.read_bytes() == Path(v["PROMPT_FILE"]).read_bytes()
            assert Path(v["RESPONSE_FILE"]).read_bytes() == f.model_response.read_bytes()
            args = json.loads(f.model_args.read_text())["argv"]
            assert args == ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "-m", "gpt-6-astra", "-c", 'model_reasoning_effort="high"', "-"]
            shutil.copy2(f.model_input, f.root / "outputs" / f"{f.sequence:03d}-captured-evaluator-input.txt")
            shutil.copy2(f.model_args, f.root / "outputs" / f"{f.sequence:03d}-captured-evaluator-argv.json")
        return result

    resolved = run("resolve-paths", "select isolated store and checkout scripts").stdout.decode()
    assert str(f.store) in resolved and str(implementation / "scripts") in resolved
    assert run("resolve-item", "direct entry resolves existing item").stdout.strip() == b"recipes"
    assert run("resolve-evaluator-model", "configured model is preserved").stdout.decode().strip() == "gpt-6-astra-high"

    def prepare(attempt):
        published = json.loads(run("publish-revision", "publish before evaluation").stdout)
        v["REVISION_ID"] = published["revision_id"]
        result = json.loads(run("prepare-review", "freeze full task plan and anchor", ATTEMPT_ID=attempt).stdout)
        v["PREPARED_PATH"] = result["prepared_path"]
        v["PREPARED_DIR"] = str(Path(result["prepared_path"]).parent)
        bound = json.loads(run("read-prepared", "commissioned input uses supplied attempt and revision").stdout)
        assert bound["task_count"] == 2, bound
        for key in ("plan_file", "tasks_file", "anchor_file"):
            v[key.upper()] = bound[key]
        tasks = json.loads(Path(v["TASKS_FILE"]).read_text())["tasks"]
        assert len(tasks) == 2
        assert tasks[1]["blockedBy"] == ["task-1"]
        criterion = tasks[0]["close_criteria"][0]
        assert criterion["argv"][0] == sys.executable and "execution-count" in criterion["argv"][2]
        return bound

    bound = prepare("plan-r1")
    original_tree = tree_hashes(Path(bound["prepared_dir"]))
    assert Path(v["PLAN_FILE"]).read_text() == original
    assert json.loads(run("publish-revision", "unchanged direct publication reuses revision").stdout)["revision_id"] == v["REVISION_ID"]
    run("plan-prompt-round-1", "full plan and original anchor reach evaluator input")
    assert "<PLAN>\n" + original + "\n</PLAN>" in Path(v["PROMPT_FILE"]).read_text()
    rating_names = ["Objective and Scope", "Evidence and Uncertainty", "Interface Clarity", "Design Coherence", "Execution Readiness", "Validation and Traceability"]
    first_ratings = dict(zip(rating_names, ["STRONG", "ADEQUATE", "WEAK", "ADEQUATE", "WEAK", "MISSING"]))
    f.model_response.write_text("Fixture evaluator response, round 1.\n" + json.dumps(first_ratings) + "\nGATE FAILED\n")
    run("codex-submit", "captures exact prepared input; output is declared fixture data")
    first = {"round": 1, "attempt_id": v["ATTEMPT_ID"], "revision_id": v["REVISION_ID"], "verdict": "GATE FAILED", "ratings": first_ratings, "edits": [
        {"description": "Clarify ownership", "criterion": "Interface Clarity", "disposition": "Modify", "rationale": "Preserve the existing writer.", "applied": "Clarified boundary marker."}]}
    ledger = {"schema_version": 1, "skill": skill, "rounds": [first]}
    first_ledger = f.data("ledger-round-1.json", ledger)
    first_bytes = first_ledger.read_bytes()
    v.update(LEDGER_FILE=first_ledger, ROUND1_RESPONSE_FILE=v["RESPONSE_FILE"])
    live = item / "plan.md"
    live.write_text(original.replace("The revision identifies the draft.", "Clarified boundary marker. The revision identifies the draft."))
    # The commissioned reader must keep using N even while the live draft is edited.
    run("read-prepared", "live edits do not alter commissioned input")
    run("plan-prompt-round-1", "changed live draft never leaks into old prepared prompt")
    assert "Clarified boundary marker." not in Path(v["PROMPT_FILE"]).read_text()
    assert tree_hashes(Path(bound["prepared_dir"])) == original_tree
    bound = prepare("plan-r2")
    assert v["REVISION_ID"] != first["revision_id"]
    run("plan-prompt-round-2", "fresh attempt carries full revised plan and prior decisions")
    assert "Clarified boundary marker." in Path(v["PROMPT_FILE"]).read_text()
    final_ratings = dict(first_ratings, **{"Interface Clarity": "ADEQUATE"})
    f.model_response.write_text("Fixture evaluator response, round 2.\n" + json.dumps(final_ratings) + "\nGATE PASSED\n")
    run("codex-submit", "second-round output is fixture input", RESPONSE_FILE=f.root / "response-2.md")
    assert first_ledger.read_bytes() == first_bytes
    ledger["rounds"].append({"round": 2, "attempt_id": v["ATTEMPT_ID"], "revision_id": v["REVISION_ID"], "verdict": "GATE PASSED", "ratings": final_ratings, "edits": []})
    final_ledger = f.data("ledger-final.json", ledger)
    v.update(LEDGER_FILE=final_ledger, ROUND2_RESPONSE_FILE=v["RESPONSE_FILE"], REVIEW_OUTPUT=f.root / "review-output.md",
             OUTCOME="completed", REASON="", JUDGMENT="adequate", RATIONALE="The published task criteria cover the fixture anchor.",
             DISPOSITIONS_FILE=f.root / "dispositions.json", FINAL_ROUND=2, EVALUATOR_FILE=f.root / "evaluator.json",
             SEAL_RESULT=f.root / "seal-result.json", EVIDENCE_FILE=f.root / "evidence.json", VERDICT="GATE PASSED")
    run("compose-review-output", "both raw rating rounds and decisions remain visible")
    run("compose-dispositions", "raw terminal verdict and prior decisions are retained")
    dispositions = json.loads(Path(v["DISPOSITIONS_FILE"]).read_text())
    assert dispositions["verdict"] == "GATE PASSED" and dispositions["judgments"][0]["result_ids"] == []
    run("evaluator-manifest", "reviewer identity names the evaluated skill")
    run("seal-review", "seal revision actually evaluated in the final round")
    reviewed_revision = v["REVISION_ID"]
    reviewed_tree = tree_hashes(Path(bound["prepared_dir"]))
    run("file-outcome", "completed outcome retains exact raw gate verdict")
    live.write_text(live.read_text().replace("Clarified boundary marker.", "Later unreviewed edit marker."))
    published = json.loads(run("publish-revision", "later accepted edits publish another revision").stdout)
    assert published["revision_id"] != reviewed_revision
    run("seal-review", "historical seal replay does not certify the edited revision")
    assert tree_hashes(Path(bound["prepared_dir"])) == reviewed_tree
    assert json.loads(run("file-outcome", "historical outcome is reused without relabeling").stdout)["status"] == "reused"
    records = [json.loads(line.split(": ", 1)[1]) for line in (item / "execution-log.md").read_text().splitlines() if line.startswith("Spec-outcome-record: ")]
    assert len(records) == 1 and records[0]["revision_id"] == reviewed_revision
    assert not (item / "results.jsonl").exists()

    score_path = f.store / "_scorecards/rows.jsonl"
    producer_version = digest((implementation / "skills/spec/SKILL.md").read_bytes())[:12]
    rating_values = {"STRONG": 1.0, "ADEQUATE": .75, "WEAK": .25, "MISSING": 0.0}
    for clarity, gate in (("STRONG", "pass"), ("ADEQUATE", "pass"), ("WEAK", "fail"), ("MISSING", "fail")):
        current = copy.deepcopy(ledger)
        current["rounds"][-1]["ratings"]["Interface Clarity"] = clarity
        current["rounds"][-1]["verdict"] = "GATE PASSED" if gate == "pass" else "GATE FAILED"
        rating_ledger = f.data("rating-" + clarity + ".json", current)
        before = len(rows(score_path))
        result = run("capture-ratings", "six ratings plus the Interface Clarity gate: " + clarity, LEDGER_FILE=rating_ledger)
        assert ("gate=" + gate).encode() in result.stdout
        captured = rows(score_path)[before:]
        assert len(captured) == 7, captured
        assert {r["template_version"] for r in captured} == {producer_version}
        assert {r["template_id"] for r in captured} == {"codex-plan-review"}
        assert all(r["kind"] == "scored" and r["source_artifact_ids"] == ["recipes"] for r in captured)
        for name, rating in current["rounds"][-1]["ratings"].items():
            row = next(r for r in captured if r["metric"] == "criterion:" + name.lower().replace(" ", "-"))
            assert row["rating_label"] == rating and row["value"] == rating_values[rating]
        assert next(r for r in captured if r["metric"] == "gate")["value"] == (1.0 if gate == "pass" else 0.0)
    score_dir = score_path.parent
    backup = score_dir.with_name("scorecards-retained")
    score_dir.rename(backup)
    score_dir.write_text("Explicit fixture obstruction: scorecard directory unavailable.\n")
    result = run("capture-ratings", "real scorecard write failure does not block gate reporting", LEDGER_FILE=final_ledger)
    assert b"gate=pass" in result.stdout and b"Warning" in result.stderr
    score_dir.unlink()
    backup.rename(score_dir)
    assert tree_hashes(Path(bound["prepared_dir"])) == reviewed_tree
    invalid = copy.deepcopy(ledger)
    del invalid["rounds"][-1]["ratings"]["Objective and Scope"]
    result = run("capture-ratings", "missing criterion refuses before emission", expected=5, LEDGER_FILE=f.data("missing-rating.json", invalid))
    assert b"six criteria" in result.stderr
    run("plan-prompt-round-2", "missing required structured input fails", expected=1, LEDGER_FILE=f.root / "absent-ledger.json")
    # Unavailable evaluator evidence is an explicit schema-1 absence, not a forged seal.
    evidence = f.data("unavailable-evidence.json", dict(schema_version=1, evaluator_locator=None, evaluator_template_version=None,
        framework=None, model=None, final_round=None, disposition_ledger_sha256=None, source_plan_sha256=None))
    run("file-outcome", "unavailable evaluator stays skipped with null evidence", ATTEMPT_ID="unavailable", OUTCOME="skipped", VERDICT="UNAVAILABLE", REASON="Fixture evaluator unavailable.", EVIDENCE_FILE=evidence)
    run("file-outcome", "unavailable evidence cannot claim a completed review", expected=1, ATTEMPT_ID="unavailable-completed", OUTCOME="completed", REASON="")
    all_accepted(f, item, skill, run, prepare, v)
    identity_controls(f, item, run, v)
    unavailable_evaluator(f, item, run, prepare, v)
    f.finish()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True, choices=("inventory", "design", "plan", "installation"))
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    args.root = args.root.resolve()
    if args.scenario == "inventory":
        extraction_controls(args.root)
    elif args.scenario == "plan":
        exercise_plan(Path(__file__).resolve().parents[2], args.root, args.source_root)
    elif args.scenario == "design":
        exercise_design(Path(__file__).resolve().parents[2], args.root, args.source_root)
    elif args.scenario == "installation":
        install_sources(Path(__file__).resolve().parents[2], args.root, args.source_root)
    else:
        raise NotImplementedError(args.scenario)


if __name__ == "__main__":
    main()
