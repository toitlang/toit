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

"""Differential test of the reference interpreter against the C++ VM on the
repository's test suite.

For every `tests/*-test.toit` and `tests/regress/*-test.toit` (plus the
`-test-slow`, `-test-force` variants) the driver

  1. compiles the test to a snapshot (old format) and, with `--format 2`,
     also to a revised-format snapshot (`-Xbytecode_format=2`),
  2. dumps the snapshot with tools/spec_dump.toit,
  3. runs the dump on the reference interpreter (64-bit smis). A run that
     ends in an unimplemented primitive is *not runnable* and counted per
     primitive; a run that exceeds the step limit is counted as too long,
  4. runs the snapshot on the C++ VM and compares stdout and the exit code
     with the interpreter's (64-bit and 32-bit smis, and with the verified
     step disabled).

Tests run like ctest runs them: from the repository root with the arguments
`foo bar gee` and TOIT_TEST_ENV_ENTRY set.

Usage: run_suite.py [--format 1|2|both] [--jobs N] [--max-steps N]
                    [--filter SUBSTRING] [--out DIR] [--no-32]
"""

import argparse
import collections
import concurrent.futures
import glob
import json
import os
import re
import subprocess
import sys

CRATE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(CRATE))
TOIT = os.environ.get("TOIT", os.path.join(REPO, "build/host/sdk/bin/toit"))
TOIT_COMPILE = os.path.join(os.path.dirname(os.path.dirname(TOIT)), "lib/toit/bin/toit.compile")
RUNNER = os.path.join(CRATE, "target/release/toit-spec-run")
TEST_ARGS = ["foo", "bar", "gee"]
ENV = dict(os.environ, TOIT_TEST_ENV_ENTRY="TOIT_TEST_ENV_VALUE")


def run(cmd, timeout, out_path=None, cwd=REPO):
  try:
    p = subprocess.run(cmd, cwd=cwd, env=ENV, capture_output=True, timeout=timeout)
    rc, out, err = p.returncode, p.stdout, p.stderr
  except subprocess.TimeoutExpired as e:
    rc, out, err = "timeout", e.stdout or b"", e.stderr or b""
  if out_path:
    with open(out_path + ".out", "wb") as f: f.write(out)
    with open(out_path + ".err", "wb") as f: f.write(err)
  return rc, out, err


def discover(filt):
  patterns = ["tests/*-test.toit", "tests/regress/*-test.toit",
              "tests/*-test-slow.toit", "tests/*-test-force.toit",
              "tests/regress/*-test-force.toit"]
  files = []
  for pat in patterns:
    files.extend(sorted(glob.glob(os.path.join(REPO, pat))))
  files = [os.path.relpath(f, REPO) for f in files]
  if filt:
    files = [f for f in files if any(x in f for x in filt)]
  return files


def spec_run(dump, bits, extra, max_steps, path, timeout):
  # The C++ VM reports the snapshot path it was started with as the program
  # name.
  name = os.path.join(os.path.dirname(dump).replace("/f2", "/f1"), os.path.basename(dump)[:-5] + ".snapshot")
  cmd = [RUNNER, "--word-bits", str(bits), "--max-steps", str(max_steps), "--stats",
         "--program-name", name] + extra + [dump, "--"] + TEST_ARGS
  return run(cmd, timeout, path)


def classify_spec(rc, err):
  text = err.decode("utf-8", "replace")
  m = re.search(r"unimplemented primitive (\S+)", text)
  if m: return ("unimplemented", m.group(1))
  if "StepLimit" in text: return ("steplimit", None)
  if rc == "timeout": return ("timeout", None)
  m = re.search(r"\[spec\] stuck: (\S+)", text)
  if m: return ("stuck", m.group(1))
  if "cannot load" in text: return ("load", None)
  return ("ran", None)


