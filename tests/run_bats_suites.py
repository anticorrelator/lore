#!/usr/bin/env python3
"""Run independent Bats suites concurrently and preserve every exit status."""

from concurrent.futures import ThreadPoolExecutor
import subprocess
import sys


def run_suite(path):
    result = subprocess.run(["bats", path], capture_output=True)
    return path, result


def main(paths):
    if not paths:
        print("usage: run_bats_suites.py <suite.bats> ...", file=sys.stderr)
        return 2
    failed = False
    with ThreadPoolExecutor(max_workers=min(4, len(paths))) as pool:
        for path, result in pool.map(run_suite, paths):
            print(f"Suite: {path} (exit {result.returncode})", flush=True)
            sys.stdout.buffer.write(result.stdout)
            sys.stdout.buffer.flush()
            sys.stderr.buffer.write(result.stderr)
            sys.stderr.buffer.flush()
            failed |= result.returncode != 0
    return int(failed)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
