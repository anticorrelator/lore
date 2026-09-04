"""Fixtures for the published work evidence contract, including future producers."""

import copy
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
API = runpy.run_path(str(ROOT / "scripts/work-evidence.py"))
project = API["project"]
work_view = API["work_view"]
identity_projection = API["identity_projection"]
canonical = API["canonical"]
sha256 = API["sha256"]


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value if isinstance(value, str) else json.dumps(value, indent=2) + "\n")


def ledger(path, rows):
    write(path, "".join(json.dumps(row) + "\n" for row in rows))


@pytest.fixture
def store(tmp_path):
    root = tmp_path / "store"
    item = root / "_work/example"
    write(item / "_meta.json", {"title": "Example", "status": "active", "branches": ["feature"]})
    write(item / "plan.md", "# Plan\n\nImplement both criteria.\n")
    write(item / "notes.md", "# Notes\n")
    return root, item


@pytest.fixture
def code(tmp_path):
    path = tmp_path / "code"
    path.mkdir()
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    write(path / "source.py", "answer = 42\n")
    subprocess.run(["git", "-C", str(path), "add", "."], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=Fixture", "-c", "user.email=f@example.test",
                    "commit", "-qm", "Fixture"], check=True)
    return path


def criterion(name):
    return {"id": name, "intent": "Verify " + name, "argv": ["python3", "-c", "print('ok')"],
            "cwd": ".", "timeout": 10, "expected_exit": 0}


def revision(item, revision_id, predecessor=None, criteria=None):
    tasks = {"schema_version": 1, "revision_id": revision_id, "plan_checksum": sha256((item / "plan.md").read_bytes()),
             "tasks": [{"id": "task-1", "subject": "First", "description": "Full delivered context",
                        "blockedBy": ["task-0"], "file_targets": ["source.py"],
                        "close_criteria": criteria or [criterion("one"), criterion("two")]}]}
    write(item / "tasks.json", tasks)
    base = f"revisions/{revision_id}"
    write(item / base / "plan.md", (item / "plan.md").read_text())
    write(item / base / "tasks.json", tasks)
    return {"schema_version": 1, "record_type": "revision", "revision_id": revision_id,
            "predecessor": predecessor, "plan_sha256": sha256((item / "plan.md").read_bytes()),
            "tasks_sha256": sha256((item / "tasks.json").read_bytes()), "tasks_payload_sha256": "b" * 64,
            "old_plan_sha256": None, "old_tasks_sha256": None, "source_head": "a" * 40,
            "author_role": "designer", "timestamp": "2026-09-04T20:00:00Z", "kind": "semantic",
            "reason": "Two checks cover distinct behavior", "scope_delta": "none", "changed_task_ids": ["task-1"],
            "changes": {"task": ["task-1"], "edge": [], "file": [], "constraint": [], "output_contract": [], "criterion": ["one", "two"]},
            "anchor_coverage": {"disposition": "covered", "by": "designer", "note": "Both requirements represented"},
            "review_requirement": {"disposition": "required", "by": "designer", "note": "Behavior changed", "prior_review_refs": []},
            "plan_path": base + "/plan.md", "tasks_path": base + "/tasks.json"}


def result(item, code, rid="result-1", criterion_id="one", revision_id="222222222222", state="pass"):
    output = f"results/{rid}/output.txt"
    write(item / output, "ok\n")
    source = API["code_identity"](code)
    assert source["state"] == "read"
    return {"schema_version": 1, "result_id": rid, "execution_attempt_id": rid, "dispatch_attempt_id": "dispatch-1",
            "task_id": "task-1", "criterion_id": criterion_id,
            "criterion_version": API["criterion_version"](criterion(criterion_id)), "revision_id": revision_id,
            "packet_id": "packet-2", "unbound_reason": None, "source_start": source, "source_end": source,
            "source_head": source["head"], "worktree_digest": source["digest"], "digest_version": "1",
            "argv": criterion(criterion_id)["argv"], "cwd": ".", "exit": 0, "signal": None,
            "timed_out": False, "duration_ms": 7, "output_path": output,
            "output_sha256": sha256((item / output).read_bytes()), "state": state,
            "reason": "expected-exit", "timestamp": "2026-09-04T21:00:00Z"}