def steps_of(err):
  m = re.search(rb"steps: (\d+), verified steps: (\d+)", err)
  return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def one(test, fmt, opts):
  name = test.replace("/", "_")[:-5]
  base = os.path.join(opts.out, "f%d" % fmt, name)
  os.makedirs(os.path.dirname(base), exist_ok=True)
  result = {"test": test, "format": fmt}
  # The C++ VM always runs the old format.
  vm_snapshot = os.path.join(opts.out, "f1", name + ".snapshot")
  snapshot = base + ".snapshot"
  if fmt == 1:
    cmd = [TOIT, "compile", "--snapshot", "-o", snapshot, test]
  else:
    cmd = [TOIT_COMPILE, "-Xbytecode_format=2", "-w", snapshot, test]
  rc, _, err = run(cmd, 300, base + ".compile")
  if rc != 0:
    result["status"] = "compile-error"
    return result
  if fmt != 1 and not os.path.exists(vm_snapshot):
    rc, _, _ = run([TOIT, "compile", "--snapshot", "-o", vm_snapshot, test], 300)
    if rc != 0:
      result["status"] = "compile-error"
      return result
  rc, _, err = run([TOIT, "run", opts.dumper, "--", snapshot, base + ".dump"], 300, base + ".dumplog")
  if rc != 0:
    result["status"] = "dump-error"
    result["detail"] = err.decode("utf-8", "replace")[-300:]
    return result
  rc64, out64, err64 = spec_run(base + ".dump", 64, [], opts.max_steps, base + ".spec64", opts.timeout)
  kind, detail = classify_spec(rc64, err64)
  result["steps"], result["verified_steps"] = steps_of(err64)
  if kind in ("unimplemented", "steplimit", "timeout", "load"):
    result["status"] = kind
    result["detail"] = detail
    return result
  vm_path = os.path.join(opts.out, "f1", name + ".vm")
  if fmt == 1 or not os.path.exists(vm_path + ".out"):
    rc, out, _ = run([TOIT, "run", vm_snapshot, "--"] + TEST_ARGS, opts.timeout, vm_path)
    with open(vm_path + ".rc", "w") as f: f.write(str(rc))
  with open(vm_path + ".out", "rb") as f: vm_out = f.read()
  with open(vm_path + ".rc") as f: vm_rc = f.read()
  expected = (vm_out, vm_rc)
  failures = []
  if (out64, str(rc64)) != expected:
    failures.append("64")
  runs = []
  if not opts.no_32:
    runs.append((32, []))
  if opts.unverified:
    runs.append((64, ["--no-verified"]))
  for bits, extra in runs:
    tag = "%d%s" % (bits, "u" if extra else "")
    rc, out, err = spec_run(base + ".dump", bits, extra, opts.max_steps, base + ".spec" + tag, opts.timeout)
    exp = expected
    exp32 = os.path.join(REPO, test[:-5] + ".expected32")
    if bits == 32 and os.path.exists(exp32):
      with open(exp32, "rb") as f: exp = (f.read(), vm_rc)
    if (out, str(rc)) != exp:
      failures.append(tag)
  if failures:
    # Tests whose output depends on timing, addresses or the environment
    # are not comparable: run the VM again and see whether it agrees with
    # itself.
    rc2, out2, _ = run([TOIT, "run", vm_snapshot, "--"] + TEST_ARGS, opts.timeout, vm_path + "2")
    if (out2, str(rc2)) != expected:
      result["status"] = "nondeterministic"
      return result
  result["status"] = "pass" if not failures else "fail"
  if failures:
    result["detail"] = ",".join(failures)
    result["spec_kind"] = kind
    result["spec_detail"] = detail
  return result


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--format", default="1", choices=["1", "2", "both"])
  ap.add_argument("--jobs", type=int, default=os.cpu_count())
  ap.add_argument("--max-steps", type=int, default=200_000_000)
  ap.add_argument("--timeout", type=int, default=300)
  ap.add_argument("--filter", action="append")
  ap.add_argument("--out", default=os.path.join(CRATE, "target/suite"))
  ap.add_argument("--no-32", action="store_true")
  ap.add_argument("--unverified", action="store_true")
  ap.add_argument("--json")
  opts = ap.parse_args()
  opts.out = os.path.abspath(opts.out)
  os.makedirs(os.path.join(opts.out, "f1"), exist_ok=True)
  subprocess.run(["cargo", "build", "--release", "--quiet"], cwd=CRATE, check=True)
  opts.dumper = os.path.join(opts.out, "spec_dump.snapshot")
  subprocess.run([TOIT, "compile", "--snapshot", "-o", opts.dumper, os.path.join(REPO, "tools/spec_dump.toit")], check=True)
  formats = [1, 2] if opts.format == "both" else [int(opts.format)]
  tests = discover(opts.filter)
  results = []
  for fmt in formats:
    with concurrent.futures.ThreadPoolExecutor(opts.jobs) as ex:
      futures = {ex.submit(one, t, fmt, opts): t for t in tests}
      for fut in concurrent.futures.as_completed(futures):
        r = fut.result()
        results.append(r)
        if r["status"] in ("fail", "dump-error", "load"):
          print("FAIL f%d %s %s" % (fmt, r["test"], r.get("detail", "")), flush=True)
  for fmt in formats:
    rs = [r for r in results if r["format"] == fmt]
    counts = collections.Counter(r["status"] for r in rs)
    prims = collections.Counter(r.get("detail") for r in rs if r["status"] == "unimplemented")
    runnable = [r for r in rs if r["status"] in ("pass", "fail")]
    print()
    print("format %d: %d tests discovered" % (fmt, len(rs)))
    for k, v in sorted(counts.items()):
      print("  %-14s %d" % (k, v))
    print("  runnable: %d, passed: %d, failed: %d" % (len(runnable), counts["pass"], counts["fail"]))
    steps = sum(r.get("steps", 0) for r in runnable)
    vsteps = sum(r.get("verified_steps", 0) for r in runnable)
    print("  steps on runnable tests: %d (verified: %d)" % (steps, vsteps))
    print("  unimplemented primitives (tests blocked):")
    for p, n in prims.most_common(25):
      print("    %4d %s" % (n, p))
    fails = sorted(r["test"] for r in rs if r["status"] == "fail")
    if fails:
      print("  failing: " + " ".join(fails))
  if opts.json:
    with open(opts.json, "w") as f:
      json.dump(results, f, indent=1, sort_keys=True)
  bad = [r for r in results if r["status"] == "fail"]
  sys.exit(1 if bad else 0)


if __name__ == "__main__":
  main()
