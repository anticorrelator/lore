"""Portability guards: lore runs on a stock python3 >= 3.9 with nothing pip-installed.

macOS's Command Line Tools ship Python 3.9 at /usr/bin/python3, and Homebrew
and Debian/Ubuntu Pythons refuse `pip install` (PEP 668). So shipped Python
must (a) avoid 3.10+ runtime features and (b) import only the standard
library, lore's own modules, and what lore vendors under scripts/vendor.

The static checks run everywhere. The 3.9 import smoke runs when a 3.9
interpreter exists (every Mac has one). The jsonschema parity check runs when
jsonschema happens to be installed. It is the reference lore_schema must match.
"""

from __future__ import annotations

import ast
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"
sys.path.insert(0, str(SCRIPTS))

import lore_schema  # noqa: E402

FLOOR = (3, 9)


# --------------------------------------------------------------------------
# Sources: every shipped .py file and every Python heredoc in shell scripts.
# --------------------------------------------------------------------------

def _shipped_py_files():
    for base in ("scripts", "adapters", "cli"):
        for path in sorted((REPO / base).rglob("*.py")):
            if "__pycache__" in path.parts or "vendor" in path.relative_to(REPO).parts:
                continue
            yield path


def _shell_files():
    seen = set()
    for pattern in ("scripts/**/*.sh", "adapters/**/*.sh"):
        for path in REPO.glob(pattern):
            if "vendor" not in path.relative_to(REPO).parts:
                seen.add(path)
    seen.update({REPO / "cli" / "lore", REPO / "install.sh"})
    return sorted(seen)


_OPENER = re.compile(r"""(?<!<)<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1(?!<)""")


def _python_heredocs():
    """Yield (label, source, launch_line) for each heredoc that holds Python.

    A heredoc is Python when its tag names it (PY, PYEOF, PYTHON, ...) or the
    command that receives it is `python3 -` / `python3 <<`. Commands continued
    with backslashes are joined, so multi-line launches are included.
    """
    for path in _shell_files():
        lines = path.read_text(encoding="utf-8").split("\n")
        i = 0
        while i < len(lines):
            line = lines[i]
            match = None if line.lstrip().startswith("#") else _OPENER.search(line)
            if not match:
                i += 1
                continue
            tag = match.group(2)
            start, logical = i, line
            while start > 0 and lines[start - 1].rstrip().endswith("\\"):
                start -= 1
                logical = lines[start] + " " + logical
            end = i + 1
            while end < len(lines) and lines[end].strip() != tag:
                end += 1
            launcher = logical.split("<<")[0]
            if "PY" in tag.upper() or re.search(r"python3?\s+-(\s|$|\")", launcher) \
                    or re.search(r"python3?\s*$", launcher.strip()):
                label = f"{path.relative_to(REPO)}:{i + 1}"
                yield label, textwrap.dedent("\n".join(lines[i + 1:end])), logical
            i = end + 1


def _all_sources():
    for path in _shipped_py_files():
        yield str(path.relative_to(REPO)), path.read_text(encoding="utf-8"), ""
    yield from _python_heredocs()


def test_heredoc_discovery_finds_the_embedded_python():
    # Guards the extractor itself: lore embeds hundreds of Python heredocs.
    # If this collapses, the floor checks below silently stop covering them.
    assert sum(1 for _ in _python_heredocs()) > 200


# --------------------------------------------------------------------------
# Python 3.9 floor
# --------------------------------------------------------------------------

def _guarded_by_import_error(node, parents):
    """True when node sits in a try whose handlers catch ImportError."""
    current = node
    while current in parents:
        parent = parents[current]
        if isinstance(parent, ast.Try) and current in parent.body:
            for handler in parent.handlers:
                names = []
                if handler.type is None:
                    return True
                for t in (handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]):
                    names.append(getattr(t, "id", getattr(t, "attr", "")))
                if {"ImportError", "ModuleNotFoundError", "Exception"} & set(names):
                    return True
        current = parent
    return False


