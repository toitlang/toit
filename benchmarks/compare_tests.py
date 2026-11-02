#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Checks that tests behave the same when they are compiled to native code.

Usage: benchmarks/compare_tests.py [--sdk <dir>] <directory>...
"""

import argparse
import concurrent.futures
import glob
import os
import subprocess
import sys
import tempfile

ARGUMENTS = ["foo", "bar", "gee"]

# These look at how they are run, or print timings. The first two
# behave the same way in executables that have bytecodes.
EXPECTED_DIFFERENCES = {
  "tests/program-name-test.toit",
  "tests/program-path-test.toit",
  "tests/rpc-test.toit",
}

def run(command):
  try:
    result = subprocess.run(command, capture_output=True, timeout=150, stdin=subprocess.DEVNULL)
    return result.returncode, result.stdout
  except subprocess.TimeoutExpired:
    return "timeout", b""

def check(toit, out, test):
  executable = os.path.join(out, test.replace("/", "_")[:-5])
  built = subprocess.run([toit, "compile", "--native", "-o", executable, test], capture_output=True)
  interpreted = run([toit, "run", "-O2", test] + ARGUMENTS)
  if built.returncode != 0:
    return (test, "skipped") if interpreted[0] != 0 else (test, "build failed")
  native = run([executable] + ARGUMENTS)
  if native == interpreted: return test, "ok"
  # Some tests print random numbers or timings.
  if native[0] == interpreted[0] and run([toit, "run", "-O2", test] + ARGUMENTS) != interpreted:
    return test, "unstable"
  return test, f"differs: exit codes {native[0]} and {interpreted[0]}"

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--sdk", default="build/host/sdk")
  parser.add_argument("directories", nargs="+")
  args = parser.parse_args()
  toit = os.path.join(args.sdk, "bin", "toit")
  tests = [t for d in args.directories for t in sorted(glob.glob(f"{d}/*-test.toit"))
           if t not in EXPECTED_DIFFERENCES]
  good = 0
  with tempfile.TemporaryDirectory() as out:
    with concurrent.futures.ThreadPoolExecutor(6) as executor:
      for test, result in executor.map(lambda t: check(toit, out, t), tests):
        if result in ("ok", "unstable", "skipped"):
          good += 1
        else:
          print(f"{test}: {result}", flush=True)
  print(f"{good}/{len(tests)} match the interpreter")
  if good != len(tests): sys.exit(1)

if __name__ == "__main__":
  main()
