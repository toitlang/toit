#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

"""Runs the programs the reference interpreter can run untrusted in format 2.

verified/spec/tests/run_suite.py classifies every test of the suite; a
format-2 test whose status is `pass` or `steplimit` uses only primitives the
reference interpreter implements (the allowed set). Each of them runs

  * in format 1, trusted, on the C++ interpreter (`toit.run test`), and
  * in format 2, as an untrusted container on the verified core
    (`toit.run --untrusted test`, which compiles to format 2),

like ctest runs them (from the repository root, arguments `foo bar gee`,
TOIT_TEST_ENV_ENTRY set). Stdout and the exit code must be identical.

Usage: untrusted_suite.py [--jobs N] [--status FILE] [--filter S] [--out DIR]
"""

import argparse
import concurrent.futures
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RUN = os.path.join(REPO, "build/host/sdk/lib/toit/bin/toit.run")
STATUS = os.path.join(REPO, "verified/spec/tests/suite-status.txt")
ARGS = ["foo", "bar", "gee"]


def env(**extra):
  e = dict(os.environ, TOIT_TEST_ENV_ENTRY="TOIT_TEST_ENV_VALUE")
  e.pop("TOIT_BYTECODE_FORMAT", None)
  e.update(extra)
  return e


def run(cmd, e, timeout=300):
  try:
    p = subprocess.run(cmd, cwd=REPO, env=e, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr
  except subprocess.TimeoutExpired as x:
    return "timeout", x.stdout or b"", x.stderr or b""


def one(test):
  rc1, out1, err1 = run([RUN, test] + ARGS, env())
  rc2, out2, err2 = run([RUN, "--untrusted", test] + ARGS, env())
  same = rc1 == rc2 and out1 == out2
  return test, same, rc1, rc2, out1, out2, err2


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--jobs", type=int, default=8)
  ap.add_argument("--status", default=STATUS)
  ap.add_argument("--filter", default=None)
  ap.add_argument("--out", default=os.path.join(REPO, "build/untrusted-suite"))
  opts = ap.parse_args()
  tests = {}
  for line in open(opts.status):
    if line.startswith("#"): continue
    parts = line.split(None, 3)
    if parts[0] != "2": continue
    tests[parts[2]] = parts[1]
  selected = sorted(t for t, s in tests.items() if s in ("pass", "steplimit"))
  if opts.filter: selected = [t for t in selected if opts.filter in t]
  os.makedirs(opts.out, exist_ok=True)
  results = []
  with concurrent.futures.ThreadPoolExecutor(opts.jobs) as pool:
    for test, same, rc1, rc2, out1, out2, err2 in pool.map(one, selected):
      results.append({"test": test, "status": tests[test], "same": same, "rc1": rc1, "rc2": rc2})
      if not same:
        base = os.path.join(opts.out, test.replace("/", "_"))
        open(base + ".f1.out", "wb").write(out1)
        open(base + ".f2.out", "wb").write(out2)
        open(base + ".f2.err", "wb").write(err2)
        print(f"DIFF {test} (exit {rc1} vs {rc2})", flush=True)
  counts = {
    "selected": len(selected),
    "identical": sum(1 for r in results if r["same"]),
    "different": [r["test"] for r in results if not r["same"]],
    "excluded": {s: sum(1 for t, x in tests.items() if x == s) for s in sorted(set(tests.values())) if s not in ("pass", "steplimit")},
  }
  json.dump({"summary": counts, "results": results}, open(os.path.join(opts.out, "results.json"), "w"), indent=2)
  print(json.dumps(counts, indent=2))
  return 0 if not counts["different"] else 1


if __name__ == "__main__":
  sys.exit(main())
