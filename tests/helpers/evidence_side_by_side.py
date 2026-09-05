"""Build and inspect retained evidence using the production writers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

SLUG = "mixed-evidence"
ANCHOR = "Keep legacy reports and immutable execution evidence readable together."


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


class Fixture:
    def __init__(self, repo, root):
        self.repo, self.root = Path(repo).resolve(), Path(root).resolve()
        self.store = self.root / "store"
        self.item = self.store / "_work" / SLUG
        self.code = self.root / "execution"
        self.env = dict(os.environ, LORE_KNOWLEDGE_DIR=str(self.store),
                        LORE_DATA_DIR=str(self.root / "runtime"), PYTHONDONTWRITEBYTECODE="1")
        for key in ("LORE_CRITERIA_FAIL_AT", "LORE_PLAN_REVISE_FAIL_AT", "LORE_PLAN_REVIEW_FAIL_AT"):
            self.env.pop(key, None)

    def run(self, argv, expected=0):
        proc = subprocess.run(list(map(str, argv)), cwd=self.repo, env=self.env, capture_output=True, text=True)
        if proc.returncode != expected:
            raise AssertionError(f"{argv}: exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        return proc.stdout

    def script(self, name, *args):
        return self.run(["bash", self.repo / "scripts" / name, *args])

    def export(self, name, value):
        (self.root / name).write_text(value)
        return json.loads(value)

    def packet(self, name, revision=None):
        row = dict(packet_id=name, packet_scope="task", delivery_stage="assembled", session_id="mixed-session",
                   work_item=SLUG, phase=1, task_id="task-1", arm=None, task_scale_set="subsystem,implementation",
                   delivered_entries=[], empty_reason="Isolated integration fixture has no knowledge entries.",
                   budget={"chars_used": 0, "chars_budget": 8000})
        if revision:
            row.update(revision_id=revision["revision_id"], dispatch_attempt_id="dispatch-" + name,
                       source_head=revision["source_head"])
        self.script("packet-append.sh", "--row", json.dumps(row), "--kdir", self.store)

    def plan(self, expected):
        check = [{"id": "content-check", "intent": "The source file has the expected content.",
                  "argv": ["python3", "-B", "-c", f"from pathlib import Path; s=Path('source.txt').read_text(); print(s,end=''); assert s == {expected!r}"],
                  "cwd": ".", "timeout": 10, "expected_exit": 0}]
        integration = [{"id": "integration-suites", "intent": "Real runner, legacy report acceptance, and retrospective reader suites pass.",
                        "argv": ["env", "UV_CACHE_DIR=/private/tmp/lore-uv-cache", "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1", "uv", "run", "--no-project", "--python", "/opt/homebrew/bin/python3", "--with", "pyyaml", "--with", "pytest", "bats", "tests/test_criteria_run.bats", "tests/frameworks/impl_check_report.bats", "tests/frameworks/retro_prepare.bats"],
                        "cwd": ".", "timeout": 600, "expected_exit": 0}]
        (self.item / "plan.md").write_text(f"""# Mixed evidence

## Intent Anchor
{ANCHOR}

**Scope delta:** none

## Tasks

**Merge rationale:** Exercise the same reader contract across old and new evidence.

### Task 1: Validate source content
**Deliverable:** Immutable source-content result.
**Files:** `source.txt`
**Close criteria:**
```json
{json.dumps(check)}
```
- [ ] Validate source content [class: mechanical]