def _floor_violations(source: str):
    tree = ast.parse(source, feature_version=FLOOR)
    parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
    lazy_annotations = any(
        isinstance(n, ast.ImportFrom) and n.module == "__future__"
        and any(a.name == "annotations" for a in n.names)
        for n in tree.body
    )
    found = []

    def union(expr):
        return any(isinstance(s, ast.BinOp) and isinstance(s.op, ast.BitOr) for s in ast.walk(expr))

    for node in ast.walk(tree):
        line = getattr(node, "lineno", 0)
        if not lazy_annotations:
            annotations = []
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                args = node.args.posonlyargs + node.args.args + node.args.kwonlyargs
                args += [a for a in (node.args.vararg, node.args.kwarg) if a]
                annotations = [a.annotation for a in args if a.annotation]
                annotations += [node.returns] if node.returns else []
            elif isinstance(node, ast.AnnAssign):
                annotations = [node.annotation]
            if any(union(a) for a in annotations):
                found.append(f"line {line}: `X | Y` annotation needs `from __future__ import annotations` on 3.9")
        if isinstance(node, ast.Call):
            name = node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
            if name in ("isinstance", "issubclass") and len(node.args) == 2 and union(node.args[1]):
                found.append(f"line {line}: {name}() with `X | Y` is 3.10+")
            if name == "zip" and any(k.arg == "strict" for k in node.keywords):
                found.append(f"line {line}: zip(strict=) is 3.10+")
            if name == "dataclass" and any(k.arg in ("slots", "kw_only") for k in node.keywords):
                found.append(f"line {line}: dataclass(slots=/kw_only=) is 3.10+")
        if isinstance(node, (ast.Import, ast.ImportFrom)) and not _guarded_by_import_error(node, parents):
            modules = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module or ""]
            names = [a.name for a in node.names]
            if "tomllib" in modules:
                found.append(f"line {line}: tomllib is 3.11+; guard it with try/except ImportError")
            if isinstance(node, ast.ImportFrom) and node.module == "datetime" and "UTC" in names:
                found.append(f"line {line}: datetime.UTC is 3.11+; use timezone.utc")
            if isinstance(node, ast.ImportFrom) and node.module == "enum" and "StrEnum" in names:
                found.append(f"line {line}: enum.StrEnum is 3.11+")
            if isinstance(node, ast.ImportFrom) and node.module == "itertools" and "pairwise" in names:
                found.append(f"line {line}: itertools.pairwise is 3.10+")
        if isinstance(node, ast.Attribute) and node.attr == "UTC" \
                and isinstance(node.value, ast.Name) and node.value.id == "datetime":
            found.append(f"line {line}: datetime.UTC is 3.11+; use timezone.utc")
    return found


def test_shipped_python_runs_on_the_3_9_floor():
    problems = []
    for label, source, _ in _all_sources():
        try:
            for issue in _floor_violations(source):
                problems.append(f"{label} {issue}")
        except SyntaxError as exc:
            problems.append(f"{label}: does not parse as Python 3.9: {exc.msg} (line {exc.lineno})")
    assert not problems, "\n".join(problems)


# --------------------------------------------------------------------------
# No pip installs: stdlib, lore's own modules, and scripts/vendor only
# --------------------------------------------------------------------------

def _local_module_names():
    names = {"adapters", "scripts"}  # repo-root packages imported via sys.path
    for base in ("scripts", "adapters", "cli"):
        for path in (REPO / base).rglob("*.py"):
            names.add(path.stem)
    names.update(p.name for p in (SCRIPTS / "vendor").iterdir() if p.is_dir())
    return names


@pytest.mark.skipif(sys.version_info < (3, 10), reason="needs sys.stdlib_module_names")
def test_shipped_python_imports_nothing_from_pip():
    stdlib = set(sys.stdlib_module_names)
    local = _local_module_names()
    vendored = {p.name for p in (SCRIPTS / "vendor").iterdir() if p.is_dir()}
    problems = []
    for label, source, launch in _all_sources():
        tree = ast.parse(source)
        parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                modules = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                modules = [node.module]
            else:
                continue
            for module in modules:
                top = module.split(".")[0]
                if top in stdlib or top == "__future__":
                    continue
                if top in vendored:
                    # The vendor directory has to be on the path where it is imported.
                    if "vendor" not in source and "vendor" not in launch:
                        problems.append(f"{label} line {node.lineno}: imports {top} without putting scripts/vendor on the path")
                    continue
                if top in local:
                    continue
                if _guarded_by_import_error(node, parents) or _inside_function_after_check(node, parents):
                    continue
                problems.append(f"{label} line {node.lineno}: imports third-party {top!r}; vendor it or use the stdlib")
    assert not problems, "\n".join(problems)


