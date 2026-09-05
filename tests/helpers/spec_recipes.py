#!/usr/bin/env python3
"""Execute the spec skill's exact recipes through isolated, real writers."""

import argparse
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

import yaml

from implement_recipes import Fixture, assert_coverage, capture_prepared_launch, digest, inventory
from spec_review_recipes import extraction_controls, rows, tree_hashes


PROSE_FILES = ("skills/spec/SKILL.md", "skills/spec/templates/plan.md", "docs/position-report-contracts.md")


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
        super().__init__(repo, root, repo / "skills/spec/SKILL.md", "spec")
        self.values = dict(SCRIPTS_DIR=repo / "scripts", KNOWLEDGE_DIR=self.store,
                           SKILL_FILE=repo / "skills/spec/SKILL.md", SLUG="recipes")
        assert Path(shutil.which("lore", path=self.env["PATH"])).resolve() == repo / "cli/lore"
        self.timings = []
        self.connections = []
        self.external_inventories = {}

    def connection(self, name, *, producer, consumer, value, actor, revision=None, attempt=None):
        self.connections.append(dict(name=name, producer=producer, consumer=consumer, value=str(value),
                                     actor=actor, revision=revision, attempt=attempt))
        self.data("handoff-trace.json", self.connections)

    def external(self, skill, namespace, name, scenario, expected=0, **values):
        """Use the shared extractor to run a consuming skill in the same store."""
        if namespace not in self.external_inventories:
            self.external_inventories[namespace] = inventory(self.repo / "skills" / skill / "SKILL.md", namespace)
        document, bodies = self.external_inventories[namespace]
        consumer = copy.copy(self)
        consumer.document, consumer.bodies = document, bodies
        consumer.rows = {row["id"]: row for row in document["recipes"]}
        assert set(values) <= set(consumer.rows[name]["inputs"]), (name, "undeclared external inputs")
        self.values.update(values)
        consumer.save = lambda: self.data(namespace + "-inventory.json", document)
        inputs = {key: self.values[key] for key in consumer.rows[name]["inputs"]}
        start = time.monotonic()
        try:
            return consumer.run(name, inputs, scenario, expected)
        finally:
            self.sequence = consumer.sequence
            self.measure(consumer, name, scenario, inputs, start)

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

    def investigator_claim(self, bindings, reference, name, *, producer="researcher", source=None, revision=None):
        sys.path.insert(0, str(self.repo / "scripts"))
        from snippet_normalize import hash_normalized
        source = source or self.code / "tracked"
        snippet = source.read_text().splitlines()[0]
        return {"claim_id": name, "tier": "task-evidence", "claim": "The tracked source contains the observed first line.",
                "producer_role": producer, "protocol_slot": "spec", "task_id": bindings["task_id"] or "inline-investigation",
                "scale": "implementation", "file": str(source), "line_range": "1-1", "exact_snippet": snippet,
                "normalized_snippet_hash": hash_normalized(snippet), "falsifier": "The committed first line differs.",
                "why_this_work_needs_it": "Check collection against committed source.",
                "captured_at_sha": revision or self.call(["git", "rev-parse", "HEAD"]).stdout.decode().strip(),
                "change_context": {"summary": "Fixture source", "changed_files": [str(source)], "diff_ref": None},
                "significance": "low", "report_id": bindings["report_id"],
                "dispatch_attempt_id": bindings["dispatch_attempt_id"],
                "position_dispatch": {key: reference[key] for key in ("manifest_path", "manifest_sha256")}}


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
    packet = json.loads(f.recipe("investigator-packet", "assemble candidate source history before applicability",
                                INVESTIGATION_ID="synthesis", QUERY="source history synthesis", SCALE_SET="implementation").stdout)
    packet_id = packet["packet_id"]
    candidate = json.loads(f.lore("packet", "show", packet_id, "--json").stdout)
    assert candidate["delivery_stage"] == "assembled"
    paths = [str(p.relative_to(f.store)) for p in entries]
    assert set(paths) <= {e["path"] for e in candidate["delivered_entries"]}
    assert all(token in candidate["content"] for token in tokens)
    candidate_file = f.data("candidate-packet.json", candidate)
    bindings_file = f.root / "synthesis-bindings.json"
    f.recipe("investigator-bindings", "bind the candidate identity before testing its delivery stage",
             PACKET_ID=packet_id, INVESTIGATION_ID="synthesis", QUESTION="Which source history conventions apply?",
             COMPLEXITY="simple", REPORT_ID="synthesis-report", EXECUTION_ROOT="", BINDINGS_FILE=bindings_file)
    failed = compile_and_wrap(f, bindings_file, position="investigator", route="session", expected=1)
    assert b"synthesi" in (failed.stdout + failed.stderr).lower()
    assert not (item / "position-dispatch").exists()
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
    context = compile_and_wrap(f, bindings_file, position="investigator", route="session")
    enqueue(f, context)
    selected = host_reference(f, context)
    collect_external_report(f, selected, "synthesized")
    assert selected["bindings"]["packet_id"] == packet_id and selected["delivery_proven"] is False
    f.finish({"investigator-packet", "packet-synthesis", "investigator-bindings", "compile-position", "author-wrapper",
              "prepare-session", "seat-packet-show", "work-show", "request-session", "session-reference", "land-report",
              "check-identity", "typed-completion"})


def exercise_entry(f):
    r = f.recipe
    r("resolve-paths", "resolve only the selected checkout and isolated store")
    r("lore-defaults", "read isolated standing defaults")
    before = tree_hashes(f.store)
    started = json.loads(r("spec-start", "unresolved standalone entry creates no item or packet",
                          INPUT="new-fixture-capability", TRACK="short", MODEL_OVERRIDE="gpt-6-astra-high").stdout)
    assert started["resolved"] is False and started["track"] == "short"
    assert started["effective_lead_model"] == "gpt-6-astra-high"
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
    r("knowledge-search", "local investigation explicitly declares its retrieval scale", TOPIC="source history", SCALE_SET="implementation", LIMIT=5)
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


def compile_and_wrap(f, bindings_file, *, position, route, model="", framework="codex", expected=0):
    b = json.loads(bindings_file.read_text())
    stem = b["dispatch_attempt_id"]
    f.recipe("compile-position", "compile the " + position + " for " + route,
             POSITION=position, TARGET_FRAMEWORK=framework,
             GUIDANCE_FILE=f.root / (stem + "-guidance.md"), DESCRIPTOR_FILE=f.root / (stem + "-descriptor.json"))
    f.recipe("author-wrapper", "retain producer and wrapper identity separately", BINDINGS_FILE=bindings_file,
             WRAPPER_FILE=f.root / (stem + "-wrapper.json"), PREFIX_FILE=f.root / (stem + "-prefix.md"),
             SUFFIX_FILE=f.root / (stem + "-suffix.md"), ROUTE=route, WORK_TITLE="Recipe behavior",
             PLACEMENT_NOTE="Read committed fixture source in the assigned physical root.")
    if b["execution_root"] is None:
        context = f.root / (stem + "-context.json")
        result = f.recipe("prepare-session", "prepare the host-owned execution root without a launch claim", expected=expected,
                          SESSION_SLUG="recipes--w1", CONTEXT_FILE=context)
        if expected:
            return result
        prepared = json.loads(context.read_text())["position_preparation"]
        assert prepared["bindings"]["execution_root"] is None
        assert not (f.store / "_work/recipes/position-dispatch" / stem).exists()
        return context
    result = f.recipe("bind-attempt", "publish an immutable " + route + " attempt",
                      REQUIRED_BINDINGS="packet_id packet_pointer", NATIVE_MODEL=model)
    reference = json.loads(result.stdout)
    ref_file = f.data(stem + "-reference.json", reference)
    manifest = json.loads(Path(reference["manifest_path"]).read_text())
    assert manifest["bindings"] == b
    assert manifest["producer"]["position"] == position
    assert manifest["wrapper"]["template_id"] == "spec/skill"
    assert manifest["producer"]["template_version"] != manifest["wrapper"]["template_version"]
    return ref_file


def inline_attempt(f, *, name="inline", empty=False):
    packet_id, brief = synthesized_packet(f, "investigator-packet", role="investigator",
                                         INVESTIGATION_ID=name, QUERY="source history", SCALE_SET="implementation")
    bindings_file = f.root / (name + "-bindings.json")
    f.recipe("investigator-bindings", "bind the inline investigation to its actual source root",
             PACKET_ID=packet_id, INVESTIGATION_ID=name, QUESTION="Which committed bytes ground this investigation?",
             COMPLEXITY="simple", REPORT_ID=name + "-report", EXECUTION_ROOT=f.code, BINDINGS_FILE=bindings_file)
    reference_file = compile_and_wrap(f, bindings_file, position="investigator", route="inline")
    b = json.loads(bindings_file.read_text())
    reference = json.loads(reference_file.read_text())
    assert b["task_id"] is None and b["revision_id"] is None
    frozen = tree_hashes(Path(reference["manifest_path"]).parent)
    payload = f.recipe("read-payload", "short mode reads the exact compiled investigator payload",
                       REFERENCE_FILE=reference_file).stdout
    assert payload.rstrip(b"\n") == Path(reference["payload_path"]).read_bytes().rstrip(b"\n")
    assert json.loads(f.recipe("bind-attempt", "identical inline binding reuses frozen bytes").stdout) == reference
    assert tree_hashes(Path(reference["manifest_path"]).parent) == frozen
    f.recipe("typed-completion", "typing cannot complete an unlanded inline report", expected=2,
             REFERENCE_FILE=reference_file, TASK_ID="")
    claims = []
    if not empty:
        claim = f.investigator_claim(b, reference, "claim-" + name)
        hashed = f.recipe("snippet-hash", "canonical normalizer grounds the investigator assertion", SNIPPET=claim["exact_snippet"]).stdout.decode().strip()
        assert hashed == claim["normalized_snippet_hash"]
        f.recipe("append-tier2", "investigator self-emission retains researcher attribution",
                 ROW_FILE=f.data(name + "-claim.json", claim))
        claims.append(claim)
    source = f.investigator_report(b, reference, claims)
    source.write_bytes(source.read_bytes() + b"\n\n\n")
    f.recipe("land-report", "land the complete inline report before checking identity",
             REPORT_ID=b["report_id"], REPORT_BODY_FILE=source)
    report = Path(b["report_path"])
    assert report.read_bytes() == source.read_bytes().rstrip(b"\n") + b"\n"
    assert report.read_bytes() != source.read_bytes()
    f.recipe("check-identity", "compare headers with the independently held reference",
             REPORT_PATH=report, REFERENCE_FILE=reference_file)
    claim_rows = rows(f.store / "_work/recipes/task-claims.jsonl")
    f.recipe("typed-completion", "inline investigator uses the same typed completion boundary", TASK_ID="")
    assert rows(f.store / "_work/recipes/task-claims.jsonl") == claim_rows
    assert {row["producer_role"] for row in claim_rows} <= {"researcher"}
    assert not (f.store / "_work/recipes/spec-dispatch.json").exists()
    f.recipe("land-report", "retry cannot overwrite the original report", expected=4)
    assert report.read_bytes() == source.read_bytes().rstrip(b"\n") + b"\n"
    return b, reference, report


