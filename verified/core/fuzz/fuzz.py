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

"""End-to-end fuzzer for the verified core (verified/core/DESIGN.md, "Fuzzing").

For every seed program the driver

  1. compiles it to a format-2 snapshot (TOIT_BYTECODE_FORMAT=2),
  2. asks toit.run for the raw bytecodes and their coverage (instruction
     starts and operand bytes) and locates the bytecodes in the snapshot,
  3. applies one mutation per mutant: a random opcode byte, or an operand
     byte set to a random or boundary value (0x00, 0x01, 0x7f, 0x80, 0xff),
  4. keeps the mutants the verified structural verifier accepts: the
     snapshot is dumped with tools/spec_dump.toit and checked by
     `toit_spec_verify` (verified/spec, `check::verify`, proven equal to
     `accepts`; untrusted rules). With --filter=loader the C++ loader's
     table checks (`toit.run --verify`) are used instead,
  5. runs each kept mutant as an untrusted container
     (`toit.run --untrusted`) on a sanitizer build with a time limit and
     classifies the outcome.

A crash is a run that ends by a signal or prints an AddressSanitizer or
UndefinedBehaviorSanitizer report. Everything else (normal exit, Toit
exception, the core's "stuck state" termination, a timeout) is fine.

Usage: fuzz.py [--seconds N] [--seed N] [--jobs N] [--out DIR]
               [--run PATH] [--check-run PATH] [programs...]

--run is the toit.run that runs the mutants (default: build/asan, falling
back to build/host); --check-run the one that compiles and checks them
(default: build/host). Results go to DIR (default build/fuzz): summary.json
and, for every crash, the mutant snapshot and its output.
"""

import argparse
import concurrent.futures
import json
import os
import random
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

DEFAULT_SEEDS = [
  "tests/sandbox/cli/print-main.toit",
  "tests/block-test.toit",
  "tests/lambda-test.toit",
  "tests/try-finally-test.toit",
  "tests/exception-test.toit",
  "tests/string-test.toit",
  "tests/list-test.toit",
  "tests/map-test.toit",
  "tests/class-id-test.toit",
  "tests/non-local-branch-test.toit",
  "tests/task-test.toit",
]

BOUNDARY = [0x00, 0x01, 0x7f, 0x80, 0xff]
ENV = dict(os.environ, TOIT_BYTECODE_FORMAT="2", TOIT_TEST_ENV_ENTRY="TOIT_TEST_ENV_VALUE")