@pytest.fixture
def mixed(store, code):
    root, item = store
    first = revision(item, "111111111111")
    write(item / "plan.md", "# Plan\n\nRevised implementation.\n")
    second = revision(item, "222222222222", first["revision_id"])
    decision = {"schema_version": 1, "record_type": "decision", "revision_id": second["revision_id"],
                "decision_id": "decision-1", "dispatch_decision": {"disposition": "proceed", "by": "coordinator",
                "reason": "Review can complete alongside isolated work", "task_ids": ["task-1"]}}
    ledger(item / "revisions.jsonl", [first, second, decision])
    rows = [result(item, code, "old", revision_id=first["revision_id"]),
            result(item, code, "latest"), result(item, code, "failed", "two", state="fail")]
    ledger(item / "results.jsonl", rows)
    ledger(root / "_packets/packets.jsonl", [
        {"schema_version": "1", "packet_id": "legacy", "work_item": item.name, "task_id": "task-1",
         "delivery_stage": "assembled", "delivered_entries": [{"path": "conventions/example.md", "render_mode": "full"}],
         "template_version": "a" * 12, "trust_compute_sha": "b" * 64},
        {"schema_version": "2", "packet_id": "packet-2", "work_item": item.name, "task_id": "task-1",
         "revision_id": second["revision_id"], "dispatch_attempt_id": "dispatch-1", "source_head": "a" * 40,
         "delivery_stage": "delivered", "delivered_entries": [], "empty_reason": "No relevant entries"},
        {"schema_version": "2", "packet_id": "other", "work_item": "another", "delivery_stage": "assembled"}])
    review = {"schema_version": 1, "ceremony": "spec-design", "attempt_id": "review-1",
              "revision_id": first["revision_id"], "purpose": "design", "plan_sha256": first["plan_sha256"],
              "tasks_sha256": first["tasks_sha256"], "input_path": "reviews/review-1/input.md",
              "output_path": "reviews/review-1/output.md", "disposition_path": "reviews/review-1/disposition.json"}
    write(item / "reviews/review-1/manifest.json", review)
    write(item / "reviews/review-1/input.md", "Immutable review input\n")
    write(item / "reviews/review-1/output.md", "The two criteria cover separate requirements.\n")
    write(item / "reviews/review-1/disposition.json", {"findings": [], "decision": "accepted"})
    old_outcome = {"schema_version": 1, "outcome_id": "old-outcome", "ceremony": "spec-post-plan", "outcome": "completed"}
    outcome = {"schema_version": 2, "outcome_id": "outcome-1", "ceremony": "spec-design", "attempt_id": "review-1",
               "revision_id": first["revision_id"], "outcome": "completed", "review_path": "reviews/review-1/manifest.json"}
    write(item / "execution-log.md", "## 2026-09-04T20:00:00Z | source: spec-verb\nLegacy log delivery\n" +
          "\n".join("Spec-outcome-record: " + json.dumps(row) for row in [old_outcome, outcome]) + "\n")
    write(item / "worker-reports/deep/report.md", "Report-schema: 1\nReport-id: report-1\nStatus: completed\n\nFull report body.\n")
    ledger(item / "task-claims.jsonl", [{"claim_id": "claim-1", "exact_snippet": "answer = 42", "file": "source.py"}])
    write(item / "retro-bundle.json", {"work_item": item.name, "tasks_completed": 1, "tier2_claim_ids": ["claim-1"],
          "tier3_promoted_ids": [], "advisor_consultations_count": 2, "blockers": [],
          "template_versions": {"lead": "a" * 12, "worker": "b" * 12, "advisor": None},
          "captured_at_sha": "a" * 40, "run_started_at": "2026-09-04T20:00:00Z"})
    return root, item, code


def snapshot(root):
    return {str(p.relative_to(root)): (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode)
            for p in root.rglob("*") if p.is_file()}


