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

"""Runs the Toit tests on the WebAssembly VM.

Each test is compiled to a snapshot with the host compiler, and then run
with Node.js on the WebAssembly VM. The tests are run from the root of the
repository, with the same arguments and environment as the host tests.

With '--backend gc', the tests are instead compiled to WebAssembly GC
modules with the experimental backend (see docs/wasm-gc-backend.md), and run
with the JavaScript host in src/wasm/toit-gc.mjs.
"""

import argparse
import concurrent.futures
import fnmatch
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def parse_args():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--host-toit", default=os.path.join(ROOT, "build/host/sdk/bin/toit"))
  parser.add_argument("--wasm-vm", default=os.path.join(ROOT, "build/wasm/sdk/bin/toit.run.js"))
  parser.add_argument("--node", default="node")
  parser.add_argument("--backend", choices=["vm", "gc"], default="vm")
  parser.add_argument("--toit-compile", default=os.path.join(ROOT, "build/host/sdk/lib/toit/bin/toit.compile"))
  parser.add_argument("--wasm-as", default="wasm-as")
  parser.add_argument("--timeout", type=int, default=120)
  parser.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
  parser.add_argument("--skip-file", default=os.path.join(ROOT, "tests/wasm-skip.txt"),
                      help="File with test patterns to skip, one per line.")
  parser.add_argument("--no-skip", action="store_true", help="Ignore the skip file.")
  parser.add_argument("--expected-failures",
                      help="File with test patterns that are expected to fail, one per line. " +
                           "Defaults to tests/wasm-gc-expected-failures.txt with '--backend gc'.")
  parser.add_argument("-v", "--verbose", action="store_true")
  parser.add_argument("tests", nargs="*",
                      help="Test files or glob patterns (relative to the root). Defaults to all tests.")
  args = parser.parse_args()
  if args.expected_failures is None and args.backend == "gc":
    args.expected_failures = os.path.join(ROOT, "tests/wasm-gc-expected-failures.txt")
  return args


def find_tests(patterns):
  if not patterns:
    patterns = ["tests/*-test.toit", "tests/regress/*-test.toit", "tests/wasm/*-test.toit"]
  result = []
  for dir_pattern in patterns:
    directory, pattern = os.path.split(dir_pattern)
    full_dir = os.path.join(ROOT, directory)
    for name in sorted(os.listdir(full_dir)):
      if fnmatch.fnmatch(name, pattern):
        result.append(os.path.join(directory, name))
  return result


def read_patterns(path):
  if not path or not os.path.exists(path): return []
  result = []
  with open(path) as f:
    for line in f:
      line = line.split("#")[0].strip()
      if line: result.append(line)
  return result


WASM_FEATURES = [
  "--enable-gc", "--enable-reference-types", "--enable-exception-handling",
  "--enable-multivalue", "--enable-tail-call", "--enable-bulk-memory",
  "--enable-nontrapping-float-to-int", "--enable-sign-ext",
]


def compile_gc(args, test, output_dir):
  """Compiles the test to a WebAssembly GC module. Returns the module's path or an error."""
  base = os.path.join(output_dir, test.replace("/", "_"))
  result = subprocess.run(
      [args.toit_compile, "-Xwasm_output=" + base + ".wat", "-w", base + ".snapshot", test],
      cwd=ROOT, capture_output=True, text=True)
  if result.returncode != 0:
    return None, result.stdout + result.stderr
  result = subprocess.run([args.wasm_as] + WASM_FEATURES + ["-g", "-o", base + ".wasm", base + ".wat"],
                          cwd=ROOT, capture_output=True, text=True)
  if result.returncode != 0:
    return None, result.stdout + result.stderr
  return base + ".wasm", None