def exercise_inline(f):
    item = f.create_item()
    authored_plan(f, item)
    b, reference, report = inline_attempt(f)
    inline_attempt(f, name="inline-empty", empty=True)
    before_capture = knowledge_entries(f)
    producer_version = json.loads(Path(reference["manifest_path"]).read_text())["producer"]["template_version"]
    captured = f.recipe("capture-observation", "capture the investigator finding when collected, with a separate seat filer",
                        INSIGHT="The investigator observed that independently collected report identity remains separate from prepared model input.",
                        SCALE="implementation", PRODUCER_ROLE="researcher", CAPTURER_ROLE="spec-lead",
                        SOURCE_ARTIFACT_IDS=b["report_id"], TEMPLATE_VERSION=producer_version)
    created = knowledge_entries(f) - before_capture
    assert len(created) == 1
    captured_text = next(iter(created)).read_text()
    assert "producer_role: researcher" in captured_text and "capturer_role: spec-lead" in captured_text
    assert "source_artifact_ids: " + b["report_id"] in captured_text
    before_invalid = knowledge_entries(f)
    rejected = f.recipe("capture-observation", "investigator-derived capture refuses missing source identity", expected=1,
                        SOURCE_ARTIFACT_IDS="")
    assert b"source" in (rejected.stdout + rejected.stderr).lower()
    assert knowledge_entries(f) == before_invalid
    manifest = json.loads(Path(reference["manifest_path"]).read_text())
    lead_version = digest((f.repo / "skills/spec/SKILL.md").read_bytes())[:12]
    f.recipe("log-worker-leads", "worker leads preserve producer, filer and attempt reference",
             INVESTIGATION_ID="inline", REPORT_ID=b["report_id"], WORKER_LEADS="Inspect tracked:1 when implementing source history.",
             PRODUCER_TEMPLATE_VERSION=manifest["producer"]["template_version"], LEAD_TEMPLATE_VERSION=lead_version,
             MANIFEST_PATH=reference["manifest_path"], MANIFEST_SHA256=reference["manifest_sha256"])
    f.recipe("log-worker-leads", "an empty worker-leads block emits no concern", WORKER_LEADS="None")
    f.recipe("log-investigation-summary", "summary follows durable reports and canonical assertions", COUNT=2, TOPICS="source history, empty assertions")
    log = (item / "execution-log.md").read_text()
    assert "Investigations: 2" in log and "source history" in log
    concerns = item / "surfaced_concerns.jsonl"
    before = concerns.read_bytes() if concerns.exists() else None
    f.recipe("read-surfaced-concerns", "synthesis reads concerns without altering the ledger")
    assert (concerns.read_bytes() if concerns.exists() else None) == before
    f.finish({"investigator-packet", "packet-synthesis", "investigator-bindings", "compile-position", "author-wrapper", "bind-attempt",
              "read-payload", "land-report", "check-identity", "snippet-hash", "append-tier2", "typed-completion", "log-worker-leads",
              "log-investigation-summary", "read-surfaced-concerns"})


def full_manifest():
    return {"schema_version": 1, "track": "full", "investigations": [
        {"id": "external", "kind": "fixed", "question": "External skill and agent applicability", "complexity": "simple", "prefetch": []},
        {"id": "preferences", "kind": "fixed", "question": "Preferences and conventions applicability", "complexity": "simple", "prefetch": []},
        {"id": "code", "kind": "lead-authored", "question": "Which source bytes must remain inspectable?", "complexity": "moderate", "prefetch": []}]}


def host_reference(f, context_file, *, framework="codex", root=None):
    root = root or f.code
    # This invokes the host's real preparation writer; it starts no model process.
    launched = json.loads(f.call([sys.executable, str(f.repo / "scripts/position-bind.py"), "launch", "--framework", framework,
                                 "--slug", "recipes--w1", "--execution-root", str(root), "--kdir", str(f.store)],
                                input=context_file.read_bytes()).stdout)
    collected = json.loads(f.recipe("session-reference", "read the independent prepared reference after host publication",
                                   CONTEXT_FILE=context_file).stdout)
    assert collected["reference"] == launched["reference"]
    assert collected["bindings"]["execution_root"] == str(root)
    assert collected["delivery_proven"] is False
    assert Path(collected["reference"]["payload_path"]).read_text() == launched["payload"]
    return collected


def enqueue(f, context_file, *, framework="codex", model="gpt-6-astra", fixed=False):
    # The declared fixture host remains live while these serial steps execute.
    (f.store / "_sessions/instances/fixture.json").touch()
    result = f.recipe("request-session", "enqueue " + ("fixed" if fixed else "ordinary") + " prepared session",
                      SESSION_SLUG="recipes--w1", TARGET_FRAMEWORK=framework, MODEL=model, CONTEXT_FILE=context_file,
                      TARGET_INSTANCE="", MIN_VINTAGE="", WORKTREE_ID="fixture-worktree" if fixed else "",
                      EXECUTION_DIR=str(f.code) if fixed else "")
    queued = json.loads((f.store / json.loads(result.stdout)["path"]).read_text())
    assert queued["framework"] == framework and queued["model"] == model
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


def land_designer_record(f, selected, revision, name, claim_id=None):
    reference, bindings = selected["reference"], selected["bindings"]
    manifest = json.loads(Path(reference["manifest_path"]).read_text())
    report = f.root / (name + "-design-record.md")
    report.write_text(f"""Template-version: {manifest['producer']['template_version']}
Position-dispatch-manifest: {reference['manifest_path']}
Position-dispatch-sha256: {reference['manifest_sha256']}
**Revision:** {revision}
**Decisions:** Preserve source and report history in the published plan.
**Open questions:** None
**Tier 2 evidence:**
{("- " + claim_id) if claim_id else "none"}
""")
    f.recipe("land-report", "retain the independently commissioned designer's durable record", REPORT_BODY_FILE=report,
             REPORT_ID=bindings["report_id"])
    landed = Path(bindings["report_path"])
    assert landed.read_text().rstrip() == report.read_text().rstrip()
    f.recipe("check-identity", "check the designer record against its actual compiled producer", REPORT_PATH=landed,
             REFERENCE_FILE=f.data(name + "-design-reference.json", reference))
    return landed


def collect_external_report(f, selected, name):
    b, reference = selected["bindings"], selected["reference"]
    ref_file = f.data(name + "-reference.json", reference)
    source = f.investigator_report(b, reference)
    f.recipe("land-report", "land full-wave returned report " + name, REPORT_ID=b["report_id"], REPORT_BODY_FILE=source)
    f.recipe("check-identity", "check full-wave independent reference " + name, REPORT_PATH=b["report_path"], REFERENCE_FILE=ref_file)
    f.recipe("typed-completion", "type full-wave report before accepting its findings " + name, TASK_ID=b["task_id"] or "")
    return Path(b["report_path"])