def test_mixed_full_content_and_versions_are_public(mixed):
    root, item, _ = mixed
    before = snapshot(root)
    view = work_view(item, root)
    assert view["reader_contract_version"] == "2"
    evidence = view["evidence"]
    assert evidence["schema_version"] == 1
    assert evidence["reader_contract_version"] == "2"
    assert evidence["revision"]["head"]["revision_id"] == "222222222222"
    assert evidence["revision"]["publication_state"] == "current"
    sources = evidence["sources"]
    assert set(sources) == {"tasks", "revisions", "results", "packets", "outcomes", "reviews", "reports", "claims", "bundle"}
    assert all(s["state"] == "read" for s in sources.values())
    assert view["tasks_content"]["tasks"][0]["description"] == "Full delivered context"
    assert view["tasks_content"]["tasks"][0]["blockedBy"] == ["task-0"]
    assert sources["revisions"]["row_count"] == 3
    assert sources["revisions"]["rows"][-1]["record_type"] == "decision"
    assert len(sources["revisions"]["snapshots"]["entries"]) == 4
    assert sources["results"]["records"][0]["freshness"]["state"] == "stale"
    assert sources["results"]["records"][1]["artifacts"][0]["content"] == "ok\n"
    summaries = {s["criterion_id"]: s for s in evidence["result_summary"]}
    assert summaries["one"]["result_id"] == "latest"
    assert summaries["one"]["freshness"] == {"state": "current", "reasons": []}
    assert summaries["two"]["state"] == "fail"
    assert [r["packet_id"] for r in sources["packets"]["rows"]] == ["legacy", "packet-2"]
    assert sources["packets"]["records"][0]["binding"]["state"] == "legacy-unbound"
    assert sources["packets"]["records"][0]["receipt"] == "unknown"
    assert sources["outcomes"]["records"][1]["binding"]["state"] == "stale"
    assert sources["reports"]["entries"][0]["declared_status"] == "completed"
    assert "Full report body" in sources["reports"]["entries"][0]["content"]
    assert sources["claims"]["row_count"] == 1
    assert sources["claims"]["rows"][0]["exact_snippet"] == "answer = 42"
    assert sources["bundle"]["format"] == "legacy-v0"
    assert sources["bundle"]["data"]["advisor_consultations_count"] == 2
    assert snapshot(root) == before


def test_missing_legacy_and_archive(store):
    root, item = store
    evidence = project(item, root)
    assert all(s["state"] == "absent" for s in evidence["sources"].values())
    assert evidence["result_summary"] == []
    assert evidence["revision"]["publication_state"] == "legacy-unbound"
    write(item / "tasks.json", {"phases": [{"tasks": [{"id": "task-1", "description": "old", "blockedBy": []}]}]})
    write(item / "worker-reports/legacy.md", "An older report without headers.\n")
    evidence = project(item, root)
    assert evidence["sources"]["reports"]["entries"][0]["declared_status"] == "unknown"
    assert evidence["sources"]["tasks"]["state"] == "read"
    archived = root / "_work/_archive/example"
    archived.parent.mkdir()
    item.rename(archived)
    assert work_view(archived, root)["archived"] is True
    assert project(archived, root)["sources"]["reports"]["path"] == "_work/_archive/example/worker-reports"


@pytest.mark.parametrize("filename,content,source,state", [
    ("tasks.json", "{", "tasks", "unreadable"),
    ("tasks.json", "[1]", "tasks", "unreadable"),
    ("tasks.json", '{"tasks":42}', "tasks", "unreadable"),
    ("tasks.json", '{"schema_version":99,"tasks":[]}', "tasks", "unsupported"),
    ("revisions.jsonl", '{"schema_version":1}\n{"torn":', "revisions", "unreadable"),
    ("revisions.jsonl", '{"schema_version":99}\n', "revisions", "unsupported"),
    ("results.jsonl", '[]\n', "results", "unreadable"),
    ("results.jsonl", '{"schema_version":99,"state":"pass"}\n', "results", "unsupported"),
    ("retro-bundle.json", '{}', "bundle", "unreadable"),
    ("retro-bundle.json", '{"schema_version":99}', "bundle", "unsupported"),
    ("worker-reports/r.md", "Report-schema: 77\nStatus: completed\n", "reports", "unsupported"),
    ("reviews/r/input.json", '{"schema_version":77}', "reviews", "unsupported"),
    ("execution-log.md", 'Spec-outcome-record: {\n', "outcomes", "unreadable"),
    ("task-claims.jsonl", 'null\n', "claims", "unreadable"),
])
def test_malformed_and_unsupported_keep_hashes(store, filename, content, source, state):
    root, item = store
    write(item / filename, content)
    observed = project(item, root)["sources"][source]
    assert observed["state"] == state
    assert observed["sha256"] is not None
    assert observed["reason"]


def test_partial_publication_and_missing_criteria(store):
    root, item = store
    head = revision(item, "111111111111")
    ledger(item / "revisions.jsonl", [head])
    data = json.loads((item / "tasks.json").read_text())
    data["revision_id"] = "000000000000"
    write(item / "tasks.json", data)
    assert project(item, root)["revision"]["publication_state"] == "incomplete"
    assert [s["state"] for s in project(item, root)["result_summary"]] == ["missing", "missing"]
    with (item / "revisions.jsonl").open("a") as f:
        f.write('{"schema_version":')
    evidence = project(item, root)
    assert evidence["revision"]["reason"] == "revision-history-unreadable"
    assert evidence["sources"]["revisions"]["rows"][0] == head


