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

"""Generates src/v2/prim_arity.rs (the primitive table of the VM: module
names, primitive names and arities, in the order of src/primitive.h).
tests/prim_table.rs checks that the generated file is up to date."""

import os
import re
import sys

CRATE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADER = os.path.join(CRATE, "../../src/primitive.h")

HEAD = """// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

//! The VM's primitive table: for each module (in module-number order) its
//! name and its primitives' names and arities. Generated from
//! `src/primitive.h` by `tests/gen_prim_arity.py`; `tests/prim_table.rs`
//! checks that it is up to date. Part of the verifier's trusted input: a
//! PRIMITIVE is only accepted in a method whose arity is the primitive's.
"""


def parse(text):
  modules = re.findall(r"^\s*M\((\w+),\s*(MODULE_\w+)\)", text, re.M)
  table = []
  for name, macro in modules:
    m = re.search(r"#define " + macro + r"\(PRIMITIVE\)(.*?)(?:\n\s*\n|\n#)", text, re.S)
    prims = re.findall(r"PRIMITIVE\((\w+),\s*(\d+)\)", m.group(1)) if m else []
    table.append((name, [(p, int(a)) for p, a in prims]))
  return table


def generate(table):
  out = [HEAD, "pub const PRIM_TABLE: &[(&str, &[(&str, u8)])] = &["]
  for name, prims in table:
    out.append("    (\"%s\", &[" % name)
    for p, a in prims:
      out.append("        (\"%s\", %d)," % (p, a))
    out.append("    ]),")
  out.append("];")
  return "\n".join(out) + "\n"


def main():
  with open(HEADER) as f:
    table = parse(f.read())
  text = generate(table)
  if len(sys.argv) > 1 and sys.argv[1] == "--print":
    sys.stdout.write(text)
  else:
    with open(os.path.join(CRATE, "src/v2/prim_arity.rs"), "w") as f:
      f.write(text)


if __name__ == "__main__":
  main()