def exercise_full(f):
    item = f.create_item()
    authored_plan(f, item)
    document = full_manifest()
    bindings_dir = f.root / "wave-bindings"
    bindings_dir.mkdir()
    for inv in document["investigations"]:
        packet_id, _ = synthesized_packet(f, "investigator-packet", role="investigator", INVESTIGATION_ID=inv["id"],
                                          QUERY=inv["question"], SCALE_SET="implementation")
        f.recipe("investigator-bindings", "declare ordinary full-wave placement for " + inv["id"], PACKET_ID=packet_id,
                 INVESTIGATION_ID=inv["id"], QUESTION=inv["question"], COMPLEXITY=inv["complexity"],
                 REPORT_ID="full-" + inv["id"], EXECUTION_ROOT="", BINDINGS_FILE=bindings_dir / (inv["id"] + ".json"))
    settings_path = f.root / "data/config/settings.json"
    settings = json.loads(settings_path.read_text())
    settings["harnesses"]["claude-code"] = {"roles": {"lead": "opus", "researcher": "opus", "default": "opus"}}
    settings["harnesses"]["codex"]["ceremony_roles"] = {"spec": {"researcher": "gpt-6-astra-high"}}
    settings_path.write_text(json.dumps(settings))
    f.env["LORE_FRAMEWORK"] = "claude-code"
    model = f.recipe("resolve-role-model", "resolve target Codex while the active lead is Claude",
                     ROLE="researcher", CEREMONY="spec", TARGET_FRAMEWORK="codex").stdout.decode().strip()
    assert model == "gpt-6-astra-high"
    draft = f.data("investigations-draft.json", document)
    declared = f.root / "investigations.json"
    f.recipe("declare-dispatch", "full mode explicitly selects ordinary sessions", INVESTIGATIONS_DRAFT=draft,
             BINDINGS_DIR=bindings_dir, TARGET_FRAMEWORK="codex", MODEL=model, INVESTIGATIONS_JSON=declared)
    shaped = json.loads(declared.read_text())
    assert all(inv["dispatch"]["route"] == "session" and inv["dispatch"]["bindings"]["execution_root"] is None
               for inv in shaped["investigations"])
    assert all(inv["dispatch"]["model"] == model for inv in shaped["investigations"])
    f.recipe("declare-dispatch", "negative input substitutes the incompatible active-framework model", MODEL="claude-code/opus")
    refused = f.recipe("spec-open", "the active Claude model is not a target Codex binding", expected=1)
    assert b"model" in (refused.stdout + refused.stderr).lower()
    assert not (item / "spec-dispatch.json").exists()
    f.recipe("declare-dispatch", "carry the resolver's emitted binding unchanged", MODEL=model)
    opened = json.loads(f.recipe("spec-open", "prepare the full wave with both fixed questions").stdout)
    assert opened["status"] == "created" and len(opened["directives"]) == 3
    frozen = (item / "spec-dispatch.json").read_bytes()
    assert json.loads(f.recipe("spec-open", "unchanged full preparation is reused").stdout)["status"] == "reused"
    assert (item / "spec-dispatch.json").read_bytes() == frozen
    dispatch_file = f.data("dispatch.json", opened)
    reports = []
    for directive in opened["directives"]:
        payload = directive["payload"]
        name = payload["investigation_id"]
        assert payload["publication_state"] == "pending-execution-root"
        assert payload["prompt"] is None and payload["position_dispatch"] is None
        context_file = f.root / (name + "-context.json")
        f.recipe("directive-context", "retain admitted full-wave context " + name, DISPATCH_JSON=dispatch_file,
                 INVESTIGATION_ID=name, CONTEXT_FILE=context_file, REFERENCE_FILE=f.root / (name + "-pending-reference.json"))
        f.recipe("session-reference", "an unlaunched preparation has no published reference", expected=1, CONTEXT_FILE=context_file)
        queued = enqueue(f, context_file, framework=payload["framework"], model=payload["model"])
        assert queued["model"] == model
        f.connection("target model", producer="resolve-role-model", consumer="declare-dispatch -> spec-open -> request-session",
                     value=model, actor="spec-lead", attempt=payload["bindings"]["dispatch_attempt_id"])
        selected = host_reference(f, context_file)
        assert selected["bindings"]["report_id"] == payload["bindings"]["report_id"]
        reports.append(collect_external_report(f, selected, name))
    assert len(reports) == 3 and all(p.is_file() for p in reports)
    assert json.loads(f.recipe("spec-open", "collection does not rewrite full-wave preparation").stdout)["directives"] == opened["directives"]
    assert (item / "spec-dispatch.json").read_bytes() == frozen
    old_reports = {str(p): p.read_bytes() for p in reports}
    old_bundles = tree_hashes(item / "position-dispatch")
    followup = document["investigations"][-1]
    followup["question"] += " Which prior source fact needs a targeted follow-up?"
    packet_id, _ = synthesized_packet(f, "investigator-packet", role="investigator", INVESTIGATION_ID=followup["id"],
                                      QUERY=followup["question"], SCALE_SET="implementation")
    f.recipe("investigator-bindings", "targeted follow-up receives a fresh report and attempt", PACKET_ID=packet_id,
             INVESTIGATION_ID=followup["id"], QUESTION=followup["question"], COMPLEXITY=followup["complexity"],
             REPORT_ID="full-code-followup", EXECUTION_ROOT="", BINDINGS_FILE=bindings_dir / "code.json")
    draft.write_text(json.dumps(document))
    f.recipe("declare-dispatch", "declare the changed question with its new identities")
    refused = f.recipe("spec-open", "a changed wave cannot reuse already-published session attempts", expected=1)
    assert b"published session differs from admitted content" in refused.stderr
    assert (item / "spec-dispatch.json").read_bytes() == frozen
    for inv in document["investigations"][:2]:
        packet_id, _ = synthesized_packet(f, "investigator-packet", role="investigator", INVESTIGATION_ID=inv["id"],
                                          QUERY=inv["question"], SCALE_SET="implementation")
        f.recipe("investigator-bindings", "the retained fixed question also gets a fresh wave attempt", PACKET_ID=packet_id,
                 INVESTIGATION_ID=inv["id"], QUESTION=inv["question"], COMPLEXITY=inv["complexity"],
                 REPORT_ID="full-" + inv["id"] + "-followup", EXECUTION_ROOT="", BINDINGS_FILE=bindings_dir / (inv["id"] + ".json"))
    f.recipe("declare-dispatch", "declare fresh attempts for the complete follow-up wave")
    retried = json.loads(f.recipe("spec-open", "prepare the follow-up wave without relabeling prior reports").stdout)
    dispatch_file.write_text(json.dumps(retried))
    for previous, directive in zip(opened["directives"], retried["directives"]):
        newer = directive["payload"]
        assert newer["bindings"]["dispatch_attempt_id"] != previous["payload"]["bindings"]["dispatch_attempt_id"]
        name = newer["investigation_id"]
        context_file = f.root / (name + "-followup-context.json")
        f.recipe("directive-context", "read the freshly prepared continuation context", INVESTIGATION_ID=name, CONTEXT_FILE=context_file)
        enqueue(f, context_file, framework=directive["payload"]["framework"], model=directive["payload"]["model"])
        followup_selected = host_reference(f, context_file)
        collect_external_report(f, followup_selected, name + "-followup")
    assert all(Path(path).read_bytes() == raw for path, raw in old_reports.items())
    current_bundles = tree_hashes(item / "position-dispatch")
    assert all(current_bundles[path] == value for path, value in old_bundles.items())
    f.finish({"investigator-packet", "packet-synthesis", "investigator-bindings", "resolve-role-model", "declare-dispatch",
              "spec-open", "directive-context", "request-session", "session-reference", "land-report", "check-identity", "typed-completion"})


def exercise_native(f):
    item = f.create_item()
    document = full_manifest()
    document["investigations"][-1]["question"] += " " + "distinct prepared input " * 1200 + "λ final sentinel"
    draft = f.data("native-draft.json", document)
    declared = f.root / "native-investigations.json"
    settings_path = f.root / "data/config/settings.json"
    settings = json.loads(settings_path.read_text())
    settings["harnesses"]["codex"]["roles"]["researcher"] = "gpt-6-astra-high"
    settings_path.write_text(json.dumps(settings))
    model = f.recipe("resolve-role-model", "resolve the native model and effort before declaration", ROLE="researcher",
                     CEREMONY="spec", TARGET_FRAMEWORK="codex").stdout.decode().strip()
    assert model == "gpt-6-astra-high"
    f.recipe("declare-dispatch", "native opt-in leaves the existing open default intact", INVESTIGATIONS_DRAFT=draft,
             BINDINGS_DIR="", TARGET_FRAMEWORK="codex", MODEL=model, INVESTIGATIONS_JSON=declared)
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
    settings["harnesses"]["claude-code"] = {"roles": {"lead": "opus", "researcher": "opus", "default": "opus"}}
    settings_path.write_text(json.dumps(settings))
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
    settings["harnesses"]["opencode"] = {"roles": {"lead": "anthropic/opus", "researcher": "anthropic/opus", "default": "anthropic/opus"}}
    settings_path.write_text(json.dumps(settings))
    failed = f.recipe("spec-open", "unsupported native route refuses without replacing prior preparation", expected=1)
    assert b"unsupported" in (failed.stdout + failed.stderr).lower() or b"unavailable" in (failed.stdout + failed.stderr).lower()
    assert (item / "spec-dispatch.json").read_bytes() == before
    f.finish({"declare-dispatch", "spec-open", "native-input"})