def _inside_function_after_check(node, parents):
    # pk_semantic loads sentence_transformers lazily inside a function that
    # checks for it first: an opt-in extra, never needed for lore to work.
    current = node
    while current in parents:
        current = parents[current]
        if isinstance(current, (ast.FunctionDef, ast.AsyncFunctionDef)):
            return True
    return False


# --------------------------------------------------------------------------
# Actually running under 3.9, when this machine has one
# --------------------------------------------------------------------------

def _python39():
    for candidate in ("python3.9", "/usr/bin/python3"):
        exe = shutil.which(candidate) if not candidate.startswith("/") else candidate
        if not exe or not os.access(exe, os.X_OK):
            continue
        try:
            out = subprocess.run([exe, "-c", "import sys; print(sys.version_info[:2])"],
                                 capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if out.returncode == 0 and out.stdout.strip() == "(3, 9)":
            return exe
    return None


@pytest.mark.skipif(_python39() is None, reason="no Python 3.9 interpreter on this machine")
def test_every_library_module_imports_under_python_3_9_without_pip_packages():
    modules = sorted(p.stem for p in SCRIPTS.glob("*.py") if re.fullmatch(r"[A-Za-z_]\w*", p.stem))
    probe = textwrap.dedent("""
        import importlib, sys
        failures = []
        for name in sys.argv[1:]:
            try:
                importlib.import_module(name)
            except BaseException as exc:
                failures.append(f"{name}: {type(exc).__name__}: {exc}")
        import yaml
        if "vendor" not in yaml.__file__:
            failures.append(f"yaml resolved outside scripts/vendor: {yaml.__file__}")
        print("\\n".join(failures))
        sys.exit(1 if failures else 0)
    """)
    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    python39 = _python39()
    assert python39 is not None
    result = subprocess.run([python39, "-c", probe, *modules], cwd=SCRIPTS, env=env,
                            capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
    assert result.returncode == 0, result.stdout + result.stderr


# --------------------------------------------------------------------------
# lore_schema: the stdlib stand-in for jsonschema
# --------------------------------------------------------------------------

SCHEMA = json.loads((REPO / "adapters" / "settings.schema.json").read_text(encoding="utf-8"))
TEMPLATE = json.loads((REPO / "adapters" / "settings.template.json").read_text(encoding="utf-8"))

# The template plus every optional branch it leaves empty: object-form routes
# (each oneOf arm), ceremony overlays, a vault, a standing decision, and a
# capability override, so mutation reaches every $defs entry.
RICH = copy.deepcopy(TEMPLATE)
RICH["routes"]["worker"] = {"framework": "codex", "model": "gpt-5.5", "effort": "high", "service_tier": "fast"}
RICH["routes"]["reviewer"] = {"framework": "opencode", "model": "anthropic/opus"}
RICH["routes"]["advisor"] = {"framework": "claude-code", "model": "opus"}
RICH["routes"]["ceremony_overlays"] = {"spec": {"lead": "claude-code/opus"}, "implement": {"worker": "codex/gpt-5.5"}}
RICH["capability_overrides"] = {"mcp": "partial"}
RICH["obsidian"] = {"vaults": {"github.com/example/repo": {"enabled": True, "vault_path": "/tmp/vault"}}}
RICH["standing_decisions"] = {"modal_answers": {"trust-folder": {
    "enabled": True, "framework": "claude-code",
    "signature": {"kind": "numbered-modal-v1", "title": "Trust this folder?",
                  "options": [{"number": 1, "label": "Yes"}, {"number": 2, "label": "No"}]},
    "answer": {"option": 1, "expect": "Yes"}, "registered_by": "user",
    "registered_at": "2026-10-04T00:00:00Z", "rationale": "always trust repos I clone"}}}


def test_settings_template_and_rich_fixture_validate():
    lore_schema.validate(TEMPLATE, SCHEMA)
    lore_schema.validate(RICH, SCHEMA)


def test_settings_schema_uses_only_implemented_keywords():
    # Construction walks the whole schema and refuses unknown keywords.
    lore_schema._Validator(SCHEMA)


def test_unimplemented_keyword_is_refused_not_skipped():
    with pytest.raises(lore_schema.SchemaError, match="dependentRequired"):
        lore_schema.validate({}, {"type": "object", "dependentRequired": {"a": ["b"]}})


@pytest.mark.parametrize("instance,schema,valid", [
    (True, {"type": "integer"}, False),          # booleans are not numbers
    (1.0, {"type": "integer"}, True),            # 1.0 is an integer in JSON Schema
    (True, {"enum": [1]}, False),
    (1, {"const": 1.0}, True),
    ({"a": 1}, {"additionalProperties": False, "properties": {"b": {}}}, False),
    ({"a": 1}, {"additionalProperties": {"type": "string"}}, False),
    ("ab", {"pattern": "^a"}, True),
    ("", {"minLength": 1}, False),
    (5, {"oneOf": [{"minimum": 1}, {"maximum": 10}]}, False),  # both match
    ([1, 1], {"uniqueItems": True}, False),
])
def test_lore_schema_keyword_semantics(instance, schema, valid):
    assert lore_schema.is_valid(instance, schema) is valid


def test_cli_reports_the_failing_path(tmp_path):
    bad = copy.deepcopy(TEMPLATE)
    bad["routes"]["default"] = "gpt"
    doc = tmp_path / "settings.json"
    doc.write_text(json.dumps(bad))
    result = subprocess.run([sys.executable, str(SCRIPTS / "lore_schema.py"),
                             str(REPO / "adapters" / "settings.schema.json"), str(doc)],
                            capture_output=True, text=True)
    assert result.returncode == 1
    assert result.stdout.startswith("validation failed at routes/default:")


_REPLACEMENTS = [None, 0, -1, 1, 1.5, 2.0, 10 ** 9, "", "x", "claude-code/opus", "codex/gpt",
                 True, False, [], ["x"], [1], {}, {"x": 1}]


def _mutants(doc):
    """The document with each value replaced, each object's keys dropped one at
    a time, an unknown key added to each object, and each absent root
    property added with each replacement value."""
    def walk(node, path=()):
        yield path, node
        if isinstance(node, dict):
            for k, v in node.items():
                yield from walk(v, path + (k,))
        elif isinstance(node, list):
            for i, v in enumerate(node):
                yield from walk(v, path + (i,))

    def put(path, value):
        out = copy.deepcopy(doc)
        if not path:
            return value
        cur = out
        for p in path[:-1]:
            cur = cur[p]
        cur[path[-1]] = value
        return out

    for path, value in list(walk(doc)):
        for replacement in _REPLACEMENTS:
            yield put(path, replacement)
        if isinstance(value, dict):
            yield put(path, {**value, "__unknown__": 1})
            for key in value:
                yield put(path, {k: v for k, v in value.items() if k != key})
    for key in SCHEMA["properties"]:
        if key not in doc:
            for replacement in _REPLACEMENTS:
                yield {**doc, key: replacement}


def test_lore_schema_matches_jsonschema_on_settings_mutants():
    jsonschema = pytest.importorskip("jsonschema")
    reference = jsonschema.Draft202012Validator(SCHEMA)
    disagreements, total = [], 0
    for instance in [TEMPLATE, RICH, *_mutants(TEMPLATE), *_mutants(RICH)]:
        total += 1
        ours, theirs = lore_schema.is_valid(instance, SCHEMA), reference.is_valid(instance)
        if ours != theirs:
            disagreements.append((ours, theirs, json.dumps(instance)[:200]))
    assert total > 1000
    assert not disagreements, disagreements[:5]


# --------------------------------------------------------------------------
# Vendored PyYAML
# --------------------------------------------------------------------------

def test_vendored_yaml_matches_its_provenance_note():
    readme = (SCRIPTS / "vendor" / "README.md").read_text(encoding="utf-8")
    init = (SCRIPTS / "vendor" / "yaml" / "__init__.py").read_text(encoding="utf-8")
    match = re.search(r"__version__ = '([^']+)'", init)
    assert match is not None
    assert f"| {match.group(1)} |" in readme
    assert (SCRIPTS / "vendor" / "yaml" / "LICENSE").is_file()
