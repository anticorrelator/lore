"""Probe-suite conftest.

Two directory-scoped collection concerns:

1. The live contract modules are named `probe_<harness>.py`, which does NOT match
   pytest's default `python_files` (`test_*.py`). So a whole-directory run
   (`pytest tests/probes/session_injection/`) would silently skip them. The
   `pytest_collect_file` hook below collects `probe_*.py` in this subtree as test
   modules so the directory run exercises the live contract suite (gated by
   LORE_LIVE_PROBES), alongside the always-on `test_*.py` pure-function tests.

2. The claude-code live probes share a harness session across sibling probe
   functions (P1 -> P3 -> P4 on one `shared_session`), so they must run in
   definition order. pytest-randomly (installed in this repo) otherwise shuffles
   items. `pytest_collection_modifyitems` groups items by defining module first,
   then by line number within the module — grouping by module keeps a
   module-scoped fixture from being torn down and rebuilt when the whole directory
   is collected together (which interleaving files by absolute line number would
   otherwise cause).
"""

import pytest


def pytest_collect_file(parent, file_path):
    if file_path.suffix == ".py" and file_path.name.startswith("probe_"):
        return pytest.Module.from_parent(parent, path=file_path)
    return None


def pytest_collection_modifyitems(items):
    def sort_key(item):
        try:
            module = item.function.__module__
            line = item.function.__code__.co_firstlineno
        except AttributeError:
            return ("", 0)
        return (module, line)

    items.sort(key=sort_key)