def exercise_designer(f):
    item = f.create_item()
    # Independently commission one investigator without invoking spec start/open.
    packet_id, _ = synthesized_packet(f, "investigator-packet", role="investigator", INVESTIGATION_ID="independent",
                                      QUERY="source history", SCALE_SET="implementation")
    investigator = f.root / "independent-bindings.json"
    f.recipe("investigator-bindings", "commission an investigation independently of the full workflow", PACKET_ID=packet_id,
             INVESTIGATION_ID="independent", QUESTION="Which source bytes remain?", COMPLEXITY="simple", REPORT_ID="independent-report",
             EXECUTION_ROOT="", BINDINGS_FILE=investigator)
    context = compile_and_wrap(f, investigator, position="investigator", route="session")
    enqueue(f, context)
    refuse_missing_placement(f, context)
    selected = host_reference(f, context)
    report = collect_external_report(f, selected, "independent")
    strawman = f.root / "strawman.md"
    strawman.write_text("Keep immutable source and report identity with the planning artifact.\n")
    norms = f.data("norms.json", [])
    assignment = f.root / "abstract-assignment.json"
    f.recipe("designer-assignment", "independent planning names every authored design input",
             STAGE="abstract", ANCHOR="Preserve execution and dispatch history.", STRAWMAN_FILE=strawman,
             REPORT_PATHS=str(report), NORMS_FILE=norms, ACCEPTED_REVISION="", DISPOSITIONS_FILE="",
             ASSIGNMENT_FILE=assignment)
    original_assignment = assignment.read_text()
    abstract_input = json.loads(original_assignment)
    for key in ("accepted_plan_path", "accepted_plan_sha256", "dispositions", "dispositions_sha256"):
        assert abstract_input[key] is None
    assert str(report) in original_assignment and "Preserve execution and dispatch history." in original_assignment
    packet_id, _ = synthesized_packet(f, "designer-packet", role="designer", TOPIC="source history design", SCALE_SET="architecture")
    bindings = f.root / "abstract-designer-bindings.json"
    f.recipe("designer-bindings", "planning mode is explicit before independent session preparation",
             PACKET_ID=packet_id, ASSIGNMENT_FILE=assignment, REPORT_ID="abstract-designer", EXECUTION_ROOT="", BINDINGS_FILE=bindings)
    abstract_binding = json.loads(bindings.read_text())
    assert abstract_binding["mode"] == "planning"
    assert abstract_binding["task_id"] is None and abstract_binding["revision_id"] is None
    context = compile_and_wrap(f, bindings, position="designer", route="session")
    enqueue(f, context)
    selected = host_reference(f, context)
    assert selected["producer"]["template_id"] == "position/designer/codex"
    # Only the sections delivered to the abstract author may enter this response.
    wrapper = Path(f.values["SUFFIX_FILE"]).read_text()
    owned = wrapper.split("sections your stage owns:", 1)[1].split("for abstract", 1)[0]
    assert "Intent Anchor" in owned, "abstract wrapper omitted its publication prerequisite"
    anchor = abstract_input["anchor"]
    assert anchor == json.loads((item / "_meta.json").read_text())["intent_anchor"]
    abstract = ("# Recipe behavior\n## Goal\nKeep source history inspectable.\n"
                "## Narrative\nThe investigation grounds this design.\n"
                "## Design Decisions\n### D1: Preserve history\n"
                "**Decision:** Retain source and report identity.\n"
                "**Rationale:** A later reader can recover the source-history basis.\n"
                "## Architecture Diagram\n```text\nsource -> report -> plan\n```\n")
    (item / "plan.md").write_text(abstract)
    refused = f.recipe("publish-revision", "an anchor-less fresh abstract cannot publish", expected=1,
                       REASON="Attempt the incomplete abstract response.", AUTHOR_ROLE="spec-lead")
    assert b"anchor" in (refused.stdout + refused.stderr).lower()
    assert not (item / "revisions.jsonl").exists() and not (item / "reviews").exists()
    abstract = abstract.replace("## Design Decisions", "## Intent Anchor\n" + anchor +
                                "\n\n**Scope delta:** none — anchor preserved unchanged\n## Design Decisions")
    (item / "plan.md").write_text(abstract)
    published = json.loads(f.recipe("publish-revision", "publish the abstract before its design gate",
                                   REASON="Record the independently authored abstract design.", AUTHOR_ROLE="spec-lead").stdout)
    abstract_revision = published["revision_id"]
    land_designer_record(f, selected, abstract_revision, "abstract")
    snapshot = item / "revisions" / abstract_revision / "plan.md"
    assert snapshot.read_bytes() == (item / "plan.md").read_bytes()
    assert not json.loads((item / "tasks.json").read_text()).get("tasks")
    f.connection("fresh abstract anchor", producer="designer-assignment.anchor and author-wrapper owned sections",
                 consumer="publish-revision", value=anchor, actor="planning-designer", revision=abstract_revision,
                 attempt=abstract_binding["dispatch_attempt_id"])
    gate = f.recipe("review-prepare", "prepare the fresh anchored abstract gate", ATTEMPT_ID="independent-design-gate",
                    CEREMONY="spec-design", REVISION_ID=abstract_revision, PURPOSE="criterion-adequacy", EXECUTION_WORKTREE="")
    gate_dir, _ = prepared_connection(f, gate, ceremony="spec-design", evaluator="coordinator")
    note = f.root / "accepted-design.md"
    note.write_text("Fixture coordinator read the whole abstract revision " + abstract_revision + " and accepts the design.\n")
    f.recipe("work-note", "seat acceptance is recorded separately from the designer output", NOTE_FILE=note)
    note_ref = re.findall(r"(?m)^## .+$", (item / "notes.md").read_text())[-1]
    projection = Path(f.recipe("acceptance-projection", "project the actual notes acceptance into the consuming JSON shape",
                               CEREMONY="spec-design", REVISION_ID=abstract_revision, NOTE_REF=note_ref).stdout.decode().strip())
    projected = json.loads(projection.read_text())
    assert projected["verdict"] == "ACCEPTED" and projected["outcome"] == "completed"
    assert note_ref in projected["judgments"][0]["rationale"] and abstract_revision in projected["judgments"][0]["rationale"]
    assert f.recipe("acceptance-projection", "identical acceptance projection reuses its authored bytes").stdout.decode().strip() == str(projection)
    for invalid in ({"CEREMONY": "unregistered-ceremony"}, {"REVISION_ID": "not-a-revision"}, {"REVISION_ID": "0" * 12}):
        f.recipe("acceptance-projection", "invalid ceremony, id format or absent snapshot refuses", expected=1, **invalid)
        f.values.update(CEREMONY="spec-design", REVISION_ID=abstract_revision)
    f.recipe("acceptance-projection", "an empty note reference refuses", expected=1, NOTE_REF="")
    f.recipe("acceptance-projection", "conflicting note reference cannot replace the existing acceptance", expected=1, NOTE_REF="## Missing note")
    f.values["NOTE_REF"] = note_ref
    disposition = f.data("accepted-design.json", {"anchor_coverage": {"disposition": "covered", "by": "fixture-coordinator",
                                                                 "note": "Source and report history remain explicit."}})
    f.recipe("plan-decision", "the seat records its authored anchor judgment against the published revision", REVISION_ID=abstract_revision,
             DECISION_ID="abstract-covered", DECISIONS_FILE=disposition)
    continuation = f.root / "concrete-assignment.json"
    f.recipe("designer-assignment", "concrete planning refuses an absent accepted revision", expected=1,
             STAGE="concrete", ACCEPTED_REVISION="", DISPOSITIONS_FILE=projection, ASSIGNMENT_FILE=continuation)
    f.recipe("designer-assignment", "Markdown notes are not the dispositions JSON input", expected=1,
             ACCEPTED_REVISION=abstract_revision, DISPOSITIONS_FILE=item / "notes.md")
    f.recipe("designer-assignment", "concrete continuation consumes the projection's emitted path", DISPOSITIONS_FILE=projection)
    continuation_input = json.loads(continuation.read_text())
    assert abstract_revision in continuation.read_text()
    assert continuation_input["accepted_plan_path"] == str(snapshot)
    assert continuation_input["accepted_plan_sha256"] == digest(snapshot.read_bytes())
    accepted_dispositions = json.loads(projection.read_text())
    assert continuation_input["dispositions"] == accepted_dispositions
    assert continuation_input["dispositions_sha256"] == digest(projection.read_bytes())
    committed = [row for row in rows(item / "revisions.jsonl") if row.get("record_type", "revision") == "revision" and row["revision_id"] == abstract_revision]
    assert len(committed) == 1 and committed[0]["plan_sha256"] == continuation_input["accepted_plan_sha256"]
    # These are deliberately corrupt inputs, not publication or gate evidence.
    original_values = dict(f.values)
    invented = "f" * 12
    fake_snapshot = item / "revisions" / invented / "plan.md"
    fake_snapshot.parent.mkdir()
    fake_snapshot.write_bytes(snapshot.read_bytes())
    fake_projection = Path(f.recipe("acceptance-projection", "characterize snapshot existence without canonical publication",
                                    REVISION_ID=invented).stdout.decode().strip())
    f.recipe("designer-assignment", "the assignment writer also copies an unregistered snapshot",
             ACCEPTED_REVISION=invented, DISPOSITIONS_FILE=fake_projection,
             ASSIGNMENT_FILE=f.root / "unregistered-continuation.json")
    assert not [row for row in rows(item / "revisions.jsonl") if row.get("revision_id") == invented]
    f.data("unregistered-provenance.json", {"supplied_revision": invented, "snapshot_exists": True,
           "projection_exit": 0, "assignment_exit": 0, "canonical_revision_present": False,
           "accepted_gate_revision": abstract_revision, "caller_admits_continuation": False})
    fake_snapshot.unlink()
    fake_snapshot.parent.rmdir()
    fake_projection.unlink()
    original_snapshot = snapshot.read_bytes()
    snapshot.write_bytes(original_snapshot + b"\nUnpublished negative-control drift.\n")
    f.recipe("designer-assignment", "the copied snapshot hash exposes drift to the canonical comparison",
             ACCEPTED_REVISION=abstract_revision, DISPOSITIONS_FILE=projection,
             ASSIGNMENT_FILE=f.root / "drifted-continuation.json")
    drifted = json.loads(Path(f.values["ASSIGNMENT_FILE"]).read_text())
    assert drifted["accepted_plan_sha256"] != committed[0]["plan_sha256"]
    f.data("drifted-provenance.json", {"assignment_sha256": drifted["accepted_plan_sha256"],
           "canonical_sha256": committed[0]["plan_sha256"], "caller_admits_continuation": False})
    snapshot.write_bytes(original_snapshot)
    f.values.update(original_values)
    for unsupported in ("gate_acceptance", "task_checkoff", "archive"):
        failure = f.recipe("plan-decision", "revision metadata does not grant " + unsupported, expected=1,
                           DECISION_ID="unsupported-" + unsupported.replace("_", "-"),
                           DECISIONS_FILE=f.data(unsupported + ".json", {unsupported: {"disposition": "accepted"}}))
        assert b"decisions must be an object containing anchor_coverage, review_requirement, or dispatch_decision" in failure.stderr
    f.values.update(original_values)
    f.connection("notes acceptance", producer="work-note -> acceptance-projection", consumer="designer-assignment",
                 value=projection, actor="coordinator", revision=abstract_revision, attempt="independent-design-gate")
    # The sealed route supplies the ledger directly, without a notes conversion.
    review_inputs(f, "independent-design-gate")
    f.recipe("review-seal", "retain the alternative sealed gate disposition input")
    sealed_dispositions = gate_dir / "sealed/dispositions.json"
    f.recipe("designer-assignment", "sealed dispositions are copied directly from their canonical path",
             ACCEPTED_REVISION=abstract_revision, DISPOSITIONS_FILE=sealed_dispositions,
             ASSIGNMENT_FILE=f.root / "sealed-continuation.json")
    assert json.loads(Path(f.values["ASSIGNMENT_FILE"]).read_text())["dispositions"] == json.loads(sealed_dispositions.read_text())
    f.values.update(ASSIGNMENT_FILE=continuation, DISPOSITIONS_FILE=projection)
    next_packet, _ = synthesized_packet(f, "designer-packet", role="designer", TOPIC="source history concrete plan", SCALE_SET="subsystem")
    assert next_packet != packet_id
    next_bindings = f.root / "concrete-bindings.json"
    f.recipe("designer-bindings", "concrete continuation gets fresh packet and attempt identities", PACKET_ID=next_packet,
             ASSIGNMENT_FILE=continuation, REPORT_ID="concrete-designer", EXECUTION_ROOT=f.code, BINDINGS_FILE=next_bindings)
    concrete_binding = json.loads(next_bindings.read_text())
    assert concrete_binding["dispatch_attempt_id"] != abstract_binding["dispatch_attempt_id"]
    assert concrete_binding["revision_id"] is None and abstract_revision in concrete_binding["assignment"]
    ref_file = compile_and_wrap(f, next_bindings, position="designer", route="session")
    reference = json.loads(ref_file.read_text())
    fixed_context = f.data("concrete-context.json", {"position_dispatch": reference,
                                                   "dispatch_guidance": Path(reference["payload_path"]).read_text()})
    enqueue(f, fixed_context, fixed=True)
    concrete_selected = host_reference(f, fixed_context)
    assert concrete_selected["reference"] == reference
    projection.write_text(json.dumps({"changed_after_binding": "MUTABLE-DISPOSITIONS-DRIFT-4819"}))
    retained = f.recipe("read-payload", "the accepted continuation retains dispositions despite input-file drift", REFERENCE_FILE=ref_file).stdout
    frozen_assignment = json.loads(json.loads(Path(reference["manifest_path"]).read_text())["bindings"]["assignment"])
    assert frozen_assignment == continuation_input
    assert b"MUTABLE-DISPOSITIONS-DRIFT-4819" not in retained
    assert str(snapshot).encode() in retained
    authored_plan(f, item, concrete=True)
    concrete_revision = json.loads(f.recipe("publish-revision", "concrete tasks publish after the accepted abstract").stdout)["revision_id"]
    assert concrete_revision != abstract_revision
    land_designer_record(f, concrete_selected, concrete_revision, "concrete")
    assert snapshot.read_bytes() != (item / "plan.md").read_bytes()
    graph = json.loads((item / "tasks.json").read_text())
    assert len(graph["tasks"]) == 1 and graph["tasks"][0]["close_criteria"]
    history = f.lore("tradeoffs", "recipes", "--scale-set", "architecture").stdout.decode()
    assert "Preserve history" in history and "plan.md" in history
    assert "worker-reports/abstract-designer.md" not in history
    assert not (item / "spec-dispatch.json").exists()
    # The same planning position can be read locally for short mode.
    inline_packet, _ = synthesized_packet(f, "designer-packet", role="designer", TOPIC="source history short plan", SCALE_SET="subsystem")
    f.recipe("designer-bindings", "short planning retains truthful inline provenance", PACKET_ID=inline_packet,
             ASSIGNMENT_FILE=continuation, REPORT_ID="inline-designer", EXECUTION_ROOT=f.code,
             BINDINGS_FILE=f.root / "inline-designer-bindings.json")
    local_ref = compile_and_wrap(f, Path(f.values["BINDINGS_FILE"]), position="designer", route="inline")
    actual = f.recipe("read-payload", "short mode reads the compiled planning designer", REFERENCE_FILE=local_ref).stdout
    assert b"planning" in actual and abstract_revision.encode() in actual
    inline_bindings = json.loads(Path(f.values["BINDINGS_FILE"]).read_text())
    inline_reference = json.loads(local_ref.read_text())
    claim = f.investigator_claim(inline_bindings, inline_reference, "short-design-source", producer="spec-lead")
    claim["task_id"] = "spec-synthesis"
    row_file = f.data("short-design-source.json", claim)
    f.recipe("append-tier2", "seat-authored short design retains spec-lead attribution", ROW_FILE=row_file)
    recorded = rows(item / "task-claims.jsonl")
    assert [row["producer_role"] for row in recorded if row["claim_id"] == claim["claim_id"]] == ["spec-lead"]
    land_designer_record(f, {"reference": inline_reference, "bindings": inline_bindings}, concrete_revision, "short", claim["claim_id"])
    f.finish({"investigator-packet", "packet-synthesis", "investigator-bindings", "compile-position", "author-wrapper", "prepare-session",
              "request-session", "session-reference", "land-report", "check-identity", "typed-completion", "designer-assignment",
              "designer-packet", "designer-bindings", "publish-revision", "work-note", "plan-decision", "bind-attempt", "read-payload"})


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
    for case in ("passing", "path-line"):
        packet, _ = synthesized_packet(f, "investigator-packet", role="investigator", INVESTIGATION_ID=case,
                                        QUERY="report writer source", SCALE_SET="implementation")
        binding_file = f.root / (case + "-bindings.json")
        f.recipe("investigator-bindings", "bind the documented report example " + case, PACKET_ID=packet,
                 INVESTIGATION_ID=case, QUESTION="Which writer lands compiled reports?", COMPLEXITY="simple",
                 REPORT_ID="documented-" + case, EXECUTION_ROOT=f.code, BINDINGS_FILE=binding_file)
        reference_file = compile_and_wrap(f, binding_file, position="investigator", route="inline")
        reference = json.loads(reference_file.read_text())
        bindings = json.loads(binding_file.read_text())
        manifest = json.loads(Path(reference["manifest_path"]).read_text())
        claim = f.investigator_claim(bindings, reference, "documented-" + case, source=source, revision=commit)
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
    f.finish({"append-tier2", "land-report", "check-identity", "typed-completion"})


