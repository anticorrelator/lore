#!/usr/bin/env python3
"""Compile and retain a native position definition with its reusable inputs."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

POSITIONS = ("investigator", "designer", "worker", "reviewer")
CONTRACT = "docs/position-report-contracts.md"
STAMP = "{{template_version}}"
ROOT_SLOT = "{{compiled_root}}"
REPO = Path(__file__).resolve().parent.parent


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encoded(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def run(args, *, env=None, data=None) -> bytes:
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if result.returncode:
        raise ValueError(f"{Path(args[1] if args[0] == 'bash' else args[0]).name}: "
                         f"{result.stderr.decode(errors='replace').strip() or result.stdout.decode(errors='replace').strip()}")
    return result.stdout


def helper(name, framework=None) -> str:
    args = ["bash", "-c", 'source "$1"; shift; "$@"', "position-compile", str(REPO / "scripts/lib.sh"), name]
    if framework is not None:
        args += ["agents", framework]
    return run(args).decode().strip()


def read(path: Path) -> bytes:
    data = path.read_bytes()
    if not data or b"\x00" in data:
        raise ValueError(f"empty or malformed input: {path}")
    data.decode("utf-8")
    return data


def normalize_guidance(data: bytes) -> bytes:
    if not data.startswith(b"<!-- lore-dispatch-guidance:v1:begin -->\n") or not data.endswith(b"\n<!-- lore-dispatch-guidance:v1:end -->\n"):
        raise ValueError("compiler guidance must contain only the canonical guidance block")
    text, count = re.subn(r"(?m)^=== Standing defaults in force \(rendered [^)]+\) ===$",
                          "=== Standing defaults in force (rendered <invocation>) ===", data.decode())
    if count != 1:
        raise ValueError("guidance requires exactly one defaults timestamp")
    return text.encode()


def native_prompt(native: bytes, surface: dict, position: str) -> bytes:
    if surface["format"] == "prompt":
        return native
    parts = native.split(b"---\n", 2)
    if len(parts) != 3 or parts[0]:
        raise ValueError("renderer returned malformed agent frontmatter")
    header = yaml.safe_load(parts[1])
    if not isinstance(header, dict) or not header.get("description") or "model" in header:
        raise ValueError("renderer returned invalid agent metadata")
    if "tools" in header:
        if not isinstance(header["tools"], str):
            raise ValueError("renderer returned invalid tool metadata")
        tools = {tool.strip() for tool in header["tools"].split(",")}
        if not {"Read", "Bash"} <= tools or (position != "worker" and tools & {"Write", "Edit"}):
            raise ValueError("renderer returned invalid tool scope")
    elif header.get("mode") != "subagent" or header.get("permission", {}).get("edit") != ("allow" if position == "worker" else "deny"):
        raise ValueError("renderer returned invalid agent permissions")
    return parts[2]


def validate_descriptor(descriptor: dict) -> dict:
    """Validate retained bytes before a caller binds or dispatches them."""
    supplied = dict(descriptor)
    expected_hash = supplied.pop("descriptor_sha256", None)
    path = Path(supplied["descriptor_path"])
    data = path.read_bytes()
    if expected_hash is not None and digest(data) != expected_hash:
        raise ValueError("compiled descriptor digest mismatch")
    if json.loads(data) != supplied:
        raise ValueError("compiled descriptor differs from retained descriptor")
    root = path.parent.resolve()
    for name, entry in supplied["retained_files"].items():
        target = root / name
        if target.resolve().parent != root or target.is_symlink():
            raise ValueError(f"invalid retained dependency path: {name}")
        content = target.read_bytes()
        if digest(content) != entry["sha256"] or len(content) != entry["bytes"]:
            raise ValueError(f"retained dependency mismatch: {target}")
    manifest = (root / "components.json").read_bytes()
    if digest(manifest) != supplied["component_manifest_sha256"] or digest(manifest)[:12] != supplied["template_version"]:
        raise ValueError("compiled component identity mismatch")
    for field in ("artifact_path", "prompt_path", "body_path", "guidance_path"):
        target = Path(supplied[field])
        if target.parent != root or target.name not in supplied["retained_files"]:
            raise ValueError(f"unretained descriptor reference: {field}")
    for dependency in supplied["contract_references"]:
        target = Path(dependency["path"])
        if target.parent != root or supplied["retained_files"].get(target.name, {}).get("sha256") != dependency["sha256"]:
            raise ValueError("unretained report contract reference")
    for path_field, hash_field in (("artifact_path", "artifact_sha256"), ("prompt_path", "prompt_sha256")):
        if supplied["retained_files"][Path(supplied[path_field]).name]["sha256"] != supplied[hash_field]:
            raise ValueError(f"compiled content identity mismatch: {hash_field}")
    registry = json.loads(Path(supplied["registry_path"]).read_bytes())
    entries = [entry for entry in registry["entries"] if entry["template_id"] == supplied["template_id"] and entry["template_version"] == supplied["template_version"]]
    if len(entries) != 1 or entries[0]["template_path"] != supplied["artifact_path"]:
        raise ValueError("registered template path conflicts with retained compilation")
    return supplied


def compile_position(position: str, framework: str, kdir: Path, guidance_file: Path | None) -> dict:
    if position not in POSITIONS:
        raise ValueError(f"unknown position: {position}")
    capabilities = json.loads(read(REPO / "adapters/capabilities.json"))
    profile = capabilities["frameworks"].get(framework)
    if not profile:
        raise ValueError(f"unknown framework: {framework}")
    surface = profile.get("position_compilation")
    if not surface or surface.get("format") not in ("agent-markdown", "prompt"):
        raise ValueError(f"position compilation unavailable: {framework}")
    install_dir = helper("resolve_harness_install_path", framework)
    if install_dir == "unsupported":
        raise ValueError(f"agent installation unavailable: {framework}")
    adapter = REPO / "adapters/agents" / f"{framework}.sh"
    env = dict(os.environ, LORE_FRAMEWORK=framework)
    brief = read(REPO / "agents/positions" / f"{position}.md")
    if not brief.startswith(f"# {position.title()}\n".encode()) or brief.count(b"\n## ") != 6 or b"{{" in brief:
        raise ValueError("malformed position brief")
    if CONTRACT.encode() not in brief:
        raise ValueError("brief is missing its report contract reference")
    contract = read(REPO / CONTRACT)
    if not contract.startswith(b"# Position report contracts\n"):
        raise ValueError("malformed report contract")
    guidance = read(guidance_file) if guidance_file else run(["bash", str(REPO / "scripts/render-dispatch-guidance.sh")], env=env)
    run(["bash", str(REPO / "scripts/validate-dispatch-guidance.sh")], env=env, data=guidance)
    guidance = normalize_guidance(guidance)
    # Hash reusable bytes before expanding the version and retention location.
    body = (f"Position: {position}\nTemplate-id: position/{position}/{framework}\nTemplate-version: {STAMP}\n\n".encode()
            + brief.replace(CONTRACT.encode(), f"{ROOT_SLOT}/report-contract.md".encode()))
    prompt = guidance + b"\n" + body
    components = {"brief": brief, "report-contract": contract, "guidance": guidance,
                  "surface": encoded(surface), "position": position.encode(), "framework": framework.encode()}
    for filename in ("scripts/position_compile.py", "scripts/position-compile.sh", "scripts/lib.sh",
                     "scripts/render-dispatch-guidance.sh", "scripts/validate-dispatch-guidance.sh",
                     "scripts/render-standing-defaults.sh", f"adapters/agents/{framework}.sh"):
        components[filename] = read(REPO / filename)
    with tempfile.TemporaryDirectory(prefix="position-render-") as temporary:
        source = Path(temporary) / "body.md"
        source.write_bytes(prompt)
        native = run(["bash", str(adapter), "render_position", position, str(source)], env=env)
    if native_prompt(native, surface, position) != prompt:
        raise ValueError("renderer changed or omitted the compiled prompt")
    components["native-unstamped"] = native
    manifest = encoded({"schema_version": 1, "framing": "position-components-v1",
                        "components": [{"name": name, "bytes": len(data), "sha256": digest(data)}
                                       for name, data in sorted(components.items())]})
    version = digest(manifest)[:12]
    root = kdir.resolve() / "_templates/positions" / position / framework / version
    def expand(data):
        return data.replace(STAMP.encode(), version.encode()).replace(ROOT_SLOT.encode(), str(root).encode())
    files = {"brief.md": brief, "report-contract.md": contract, "guidance.md": guidance,
             "body.md": expand(body), "prompt.md": expand(prompt), "native.md": expand(native), "components.json": manifest}
    descriptor = {
        "schema_version": 1, "position": position, "framework": framework,
        "template_id": f"position/{position}/{framework}", "template_version": version,
        "artifact_path": str(root / "native.md"), "artifact_sha256": digest(files["native.md"]),
        "prompt_path": str(root / "prompt.md"), "prompt_sha256": digest(files["prompt.md"]),
        "body_path": str(root / "body.md"), "guidance_path": str(root / "guidance.md"),
        "descriptor_path": str(root / "descriptor.json"), "component_manifest_sha256": digest(manifest),
        "components": json.loads(manifest)["components"], "native_surface": surface,
        "contract_references": [{"source": CONTRACT, "path": str(root / "report-contract.md"), "sha256": digest(contract)}],
        "retained_files": {name: {"sha256": digest(data), "bytes": len(data)} for name, data in files.items()},
        "accounting": {"body_bytes": len(files["body.md"]), "guidance_bytes": len(guidance),
                       "prompt_bytes": len(files["prompt.md"]), "native_bytes": len(files["native.md"]),
                       "on_demand_contract_bytes": len(contract)},
        "dispatch_bindings": {name: None for name in ("work_item", "task_id", "revision_id", "packet_id", "packet_pointer",
                              "dispatch_attempt_id", "assignment", "report_id", "report_path", "execution_root", "mode",
                              "consultation_id", "domain", "reply_destination")},
        "install_target": str(Path(install_dir) / f"position-{position}-{framework}.md"),
        "registry_path": str(kdir.resolve() / "_scorecards/template-registry.json"),
    }
    files["descriptor.json"] = encoded(descriptor)
    root.parent.mkdir(parents=True, exist_ok=True)
    with (root.parent / f".{version}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if root.exists():
            if {p.name for p in root.iterdir()} != set(files):
                raise ValueError(f"incomplete retained compilation: {root}")
            for name, data in files.items():
                if (root / name).is_symlink() or (root / name).read_bytes() != data:
                    raise ValueError(f"retained compilation mismatch: {root / name}")
        else:
            staging = Path(tempfile.mkdtemp(prefix=f".{version}-", dir=root.parent))
            try:
                for name, data in files.items():
                    (staging / name).write_bytes(data)
                staging.rename(root)
            finally:
                if staging.exists():
                    shutil.rmtree(staging)
        registration = json.loads(run(["bash", str(REPO / "scripts/template-registry-register.sh"),
                                       "--template-id", descriptor["template_id"], "--template-version", version,
                                       "--template-path", descriptor["artifact_path"], "--kdir", str(kdir), "--json"], env=env))
        if registration.get("status") not in ("registered", "exists"):
            raise ValueError("template registration did not succeed")
        validate_descriptor(descriptor)
    return dict(descriptor, descriptor_sha256=digest(files["descriptor.json"]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("position", choices=POSITIONS)
    parser.add_argument("--framework", required=True)
    parser.add_argument("--kdir", type=Path)
    parser.add_argument("--guidance-file", type=Path)
    args = parser.parse_args()
    try:
        kdir = args.kdir or Path(helper("resolve_knowledge_dir"))
        if not kdir.is_dir():
            raise ValueError(f"knowledge store not found: {kdir}")
        result = compile_position(args.position, args.framework, kdir, args.guidance_file)
        sys.stdout.buffer.write(encoded(result))
        return 0
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as exc:
        print(f"position compile: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
