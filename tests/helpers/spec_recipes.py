#!/usr/bin/env python3
"""Execute the spec skill's exact recipes through isolated, real writers."""

import argparse
import copy
import json
import os
from pathlib import Path
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

    def recipe(self, name, scenario, expected=0, **values):
        assert set(values) <= set(self.rows[name]["inputs"]), (name, "undeclared supplied inputs", set(values) - set(self.rows[name]["inputs"]))
        self.values.update(values)
        inputs = {key: self.values[key] for key in self.rows[name]["inputs"]}
        start = time.monotonic()
        try:
            return self.run(name, inputs, scenario, expected)
        finally:
            self.timings.append({"recipe": name, "scenario": scenario, "cwd": str(self.code),
                                 "inputs": {key: str(value) for key, value in inputs.items()},
                                 "elapsed_seconds": time.monotonic() - start})
            (self.root / "recipe-timings.json").write_text(json.dumps(self.timings, indent=2) + "\n")

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
    assert summaries[0]["synthesis"] == latest["synthesis"] and summaries[0]["superseded_rows"] == 1
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
    f.recipe("land-report", "land the complete inline report before checking identity",
             REPORT_ID=b["report_id"], REPORT_BODY_FILE=source)
    report = Path(b["report_path"])
    assert report.read_bytes() == source.read_bytes()
    f.recipe("check-identity", "compare headers with the independently held reference",
             REPORT_PATH=report, REFERENCE_FILE=reference_file)
    claim_rows = rows(f.store / "_work/recipes/task-claims.jsonl")
    f.recipe("typed-completion", "inline investigator uses the same typed completion boundary", TASK_ID="")
    assert rows(f.store / "_work/recipes/task-claims.jsonl") == claim_rows
    assert {row["producer_role"] for row in claim_rows} <= {"researcher"}
    assert not (f.store / "_work/recipes/spec-dispatch.json").exists()
    f.recipe("land-report", "retry cannot overwrite the original report", expected=4)
    assert report.read_bytes() == source.read_bytes()
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
    model = f.recipe("resolve-role-model", "resolve the configured investigation model", ROLE="researcher", CEREMONY="spec").stdout.decode().strip()
    assert model == "gpt-6-astra"
    draft = f.data("investigations-draft.json", document)
    declared = f.root / "investigations.json"
    f.recipe("declare-dispatch", "full mode explicitly selects ordinary sessions", INVESTIGATIONS_DRAFT=draft,
             BINDINGS_DIR=bindings_dir, TARGET_FRAMEWORK="codex", MODEL=model, INVESTIGATIONS_JSON=declared)
    shaped = json.loads(declared.read_text())
    assert all(inv["dispatch"]["route"] == "session" and inv["dispatch"]["bindings"]["execution_root"] is None
               for inv in shaped["investigations"])
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
        queued = enqueue(f, context_file)
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
        enqueue(f, context_file)
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
    f.recipe("declare-dispatch", "native opt-in leaves the existing open default intact", INVESTIGATIONS_DRAFT=draft,
             BINDINGS_DIR="", TARGET_FRAMEWORK="codex", MODEL="gpt-6-astra-high", INVESTIGATIONS_JSON=declared)
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
    # This is the declared external designer response, not an invented writer row.
    authored_plan(f, item)
    published = json.loads(f.recipe("publish-revision", "publish the abstract before its design gate",
                                   REASON="Record the independently authored abstract design.", AUTHOR_ROLE="spec-lead").stdout)
    abstract_revision = published["revision_id"]
    land_designer_record(f, selected, abstract_revision, "abstract")
    snapshot = item / "revisions" / abstract_revision / "plan.md"
    assert snapshot.read_bytes() == (item / "plan.md").read_bytes()
    assert not json.loads((item / "tasks.json").read_text()).get("tasks")
    note = f.root / "accepted-design.md"
    note.write_text("Fixture coordinator read the whole abstract revision " + abstract_revision + " and accepts the design.\n")
    f.recipe("work-note", "seat acceptance is recorded separately from the designer output", NOTE_FILE=note)
    disposition = f.data("accepted-design.json", {"anchor_coverage": {"disposition": "covered", "by": "fixture-coordinator",
                                                                 "note": "Source and report history remain explicit."}})
    f.recipe("plan-decision", "the seat records its authored anchor judgment against the published revision", REVISION_ID=abstract_revision,
             DECISION_ID="abstract-covered", DECISIONS_FILE=disposition)
    continuation = f.root / "concrete-assignment.json"
    f.recipe("designer-assignment", "concrete planning refuses an absent accepted revision", expected=1,
             STAGE="concrete", ACCEPTED_REVISION="", DISPOSITIONS_FILE=disposition, ASSIGNMENT_FILE=continuation)
    f.recipe("designer-assignment", "concrete continuation names the accepted revision and dispositions", ACCEPTED_REVISION=abstract_revision)
    continuation_input = json.loads(continuation.read_text())
    assert abstract_revision in continuation.read_text()
    assert str(snapshot) in continuation_input.values(), "the assignment must name the exact frozen accepted plan"
    accepted_dispositions = json.loads(disposition.read_text())
    assert accepted_dispositions in continuation_input.values(), "mutable dispositions must be embedded in the bound assignment"
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
    disposition.write_text(json.dumps({"changed_after_binding": "MUTABLE-DISPOSITIONS-DRIFT-4819"}))
    retained = f.recipe("read-payload", "the accepted continuation retains dispositions despite input-file drift", REFERENCE_FILE=ref_file).stdout
    frozen_assignment = json.loads(json.loads(Path(reference["manifest_path"]).read_text())["bindings"]["assignment"])
    assert accepted_dispositions in frozen_assignment.values()
    assert b"MUTABLE-DISPOSITIONS-DRIFT-4819" not in retained
    assert str(snapshot).encode() in retained
    authored_plan(f, item, concrete=True)
    concrete_revision = json.loads(f.recipe("publish-revision", "concrete tasks publish after the accepted abstract").stdout)["revision_id"]
    assert concrete_revision != abstract_revision
    land_designer_record(f, concrete_selected, concrete_revision, "concrete")
    assert snapshot.read_bytes() != (item / "plan.md").read_bytes()
    graph = json.loads((item / "tasks.json").read_text())
    assert len(graph["tasks"]) == 1 and graph["tasks"][0]["close_criteria"]
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
        prepared = json.loads(f.recipe("review-prepare", "freeze the registered evaluator's exact stage", ATTEMPT_ID=attempt,
                                       CEREMONY=ceremony, REVISION_ID=revision, PURPOSE="criterion-adequacy", EXECUTION_WORKTREE="").stdout)
        directory = Path(prepared["prepared_path"]).parent
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
        f.recipe("awaiting-note", "one commissioned note names the revision and prepared attempt")
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
    session_before = tree_hashes(f.store / "_sessions")
    f.recipe("journal-step", "unhosted milestone invokes no session writer", STEP_ID="spec:investigation", STEP_LABEL="Investigation complete")
    assert tree_hashes(f.store / "_sessions") == session_before
    f.env.update(LORE_SESSION_INSTANCE="fixture", LORE_SESSION_SLUG="recipes", LORE_SESSION_TYPE="spec")
    for step, label in (("investigation", "Investigation complete"), ("design", "Design complete"), ("plan-ready", "Plan ready")):
        f.recipe("journal-step", "journal the durable " + step + " milestone", STEP_ID="spec:" + step, STEP_LABEL=label)
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
    parser.add_argument("--scenario", required=True, choices=("inventory", "coverage", "synthesis", "entry", "inline", "full", "native", "designer", "reviews", "finalize", "stewardship"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--prose-ref")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--inventories", type=Path, nargs="*")
    args = parser.parse_args()
    args.root = args.root.resolve()
    if args.scenario == "inventory":
        extraction_controls(args.root)
        empty = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--scenario", "unknown", "--root", str(args.root / "empty-spec")], capture_output=True)
        assert empty.returncode == 2 and b"invalid choice" in empty.stderr
        assert not (args.root / "empty-spec").exists()
    elif args.scenario in ("synthesis", "entry", "inline", "full", "native", "designer", "reviews", "finalize", "stewardship"):
        implementation = compose_source(Path(__file__).resolve().parents[2], args.root / "source", args.prose_ref)
        {"synthesis": exercise_synthesis, "entry": exercise_entry, "inline": exercise_inline, "full": exercise_full, "native": exercise_native, "designer": exercise_designer, "reviews": exercise_reviews, "finalize": exercise_finalize, "stewardship": exercise_stewardship}[args.scenario](SpecFixture(implementation, args.root / "case"))
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