def exercise_consultation(f):
    item = f.create_item()
    authored_plan(f, item, concrete=True)
    revision = json.loads(f.recipe("publish-revision", "publish the requesting worker's real task",
                                  REASON="Prepare a task-domain consultation.", AUTHOR_ROLE="spec-lead").stdout)["revision_id"]
    decisions = f.data("consultation-task-decisions.json", {
        "anchor_coverage": {"disposition": "covered", "by": "fixture-coordinator", "note": "The task retains inspectable history."},
        "review_requirement": {"disposition": "not-required", "by": "fixture-coordinator", "note": "Declared isolated consultation fixture."},
        "dispatch_decision": {"disposition": "proceed", "by": "fixture-coordinator", "note": "Exercise the requested consultation.",
                              "task_ids": ["task-1"], "prior_review_refs": []}})
    f.recipe("plan-decision", "record the fixture seat's explicit task preparation decision", REVISION_ID=revision,
             DECISION_ID="consultation-task", DECISIONS_FILE=decisions)
    opened = json.loads(f.lore("impl", "open", "recipes", "--all", "--compiled-positions", "--json").stdout)
    task = next(row for row in opened["manifest"] if row["op"] == "TaskCreate")
    worker = task["position_binding_inputs"]
    assert worker["task_id"] == "task-1" and worker["revision_id"] == revision
    impl = lambda name, scenario, **values: f.external("implement", "implement", name, scenario, **values)
    packet = json.loads(impl("designer-packet", "build the consultation packet through the existing implement handoff",
                            DOMAIN="storage", QUESTION="Where is the committed source?", SCALE_SET="implementation").stdout)
    packet_id = packet["packet_id"]
    impl("synthesize-packet", "synthesize this consultation before binding", PACKET_ID=packet_id,
         SYNTHESIS_FILE=f.data("consultation-synthesis.json", {"dropped": [], "added": []}))
    request = f.root / "consultation-request.md"
    request.write_text("## Consultation\nconsultation-id: storage-question\ndomain: storage\nreason: Locate committed source.\nquestion: Where is the committed source?\ntask: task-1\n")
    binding_file = f.root / "consultation-bindings.json"
    impl("designer-bindings", "worker identity is carried in the assignment with a session-scoped envelope",
         REQUEST_FILE=request, ADVISOR_NAME="storage-advisor", WORKER_NAME=worker["task_id"], TASK_ID=worker["task_id"],
         REVISION_ID=revision, EXECUTION_ROOT=f.code, BINDINGS_FILE=binding_file)
    bindings = json.loads(binding_file.read_text())
    assert bindings["mode"] == "consultation" and bindings["task_id"] is None and bindings["revision_id"] is None
    assigned = json.loads(bindings["assignment"])
    assert assigned["task_id"] == worker["task_id"] and assigned["revision_id"] == revision
    assert assigned["request"] == request.read_text()
    assert bindings["consultation_id"] == "storage-question" and bindings["domain"] == "storage"
    impl("compile-position", "compile the consultation-specific producer", POSITION="designer", TARGET_FRAMEWORK="codex",
         GUIDANCE_FILE=f.root / "consult-guidance.md", DESCRIPTOR_FILE=f.root / "consult-descriptor.json")
    impl("author-wrapper", "read the actual consultation reply contract", SKILL_FILE=f.repo / "skills/implement/SKILL.md",
         WRAPPER_FILE=f.root / "consult-wrapper.json", PREFIX_FILE=f.root / "consult-prefix.md", SUFFIX_FILE=f.root / "consult-suffix.md",
         ROUTE="designer", WORK_TITLE="Recipe behavior", TEAM_NAME="", LEAD_NAME="", PLACEMENT_NOTE="Use the assigned root.", TIER2_EXTRACT_FILE="")
    suffix = Path(f.values["SUFFIX_FILE"]).read_text()
    assert "advisor-acknowledged: true" in suffix and "reply_destination" in suffix
    reference = json.loads(impl("bind-attempt", "bind a fresh consultation attempt with its own packet",
                                REQUIRED_BINDINGS="packet_id packet_pointer", NATIVE_MODEL="").stdout)
    f.connection("task-domain commission", producer="implement designer-bindings", consumer="implement bind-attempt",
                 value=packet_id, actor="implement-lead", revision=revision, attempt=bindings["dispatch_attempt_id"])
    impl("synthesize-packet", "the worker packet remains a different identity", PACKET_ID=worker["packet_id"],
         SYNTHESIS_FILE=f.data("worker-synthesis.json", {"dropped": [], "added": []}))
    bad = dict(bindings, **{key: worker[key] for key in ("task_id", "revision_id", "packet_id", "packet_pointer")})
    bad["absence_reasons"] = {key: value for key, value in bindings["absence_reasons"].items()
                              if key not in ("task_id", "revision_id")}
    bad_file = f.data("wrong-task-packet.json", bad)
    failure = impl("bind-attempt", "a worker packet cannot supply a fresh designer attempt", expected=1, BINDINGS_FILE=bad_file)
    assert b"dispatch_attempt_id mismatch" in failure.stdout + failure.stderr
    f.values["BINDINGS_FILE"] = binding_file
    manifest = json.loads(Path(reference["manifest_path"]).read_text())
    version = manifest["producer"]["template_version"]
    reply = Path(bindings["reply_destination"])
    reply.parent.mkdir(parents=True, exist_ok=True)
    reply.write_text("**Revision:** " + revision + "\n**Decisions:** Preserve history.\n")
    impl("check-reply", "a planning record cannot substitute for a consultation reply", expected=1,
         REPLY_FILE=reply, CONSULTATION_ID=bindings["consultation_id"], DESIGNER_TEMPLATE_VERSION=version)
    reply.write_text(f"consultation-id: {bindings['consultation_id']}\nhandler: agent\nadvisor_template_version: {version}\nadvisor-acknowledged: true\n**Domain:** storage\n**Guidance:** Read tracked in the assigned root.\n**Key files:**\n- {f.code / 'tracked'}\n")
    impl("check-reply", "the reply joins the actual consultation identity")
    impl("consult-log", "file the acknowledged reply through the canonical consultation writer", HANDLER="agent",
         QUESTION="Where is the committed source?", ANSWER=reply.read_text(), SKILL_TEMPLATE_VERSION="",
         ADVISOR_TEMPLATE_VERSION=version, MANIFEST_PATH=reference["manifest_path"], MANIFEST_SHA256=reference["manifest_sha256"],
         LEAD_TEMPLATE_VERSION=digest((f.repo / "skills/implement/SKILL.md").read_bytes())[:12])
    transcript = rows(item / "consultation-transcript.jsonl")
    assert len(transcript) == 1 and transcript[0]["consultation_id"] == bindings["consultation_id"]
    f.values["SKILL_FILE"] = f.repo / "skills/spec/SKILL.md"
    f.finish({"publish-revision"})