@pytest.mark.parametrize("change,reason", [
    ("code", "source-code-mismatch"),
    ("output", "output-digest-mismatch"),
    ("criterion", "criterion-version-mismatch"),
    ("during", "code-changed-during-execution"),
    ("remove-code", "code-unavailable"),
    ("remove-output", "result-output-unavailable"),
])
def test_freshness_keeps_execution_state_distinct(mixed, change, reason):
    root, item, code = mixed
    if change == "code":
        write(code / "source.py", "answer = 43\n")
    elif change == "output":
        write(item / "results/latest/output.txt", "changed\n")
    elif change == "criterion":
        data = json.loads((item / "tasks.json").read_text())
        data["tasks"][0]["close_criteria"][0]["expected_exit"] = 2
        write(item / "tasks.json", data)
    elif change == "during":
        rows = [json.loads(line) for line in (item / "results.jsonl").read_text().splitlines()]
        rows[1]["source_start"] = {**rows[1]["source_start"], "digest": "0" * 64}
        ledger(item / "results.jsonl", rows)
    elif change == "remove-code":
        code.rename(code.with_name("removed-code"))
    elif change == "remove-output":
        (item / "results/latest/output.txt").unlink()
    summary = project(item, root)["result_summary"][0]
    assert summary["state"] == "pass"
    assert reason in summary["freshness"]["reasons"]
    assert summary["freshness"]["state"] == ("unknown" if change.startswith("remove-") else "stale")


def test_code_digest_includes_staging_untracked_modes_and_symlinks(code):
    initial = API["code_identity"](code)
    write(code / "untracked", "new\n")
    assert API["code_identity"](code)["digest"] != initial["digest"]
    (code / "untracked").unlink()
    assert API["code_identity"](code)["digest"] == initial["digest"]
    (code / "source.py").chmod(0o755)
    assert API["code_identity"](code)["digest"] != initial["digest"]
    (code / "source.py").chmod(0o644)
    write(code / "source.py", "staged\n")
    subprocess.run(["git", "-C", str(code), "add", "source.py"], check=True)
    write(code / "source.py", "answer = 42\n")
    assert API["code_identity"](code)["digest"] != initial["digest"]
    subprocess.run(["git", "-C", str(code), "reset", "--quiet", "HEAD"], check=True)
    (code / "link").symlink_to("source.py")
    link_digest = API["code_identity"](code)["digest"]
    (code / "link").unlink()
    (code / "link").symlink_to("different.py")
    assert API["code_identity"](code)["digest"] != link_digest


@pytest.mark.parametrize("source", ["tasks", "report", "review", "packet", "output", "bundle", "outcome", "log"])
def test_substantive_changes_alter_public_identity(mixed, source):
    root, item, _ = mixed
    before = canonical(identity_projection(work_view(item, root)))
    target = {"tasks": item / "tasks.json", "report": item / "worker-reports/deep/report.md",
              "review": item / "reviews/review-1/disposition.json", "packet": root / "_packets/packets.jsonl",
              "output": item / "results/latest/output.txt", "bundle": item / "retro-bundle.json",
              "outcome": item / "execution-log.md", "log": item / "execution-log.md"}[source]
    if source == "packet":
        rows = [json.loads(line) for line in target.read_text().splitlines()]
        rows[1]["revision_id"] = "111111111111"
        ledger(target, rows)
    elif source in {"outcome", "log"}:
        with target.open("a") as f:
            f.write("Spec-outcome-record: {}\n" if source == "outcome" else "Ordinary new evidence.\n")
    else:
        with target.open("a") as f:
            f.write(" \n")
    assert canonical(identity_projection(work_view(item, root))) != before


@pytest.mark.parametrize("existing", [False, True])
def test_prepare_completion_exclusion_uses_unchanged_log_writer(store, existing):
    root, item = store
    if existing:
        write(item / "execution-log.md", "# Historical log\n\n## 2026-09-01T00:00:00Z | source: manual\nOrdinary evidence.\n\n")
    before = identity_projection(work_view(item, root))
    command = ["bash", str(ROOT / "scripts/write-execution-log.sh"), "--slug", item.name, "--source", "manual"]
    env = {**os.environ, "LORE_KNOWLEDGE_DIR": str(root)}
    subprocess.run(command, input='Retro-prepare-atom: {"pack_id":"fixture"}\n', text=True,
                   cwd=ROOT, env=env, check=True, capture_output=True)
    after = identity_projection(work_view(item, root))
    assert after == before
    assert "Retro-prepare-atom" in work_view(item, root)["exec_log_content"]
    write(item / "retro-evidence-pack.json", {"schema_version": 1, "pack_id": "fixture"})
    write(item / "retro-filing.json", {"schema_version": 1})
    assert identity_projection(work_view(item, root)) == before


