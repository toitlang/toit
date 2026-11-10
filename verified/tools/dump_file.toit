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
Reading the dumps of tools/spec_dump.toit (the input of the reference
  interpreter) and the bytecode table of the VM, for the measurement tools
  in verified/tools.

A dump is line based: `bytecodes <size> <hex>`, then one
  `m <id> <body size> <arity> <name>` line per method (the debug names),
  then `dispatch ...`, `class_check_ids <count> ...` and more tables.
*/

import fs
import host.file

import .harness

/** The lines of the dump at $path (without their newlines). */
dump-lines path/string -> List:
  lines := (file.read-contents path).to-string-non-throwing.split "\n"
  if not lines.is-empty and lines.last == "": lines.resize lines.size - 1
  return lines

/** The size of the bytecodes of the dump at $path (0 without a `bytecodes` line). */
bytecodes-size path/string -> int:
  (dump-lines path).do: | line/string |
    if line.starts-with "bytecodes ":
      return int.parse (fields_ line)[1]
  return 0

/**
The bytes of the method bodies of the dump at $path: the sum of the body
  sizes of the `m` lines before the `dispatch` line.
*/
body-size path/string -> int:
  total := 0
  (dump-lines path).do: | line/string |
    if line.starts-with "m ":
      total += int.parse (fields_ line)[2]
    else if line.starts-with "dispatch ":
      return total
  return total

/**
The methods of the dump at $path, sorted by their header position: each
  [entry, end, name], where entry is the bci of the first body byte and end
  the start of the next method's header (or the end of the bytecodes).
*/
methods path/string -> List:
  ms := []
  size := 0
  (dump-lines path).do: | line/string |
    parts := line.split " "
    if parts[0] == "bytecodes":
      size = int.parse parts[1]
    else if parts[0] == "m":
      ms.add [int.parse parts[1], int.parse parts[2], parts.size > 4 ? parts[4] : "?"]
    else if parts[0] == "dispatch":
      return method-ranges_ ms size
  return method-ranges_ ms size

method-ranges_ ms/List size/int -> List:
  ms.sort --in-place: | a b | compare-lists_ a b
  result := []
  ms.size.repeat: | i |
    id := ms[i][0]
    end := i + 1 < ms.size ? ms[i + 1][0] : size
    result.add [end - ms[i][1], end, ms[i][2]]
  return result

/** Compares two lists of ints and strings element by element. */
compare-lists_ a/List b/List -> int:
  a.size.repeat: | i |
    if i >= b.size: return 1
    c := a[i].compare-to b[i]
    if c != 0: return c
  return a.size < b.size ? -1 : 0

/** The whitespace-separated fields of $line. */
fields_ line/string -> List:
  return (line.split " ").filter: it != "" and it != "\t"

/**
The opcodes of src/bytecodes.h in opcode order: each [name, print string]
  of a `BYTECODE(name, length, format, "print string")` entry.
*/
opcode-table -> List:
  text := read-file (fs.join REPO "src/bytecodes.h")
  table := []
  from := 0
  while true:
    at := text.index-of "BYTECODE(" from
    if at < 0: break
    from = at + 1
    entry := parse-bytecode-entry_ text (at + 9)
    if entry: table.add entry
  return table

is-word-char_ c/int? -> bool:
  if c == null: return false
  return 'a' <= c <= 'z' or 'A' <= c <= 'Z' or '0' <= c <= '9' or c == '_'

is-space_ c/int? -> bool:
  return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c

char-at_ text/string i/int -> int?:
  return i < text.size ? text.at --raw i : null

/** Matches `name, <digits>, word, "text")` at $i. */
parse-bytecode-entry_ text/string i/int -> List?:
  start := i
  while is-word-char_ (char-at_ text i): i++
  if i == start or (char-at_ text i) != ',': return null
  name := text[start..i]
  i++
  while is-space_ (char-at_ text i): i++
  digits := i
  while '0' <= ((char-at_ text i) or 0) <= '9': i++
  if i == digits or (char-at_ text i) != ',': return null
  i++
  while is-space_ (char-at_ text i): i++
  word := i
  while is-word-char_ (char-at_ text i): i++
  if i == word or (char-at_ text i) != ',': return null
  i++
  while is-space_ (char-at_ text i): i++
  if (char-at_ text i) != '"': return null
  i++
  printed := i
  while (char-at_ text i) != null and (char-at_ text i) != '"': i++
  if (char-at_ text i) != '"' or (char-at_ text i + 1) != ')': return null
  return [name, text[printed..i]]
