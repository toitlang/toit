#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Runs generated programs as bytecodes and as native code and compares them.

Usage: benchmarks/fuzz/run.py [--sdk <dir>] <first-seed> <last-seed>
"""

import argparse
import collections
import concurrent.futures
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen import G

def check(toit, out, seed):
  source = f"{out}/s{seed}.toit"
  executable = f"{out}/s{seed}"
  with open(source, "w") as file: file.write(G(seed).program(4))
  try:
    interpreted = subprocess.run([toit, "run", "-O0", source], capture_output=True, timeout=60)
    built = subprocess.run([toit, "compile", "--native", "-o", executable, source], capture_output=True, timeout=400)
    if built.returncode != 0: return seed, "invalid" if interpreted.returncode != 0 else "build failed"
    native = subprocess.run([executable], capture_output=True, timeout=60)
  except subprocess.TimeoutExpired:
    return seed, "timeout"
  same = native.returncode == interpreted.returncode and native.stdout == interpreted.stdout
  return seed, "ok" if same else "differs"

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--sdk", default="build/host/sdk")
  parser.add_argument("first", type=int)
  parser.add_argument("last", type=int)
  args = parser.parse_args()
  toit = os.path.abspath(os.path.join(args.sdk, "bin", "toit"))
  with tempfile.TemporaryDirectory() as out:
    with concurrent.futures.ThreadPoolExecutor(6) as executor:
      results = list(executor.map(lambda seed: check(toit, out, seed), range(args.first, args.last)))
  print(dict(collections.Counter(result for _, result in results)))
  for seed, result in results:
    if result not in ("ok", "invalid"): print(seed, result)

if __name__ == "__main__":
  main()
