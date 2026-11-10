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
Generates verified/spec/src/v2/prim_arity.rs (the primitive table of the VM:
  module names, primitive names and arities, in the order of
  src/primitive.h). verified/spec/tests/prim_table.rs checks that the
  generated file is up to date.

Usage: toit run verified/tools/gen_prim_arity.toit [-- --print]
*/

import cli
import fs
import host.file
import io

import .harness

HEAD ::= """
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

//! The VM's primitive table: for each module (in module-number order) its
//! name and its primitives' names and arities. Generated from
//! `src/primitive.h` by `verified/tools/gen_prim_arity.toit`;
//! `tests/prim_table.rs` checks that it is up to date. Part of the
//! verifier's trusted input: a PRIMITIVE is only accepted in a method whose
//! arity is the primitive's.
"""

main args:
  command := cli.Command "gen_prim_arity"
      --help="""
        Generates verified/spec/src/v2/prim_arity.rs from src/primitive.h.
        """
      --options=[
        cli.Flag "print" --help="Print the table instead of writing the file.",
      ]
      --run=:: | invocation/cli.Invocation |
        text := generate (parse (read-file (fs.join REPO "src/primitive.h")))
        if invocation["print"]:
          print_ text
        else:
          write-file (fs.join SPEC-CRATE "src/v2/prim_arity.rs") text
  command.run args

/** Writes $text to stdout without an extra newline. */
print_ text/string -> none:
  // $text ends with a newline; print adds one.
  print text[..text.size - 1]

is-word-char_ c/int? -> bool:
  if c == null: return false
  return 'a' <= c <= 'z' or 'A' <= c <= 'Z' or '0' <= c <= '9' or c == '_'

is-space_ c/int? -> bool:
  return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c

/**
Matches `PRIMITIVE(<name>, <arity>)` in $text and returns the
  [name, arity] pairs.
*/
find-primitives text/string -> List:
  result := []
  needle := "PRIMITIVE("
  from := 0
  while true:
    at := text.index-of needle from
    if at < 0: break
    from = at + 1
    i := at + needle.size
    start := i
    while is-word-char_ (char-at_ text i): i++
    if i == start or (char-at_ text i) != ',': continue
    name := text[start..i]
    i++
    while is-space_ (char-at_ text i): i++
    digits := i
    while '0' <= ((char-at_ text i) or 0) <= '9': i++
    if i == digits or (char-at_ text i) != ')': continue
    result.add [name, int.parse text[digits..i]]
  return result

char-at_ text/string i/int -> int?:
  return i < text.size ? text.at --raw i : null

/**
The modules of `MODULES(M)` in order, each [name, [[primitive, arity], ...]].
A module's primitives are the lines after its `#define <MACRO>(PRIMITIVE)`
  up to the first blank line or preprocessor line.
*/
parse text/string -> List:
  lines := text.split "\n"
  table := []
  lines.do: | line/string |
    trimmed := line.trim --left
    if not trimmed.starts-with "M(": continue.do
    i := 2
    start := i
    while is-word-char_ (char-at_ trimmed i): i++
    if i == start or (char-at_ trimmed i) != ',': continue.do
    name := trimmed[start..i]
    i++
    while is-space_ (char-at_ trimmed i): i++
    if not trimmed[i..].starts-with "MODULE_": continue.do
    macro-start := i
    i += 7
    while is-word-char_ (char-at_ trimmed i): i++
    if (char-at_ trimmed i) != ')': continue.do
    table.add [name, primitives-of text trimmed[macro-start..i]]
  return table

primitives-of text/string macro/string -> List:
  at := text.index-of "#define $(macro)(PRIMITIVE)"
  if at < 0: return []
  body-start := at + "#define $(macro)(PRIMITIVE)".size
  // The body ends at the first newline that is followed by a blank line or
  // by a '#'.
  i := body-start
  while true:
    nl := text.index-of "\n" i
    if nl < 0: return []
    j := nl + 1
    while j < text.size and (text.at --raw j) != '\n' and is-space_ (text.at --raw j): j++
    if j < text.size and ((text.at --raw j) == '\n' or (j == nl + 1 and (text.at --raw j) == '#')):
      return find-primitives text[body-start..nl]
    i = nl + 1

generate table/List -> string:
  out := io.Buffer
  out.write HEAD
  out.write "\npub const PRIM_TABLE: &[(&str, &[(&str, u8)])] = &[\n"
  table.do: | entry |
    out.write "    (\"$entry[0]\", &[\n"
    entry[1].do: | prim |
      out.write "        (\"$prim[0]\", $prim[1]),\n"
    out.write "    ]),\n"
  out.write "];\n"
  return out.to-string
