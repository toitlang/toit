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

"""Measures the effect of the format revision on executed instructions and
code size, over the tests that run_suite.py found runnable in both
formats (run it with --format both --json first).

Prints the total steps per format, the opcodes whose counts change most,
and the bytecode size of each format.

Usage: measure.py <suite.json> [--out DIR]
"""

import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys

CRATE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(CRATE, "target/release/toit-spec-run")


def histogram(dump):
  p = subprocess.run([RUNNER, "--histogram", "--max-steps", "200000000", dump, "--", "foo", "bar", "gee"],
                     capture_output=True, timeout=600)
  h = collections.Counter()
  for line in p.stderr.decode().split("\n"):
    m = re.match(r"\[histogram\] (\S+) (\d+)", line)
    if m: h[m.group(1)] += int(m.group(2))
  return h


def code_size(dump):
  with open(dump) as f:
    for line in f:
      if line.startswith("bytecodes "):
        return int(line.split()[1])
  return 0


def method_count(dump):
  with open(dump) as f:
    for line in f:
      if line.startswith("methods "):
        return int(line.split()[1])
  return 0


def main():
  results = json.load(open(sys.argv[1]))
  out = os.path.join(CRATE, "target/suite")
  by = collections.defaultdict(dict)
  for r in results:
    by[r["test"]][r["format"]] = r["status"]
  tests = sorted(t for t, f in by.items() if f.get(1) == "pass" and f.get(2) == "pass")
  dumps = {}
  for t in tests:
    name = t.replace("/", "_")[:-5]
    dumps[t] = (os.path.join(out, "f1", name + ".dump"), os.path.join(out, "f2", name + ".dump"))
  totals = [collections.Counter(), collections.Counter()]
  sizes = [0, 0]
  with concurrent.futures.ThreadPoolExecutor(16) as ex:
    futures = {}
    for t, (d1, d2) in dumps.items():
      futures[ex.submit(histogram, d1)] = (t, 0)
      futures[ex.submit(histogram, d2)] = (t, 1)
    for fut in concurrent.futures.as_completed(futures):
      t, i = futures[fut]
      totals[i].update(fut.result())
  methods = [0, 0]
  for t, (d1, d2) in dumps.items():
    sizes[0] += code_size(d1)
    sizes[1] += code_size(d2)
    methods[0] += method_count(d1)
    methods[1] += method_count(d2)
  s1 = sum(totals[0].values())
  s2 = sum(totals[1].values())
  print("tests: %d" % len(tests))
  print("steps: format 1 %d, format 2 %d (%+.1f%%)" % (s1, s2, 100.0 * (s2 - s1) / s1))
  print("bytecodes (sum over tests, incl. headers): format 1 %d, format 2 %d (%+.1f%%)"
        % (sizes[0], sizes[1], 100.0 * (sizes[1] - sizes[0]) / sizes[0]))
  bodies = [sizes[0] - 4 * methods[0], sizes[1] - 16 * methods[1] - 4 * len(tests)]
  print("method bodies only: format 1 %d, format 2 %d (%+.1f%%); headers: %d -> %d bytes"
        % (bodies[0], bodies[1], 100.0 * (bodies[1] - bodies[0]) / bodies[0], 4 * methods[0], 16 * methods[1]))
  groups = [
    ("checked field loads", ["LOAD_FIELD", "LOAD_FIELD_WIDE", "LOAD_FIELD_LOCAL", "POP_LOAD_FIELD_LOCAL"]),
    ("unchecked field loads (this)", ["LOAD_FIELD_THIS"]),
    ("checked field stores", ["STORE_FIELD", "STORE_FIELD_WIDE", "STORE_FIELD_POP"]),
    ("unchecked field stores (this)", ["STORE_FIELD_THIS"]),
    ("try/finally setup", ["LINK", "UNLINK", "TRY"]),
    ("intrinsics", ["INTRINSIC_SMI_REPEAT", "INTRINSIC_ARRAY_DO", "INTRINSIC_HASH_FIND", "INTRINSIC_HASH_DO"]),
    ("block calls", ["INVOKE_BLOCK"]),
    ("static calls", ["INVOKE_STATIC", "INVOKE_STATIC_TAIL"]),
    ("returns", ["RETURN", "RETURN_NULL"]),
  ]
  print("opcode groups (format 1 -> format 2):")
  for name, ops in groups:
    print("  %-30s %12d %12d" % (name, sum(totals[0][o] for o in ops), sum(totals[1][o] for o in ops)))
  names = set(totals[0]) | set(totals[1])
  diffs = sorted(names, key=lambda n: -abs(totals[1][n] - totals[0][n]))
  print("largest changes in executed opcodes (format 1 -> format 2):")
  for n in diffs[:25]:
    print("  %-26s %12d %12d %+12d" % (n, totals[0][n], totals[1][n], totals[1][n] - totals[0][n]))


if __name__ == "__main__":
  main()
