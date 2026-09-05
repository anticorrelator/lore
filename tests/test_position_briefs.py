"""Document contract for the four position briefs and their report reference.

These tests check the shape readers depend on: all four positions exist, each
brief stays short, the six headings are present in order, dispatch inputs and
the sanctioned verbs are named, every path the documents cite resolves, and the
report reference carries every label a live reader matches literally. They do
not score tone or pin rhetorical sentences.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIEF_DIR = ROOT / "agents" / "positions"
CONTRACT = ROOT / "docs" / "position-report-contracts.md"
POSITIONS = ("investigator", "designer", "worker", "reviewer")
MAX_LINES = 150

HEADINGS = [
    "## What you receive",
    "## What you do",
    "## When to search further, and how to capture",
    "## When the packet is wrong",
    "## What you write back, and who reads it",
    "## Boundaries and their reasons",
]

# Headings that only exist in the long templates. A brief that carries one has
# loaded old workflow prose instead of pointing at the reference.
OLD_TEMPLATE_HEADINGS = [
    "## Scale-Aware Navigation",
    "## Reporting Guidelines",
    "## Tier 2 Evidence Emission",
    "## Investigation Lifecycle",
    "## Responding to Consultations",
    "## The Durable Report",
]

# Where each position's write-back lands; the brief must name it.
DESTINATION_TOKENS = {
    "worker": ["Report-id:", "worker-reports/<report-id>.md"],
    "investigator": ["Report-id:"],
    "designer": ["consultation-id", "work item"],
    "reviewer": ["lore plan review seal", "output.md"],
}

WORKER_HEADER_LINES = [
    "Report-schema: 1",
    "Report-id:",
    "Work-item:",
    "Task:",
    "Producer-role:",
    "Dispatch-path:",
    "Harness:",
    "Status:",
    "Template-version:",
]

WORKER_SECTION_LABELS = [
    "**Artifacts:**",
    "**Changes:**",
    "**Checks:**",
    "**Skills used:**",
    "**Observations:**",
    "**Tier 2 evidence:**",
    "**Tier 3 candidates:**",
    "**Narrative:**",
    "**Convention handling:**",
    "**Surfaced concerns:**",
    "**Investigation:**",
    "**Consultations:**",
    "**Blockers:**",
    "**Spend:**",
]

INVESTIGATOR_LABELS = [
    "**Question:**",
    "**Findings:**",
    "**Key files:**",
    "**Implications:**",
    "**Assertions:**",
    "**Observations:**",
    "**Narrative:**",
    "**Worker leads:**",
    "**Unknowns:**",
]

CONSULTATION_HEADERS = [
    "consultation-id",
    "handler: agent",
    "advisor_template_version",
    "advisor-acknowledged: true",
]

CONSULTATION_BODY = ["**Domain:**", "**Guidance:**", "**Key files:**", "**Cautions:**"]

REVIEW_LEDGER_FIELDS = [
    "outcome",
    "verdict",
    "reason",
    "judgments",
    "result_ids",
    "dispositions",
    "evaluator_template_version",
    "cited-results.json",
]

LEGACY_PRODUCER_ROLES = ["researcher", "worker", "advisor", "spec-lead", "implement-lead"]

PATH_TOKEN = re.compile(r"\b(?:agents|docs|scripts|skills|tests)/[A-Za-z0-9_./-]+")


def flat(text):
    """Whitespace-flatten so a phrase survives line wrapping."""
    return re.sub(r"\s+", " ", text)


def brief_path(position):
    return BRIEF_DIR / f"{position}.md"


def read(path):
    return path.read_text(encoding="utf-8")


def h2_headings(text):
    return [line.rstrip() for line in text.splitlines() if line.startswith("## ")]


class BriefFilesExist(unittest.TestCase):
    def test_all_four_positions_have_a_brief(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                self.assertTrue(brief_path(position).is_file(), brief_path(position))

    def test_report_reference_exists(self):
        self.assertTrue(CONTRACT.is_file(), CONTRACT)


class BriefShape(unittest.TestCase):
    def test_briefs_are_bounded(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                lines = read(brief_path(position)).splitlines()
                self.assertGreater(len(lines), 0)
                self.assertLess(len(lines), MAX_LINES, f"{position}: {len(lines)} lines")

    def test_six_headings_present_in_order_and_no_others(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                self.assertEqual(h2_headings(read(brief_path(position))), HEADINGS)

    def test_briefs_do_not_carry_old_template_sections(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                text = read(brief_path(position))
                for heading in OLD_TEMPLATE_HEADINGS:
                    self.assertNotIn(heading, text)

    def test_briefs_carry_no_template_variables(self):
        # Dispatch bindings arrive in the assignment, so the reusable bytes
        # carry no substitution slots.
        for position in POSITIONS:
            with self.subTest(position=position):
                self.assertNotIn("{{", read(brief_path(position)))

    def test_title_names_the_position(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                first = read(brief_path(position)).splitlines()[0]
                self.assertEqual(first.lower(), f"# {position}")


class BriefInputsAndVerbs(unittest.TestCase):
    def test_briefs_name_dispatch_inputs(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                text = flat(read(brief_path(position)))
                self.assertIn("Packet-id:", text)
                self.assertIn("lore packet show", text)
                self.assertIn("Revision-id:", text)
                self.assertIn("execution", text.lower())
                for token in DESTINATION_TOKENS[position]:
                    self.assertIn(token, text)

    def test_briefs_name_search_with_scale_and_caller(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                text = flat(read(brief_path(position)))
                self.assertIn("--scale-set", text)
                self.assertIn(f"--caller {position}", text)

    def test_briefs_name_the_sanctioned_verbs(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                text = flat(read(brief_path(position)))
                self.assertIn(f"--source {position}", text)
                for verb in ("lore verify", "lore criteria run", "lore capture", "lore claim"):
                    self.assertIn(verb, text)

    def test_briefs_point_at_the_report_reference(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                self.assertIn("docs/position-report-contracts.md", read(brief_path(position)))

    def test_recall_is_named_as_optional(self):
        for position in POSITIONS:
            with self.subTest(position=position):
                text = flat(read(brief_path(position))).lower()
                self.assertIn("recall", text)
                self.assertIn("optional", text)

    def test_designer_names_both_modes_and_their_legacy_roles(self):
        text = flat(read(brief_path("designer")))
        self.assertIn("Planning mode", text)
        self.assertIn("Consultation mode", text)
        self.assertIn("`spec-lead`", text)
        self.assertIn("`advisor`", text)
        for header in CONSULTATION_HEADERS:
            self.assertIn(header, text)

    def test_investigator_names_its_report_labels(self):
        text = flat(read(brief_path("investigator")))
        for label in ("Findings", "Assertions", "Worker leads", "Unknowns"):
            self.assertIn(label, text)
        self.assertIn("`researcher`", text)

    def test_worker_names_schema_one(self):
        self.assertIn("schema 1", flat(read(brief_path("worker"))))

    def test_reviewer_cites_result_ids_and_cannot_accept(self):
        text = flat(read(brief_path("reviewer")))
        self.assertIn("result ID", text)
        self.assertIn("results.jsonl", text)
        self.assertIn("accept", text)


class ReferencedPathsResolve(unittest.TestCase):
    def documents(self):
        yield CONTRACT
        for position in POSITIONS:
            yield brief_path(position)

    def test_every_cited_repo_path_exists(self):
        for doc in self.documents():
            text = read(doc)
            for token in PATH_TOKEN.findall(text):
                # A placeholder path (<report-id>) describes a shape, not a file.
                if "<" in token or token.endswith("/"):
                    continue
                with self.subTest(doc=doc.name, path=token):
                    self.assertTrue((ROOT / token).exists(), f"{doc.name} cites {token}")

    def test_every_named_script_exists(self):
        for doc in self.documents():
            text = read(doc)
            for name in set(re.findall(r"`([A-Za-z0-9_-]+\.(?:sh|py))`", text)):
                with self.subTest(doc=doc.name, script=name):
                    self.assertTrue((ROOT / "scripts" / name).is_file(), f"{doc.name} cites {name}")


class ReportReferenceLabels(unittest.TestCase):
    def setUp(self):
        self.text = read(CONTRACT)
        self.flat = flat(self.text)

    def test_worker_header_lines(self):
        for line in WORKER_HEADER_LINES:
            with self.subTest(line=line):
                self.assertIn(line, self.text)

    def test_worker_section_labels(self):
        for label in WORKER_SECTION_LABELS:
            with self.subTest(label=label):
                self.assertIn(label, self.text)

    def test_task_label_accepts_plain_and_bold(self):
        self.assertIn("`Task:`", self.text)
        self.assertIn("`**Task:**`", self.text)
        # The checker this describes still reads the plain form.
        checker = read(ROOT / "scripts" / "impl-check-report.sh")
        self.assertIn('r"^\\s*(Task):\\s*(.*)$"', checker)

    def test_convention_and_tier_values(self):
        for token in ("honored:", "diverged:", "none in scope", "`none`", '- claim: "None"'):
            with self.subTest(token=token):
                self.assertIn(token, self.text)

    def test_status_values_stay_distinct(self):
        for status in ("completed", "blocked", "degraded"):
            self.assertIn(f"`{status}`", self.text)

    def test_investigator_labels(self):
        for label in INVESTIGATOR_LABELS:
            with self.subTest(label=label):
                self.assertIn(label, self.text)

    def test_consultation_reply_contract(self):
        for token in CONSULTATION_HEADERS + CONSULTATION_BODY:
            with self.subTest(token=token):
                self.assertIn(token, self.text)

    def test_reviewer_ledger_fields(self):
        for field in REVIEW_LEDGER_FIELDS:
            with self.subTest(field=field):
                self.assertIn(field, self.text)
        self.assertIn("lore plan review seal", self.text)
        self.assertIn("lore plan review prepare", self.text)

    def test_writers_table_names_the_canonical_writers(self):
        for writer in (
            "scripts/coordinate-report.sh",
            "scripts/evidence-append.sh",
            "scripts/criteria-run.sh",
            "scripts/capture.sh",
            "scripts/verify-append.sh",
            "scripts/plan-review.sh",
        ):
            with self.subTest(writer=writer):
                self.assertIn(writer, self.text)

    def test_recall_semantics_are_explicit(self):
        self.assertIn("not a quota", self.flat)
        self.assertIn("lore capture", self.flat)
        self.assertIn("compiled-position", self.flat)

    def test_legacy_producer_mapping_matches_the_writer(self):
        section = self.text.split("## Legacy producer roles at the writer boundary", 1)[1]
        for role in LEGACY_PRODUCER_ROLES:
            with self.subTest(role=role):
                self.assertIn(f"`{role}`", section)
        for position in POSITIONS:
            with self.subTest(position=position):
                self.assertIn(f"| {position}", section)
        validator = read(ROOT / "scripts" / "validate-tier2.sh")
        self.assertIn("researcher|worker|advisor|spec-lead|implement-lead)", validator)

    def test_verify_sources_match_the_writer(self):
        verify = read(ROOT / "scripts" / "verify-append.sh")
        for position in POSITIONS:
            with self.subTest(position=position):
                self.assertIn(position, verify)
                self.assertIn(f"`{position}`", self.text)


if __name__ == "__main__":
    unittest.main()
