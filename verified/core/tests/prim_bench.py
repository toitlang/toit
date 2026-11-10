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

"""Measures the Rust primitives against the C++ bridge.

For each benchmark of verified/core/tests/prim_bench.toit (and the
programs given with --program) runs the program untrusted (format 2)
under callgrind, counting only the instructions inside `toit_v2_run`
(the format-2 run loop and everything it calls: primitives, GC), once
with the C++ primitives and once with TOIT_V2_RUST_PRIMITIVES=1, and the
wall time (best of 5 inside the program) without callgrind.

Usage: prim_bench.py [--program FILE ...] [--out DIR]
"""

import argparse
import os
import re
import subprocess
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RUN = os.path.join(REPO, "build/host/sdk/lib/toit/bin/toit.run")
BENCH = os.path.join(REPO, "verified/core/tests/prim_bench.toit")
NAMES = ["map-string-keys", "string-concat-slice", "list-add", "byte-array", "large-int",
         "float", "string-compare-hash", "call-smi-add", "call-string-length", "call-array-at",
         "call-float-add", "call-blob-equals"]


def env(rust, extra=None):
  e = dict(os.environ)
  e.pop("TOIT_BYTECODE_FORMAT", None)
  e["TOIT_V2_RUST_PRIMITIVES"] = "1" if rust else "0"
  if extra: e.update(extra)
  return e


def instructions(cmd, rust, extra_env=None):
  with tempfile.TemporaryDirectory() as d:
    out = os.path.join(d, "cg.out")
    subprocess.run(["valgrind", "--tool=callgrind", "--toggle-collect=toit_v2_run",
                    "--callgrind-out-file=" + out] + cmd,
                   cwd=REPO, env=env(rust, extra_env), capture_output=True, timeout=3600)
    total = 0
    for f in os.listdir(d):
      text = open(os.path.join(d, f)).read()
      m = re.search(r"^summary: (\d+)", text, re.M) or re.search(r"^totals: (\d+)", text, re.M)
      if m: total += int(m.group(1))
    return total


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--program", action="append", default=[])
  opts = ap.parse_args()
  print("| Benchmark | C++ Ir | Rust Ir | ratio |")
  print("|---|---|---|---|")
  for name in NAMES:
    cmd = [RUN, "--untrusted", BENCH, name]
    a = instructions(cmd, False)
    b = instructions(cmd, True)
    print(f"| {name} | {a:,} | {b:,} | {b / a:.3f} |", flush=True)
  for prog in opts.program:
    cmd = [RUN, prog]
    extra = {"TOIT_BYTECODE_FORMAT": "2", "TOIT_VERIFY": "1"}
    a = instructions(cmd, False, extra)
    b = instructions(cmd, True, extra)
    print(f"| {os.path.basename(prog)} | {a:,} | {b:,} | {b / a:.3f} |", flush=True)
  print()
  for rust in (False, True):
    p = subprocess.run([RUN, "--untrusted", BENCH], cwd=REPO, env=env(rust), capture_output=True, text=True)
    print(("Rust" if rust else "C++ ") + " wall (best of 5):")
    print(p.stdout)


if __name__ == "__main__":
  main()