def review_inputs(f, name, *, outcome="completed", verdict="PASS", reason=None, evaluator="spec-lead"):
    output = f.root / (name + "-review.md")
    output.write_text("Declared fixture review response. No live evaluator was run.\nVerdict: " + verdict + "\n")
    dispositions = f.data(name + "-dispositions.json", {"schema_version": 1, "outcome": outcome, "verdict": verdict,
        "reason": reason, "judgments": [{"purpose": "criterion-adequacy", "judgment": "needs-decision" if outcome == "needs-decision" else "adequate",
        "rationale": "The authored fixture judgment names the reviewed stage without claiming execution.", "result_ids": []}], "dispositions": []})
    f.values.update(REVIEW_OUTPUT=output, DISPOSITIONS_JSON=dispositions, NORMALIZED_OUTCOME=outcome, RAW_VERDICT=verdict,
                    REASON=reason or "", EVALUATOR=evaluator, FRAMEWORK="codex", MODEL="gpt-6-astra",
                    EVALUATOR_JSON=f.root / (name + "-evaluator.json"), SEAL_RESULT=f.root / (name + "-seal.json"),
                    EVIDENCE_JSON=f.root / (name + "-evidence.json"))
    if evaluator == "spec-lead":
        f.recipe("seat-evaluator-manifest", "record the standalone seat's own whole-stage read")
    else:
        skill = f.repo / "skills" / evaluator / "SKILL.md"
        Path(f.values["EVALUATOR_JSON"]).write_text(json.dumps({"evaluator_locator": str(skill),
            "evaluator_template_version": digest(skill.read_bytes())[:12], "framework": "codex", "model": "gpt-6-astra", "final_round": 1}))


def prepared_connection(f, prepared, *, ceremony, evaluator):
    # Preserve the writer's exact output; only the authored extractor converts it.
    output = f.root / (f.values["ATTEMPT_ID"] + "-prepare-result.json")
    output.write_bytes(prepared.stdout)
    raw = json.loads(prepared.stdout)
    directory = Path(f.recipe("prepared-dir", "convert emitted prepared.json to the evaluator directory",
                              PREPARE_RESULT=output).stdout.decode().strip())
    namespace = "spec-design-review" if ceremony == "spec-design" else "spec-plan-review"
    skill = "codex-design-review" if ceremony == "spec-design" else "codex-plan-review"
    bad = f.external(skill, namespace, "read-prepared", "raw prepared.json is not a prepared directory", expected=1,
                     PREPARED_DIR=raw["prepared_path"])
    assert b"does not name attempt" in bad.stdout + bad.stderr
    bound = json.loads(f.external(skill, namespace, "read-prepared", "consume the exact authored directory output",
                                  PREPARED_DIR=directory).stdout)
    assert bound["attempt_id"] == f.values["ATTEMPT_ID"] and bound["revision_id"] == f.values["REVISION_ID"]
    assert directory == Path(bound["prepared_dir"])
    f.connection("prepared directory", producer="review-prepare -> prepared-dir", consumer=skill + " read-prepared",
                 value=directory, actor=evaluator, revision=bound["revision_id"], attempt=bound["attempt_id"])
    return directory, bound


def ceremony_records(item):
    log = item / "execution-log.md"
    return [json.loads(line.removeprefix("Spec-outcome-record: ")) for line in
            (log.read_text().splitlines() if log.exists() else []) if line.startswith("Spec-outcome-record: ")]