### Task 2: Validate composed integration
**Deliverable:** Real regression results for the composed implementation.
**Files:** `tests/test_criteria_run.bats`, `tests/frameworks/retro_prepare.bats`
**Close criteria:**
```json
{json.dumps(integration)}
```
- [ ] Validate composed integration [class: mechanical] [depends-on: task-1]
""")

    def build(self):
        self.root.mkdir(parents=True, exist_ok=True)
        self.store.mkdir(parents=True, exist_ok=True)
        assert not self.item.exists(), "Use a fresh fixture root; retained evidence is never overwritten."
        (self.root / "runtime").mkdir()
        (self.root / "runtime" / "scripts").symlink_to(self.repo / "scripts", target_is_directory=True)
        self.script("create-work.sh", "--title", "Mixed evidence", "--slug", SLUG, "--intent-anchor", ANCHOR, "--json")
        self.run(["git", "init", "-q", self.code])
        (self.code / "source.txt").write_text("revision N\n")
        self.run(["git", "-C", self.code, "add", "."])
        self.run(["git", "-C", self.code, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "Fixture source"])
        reports = self.item / "worker-reports"
        reports.mkdir()
        write_json(self.item / "tasks.json", {"tasks": [{"id": "task-1", "subject": "Legacy report acceptance", "consultations_required": []}]})
        legacy = reports / "legacy.md"
        legacy.write_text("Report-id: legacy\nStatus: completed\n**Task:** Legacy report acceptance\n**Changes:**\n- Retained legacy evidence.\n**Tier 2 evidence:** none\n**Convention handling:** none in scope\n**Surfaced concerns:** None\n")
        self.export("legacy-acceptance.json", self.script("impl-check-report.sh", SLUG, "--task", "task-1", "--report", legacy, "--json"))
        (self.root / "legacy-execution-log.md").write_bytes((self.item / "execution-log.md").read_bytes())
        self.packet("legacy-packet")
        write_json(self.item / "retro-bundle.json", dict(work_item=SLUG, tasks_completed=1, tier2_claim_ids=[], tier3_promoted_ids=[], advisor_consultations_count=0, blockers=[], template_versions={}, captured_at_sha=self.run(["git", "rev-parse", "HEAD"]).strip(), run_started_at="2026-09-04T00:00:00Z"))
        self.plan("revision N\n")
        decisions = self.root / "decisions.json"
        write_json(decisions, {"anchor_coverage": {"disposition": "covered", "by": "designer", "note": "Exercises legacy and immutable evidence together."}, "review_requirement": {"disposition": "required", "by": "designer", "note": "Review the actual joined artifacts."}, "dispatch_decision": {"disposition": "proceed", "by": "coordinator", "note": "Gather evidence for the review.", "task_ids": ["task-1", "task-2"], "prior_review_refs": []}})
        self.script("plan-revise.sh", SLUG, "--decisions", decisions)
        revision_n = json.loads((self.item / "revisions.jsonl").read_text().splitlines()[-1])
        self.packet("packet-n", revision_n)
        old = self.export("run-n.json", self.script("criteria-run.sh", SLUG, "task-1", "content-check", "--execution-worktree", self.code, "--packet-id", "packet-n", "--json"))["result"]
        old_bytes = (self.item / "results.jsonl").read_bytes()
        old_output = (self.item / old["output_path"]).read_bytes()
        self.plan("revision N+1\n")
        self.script("plan-revise.sh", SLUG, "--decisions", decisions)
        revision_next = json.loads((self.item / "revisions.jsonl").read_text().splitlines()[-1])
        assert revision_next["revision_id"] != revision_n["revision_id"]
        (self.code / "source.txt").write_text("revision N+1\n")
        self.packet("packet-next", revision_next)
        new = self.export("run-next.json", self.script("criteria-run.sh", SLUG, "task-1", "content-check", "--execution-worktree", self.code, "--packet-id", "packet-next", "--json"))["result"]
        assert (self.item / "results.jsonl").read_bytes().startswith(old_bytes)
        assert (self.item / old["output_path"]).read_bytes() == old_output
        self.script("plan-review.sh", "prepare", SLUG, "--attempt-id", "fixture-review", "--revision", revision_next["revision_id"], "--ceremony", "spec-post-plan", "--purpose", "integration", "--execution-worktree", self.code)
        (self.root / "review.md").write_text("The fixture demonstrates the joined evidence. Its content checks establish source attribution; composed implementation adequacy remains for the independent integration review.\n")
        write_json(self.root / "judgments.json", {"schema_version": 1, "outcome": "completed", "verdict": "PASS", "reason": None, "judgments": [{"purpose": purpose, "judgment": "fixture-consistent", "rationale": "The fixture content and retained output agree; implementation adequacy requires the separate integration-suites result.", "result_ids": [old["result_id"], new["result_id"]]} for purpose in ("criterion-adequacy", "integration")], "dispositions": [{"finding": "Fixture joins", "disposition": "accepted", "reason": "Actual immutable results are cited."}]})
        write_json(self.root / "evaluator.json", {"evaluator_locator": "fixture://mixed-evidence", "evaluator_template_version": "123456789abc", "framework": "codex", "model": "fixture", "final_round": 1})
        sealed = json.loads(self.script("plan-review.sh", "seal", SLUG, "--attempt-id", "fixture-review", "--output", self.root / "review.md", "--dispositions", self.root / "judgments.json", "--evaluator-manifest", self.root / "evaluator.json"))
        write_json(self.root / "manifest.json", sealed["evidence_manifest"])
        self.script("spec-outcome.sh", SLUG, "--ceremony", "spec-post-plan", "--advisor", "fixture", "--attempt-id", "fixture-review", "--outcome", "completed", "--verdict", "PASS", "--evidence-manifest", self.root / "manifest.json", "--json")
        self.refresh()
        self.script("archive-work.sh", SLUG, "--json")
        archived = self.export("archived-work.json", self.script("load-work-item.sh", SLUG, "--json"))
        assert [r["result_id"] for r in archived["evidence"]["sources"]["results"]["rows"]] == [old["result_id"], new["result_id"]]
        assert archived["evidence"]["review_summary"][0]["state"] == "sealed"
        self.script("unarchive-work.sh", SLUG, "--json")
        self.refresh()
        index = {"schema_version": 1, "slug": SLUG, "root": str(self.root), "store": str(self.store), "item": str(self.item), "execution_worktree": str(self.code), "source_checkout": str(self.repo), "revision_n": revision_n["revision_id"], "revision_next": revision_next["revision_id"], "result_ids": [old["result_id"], new["result_id"]], "packet_ids": ["legacy-packet", "packet-n", "packet-next"], "review_attempt": "fixture-review", "integration_task": "task-2", "integration_criterion": "integration-suites"}
        write_json(self.root / "artifact-index.json", index)
        self.update_index()
        self.verify()
        print(json.dumps(index))

    def refresh(self):
        self.script("retro-prepare.sh", SLUG, "--window-start", "2026-01-01T00:00:00Z", "--window-end", "2027-01-01T00:00:00Z", "--json")
        (self.root / "retro-pack.json").write_bytes((self.item / "retro-evidence-pack.json").read_bytes())
        self.export("work.json", self.script("load-work-item.sh", SLUG, "--json"))
        self.export("coordinator.json", self.script("coordinate-status.sh", "--json"))
        if (self.root / "artifact-index.json").exists():
            self.update_index()

    def update_index(self):
        path = self.root / "artifact-index.json"
        index = json.loads(path.read_text())
        rows = [json.loads(line) for line in (self.item / "results.jsonl").read_text().splitlines()]
        index["result_ids"] = [row["result_id"] for row in rows]
        index["results"] = [{key: row.get(key) for key in ("result_id", "execution_attempt_id", "dispatch_attempt_id", "packet_id", "task_id", "criterion_id", "criterion_version", "revision_id", "source_head", "source_start", "source_end", "argv", "cwd", "output_path", "output_sha256", "state")} for row in rows]
        index["review_attempts"] = sorted(p.name for p in (self.item / "reviews").iterdir() if p.is_dir())
        index["artifacts"] = [{"path": str(self.root / name), "sha256": hashlib.sha256((self.root / name).read_bytes()).hexdigest()}
                              for name in ("work.json", "retro-pack.json", "coordinator.json", "archived-work.json", "legacy-acceptance.json", "tui-test-output.txt") if (self.root / name).exists()]
        write_json(path, index)

    def verify(self):
        work = json.loads((self.root / "work.json").read_text())
        evidence = work["evidence"]
        rows = evidence["sources"]["results"]["rows"]
        assert len(rows) >= 2
        assert evidence["sources"]["results"]["state"] == "read"
        assert evidence["sources"]["results"]["records"][0]["freshness"]["state"] == "stale"
        for row in rows:
            assert row["state"] == "pass"
            body = (self.item / row["output_path"]).read_bytes()
            assert hashlib.sha256(body).hexdigest() == row["output_sha256"]
        assert evidence["sources"]["results"]["records"][1]["freshness"]["state"] == "current"
        assert rows[0]["criterion_version"] != rows[1]["criterion_version"]
        assert rows[0]["source_head"] == rows[1]["source_head"]
        assert rows[0]["source_start"]["digest"] != rows[1]["source_start"]["digest"]
        assert rows[0]["packet_id"] == "packet-n" and rows[1]["packet_id"] == "packet-next"
        packets = {row["packet_id"]: row for row in evidence["sources"]["packets"]["rows"]}
        for result in rows[:2]:
            packet = packets[result["packet_id"]]
            assert all(result[key] == packet[key] for key in ("task_id", "revision_id", "dispatch_attempt_id"))
        tasks = evidence["sources"]["tasks"]["data"]["tasks"]
        assert "integration-suites" in tasks[1]["description"]
        assert "tests/test_criteria_run.bats" in tasks[1]["description"]
        baseline = self.root / "legacy-execution-log.md"
        if baseline.exists():
            assert (self.item / "execution-log.md").read_bytes().startswith(baseline.read_bytes())
        assert rows[0]["dispatch_attempt_id"] != rows[0]["execution_attempt_id"]
        assert evidence["packet_summary"][0]["binding"]["state"] == "legacy-unbound"
        assert evidence["sources"]["reports"]["entries"][0]["content"].find("Legacy report acceptance") >= 0
        assert evidence["sources"]["bundle"]["format"] == "legacy-v0"
        assert "impl-verb" in json.dumps(work)
        pack = json.loads((self.root / "retro-pack.json").read_text())
        assert pack["source_data"]["cycle_work"]["evidence"]["result_summary"] == evidence["result_summary"]
        assert "Legacy report acceptance" in json.dumps(pack)
        def find(value):
            if isinstance(value, dict):
                if value.get("slug") == SLUG and "result_summary" in value:
                    return value
                for child in value.values():
                    found = find(child)
                    if found is not None:
                        return found
            elif isinstance(value, list):
                for child in value:
                    found = find(child)
                    if found is not None:
                        return found
        status = find(json.loads((self.root / "coordinator.json").read_text()))
        assert status is not None
        assert status["result_summary"] == evidence["result_summary"]
        assert status["review_summary"] == evidence["review_summary"]
        frozen = json.loads((self.item / "reviews/fixture-review/sealed/cited-results.json").read_text())
        assert set(frozen["result_ids"]) == {r["result_id"] for r in rows[:2]}
        for cited in frozen["results"]:
            assert cited["artifacts"][0]["content"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("build", "refresh", "verify"))
    parser.add_argument("repo")
    parser.add_argument("root")
    args = parser.parse_args()
    getattr(Fixture(args.repo, args.root), args.mode)()