def test_public_cli_and_archive_match_helper(mixed):
    root, item, _ = mixed
    env = {**os.environ, "LORE_KNOWLEDGE_DIR": str(root)}
    args = ["bash", str(ROOT / "scripts/load-work-item.sh"), item.name, "--json"]
    completed = subprocess.run(args, check=True, capture_output=True, text=True, cwd=ROOT, env=env)
    assert json.loads(completed.stdout) == work_view(item, root)
    archive = root / "_work/_archive" / item.name
    archive.parent.mkdir()
    item.rename(archive)
    completed = subprocess.run(args, check=True, capture_output=True, text=True, cwd=ROOT, env=env)
    assert json.loads(completed.stdout) == work_view(archive, root)
    assert all(a["state"] == "read" for r in project(archive, root)["sources"]["results"]["records"] for a in r["artifacts"])


def test_escaping_references_and_binary_outputs_remain_explicit(store, tmp_path):
    root, item = store
    outside = tmp_path / "secret"
    write(outside, "must not be read")
    (item / "tasks.json").symlink_to(outside)
    assert project(item, root)["sources"]["tasks"]["reason"] == "reference-outside-store"
    row = {"output_path": "../../../../secret", "input_path": str(outside)}
    refs = API["references"](row, item, root)
    assert all(r["state"] == "unreadable" and r["content"] is None for r in refs)
    output = item / "results/binary/output"
    output.parent.mkdir(parents=True)
    output.write_bytes(b"\xff\x00")
    source = API["read_file"](output, root)
    assert source["state"] == "read"
    assert source["content_base64"] == "/wA="


def test_malformed_metadata_keeps_public_reader_error(store):
    root, item = store
    write(item / "_meta.json", "{malformed")
    completed = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/work-evidence.py"),
                                "--item-dir", str(item), "--knowledge-dir", str(root), "--work"],
                               capture_output=True, text=True)
    assert completed.returncode == 1
    assert "error" in json.loads(completed.stdout)
    assert project(item, root)["reader_contract_version"] == "2"


@pytest.mark.parametrize("field,value", [("result_id", None), ("state", "green"), ("state", []),
                                        ("criterion_id", []), ("source_end", {}),
                                        ("source_end", {"worktree": {}}), ("exit", None)])
def test_malformed_attributable_result_never_appears_current(mixed, field, value):
    root, item, _ = mixed
    rows = [json.loads(line) for line in (item / "results.jsonl").read_text().splitlines()]
    rows[1][field] = value
    ledger(item / "results.jsonl", rows)
    evidence = project(item, root)
    assert evidence["sources"]["results"]["state"] == "unreadable"
    assert evidence["sources"]["results"]["rows"][1][field] == value
    assert all(s["freshness"]["state"] != "current" for s in evidence["result_summary"])


def test_revised_packet_cannot_claim_unbound_escape(mixed):
    root, item, _ = mixed
    ledger(root / "_packets/packets.jsonl", [{"schema_version": "2", "packet_id": "bad", "work_item": item.name,
           "task_id": "task-1", "unbound_reason": "not supplied"}])
    packets = project(item, root)["sources"]["packets"]
    assert packets["state"] == "unreadable"
    assert packets["records"][0]["binding"]["state"] == "invalid"


@pytest.mark.parametrize("mutation", ["predecessor", "collision", "snapshot"])
def test_revision_chain_and_snapshot_gaps_are_incomplete(mixed, mutation):
    root, item, _ = mixed
    rows = [json.loads(line) for line in (item / "revisions.jsonl").read_text().splitlines()]
    if mutation == "predecessor":
        rows[1]["predecessor"] = "000000000000"
        ledger(item / "revisions.jsonl", rows)
    elif mutation == "collision":
        rows.append({**rows[1], "reason": "Conflicting duplicate"})
        ledger(item / "revisions.jsonl", rows)
    else:
        (item / rows[1]["tasks_path"]).unlink()
    evidence = project(item, root)
    assert evidence["revision"]["publication_state"] == "incomplete"
    assert all(s["freshness"]["state"] != "current" for s in evidence["result_summary"])
