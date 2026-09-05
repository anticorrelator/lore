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
    parser.add_argument("--scenario", required=True, choices=("inventory", "coverage"))
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
    elif args.scenario == "coverage":
        assert args.source, "coverage requires the exact spec source"
        args.root.mkdir(parents=True, exist_ok=True)
        merge_coverage(args.source, args.inventories, args.root / "inventory.json")


if __name__ == "__main__":
    main()
