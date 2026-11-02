#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Compares native executables to interpreted ones.

Usage: benchmarks/run.py [--sdk <dir>] [--save <file>] [--compare <file>] [<name>...]
"""

import argparse
import glob
import json
import os
import subprocess
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

def run(path, repeats):
  best = None
  output = None
  for _ in range(repeats):
    start = time.time()
    try:
      result = subprocess.run([path], capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
      return None, b"timeout"
    if result.returncode != 0:
      return None, result.stdout[-200:] + result.stderr[-300:]
    elapsed = time.time() - start
    best = elapsed if best is None else min(best, elapsed)
    output = result.stdout
  return best, output

def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--sdk", default="build/host/sdk")
  parser.add_argument("--save")
  parser.add_argument("--compare")
  parser.add_argument("names", nargs="*")
  args = parser.parse_args()
  toit = os.path.join(args.sdk, "bin", "toit")
  previous = json.load(open(args.compare)) if args.compare else {}
  names = args.names or sorted(os.path.basename(p)[:-5] for p in glob.glob(HERE + "/*.toit"))
  results = {}
  with tempfile.TemporaryDirectory() as out:
    print(f"{'':14}{'interp':>9}{'native':>9}{'speed-up':>10}")
    for name in names:
      source = f"{HERE}/{name}.toit"
      native = f"{out}/{name}-native"
      interpreted = f"{out}/{name}-interpreted"
      subprocess.run([toit, "compile", "--native", "-o", native, source], check=True)
      subprocess.run([toit, "compile", "-O2", "-o", interpreted, source], check=True)
      interpreted_time, interpreted_output = run(interpreted, 2)
      native_time, native_output = run(native, 3)
      if interpreted_time is None or native_time is None:
        print(f"{name:14}FAILED {native_output or interpreted_output}")
        continue
      results[name] = {"i": interpreted_time, "n": native_time}
      line = f"{name:14}{interpreted_time * 1000:7.0f}ms{native_time * 1000:7.0f}ms{interpreted_time / native_time:9.2f}x"
      if name in previous: line += f"  {100 * (previous[name]['n'] / native_time - 1):+.0f}%"
      if interpreted_output != native_output: line += "  OUTPUT DIFFERS"
      print(line, flush=True)
  if args.save: json.dump(results, open(args.save, "w"))

if __name__ == "__main__":
  main()
