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

"""Attributes the executed instructions of a program to the methods that
execute them, in both formats, and prints the methods whose counts differ
most. Used for format note 16 (where the instructions that replace the
intrinsics go).

With several pairs of dumps it sums the counts and also groups them by the
intrinsic whose replacement executes them: HASH_FIND (the Toit body of
`find-body_`), HASH_DO (`hash-do_` and the loops of `Map.do`, `Set.do` and
their reverse forms and skip helpers, which iterate themselves when
`hash-do_` returns early), ARRAY_DO (`do_` of the arrays) and SMI_REPEAT
(`SmallInteger_.repeat`).

Usage: method_steps.py [--top N] <f1.dump> <f2.dump> [<f1.dump> <f2.dump>...]
                       [-- args...]
"""

import collections
import subprocess
import sys

import os
CRATE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(CRATE, "target/release/toit-spec-run")


def methods(dump):
  """Sorted (entry, end, name) of the methods in a dump: the body of the
  method whose header is at `id` ends where the next header starts."""
  ms = []
  size = 0
  with open(dump) as f:
    for line in f:
      parts = line.rstrip("\n").split(" ")
      if parts[0] == "bytecodes":
        size = int(parts[1])
      elif parts[0] == "m":
        ms.append((int(parts[1]), int(parts[2]), parts[4] if len(parts) > 4 else "?"))
      elif parts[0] == "dispatch":
        break
  ms.sort()
  result = []
  for i, (id, body, name) in enumerate(ms):
    end = ms[i + 1][0] if i + 1 < len(ms) else size
    result.append((end - body, end, name))
  return result


def steps_by_method(dump, args):
  ms = methods(dump)
  entries = [m[0] for m in ms]
  import bisect
  counts = collections.Counter()
  p = subprocess.Popen([RUNNER, "--trace-bci", "--max-steps", "400000000", dump, "--"] + args,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
  by_bci = collections.Counter()
  for line in p.stderr:
    if line.startswith("B "):
      by_bci[int(line.split(" ", 2)[1])] += 1
  p.wait()
  for bci, n in by_bci.items():
    i = bisect.bisect_right(entries, bci) - 1
    name = ms[i][2] if i >= 0 and bci < ms[i][1] else "?"
    counts[name] += n
  return counts


def main():
  argv = sys.argv[1:]
  args = ["foo", "bar", "gee"]
  if "--" in argv:
    args = argv[argv.index("--") + 1:]
    argv = argv[:argv.index("--")]
  top = 15
  if "--top" in argv:
    top = int(argv[argv.index("--top") + 1])
    del argv[argv.index("--top"):argv.index("--top") + 2]
  c1 = collections.Counter()
  c2 = collections.Counter()
  for i in range(0, len(argv), 2):
    c1.update(steps_by_method(argv[i], args))
    c2.update(steps_by_method(argv[i + 1], args))
  t1, t2 = sum(c1.values()), sum(c2.values())
  print("total: format 1 %d, format 2 %d (%+d)" % (t1, t2, t2 - t1))
  names = set(c1) | set(c2)
  for n in sorted(names, key=lambda n: -abs(c2[n] - c1[n]))[:top]:
    print("  %-60s %10d %10d %+10d" % (n[:60], c1[n], c2[n], c2[n] - c1[n]))
  groups = collections.Counter()
  for n in names:
    g = category(n)
    groups[g, 1] += c1[n]
    groups[g, 2] += c2[n]
  print("by intrinsic (format 1, format 2, difference, share of the total difference):")
  for g in ["HASH_FIND", "HASH_DO", "ARRAY_DO", "SMI_REPEAT", "other"]:
    d = groups[g, 2] - groups[g, 1]
    print("  %-12s %10d %10d %+10d %6.1f%%" % (g, groups[g, 1], groups[g, 2], d, 100.0 * d / max(1, t2 - t1)))


def category(name):
  if name.endswith(".find-body_"): return "HASH_FIND"
  if name.endswith(".hash-do_") or name.endswith(".skip_") or name == "Tombstone_.skip": return "HASH_DO"
  if name in ("Map.do", "Map.reverse-do", "Set.do", "Set.reverse-do"): return "HASH_DO"
  if name.endswith("Array_.do_"): return "ARRAY_DO"
  if name == "SmallInteger_.repeat": return "SMI_REPEAT"
  return "other"


if __name__ == "__main__":
  main()
