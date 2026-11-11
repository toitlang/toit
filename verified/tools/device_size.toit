// Copyright (C) 2026 Toit contributors.
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

/**
Splits the code and read-only data of the device Rust library, as linked
  (verified/vmverify/tests/device_size.sh), by component, from the
  linked executable's symbols (`nm -S -C --size-sort`).

Components, by the demangled symbol name (the first match wins; generic
  code instantiated for a crate's types counts for that crate):
- core: checked loop: `toit_verified_core::machine` (programs not
  accepted at launch: unverified trusted format-2 programs).
- core: primitives: `toit_verified_core::prims`.
- core: verified loop and cold paths: the rest of `toit_verified_core`
  (`toit_v2_run`, the verified handlers, the views).
- verifier: inference / heap check / checker: `toit_spec::v2::infer`,
  `toit_spec::v2::heap_check`, the rest of `toit_spec::v2`.
- spec: other: the rest of `toit_spec` (`exec_step`, the float helpers).
- glue: `toit_vmverify` (conversion from VM memory, the verdict, the C ABI,
  the device runtime).
- rust: formatting, panics, other core/alloc: the residual standard
  library.
- compiler builtins (soft float, 64-bit arithmetic: `__*`), libc (newlib:
  malloc, memcpy, libm), C stubs of the measurement program.

Usage: toit run verified/tools/device_size.toit -- [--name N] SYMBOLS SECTIONS EMPTY-SECTIONS
*/

import cli
import host.file

main args:
  command := cli.Command "device_size"
      --help="Splits the device Rust library's size by component."
      --options=[
        cli.Option "name" --default="" --help="A label for the output.",
      ]
      --rest=[
        cli.Option "symbols" --required --help="nm -S -C --size-sort output of the linked executable.",
        cli.Option "sections" --required --help="size -A output of the linked executable.",
        cli.Option "empty" --required --help="size -A output of an empty executable (C runtime only).",
      ]
      --run=:: run it
  command.run args

COMPONENTS ::= [
  ["core: checked loop", ["toit_verified_core::machine"]],
  ["core: primitives", ["toit_verified_core::prims"]],
  ["core: verified loop and cold paths", ["toit_verified_core", "toit_v2_run", "toit_vcore_"]],
  ["verifier: inference", ["toit_spec::v2::infer"]],
  ["verifier: heap check", ["toit_spec::v2::heap_check"]],
  ["verifier: checker", ["toit_spec::v2"]],
  ["spec: other", ["toit_spec"]],
  ["glue (vmverify)", ["toit_vmverify"]],
  ["rust: formatting", ["core::fmt", "alloc::fmt", "Display", "Debug"]],
  ["rust: panics", ["core::panic", "rust_begin_unwind", "panic"]],
  ["rust: other core/alloc", ["core::", "alloc::", "<"]],
]

classify name/string -> string:
  COMPONENTS.do: | entry |
    (entry[1] as List).do: | key |
      if name.contains key: return entry[0]
  if name.starts-with "__": return "compiler builtins"
  if STUBS.contains name or name.starts-with "toit_v2_" or name.starts-with "toit_vmverify_panic": return "C stubs"
  return "libc"

STUBS ::= {"main", "sink", "context_pointer", "input_pointer", "result_pointer"}

section-size path/string names/List -> int:
  total := 0
  ((file.read-contents path).to-string.split "\n").do: | line/string |
    parts := (line.split " ").filter: it != ""
    if parts.size >= 2 and (names.contains parts[0]):
      total += int.parse parts[1]
  return total

run invocation/cli.Invocation -> none:
  sizes := {:}  // component -> [text, rodata, data].
  ((file.read-contents invocation["symbols"]).to-string.split "\n").do: | line/string |
    parts := line.split " "
    if parts.size < 4: continue.do
    size := int.parse parts[1] --radix=16
    type := parts[2]
    name := (parts[3..].join " ")
    component := classify name
    entry := sizes.get component --init=: [0, 0, 0]
    if type == "t" or type == "T" or type == "W" or type == "w":
      entry[0] += size
    else if type == "r" or type == "R":
      entry[1] += size
    else:
      entry[2] += size
  text-sections := [".text", ".init", ".fini"]
  ro-sections := [".rodata", ".srodata", ".eh_frame", ".init_array", ".fini_array"]
  total-text := section-size invocation["sections"] text-sections
  total-ro := section-size invocation["sections"] ro-sections
  empty-text := section-size invocation["empty"] text-sections
  empty-ro := section-size invocation["empty"] ro-sections
  print "$invocation["name"]: linked text $total-text B, rodata $total-ro B; C runtime alone text $empty-text, rodata $empty-ro"
  print "| Component | text | rodata | text+rodata |"
  print "|---|---|---|---|"
  sum := 0
  order := COMPONENTS.map: it[0]
  order.add-all ["compiler builtins", "libc", "C stubs"]
  order.do: | component |
    entry := sizes.get component
    if entry:
      print "| $component | $entry[0] | $entry[1] | $(entry[0] + entry[1]) |"
      if component != "libc" and component != "C stubs": sum += entry[0] + entry[1]
  print "| Rust library total (without libc) | | | $sum |"