def exercise_gate_composition(f, ceremony):
    item = f.create_item()
    (f.home / ".codex/skills").mkdir(parents=True)
    authored_plan(f, item, concrete=ceremony == "spec-post-plan")
    revision = json.loads(f.recipe("publish-revision", "publish before the commissioned gate",
                                  REASON="Publish the declared ceremony stage.", AUTHOR_ROLE="spec-lead").stdout)["revision_id"]
    skill = "codex-design-review" if ceremony == "spec-design" else "codex-plan-review"
    namespace = "spec-design-review" if ceremony == "spec-design" else "spec-plan-review"
    other = "fixture-" + skill
    # A second distinct registered evaluator with an explicitly authored response.
    other_source = f.repo / "skills" / other / "SKILL.md"
    other_source.parent.mkdir()
    other_source.write_text("# Fixture evaluator\nReads the supplied revision; returns a declared test response.\n")
    for evaluator in (skill, other):
        f.lore("ceremony", "add", ceremony, evaluator)
    registered = f.recipe("ceremony-get", "read both registered identities", CEREMONY=ceremony).stdout.decode()
    assert skill in registered and other in registered
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    attempts = [ceremony + "-" + evaluator + "-" + stamp + "-r1" for evaluator in (skill, other)]
    f.data("attempt-inputs.json", {"ceremony": ceremony, "evaluators": [skill, other], "utc": stamp, "attempt_ids": attempts})
    prepared = []
    for evaluator, attempt in zip((skill, other), attempts):
        result = f.recipe("review-prepare", "commissioned lead prepares one initial attempt for " + evaluator,
                          ATTEMPT_ID=attempt, CEREMONY=ceremony, REVISION_ID=revision,
                          PURPOSE="criterion-adequacy", EXECUTION_WORKTREE="")
        prepared.append(result)
        f.connection("commissioned preparation", producer="review-prepare", consumer="coordinator handoff",
                     value=json.loads(result.stdout)["prepared_path"], actor="commissioned-spec-lead", revision=revision, attempt=attempt)
    f.recipe("awaiting-note", "lead hands both prepared attempts to the coordinator once",
             ATTEMPT_IDS=" ".join(attempts), POST_EDIT_REVISION="")
    f.recipe("awaiting-note", "an empty attempt handoff refuses before writing another note", expected=1, ATTEMPT_IDS="")
    f.values["ATTEMPT_IDS"] = " ".join(attempts)
    notes = (item / "notes.md").read_text()
    assert all(attempt in notes for attempt in attempts) and revision in notes and notes.count("Awaiting") == 1
    assert not list((item / "reviews").glob("*/sealed"))
    assert not ceremony_records(item)
    pre_seat = tree_hashes(item / "reviews")
    f.data("pre-seat-state.json", {"actor": "commissioned-spec-lead", "revision": revision, "attempts": attempts,
                                 "review_hashes": pre_seat, "seal_count": 0, "acceptance": None})
    history = []
    for index, (evaluator, attempt, result) in enumerate(zip((skill, other), attempts, prepared)):
        f.values.update(ATTEMPT_ID=attempt, REVISION_ID=revision, CEREMONY=ceremony)
        directory, bound = prepared_connection(f, result, ceremony=ceremony, evaluator="coordinator")
        review_inputs(f, attempt, evaluator=evaluator, verdict="COMPARABLE" if ceremony == "spec-design" else "GATE PASSED")
        if index == 0:
            f.external(skill, namespace, "evaluator-manifest", "coordinator runs the registered skill's terminal continuation",
                       FINAL_ROUND=1, EVALUATOR_FILE=f.values["EVALUATOR_JSON"])
            f.external(skill, namespace, "seal-review", "coordinator seals the attempt that the evaluator read",
                       DISPOSITIONS_FILE=f.values["DISPOSITIONS_JSON"], EVIDENCE_FILE=f.values["EVIDENCE_JSON"])
            outcome = json.loads(f.external(skill, namespace, "file-outcome", "coordinator files the registered skill identity",
                                           OUTCOME="completed", VERDICT=f.values["RAW_VERDICT"]).stdout)
        else:
            f.recipe("review-seal", "coordinator seals the second evaluator's independent response")
            outcome = json.loads(f.recipe("spec-outcome", "file the second evaluator under its own identity").stdout)
        assert outcome["outcome"] == "completed"
        joined = [row for row in ceremony_records(item) if row["attempt_id"] == attempt]
        assert len(joined) == 1 and joined[0]["advisor"] == evaluator and joined[0]["ceremony"] == ceremony
        evidence = json.loads(Path(f.values["EVIDENCE_JSON"]).read_text())
        assert evidence["revision_id"] == revision and evidence["review_path"] == "reviews/" + attempt + "/sealed/seal.json"
        history.append((directory, tree_hashes(directory)))
        f.connection("commissioned terminal review", producer=evaluator, consumer="seal and outcome",
                     value=f.values["EVIDENCE_JSON"], actor="coordinator", revision=revision, attempt=attempt)
        if index == 0:
            original_inputs = dict(f.values)
            review_inputs(f, attempt + "-collision", evaluator=other, verdict="SECOND DISTINCT VERDICT")
            refused = f.recipe("review-seal", "a second evaluator cannot reuse a write-once attempt", expected=1)
            assert b"attempt-id collision" in refused.stdout + refused.stderr
            f.values.update(original_inputs)
            f.recipe("spec-outcome", "an advisor identity cannot be changed after outcome filing", expected=1, EVALUATOR=other)
            f.values.update(original_inputs)
    # The seat's acceptance is a separate note, after both terminal outcomes.
    note = f.root / "gate-acceptance.md"
    note.write_text("Fixture coordinator accepts " + ceremony + " revision " + revision + " after reading it whole.\n")
    f.recipe("work-note", "acceptance follows evaluator evidence and remains a separate record", NOTE_FILE=note)
    # A user edit after the earlier publication must enter a new reviewed snapshot.
    live = item / "plan.md"
    live.write_text(live.read_text().replace("A later reader can recover the basis of the design.",
                                          "A later reader can recover the basis of the design. Accepted abstract clarification."))
    revised = json.loads(f.recipe("publish-revision", "publish intervening user-gate edits immediately before review",
                                 REASON="Publish design-affecting user-gate clarification.", AUTHOR_ROLE="spec-lead").stdout)["revision_id"]
    assert revised != revision
    # Retain all-Accept: the evaluated revision remains sealed; no unread successor is fabricated.
    f.values.update(CEREMONY=ceremony, REVISION_ID=revision)
    f.recipe("awaiting-note", "post-edit handoff names reviewed N and newly published M once",
             ATTEMPT_IDS=" ".join(attempts), POST_EDIT_REVISION=revised)
    notes = (item / "notes.md").read_text()
    assert revision in notes and revised in notes and notes.count("Awaiting") == 2
    assert sorted(path.name for path in (item / "reviews").iterdir() if path.is_dir()) == sorted(attempts)
    for path, hashes in history:
        assert tree_hashes(path) == hashes
    repeat_design = f.recipe("review-prepare", "the abstract edit repeats the affected design gate",
                             ATTEMPT_ID=ceremony + "-affected-design", CEREMONY="spec-design", REVISION_ID=revised)
    directory, bound = prepared_connection(f, repeat_design, ceremony="spec-design", evaluator="coordinator")
    assert Path(bound["plan_file"]).read_bytes() == live.read_bytes()
    # Each evaluator's follow-up gets its own attempt at the new revision.
    for evaluator, initial in zip((skill, other), attempts):
        attempt = initial.removesuffix("-r1") + "-r2"
        fresh = f.recipe("review-prepare", "independent evaluator retry retains its own attempt lineage",
                         ATTEMPT_ID=attempt, CEREMONY=ceremony, REVISION_ID=revised)
        _, bound = prepared_connection(f, fresh, ceremony=ceremony, evaluator="coordinator")
        assert Path(bound["plan_file"]).read_bytes() == live.read_bytes()
        review_inputs(f, attempt, evaluator=evaluator)
        f.recipe("review-seal", "seal the actual independently reviewed successor")
        f.recipe("spec-outcome", "file the successor without relabeling either historical review")
    for path, hashes in history:
        assert tree_hashes(path) == hashes
    assert not (item / "results.jsonl").exists()
    f.finish({"publish-revision", "ceremony-get", "review-prepare", "prepared-dir", "awaiting-note", "review-seal", "spec-outcome", "work-note"})


def exercise_reviews(f):
    item = f.create_item()
    historic = []
    (f.home / ".codex/skills").mkdir(parents=True)
    for index, (ceremony, evaluator) in enumerate((("spec-design", "codex-design-review"), ("spec-post-plan", "codex-plan-review"))):
        authored_plan(f, item, concrete=bool(index))
        revision = json.loads(f.recipe("publish-revision", "publish the stage before preparing " + ceremony,
                                      REASON="Publish the authored review fixture stage.", AUTHOR_ROLE="spec-lead").stdout)["revision_id"]
        f.lore("ceremony", "add", ceremony, evaluator)
        registered = f.recipe("ceremony-get", "the registered evaluator remains discoverable", CEREMONY=ceremony).stdout.decode()
        assert evaluator in registered
        attempt = ceremony + "-registered"
        prepared = f.recipe("review-prepare", "freeze the registered evaluator's exact stage", ATTEMPT_ID=attempt,
                            CEREMONY=ceremony, REVISION_ID=revision, PURPOSE="criterion-adequacy", EXECUTION_WORKTREE="")
        directory, _ = prepared_connection(f, prepared, ceremony=ceremony, evaluator="standalone-spec-lead")
        before = tree_hashes(directory)
        f.recipe("review-prepare", "the same attempt cannot be rebound to an unknown revision", expected=1, REVISION_ID="0" * 12)
        f.values["REVISION_ID"] = revision
        assert tree_hashes(directory) == before
        review_inputs(f, attempt, evaluator=evaluator, verdict="COMPARABLE" if index == 0 else "GATE PASSED")
        f.recipe("review-seal", "seal the declared external fixture response once")
        evidence = json.loads(Path(f.values["EVIDENCE_JSON"]).read_text())
        assert evidence["schema_version"] == 2 and evidence["revision_id"] == revision
        assert evidence["review_path"] == "reviews/" + attempt + "/sealed/seal.json"
        result = json.loads(f.recipe("spec-outcome", "file the same registered advisor and invocation identity").stdout)
        assert result["outcome"] == "completed"
        assert json.loads(f.recipe("spec-outcome", "the evaluator's already-filed outcome is reused").stdout)["status"] == "reused"
        frozen = tree_hashes(directory)
        bad_ceremony = "spec-post-plan" if index == 0 else "spec-design"
        rejected = f.recipe("spec-outcome", "sealed evidence cannot be filed under the wrong ceremony", expected=1, CEREMONY=bad_ceremony)
        assert b"ceremony" in (rejected.stdout + rejected.stderr).lower()
        f.values["CEREMONY"] = ceremony
        f.recipe("spec-outcome", "missing review evidence cannot certify a completed ceremony", expected=1, EVIDENCE_JSON=f.root / "absent-evidence.json")
        f.values["EVIDENCE_JSON"] = f.root / (attempt + "-evidence.json")
        assert tree_hashes(directory) == frozen
        historic.append((directory, frozen, revision))
        assert not (item / "results.jsonl").exists()
        # A commissioned lead prepares this handoff but seals no gate itself.
        commissioned = ceremony + "-commissioned"
        f.recipe("review-prepare", "prepare the coordinator's commissioned gate", ATTEMPT_ID=commissioned)
        f.recipe("awaiting-note", "one commissioned note names the revision and prepared attempt",
                 ATTEMPT_IDS=commissioned, POST_EDIT_REVISION="")
        notes = (item / "notes.md").read_text()
        assert revision in notes and commissioned in notes and "Awaiting" in notes
        assert not (item / "reviews" / commissioned / "sealed").exists()
        f.lore("ceremony", "remove", ceremony, evaluator)
        assert evaluator not in f.recipe("ceremony-get", "no registered evaluator leaves the read with the bound seat").stdout.decode()
        seat_attempt = ceremony + "-standalone-seat"
        f.recipe("review-prepare", "prepare the standalone whole-stage seat read", ATTEMPT_ID=seat_attempt)
        review_inputs(f, seat_attempt)
        f.recipe("review-seal", "standalone seat records its own read separately from acceptance")
        f.recipe("spec-outcome", "file the standalone no-evaluator read explicitly")
        note = f.root / (ceremony + "-accepted.md")
        note.write_text("Fixture seat accepts revision " + revision + " after reading the entire " + ceremony + " stage.\n")
        f.recipe("work-note", "record acceptance separately from evaluator evidence", NOTE_FILE=note)
        f.recipe("file-unavailable", "unavailable registered evaluator preserves schema1 absence",
                 ATTEMPT_ID=ceremony + "-unavailable", EVALUATOR=evaluator, PLAN_FILE=item / "revisions" / revision / "plan.md",
                 REASON="Declared fixture evaluator is unavailable.", EVIDENCE_JSON=f.root / (ceremony + "-unavailable.json"))
        absence = json.loads(Path(f.values["EVIDENCE_JSON"]).read_text())
        assert absence["schema_version"] == 1 and absence["final_round"] is None
        f.recipe("spec-outcome", "unavailable evidence cannot become a completed outcome", expected=1,
                 NORMALIZED_OUTCOME="completed", RAW_VERDICT="UNAVAILABLE", REASON="")
    for directory, frozen, revision in historic:
        assert tree_hashes(directory) == frozen
    # An explicit unresolved outcome leaves this scenario before finalization.
    revision = historic[-1][2]
    f.recipe("review-prepare", "prepare an unresolved post-plan decision", CEREMONY="spec-post-plan", REVISION_ID=revision, ATTEMPT_ID="unresolved")
    review_inputs(f, "unresolved", outcome="needs-decision", verdict="GATE FAILED", reason="The fixture decision remains open.")
    f.recipe("review-seal", "seal an unresolved judgment without treating it as acceptance")
    assert json.loads(f.recipe("spec-outcome", "record the unresolved gate before stopping the continuation").stdout)["outcome"] == "needs-decision"
    assert not (item / "results.jsonl").exists()
    assert "Spec-finalize-atom:" not in (item / "execution-log.md").read_text()
    f.finish({"publish-revision", "ceremony-get", "review-prepare", "review-seal", "spec-outcome", "seat-evaluator-manifest",
              "file-unavailable", "awaiting-note", "work-note"})


