#!/usr/bin/env python3
"""Validate and freeze a retrospective rubric independently of protocol prose.

`descriptor [path]` emits the declaration, exact UTF-8 text, full byte hash,
and 12-hex version. Store the entire result as evidence-pack `rubric`.
`validate-frozen path` checks that descriptor without reading today's rubric.
"""

import argparse
import hashlib
import json
from pathlib import Path
import sys


DIMENSION_KEYS = (
    "d1_delivery", "d2_quality", "d3_gaps", "d4_alignment",
    "d5_spec_utility", "d6_packet_utility",
)
DEFAULT_RUBRIC = Path(__file__).resolve().parent.parent / "skills/retro/rubric.json"


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def validate_declaration(rubric):
    if not isinstance(rubric, dict) or set(rubric) != {"rubric_id", "dimensions"}:
        raise ValueError("rubric must declare exactly rubric_id and dimensions")
    if rubric["rubric_id"] != "retro-rubric":
        raise ValueError("rubric_id must be retro-rubric")
    dimensions = rubric["dimensions"]
    if not isinstance(dimensions, list) or len(dimensions) != 6:
        raise ValueError("rubric dimensions must be ordered exactly D1-D6")
    for i, (dimension, key) in enumerate(zip(dimensions, DIMENSION_KEYS), 1):
        fields = {"dimension_id", "journal_key", "name", "anchors", "allow_not_assessable"}
        if not isinstance(dimension, dict) or set(dimension) != fields:
            raise ValueError(f"D{i} has invalid declaration fields")
        if dimension["dimension_id"] != f"D{i}" or dimension["journal_key"] != key:
            raise ValueError(f"D{i} must have its unique ordered ID and journal key {key}")
        if not nonempty(dimension["name"]):
            raise ValueError(f"D{i} name must be nonempty")
        anchors = dimension["anchors"]
        if (not isinstance(anchors, dict) or set(anchors) != set("12345")
                or not all(nonempty(v) for v in anchors.values())):
            raise ValueError(f"D{i} requires nonempty anchors 1 through 5")
        if dimension["allow_not_assessable"] is not (i == 6):
            raise ValueError("only D6 allows not-assessable")
    return rubric


def describe_bytes(data):
    text = data.decode("utf-8")
    rubric = validate_declaration(json.loads(text))
    digest = hashlib.sha256(data).hexdigest()
    return dict(rubric, rubric_version=digest[:12], rubric_sha256=digest, rubric_text=text)


def load_rubric(path=DEFAULT_RUBRIC):
    return describe_bytes(Path(path).read_bytes())


def validate_frozen(descriptor):
    if not isinstance(descriptor, dict) or not isinstance(descriptor.get("rubric_text"), str):
        raise ValueError("frozen rubric requires exact rubric_text")
    expected = describe_bytes(descriptor["rubric_text"].encode("utf-8"))
    if descriptor != expected:
        raise ValueError("frozen rubric declaration or byte identity mismatch")
    return descriptor


def validate_judgments(dimensions, descriptor, validate_refs):
    """Validate v2 dimension judgments; the caller resolves refs against its pack."""
    validate_frozen(descriptor)
    if not isinstance(dimensions, list) or len(dimensions) != 6:
        raise ValueError("dimension_judgments must contain exactly D1-D6")
    for i, (judgment, dimension) in enumerate(zip(dimensions, descriptor["dimensions"])):
        where = f"dimension_judgments[{i}]"
        fields = {"dimension_id", "disposition", "score", "rationale", "evidence_refs"}
        if not isinstance(judgment, dict):
            raise ValueError(f"{where} must be an object")
        abstained = judgment.get("disposition") == "not-assessable"
        if abstained:
            fields.add("reason")
        if set(judgment) != fields or judgment["dimension_id"] != dimension["dimension_id"]:
            raise ValueError(f"{where} has invalid fields or dimension order")
        if abstained:
            if (not dimension["allow_not_assessable"] or judgment["score"] is not None
                    or not nonempty(judgment["reason"])):
                raise ValueError(f"{where} abstention requires eligible dimension, null score and reason")
        elif (judgment["disposition"] != "scored" or type(judgment["score"]) is not int
              or not 1 <= judgment["score"] <= 5):
            raise ValueError(f"{where} requires disposition scored and integer score 1..5")
        if not nonempty(judgment["rationale"]):
            raise ValueError(f"{where}.rationale must be nonempty")
        validate_refs(judgment["evidence_refs"], where)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("descriptor", "validate-frozen"))
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    try:
        if args.command == "descriptor":
            descriptor = load_rubric(args.path or DEFAULT_RUBRIC)
        else:
            if not args.path:
                parser.error("validate-frozen requires a descriptor path")
            descriptor = validate_frozen(json.loads(Path(args.path).read_text(encoding="utf-8")))
        print(json.dumps(descriptor, ensure_ascii=False))
    except (OSError, ValueError, TypeError) as exc:
        parser.exit(1, f"Invalid rubric: {exc}\n")


if __name__ == "__main__":
    main()
