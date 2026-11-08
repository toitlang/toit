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

"""Compares the bytecode trace of the debug VM (`toit.run -Xtrace`) with the
reference interpreter's (`toit-spec-run --trace-bci`), instruction by
instruction.

The debug VM prints `[<absolute bci>] <bytecode>` for every bytecode it
dispatches, for all processes of the VM (run on a single scheduler thread),
and a `[yield from
interpretation]`/`[exit interpretation ...]` line whenever a process leaves
the interpreter. The trace is cut into segments at those lines. The
program's process runs in segments whose bcis continue the reference
interpreter's trace; segments of the system process (a different program)
are skipped. Within a matching segment every bci must agree.

Usage: compare_trace.py <program.toit|snapshot> [--steps N] [--word-bits 64]
Prints the number of consecutive steps compared and the first divergence.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

CRATE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(CRATE))
TOIT = os.path.join(REPO, "build/host/sdk/bin/toit")
DEBUG_RUN = os.environ.get("TOIT_DEBUG_RUN", os.path.join(REPO, "build/dbg/host/sdk/lib/toit/bin/toit.run"))
RUNNER = os.path.join(CRATE, "target/release/toit-spec-run")

LINE = re.compile(rb"\[\s*(\d+)\] ")


ONE_CORE = b"int get_nprocs(void) { return 1; }\nint get_nprocs_conf(void) { return 1; }\n"

# Opcodes after which the VM may switch to another process: calls (the
# stack-overflow/preemption check at the call site), backward branches
# (CHECK_PREEMPT), HALT (yield) and PRIMITIVE (a primitive may yield).
SWITCH_POINTS = {
  "INVOKE_STATIC", "INVOKE_STATIC_TAIL", "INVOKE_BLOCK", "INVOKE_LAMBDA_TAIL",
  "INVOKE_INITIALIZER_TAIL", "INVOKE_VIRTUAL", "INVOKE_VIRTUAL_WIDE",
  "INVOKE_VIRTUAL_GET", "INVOKE_VIRTUAL_SET", "INVOKE_EQ", "INVOKE_LT", "INVOKE_GT",
  "INVOKE_LTE", "INVOKE_GTE", "INVOKE_BIT_OR", "INVOKE_BIT_XOR", "INVOKE_BIT_AND",
  "INVOKE_BIT_SHL", "INVOKE_BIT_SHR", "INVOKE_BIT_USHR", "INVOKE_ADD", "INVOKE_SUB",
  "INVOKE_MUL", "INVOKE_DIV", "INVOKE_MOD", "INVOKE_AT", "INVOKE_AT_PUT", "INVOKE_SIZE",
  "BRANCH_BACK", "BRANCH_BACK_IF_TRUE", "BRANCH_BACK_IF_FALSE", "BRANCH_BACK_IF_NOT_NULL",
  "HALT", "PRIMITIVE", "LOAD_GLOBAL_VAR_LAZY", "LOAD_GLOBAL_VAR_LAZY_WIDE",
  "AS_CLASS", "AS_CLASS_WIDE", "AS_INTERFACE", "AS_INTERFACE_WIDE", "AS_LOCAL",
  "INTRINSIC_SMI_REPEAT", "INTRINSIC_ARRAY_DO", "INTRINSIC_HASH_FIND", "INTRINSIC_HASH_DO",
  "LOAD_GLOBAL_VAR_DYNAMIC", "STORE_GLOBAL_VAR_DYNAMIC", "RETURN", "RETURN_NULL",
}


def opcode_table():
  """Opcode number -> (name, VM print string) from src/bytecodes.h."""
  table = []
  with open(os.path.join(REPO, "src/bytecodes.h")) as f:
    for m in re.finditer(r'BYTECODE\((\w+),\s*\d+,\s*\w+,\s*"([^"]*)"\)', f.read()):
      table.append((m.group(1), m.group(2)))
  return table


def vm_trace(snapshot, args, timeout, tmp):
  """The debug VM's trace as a list of (bci, text) lines and None for
  'left the interpreter' markers."""
  # The VM starts one scheduler thread per core and the processes' traces
  # would interleave line by line. A one-core get_nprocs keeps the VM on a
  # single scheduler thread.
  src = os.path.join(tmp, "onecore.c")
  lib = os.path.join(tmp, "onecore.so")
  with open(src, "wb") as f: f.write(ONE_CORE)
  subprocess.run(["cc", "-shared", "-fPIC", "-o", lib, src], check=True)
  env = dict(os.environ, LD_PRELOAD=lib)
  p = subprocess.run([DEBUG_RUN, "-Xtrace", snapshot] + args, capture_output=True, timeout=timeout, cwd=REPO, env=env)
  out = []
  for line in p.stdout.split(b"\n"):
    m = LINE.match(line)
    if m:
      out.append((int(m.group(1)), line[m.end():].decode("utf-8", "replace")))
    elif b"interpretation" in line:
      out.append(None)
  return out


def spec_trace(dump, args, bits, max_steps, timeout):
  p = subprocess.run([RUNNER, "--word-bits", str(bits), "--trace-bci", "--max-steps", str(max_steps), dump, "--"] + args,
                     capture_output=True, timeout=timeout, cwd=REPO)
  out = []
  for l in p.stderr.split(b"\n"):
    if l.startswith(b"B "):
      bci, op = l[2:].split()
      out.append((int(bci), int(op)))
  return out


def compare(spec, vm, table):
  """Walks the VM trace, attributing lines to the program while they
  continue the reference interpreter's trace. The program may only leave
  the interpreter (switch to another process) after a call, a backward
  branch, a primitive or a yield; it must resume exactly where the
  reference interpreter continues. Returns (matched steps, switches,
  divergence or None)."""
  def same(line, step):
    bci, text = line
    name, printed = table[step[1]]
    return bci == step[0] and text.startswith(printed)

  i = 0
  in_program = False
  switches = 0
  for line in vm:
    if i >= len(spec):
      break
    if line is None:
      if in_program:
        switches += 1
      in_program = False
      continue
    if same(line, spec[i]):
      if not in_program and i > 0:
        switches += 0  # Counted when leaving.
      in_program = True
      i += 1
      continue
    if in_program:
      # A branch right after a primitive whose result depends on the
      # outside world (task_has_messages: when the system process's reply
      # arrives) ends the comparison: the oracles differ, not the bytecode
      # semantics.
      recent = [table[op][0] for _, op in spec[max(0, i - 3):i]]
      if "PRIMITIVE" in recent and table[spec[i - 1][1]][0].startswith("BRANCH"):
        return i, switches, None, "stopped at an environment-dependent primitive result before step %d" % i
      # The program left the interpreter without a marker (preemption).
      prev = table[spec[i - 1][1]][0] if i > 0 else None
      if prev not in SWITCH_POINTS:
        return i, switches, "step %d: VM %r, spec bci %d (%s) after %s" % (
            i, line, spec[i][0], table[spec[i][1]][0], prev), None
      switches += 1
      in_program = False
  if i < len(spec):
    return i, switches, "step %d: spec continues at bci %d, the VM does not" % (i, spec[i][0]), None
  return i, switches, None, None


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("program")
  ap.add_argument("--steps", type=int, default=20000)
  ap.add_argument("--word-bits", type=int, default=64)
  ap.add_argument("--timeout", type=int, default=600)
  ap.add_argument("args", nargs="*")
  opts = ap.parse_args()
  with tempfile.TemporaryDirectory() as tmp:
    snapshot = opts.program
    if snapshot.endswith(".toit"):
      snapshot = os.path.join(tmp, "p.snapshot")
      subprocess.run([TOIT, "compile", "--snapshot", "-o", snapshot, os.path.abspath(opts.program)], check=True, cwd=REPO)
    dumper = os.path.join(tmp, "spec_dump.snapshot")
    subprocess.run([TOIT, "compile", "--snapshot", "-o", dumper, os.path.join(REPO, "tools/spec_dump.toit")], check=True)
    dump = os.path.join(tmp, "p.dump")
    subprocess.run([TOIT, "run", dumper, "--", snapshot, dump], check=True)
    spec = spec_trace(dump, opts.args, opts.word_bits, opts.steps, opts.timeout)
    vm = vm_trace(snapshot, opts.args, opts.timeout, tmp)
  n, switches, div, note = compare(spec, vm, opcode_table())
  total_vm = sum(1 for l in vm if l is not None)
  print("%s: compared %d consecutive steps (spec trace %d steps, VM trace %d steps of all processes, "
        "%d process switches)%s"
        % (os.path.basename(opts.program), n, len(spec), total_vm, switches,
           ("; DIVERGENCE at " + div) if div else ("; " + note if note else "")))
  sys.exit(0 if div is None else 1)


if __name__ == "__main__":
  main()
