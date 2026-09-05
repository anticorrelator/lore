import importlib.util
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("implement_recipes", ROOT / "tests/helpers/implement_recipes.py")
recipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipes)


def fake_go(tmp_path, version):
    go = tmp_path / "toolchain/go"
    go.parent.mkdir(exist_ok=True)
    go.write_text("#!/bin/sh\nprintf '%s\\n' '" + version + "'\n")
    go.chmod(0o755)
    return go


def test_disposable_home_keeps_toolchain_and_caches_outside(tmp_path, monkeypatch):
    go = fake_go(tmp_path, "go1.99.0")
    monkeypatch.setenv("LORE_TEST_GO", str(go))
    case = tmp_path / "case"
    home = case / "home"
    home.mkdir(parents=True)
    env = recipes.isolated_go_environment(ROOT, case, {"HOME": str(home), "PATH": os.environ["PATH"]})
    assert env["GOTOOLCHAIN"] == "local"
    assert env["PATH"].split(os.pathsep)[0] == str(go.parent)
    for key in ("GOMODCACHE", "GOCACHE"):
        assert not Path(env[key]).is_relative_to(case)
    assert list(home.iterdir()) == []


def test_incompatible_installed_toolchain_refuses_download(tmp_path, monkeypatch):
    monkeypatch.setenv("LORE_TEST_GO", str(fake_go(tmp_path, "go1.20.0")))
    with pytest.raises(RuntimeError, match="need installed Go >="):
        recipes.isolated_go_environment(ROOT, tmp_path / "case", {"PATH": os.environ["PATH"]})
