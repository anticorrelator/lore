#!/usr/bin/env python3
"""Run independent Bats suites concurrently and preserve every exit status."""

from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import re
import subprocess
import sys


def suite_runs(path):
    if Path(path).resolve() != Path(__file__).with_name("test_position_dispatch.bats").resolve():
        return [(path, ["bats", path])]
    # These cases each create their own checkout, HOME, and store. Scheduling
    # them separately avoids serializing every expensive position matrix.
    names = re.findall(r'^@test "([^"\\]*)" \{$', Path(path).read_text(), re.MULTILINE)
    count = subprocess.run(["bats", "--count", path], check=True, capture_output=True, text=True)
    if not names or len(set(names)) != len(names) or int(count.stdout.strip()) != len(names):
        raise ValueError("position test discovery did not account for every Bats case")
    runs = []
    for name in names:
        pattern = "^" + re.sub(r'([.\\+*?\[\]^$(){}|])', r'\\\1', name) + "$"
        argv = ["bats", "--filter", pattern, path]
        selected = subprocess.run(argv[:1] + ["--count"] + argv[1:], check=True,
                                  capture_output=True, text=True)
        if selected.stdout.strip() != "1":
            raise ValueError(f"position filter did not select exactly one case: {name}")
        runs.append((f"{path}: {name}", argv))
    return runs


def run_suite(run):
    label, argv = run
    result = subprocess.run(argv, capture_output=True)
    return label, result


def main(paths):
    if not paths:
        print("usage: run_bats_suites.py <suite.bats> ...", file=sys.stderr)
        return 2
    runs = [run for path in paths for run in suite_runs(path)]
    failed = False
    with ThreadPoolExecutor(max_workers=min(4, len(runs))) as pool:
        pending = [pool.submit(run_suite, run) for run in runs]
        for completed in as_completed(pending):
            path, result = completed.result()
            print(f"Suite: {path} (exit {result.returncode})", flush=True)
            sys.stdout.buffer.write(result.stdout)
            sys.stdout.buffer.flush()
            sys.stderr.buffer.write(result.stderr)
            sys.stderr.buffer.flush()
            failed |= result.returncode != 0
    return int(failed)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