def run_test(args, test, snapshot_dir):
  if args.backend == "gc":
    return run_gc_test(args, test, snapshot_dir)
  snapshot = os.path.join(snapshot_dir, test.replace("/", "_") + ".snapshot")
  start = time.time()
  compile_result = subprocess.run(
      [args.host_toit, "compile", "--snapshot", "-o", snapshot, test],
      cwd=ROOT, capture_output=True, text=True)
  if compile_result.returncode != 0:
    return (test, "COMPILE-ERROR", compile_result.stdout + compile_result.stderr, 0)
  env = dict(os.environ)
  env["TOIT_TEST_ENV_ENTRY"] = "TOIT_TEST_ENV_VALUE"
  try:
    run_result = subprocess.run(
        [args.node, args.wasm_vm, snapshot, "foo", "bar", "gee"],
        cwd=ROOT, capture_output=True, text=True, timeout=args.timeout, env=env)
  except subprocess.TimeoutExpired as e:
    output = (e.stdout or b"").decode(errors="replace") + (e.stderr or b"").decode(errors="replace")
    return (test, "TIMEOUT", output, time.time() - start)
  status = "PASS" if run_result.returncode == 0 else "FAIL(%d)" % run_result.returncode
  return (test, status, run_result.stdout + run_result.stderr, time.time() - start)


def run_gc_test(args, test, output_dir):
  start = time.time()
  module, error = compile_gc(args, test, output_dir)
  if module is None:
    return (test, "COMPILE-ERROR", error, 0)
  env = dict(os.environ)
  env["TOIT_TEST_ENV_ENTRY"] = "TOIT_TEST_ENV_VALUE"
  runner = os.path.join(ROOT, "tools/wasm/run-gc.mjs")
  try:
    result = subprocess.run(
        [args.node, runner, module, "foo", "bar", "gee"],
        cwd=ROOT, capture_output=True, text=True, timeout=args.timeout, env=env)
  except subprocess.TimeoutExpired as e:
    output = (e.stdout or b"").decode(errors="replace") + (e.stderr or b"").decode(errors="replace")
    return (test, "TIMEOUT", output, time.time() - start)
  status = "PASS" if result.returncode == 0 else "FAIL(%d)" % result.returncode
  return (test, status, result.stdout + result.stderr, time.time() - start)


def main():
  args = parse_args()
  tests = find_tests(args.tests)
  skips = [] if args.no_skip else read_patterns(args.skip_file)
  skipped = [t for t in tests if any(fnmatch.fnmatch(t, s) for s in skips)]
  tests = [t for t in tests if t not in skipped]
  expected = read_patterns(args.expected_failures)
  is_expected_failure = lambda test: any(fnmatch.fnmatch(test, e) for e in expected)

  failures = []
  expected_failures = []
  unexpected_passes = []
  with tempfile.TemporaryDirectory() as snapshot_dir:
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
      futures = [executor.submit(run_test, args, test, snapshot_dir) for test in tests]
      for future in concurrent.futures.as_completed(futures):
        test, status, output, duration = future.result()
        if is_expected_failure(test):
          if status == "PASS":
            status = "XPASS"
            unexpected_passes.append(test)
          else:
            status = "XFAIL(%s)" % status
            expected_failures.append(test)
        print("%-10s %6.1fs %s" % (status, duration, test), flush=True)
        if status != "PASS" and status != "XPASS" and not status.startswith("XFAIL"):
          failures.append((test, status, output))
          if args.verbose:
            # Emscripten prints the (minified) source line of uncaught
            # exceptions. Shorten long lines to keep the output readable.
            lines = [l if len(l) < 300 else l[:300] + "..." for l in output.splitlines()]
            print("\n".join(lines[-40:]))

  print()
  passed = len(tests) - len(failures) - len(expected_failures)
  print("Passed: %d, failed: %d, expected failures: %d, skipped: %d" %
        (passed, len(failures), len(expected_failures), len(skipped)))
  for test, status, _ in sorted(failures):
    print("  %s %s" % (status, test))
  if unexpected_passes:
    print("Unexpected passes (remove them from %s):" % os.path.relpath(args.expected_failures, ROOT))
    for test in sorted(unexpected_passes):
      print("  %s" % test)
  return 1 if failures else 0


if __name__ == "__main__":
  sys.exit(main())