def run(cmd, timeout):
  try:
    p = subprocess.run(cmd, cwd=REPO, env=ENV, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr
  except subprocess.TimeoutExpired as e:
    return "timeout", (e.stdout or b"") + (e.stderr or b"")


def prepare(seed, check_run, work):
  """Compiles a seed; returns (snapshot bytes, bytecode offset, coverage) or None."""
  name = os.path.basename(seed).replace(".toit", "")
  snap = os.path.join(work, name + ".snapshot")
  rc, out = run([check_run, "-w", snap, seed], 300)
  if rc != 0:
    print(f"skip {seed}: compilation failed ({rc})", file=sys.stderr)
    return None
  bytecodes_file = os.path.join(work, name + ".bytecodes")
  coverage_file = os.path.join(work, name + ".coverage")
  rc1, _ = run([check_run, "--verify", "-q", f"--emit-bytecodes={bytecodes_file}", snap], 60)
  rc2, _ = run([check_run, "--verify", "-q", f"--emit-coverage={coverage_file}", snap], 60)
  if rc1 != 0 or rc2 != 0:
    print(f"skip {seed}: cannot emit bytecodes or coverage", file=sys.stderr)
    return None
  data = open(snap, "rb").read()
  bytecodes = open(bytecodes_file, "rb").read()
  coverage = open(coverage_file, "rb").read()
  offset = data.find(bytecodes)
  if offset < 0 or data.find(bytecodes, offset + 1) >= 0:
    print(f"skip {seed}: bytecodes not found exactly once in the snapshot", file=sys.stderr)
    return None
  return name, data, offset, coverage


def mutate(rng, data, offset, coverage):
  positions = [i for i, c in enumerate(coverage) if c in (1, 2)]
  i = rng.choice(positions)
  if coverage[i] == 1:
    value = rng.randrange(256)
    kind = "opcode"
  else:
    value = rng.choice(BOUNDARY) if rng.random() < 0.5 else rng.randrange(256)
    kind = "operand"
  mutant = bytearray(data)
  if mutant[offset + i] == value:
    value ^= 0x01
  mutant[offset + i] = value
  return bytes(mutant), f"{kind} bci {i}: {data[offset + i]:#04x} -> {value:#04x}"


def classify(rc, out):
  text = out.decode("utf-8", "replace")
  if "ERROR: AddressSanitizer" in text or "runtime error:" in text:
    return "crash"
  if rc == "timeout":
    return "timeout"
  if isinstance(rc, int) and rc < 0:
    return "crash"
  if "stuck state" in text:
    return "stuck"
  if "FORMAT_2_REQUIRED" in text or "VERIFICATION_FAILED" in text or "INVALID_SNAPSHOT" in text:
    return "refused"
  return "exit-%s" % rc


def one(args, prepared, index, work):
  rng = random.Random(args.seed * 1_000_003 + index)
  name, data, offset, coverage = prepared[index % len(prepared)]
  mutant, description = mutate(rng, data, offset, coverage)
  path = os.path.join(work, f"m{index}.snapshot")
  with open(path, "wb") as f: f.write(mutant)
  if args.filter == "spec":
    dump = path + ".dump"
    rc, _ = run([args.toit, "run", os.path.join(REPO, "tools/spec_dump.toit"), "--", path, dump], 60)
    accepted = False
    if rc == 0:
      rc, out = run([args.spec_verify, "--quiet", dump], 60)
      accepted = rc == 0 and out.startswith(b"accepted")
    if os.path.exists(dump): os.unlink(dump)
  else:
    rc, _ = run([args.check_run, "--verify", "-q", path], 30)
    accepted = rc == 0
  if not accepted:
    os.unlink(path)
    return name, description, "rejected", b""
  rc, out = run([args.run, "--untrusted", path], args.timeout)
  outcome = classify(rc, out)
  # Crashes are bugs; a stuck state or a refusal of a program the verified
  # verifier accepted is a disagreement between the verifier and the core
  # or its loader, kept for inspection too.
  if outcome in ("crash", "stuck", "refused"):
    keep = os.path.join(args.out, f"{outcome}-{index}.snapshot")
    os.replace(path, keep)
    with open(keep + ".txt", "wb") as f:
      f.write(f"{name}: {description}\n".encode() + out)
  else:
    os.unlink(path)
  return name, description, outcome, out


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--seconds", type=int, default=300)
  parser.add_argument("--seed", type=int, default=1)
  parser.add_argument("--jobs", type=int, default=8)
  parser.add_argument("--timeout", type=int, default=10)
  parser.add_argument("--out", default=os.path.join(REPO, "build/fuzz"))
  asan = os.path.join(REPO, "build/asan/sdk/lib/toit/bin/toit.run")
  host = os.path.join(REPO, "build/host/sdk/lib/toit/bin/toit.run")
  parser.add_argument("--run", default=asan if os.path.exists(asan) else host)
  parser.add_argument("--check-run", default=host)
  parser.add_argument("--toit", default=os.path.join(REPO, "build/host/sdk/bin/toit"))
  parser.add_argument("--spec-verify", default=os.path.join(REPO, "verified/spec/target/release/toit_spec_verify"))
  parser.add_argument("--filter", choices=["spec", "loader"], default="spec")
  parser.add_argument("programs", nargs="*")
  args = parser.parse_args()
  os.makedirs(args.out, exist_ok=True)
  seeds = args.programs or DEFAULT_SEEDS
  with tempfile.TemporaryDirectory(dir=args.out) as work:
    prepared = [p for p in (prepare(s, args.check_run, work) for s in seeds if os.path.exists(os.path.join(REPO, s))) if p]
    if not prepared:
      print("no seeds", file=sys.stderr)
      return 2
    counts = {}
    crashes = []
    start = time.time()
    index = 0
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
      pending = set()
      while time.time() - start < args.seconds or pending:
        while time.time() - start < args.seconds and len(pending) < 2 * args.jobs:
          pending.add(pool.submit(one, args, prepared, index, work))
          index += 1
        done, pending = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
        for future in done:
          name, description, outcome, _ = future.result()
          counts[outcome] = counts.get(outcome, 0) + 1
          if outcome in ("crash", "stuck", "refused"):
            print(f"{outcome.upper()} {name}: {description}", flush=True)
          if outcome == "crash":
            crashes.append(f"{name}: {description}")
    summary = {
      "seconds": round(time.time() - start),
      "seed": args.seed,
      "run": args.run,
      "filter": "toit_spec_verify (verified check::verify, untrusted rules)" if args.filter == "spec" else "toit.run --verify (format-2 loader table checks)",
      "seeds": [p[0] for p in prepared],
      "mutants": index,
      "outcomes": counts,
      "crashes": crashes,
    }
    with open(os.path.join(args.out, "summary.json"), "w") as f:
      json.dump(summary, f, indent=2)
    print(json.dumps(summary, indent=2))
    return 1 if crashes else 0


if __name__ == "__main__":
  sys.exit(main())