def exercise_finalize(f):
    item = f.create_item()
    authored_plan(f, item, concrete=True)
    lead_version = digest((f.repo / "skills/spec/SKILL.md").read_bytes())[:12]
    f.recipe("verify-backlinks", "early backlink verification uses its existing writer")
    f.recipe("regen-tasks", "advisory sizing retains the existing task generator")
    f.recipe("prefetch", "task annotation declares a deliberate retrieval scale", TOPIC="source history", SCALE_SET="implementation")
    # Hosted registry rows are declared fixture inputs; events use the real writer.
    registry = f.store / "_sessions/instances/fixture.json"
    registry.write_text(json.dumps({"name": "fixture", "project_dir": str(f.code), "sessions": [
        {"slug": "recipes", "type": "spec", "request_id": "fixture-spawn-request"}]}))
    declared_steps = dict(re.findall(r'STEP_ID=(spec:[a-z-]+)[^\n]*?STEP_LABEL="([^"]+)"',
                                    (f.repo / "skills/spec/SKILL.md").read_text()))
    assert set(declared_steps) == {"spec:investigation", "spec:design", "spec:plan-ready"}, "missing authored milestone call site"
    assert {"LORE_SESSION_INSTANCE", "LORE_SESSION_SLUG", "LORE_SESSION_TYPE"} <= set(f.rows["journal-step"]["inputs"])
    session_before = tree_hashes(f.store / "_sessions")
    investigation = next(step for step in declared_steps if step == "spec:investigation")
    unhosted = f.recipe("journal-step", "unhosted milestone invokes no session writer", STEP_ID=investigation,
                       STEP_LABEL=declared_steps[investigation], LORE_SESSION_INSTANCE="", LORE_SESSION_SLUG="", LORE_SESSION_TYPE="")
    assert unhosted.stdout == b"" and unhosted.stderr == b""
    assert tree_hashes(f.store / "_sessions") == session_before
    for step, label in declared_steps.items():
        f.recipe("journal-step", "journal the durable " + step + " milestone", STEP_ID=step, STEP_LABEL=label,
                 LORE_SESSION_INSTANCE="fixture", LORE_SESSION_SLUG="recipes", LORE_SESSION_TYPE="spec")
        f.connection("hosted milestone", producer="authored milestone call site", consumer="journal-step",
                     value=step + ": " + label, actor="spec-lead")
        before = tree_hashes(f.store / "_sessions")
        f.recipe("journal-step", "identical milestone replay is idempotent")
        assert tree_hashes(f.store / "_sessions") == before
    events = rows(f.store / "_sessions/events.jsonl")
    assert [row["step_id"] for row in events if row["event"] == "step_completed"] == [
        "spec:investigation", "spec:design", "spec:plan-ready"]
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
    assert unhosted.stdout == b"" and unhosted.stderr == b""
    assert tree_hashes(f.store / "_sessions") == session_before
    (item / "plan.md").write_text(original)
    f.recipe("spec-finalize", "successful finalization publishes the authored current revision")
    first_revision = json.loads((item / "tasks.json").read_text())["revision_id"]
    events = rows(f.store / "_sessions/events.jsonl")
    assert [row["event"] for row in events if row["event"] in ("step_completed", "close_requested")] == [
        "step_completed", "step_completed", "step_completed", "close_requested"]
    assert next(row for row in events if row["event"] == "close_requested")["reason"] == "protocol_terminus"
    assert rows(f.store / "_scorecards/rows.jsonl") != telemetry_before
    f.recipe("spec-finalize", "unchanged finalization retains the existing revision")
    assert json.loads((item / "tasks.json").read_text())["revision_id"] == first_revision
    authored_plan(f, item, concrete=True, retrieval="legacy")
    f.recipe("spec-finalize", "semantic edits publish another revision while retaining legacy retrieval declarations")
    assert json.loads((item / "tasks.json").read_text())["revision_id"] != first_revision
    assert (item / "revisions" / first_revision / "plan.md").read_text() == original
    f.recipe("work-heal", "follow-up repair retains work evidence through the existing writer")
    f.finish({"verify-backlinks", "regen-tasks", "prefetch", "journal-step", "spec-finalize", "work-heal"})


def knowledge_entries(f):
    return {p for p in f.store.rglob("*.md") if not p.relative_to(f.store).parts[0].startswith("_")}


def exercise_stewardship(f):
    item = f.create_item()
    version = digest((f.repo / "skills/spec/SKILL.md").read_bytes())[:12]
    f.recipe("diagram-conventions", "read the actual diagram convention source")
    before = knowledge_entries(f)
    insight = "The fixture source history retains the original committed first line as an inspectable fact."
    f.recipe("capture-observation", "capture a seat-authored observation through the canonical writer", INSIGHT=insight,
             SCALE="implementation", PRODUCER_ROLE="spec-lead", CAPTURER_ROLE="", SOURCE_ARTIFACT_IDS="", TEMPLATE_VERSION=version)
    created = knowledge_entries(f) - before
    assert len(created) == 1, created
    entry = created.pop()
    relative = str(entry.relative_to(f.store))
    assert insight in entry.read_text()
    f.recipe("verify-held", "ground the knowledge check in committed source", KNOWLEDGE_PATH=relative, VERIFY_SOURCE="designer",
             FILE=f.code / "tracked", LINE_RANGE="1-1", SNIPPET="observable source", CYCLE_ID="fixture-held", TEMPLATE_VERSION=version)
    trust = f.store / "_trust/trust-events.jsonl"
    assert rows(trust)
    held_bytes = trust.read_bytes()
    f.recipe("verify-held", "repeated held observation does not duplicate its trust event")
    assert trust.read_bytes() == held_bytes
    replacement = "The fixture source history is inspectable through the committed tracked file."
    f.recipe("verify-contradicted", "a systemic correction replaces the supported scope of the claim",
             RESOLUTION="corrected", RATIONALE="The replacement names the actual source boundary.", CLAIM_TEXT=insight,
             FALSIFIER="The committed tracked file is absent.", SUPERSEDED_TEXT=insight, REPLACEMENT_TEXT=replacement,
             CONFIDENCE="high", EVIDENCE_SCOPE="systemic", CLAIM_SCALE="implementation", DISPUTE_NOTE="", CYCLE_ID="fixture-correction")
    assert replacement in entry.read_text()
    refused = f.recipe("verify-contradicted", "a single call site cannot correct an architectural claim", expected=3,
                       CLAIM_TEXT=replacement, SUPERSEDED_TEXT=replacement, REPLACEMENT_TEXT="All source history uses one file.",
                       EVIDENCE_SCOPE="single-callsite", CLAIM_SCALE="architecture", CYCLE_ID="fixture-dispute")
    assert b"disputed-required" in refused.stdout + refused.stderr
    f.recipe("verify-contradicted", "the same contradiction is resolved with an explicit dispute", RESOLUTION="disputed",
             DISPUTE_NOTE="One committed file does not establish an architectural claim.")
    assert "One committed file" in entry.read_text()
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
    f.finish({"diagram-conventions", "capture-observation", "verify-held", "verify-contradicted", "claim-record", "capture-theory"})


def merge_coverage(source, paths, destination):
    document, bodies = inventory(source, "spec")
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True, choices=("inventory", "coverage", "synthesis", "entry", "inline", "full", "native", "designer", "documented-report", "consultation", "gate-design", "gate-plan", "reviews", "finalize", "stewardship"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--prose-ref")
    parser.add_argument("--source", type=Path)
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
    elif args.scenario in ("synthesis", "entry", "inline", "full", "native", "designer", "documented-report", "consultation", "gate-design", "gate-plan", "reviews", "finalize", "stewardship"):
        implementation = compose_source(Path(__file__).resolve().parents[2], args.root / "source", args.prose_ref)
        {"synthesis": exercise_synthesis, "entry": exercise_entry, "inline": exercise_inline, "full": exercise_full, "native": exercise_native, "designer": exercise_designer, "documented-report": exercise_documented_report, "consultation": exercise_consultation, "gate-design": lambda f: exercise_gate_composition(f, "spec-design"), "gate-plan": lambda f: exercise_gate_composition(f, "spec-post-plan"), "reviews": exercise_reviews, "finalize": exercise_finalize, "stewardship": exercise_stewardship}[args.scenario](SpecFixture(implementation, args.root / "case"))
    elif args.scenario == "coverage":
        assert args.source, "coverage requires the exact spec source"
        args.root.mkdir(parents=True, exist_ok=True)
        merge_coverage(args.source, args.inventories, args.root / "inventory.json")
        changed = args.root / "changed-current-spec.md"
        changed.write_bytes(args.source.read_bytes() + b"\nChanged current protocol input.\n")
        for source, paths, reason in ((changed, args.inventories, "scenario source changed"),
                                      (args.source, [], "empty coverage selection")):
            try:
                merge_coverage(source, paths, args.root / "negative-inventory.json")
            except AssertionError as exc:
                assert reason in str(exc), str(exc)
            else:
                raise AssertionError("aggregate admitted " + reason)
        assert not (args.root / "negative-inventory.json").exists()
        print("Current-source aggregate rejects changed protocol bytes and empty selection")


if __name__ == "__main__":
    main()
