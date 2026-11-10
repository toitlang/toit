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

"""Differential test of the Rust primitives (verified/core/src/prims)
against the C++ ones.

Runs tests/fuzz/primitive-diff.toit untrusted (format 2, on the verified
core) for each seed twice, with the C++ primitives and with
TOIT_V2_RUST_PRIMITIVES=1, and compares the checksum lines (one per 10,000
calls). On a difference it reruns the first differing window with a trace
and prints the first differing call.

Usage: prim_diff.py [--seeds N] [--first S] [--iterations K] [--jobs J]
"""

import argparse
import concurrent.futures
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
RUN = os.path.join(REPO, "build/host/sdk/lib/toit/bin/toit.run")
DRIVER = os.path.join(REPO, "tests/fuzz/primitive-diff.toit")


def run(seed, iterations, rust, extra=()):
  env = dict(os.environ)
  env.pop("TOIT_BYTECODE_FORMAT", None)
  env["TOIT_V2_RUST_PRIMITIVES"] = "1" if rust else "0"
  p = subprocess.run([RUN, "--untrusted", DRIVER, str(seed), str(iterations)] + list(extra),
                     cwd=REPO, env=env, capture_output=True, text=True, timeout=3600)
  return p.returncode, p.stdout, p.stderr


def one(seed, iterations):
  rc1, out1, err1 = run(seed, iterations, False)
  rc2, out2, err2 = run(seed, iterations, True)
  if rc1 == rc2 and out1 == out2 and rc1 == 0:
    return seed, True, None
  l1, l2 = out1.splitlines(), out2.splitlines()
  window = 0
  for a, b in zip(l1, l2):
    if a != b: break
    if a.startswith("checksum "): window = int(a.split()[1])
  _, t1, _ = run(seed, iterations, False, [str(window), str(window + 10_000)])
  _, t2, _ = run(seed, iterations, True, [str(window), str(window + 10_000)])
  detail = f"exit {rc1} vs {rc2}; stderr: {err1[-300:]!r} / {err2[-300:]!r}"
  for a, b in zip(t1.splitlines(), t2.splitlines()):
    if a != b:
      detail = f"C++ : {a[:400]}\nRust: {b[:400]}"
      break
  return seed, False, detail


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--seeds", type=int, default=10)
  ap.add_argument("--first", type=int, default=1)
  ap.add_argument("--iterations", type=int, default=1_000_000)
  ap.add_argument("--jobs", type=int, default=8)
  opts = ap.parse_args()
  seeds = range(opts.first, opts.first + opts.seeds)
  failures = 0
  with concurrent.futures.ThreadPoolExecutor(opts.jobs) as pool:
    for seed, same, detail in pool.map(lambda s: one(s, opts.iterations), seeds):
      if same:
        print(f"seed {seed}: identical ({opts.iterations} calls)", flush=True)
      else:
        failures += 1
        print(f"seed {seed}: DIFFERENT\n{detail}", flush=True)
  total = opts.seeds * opts.iterations
  print(f"{opts.seeds - failures}/{opts.seeds} seeds identical, {total} calls per run")
  return 1 if failures else 0


if __name__ == "__main__":
  sys.exit(main())
