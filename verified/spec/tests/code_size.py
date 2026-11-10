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

"""Measures the code size of the two bytecode formats on the three system
snapshots embedded in the host SDK (compiled with -O2 like the build does)
and on a fixed set of test programs.

For every program and format it reports the bytecode bytes (headers
included), the method-body bytes, the header bytes (everything else in the
bytecodes, including the 4-byte tag of format 2), the class-check table
(format 2 puts receiver ranges there, format note 15), and the size of the
program snapshot (the `snapshot` member of the snapshot bundle, without the
source map).

Usage: code_size.py [--out DIR] [--json FILE] [--formats 1,2]
"""

import argparse
import json
import os
import subprocess
import sys

CRATE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(CRATE))
TOIT = os.environ.get("TOIT", os.path.join(REPO, "build/host/sdk/bin/toit"))
TOIT_COMPILE = os.path.join(os.path.dirname(os.path.dirname(TOIT)), "lib/toit/bin/toit.compile")

# (name, source, package cache, extra compiler flags)
SYSTEM = [
  ("toit", "tools/toit.toit", "tools/.packages-bootstrap", ["-O2"]),
  ("toit_run", "system/extensions/host/toit.run.toit", "system/extensions/host/.packages-bootstrap", ["-O2"]),
  ("run_image", "system/extensions/host/run-image.toit", "system/extensions/host/.packages-bootstrap", ["-O2"]),
]

TESTS = [
  "tests/map-test.toit",
  "tests/deque-test.toit",
  "tests/byte-array-test.toit",
  "tests/encoding-test.toit",
  "tests/ble-advertisement-test.toit",
  "tests/is-as-many-test.toit",
  "tests/format-test.toit",
  "tests/string-slice-test.toit",
  "tests/coap-tcp-client-test.toit",
  "tests/constructor-super-test.toit",
]


def ar_member_size(path, member):
  with open(path, "rb") as f:
    data = f.read()
  assert data[:8] == b"!<arch>\n", path
  at = 8
  while at < len(data):
    name = data[at:at + 16].decode().strip().rstrip("/")
    size = int(data[at + 48:at + 58].decode().strip())
    if name == member: return size
    at += 60 + size + (size & 1)
  raise Exception("no member %s in %s" % (member, path))


def dump_stats(dump):
  stats = {"bodies": 0, "methods": 0}
  with open(dump) as f:
    for line in f:
      parts = line.split(" ", 3)
      if parts[0] == "bytecodes":
        stats["bytecodes"] = int(parts[1])
      elif parts[0] == "m":
        stats["bodies"] += int(parts[2])
        stats["methods"] += 1
      elif parts[0] == "class_check_ids":
        stats["class_check_bytes"] = 2 * int(parts[1])
        break
  stats["headers"] = stats["bytecodes"] - stats["bodies"]
  return stats


def measure(name, source, packages, flags, fmt, opts):
  base = os.path.join(opts.out, "%s.f%d" % (name, fmt))
  env = dict(os.environ)
  if packages: env["TOIT_PACKAGE_CACHE_PATHS"] = os.path.join(REPO, packages)
  subprocess.run([TOIT_COMPILE] + flags + ["-Xbytecode_format=%d" % fmt, "-w", base + ".snapshot", source],
                 cwd=REPO, env=env, check=True)
  subprocess.run([TOIT, "run", opts.dumper, "--", base + ".snapshot", base + ".dump"], check=True)
  stats = dump_stats(base + ".dump")
  stats["snapshot"] = ar_member_size(base + ".snapshot", "snapshot")
  stats.update({"program": name, "format": fmt})
  return stats


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--out", default=os.path.join(CRATE, "target/code-size"))
  ap.add_argument("--json")
  ap.add_argument("--formats", default="1,2")
  opts = ap.parse_args()
  os.makedirs(opts.out, exist_ok=True)
  opts.dumper = os.path.join(opts.out, "spec_dump.snapshot")
  subprocess.run([TOIT, "compile", "--snapshot", "-o", opts.dumper, os.path.join(REPO, "tools/spec_dump.toit")],
                 check=True)
  formats = [int(f) for f in opts.formats.split(",")]
  programs = SYSTEM + [(os.path.basename(t)[:-5], t, None, []) for t in TESTS]
  results = []
  for name, source, packages, flags in programs:
    for fmt in formats:
      results.append(measure(name, source, packages, flags, fmt, opts))
  print("%-24s %3s %9s %9s %8s %7s %6s %9s" %
        ("program", "fmt", "bytecodes", "bodies", "headers", "methods", "cc-tab", "snapshot"))
  for r in results:
    print("%-24s %3d %9d %9d %8d %7d %6d %9d" %
          (r["program"], r["format"], r["bytecodes"], r["bodies"], r["headers"], r["methods"],
           r["class_check_bytes"], r["snapshot"]))
  for fmt in formats:
    rs = [r for r in results if r["format"] == fmt]
    print("total f%d: bytecodes %d, bodies %d, headers %d, snapshot %d" %
          (fmt, sum(r["bytecodes"] for r in rs), sum(r["bodies"] for r in rs),
           sum(r["headers"] for r in rs), sum(r["snapshot"] for r in rs)))
  if opts.json:
    with open(opts.json, "w") as f:
      json.dump(results, f, indent=1, sort_keys=True)


if __name__ == "__main__":
  main()
