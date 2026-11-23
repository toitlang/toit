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
The native array constructor (heap.cc) checked with ESBMC, using the
  verified initializer's postcondition in place of the initializer: the
  `process-array-allocation` jobs of verified/cxx/annotated/run.sh, which
  runs ESBMC itself between the two steps (so that the model checker's
  memory is measured and capped alone).

Usage:
  toit run array_allocation.toit -- prepare MODE SRC DIR
  toit run array_allocation.toit -- verdict MODE OUTPUT STATUS

`prepare` writes into the directory DIR `process_array_heap.inc` (SRC's
  heap.cc with its one array initialization call replaced by
  `checked_array_init`, plus the model's layout constants) and
  `process_array_spaces.inc` (SRC's third_party/dartino/two_space_heap.cc).
  It fails (exit status 1) when the call or, for `unmarked-old`, the card
  mark does not occur exactly once (a change to the composition needs a new
  check) or a model constant is not defined exactly once. ESBMC then runs
  on verified/cxx/harness/process_array_allocation.cc with `-IDIR`.

`verdict` exits with status 0 when ESBMC's output OUTPUT (stdout and stderr
  together) and its exit status STATUS are the expected verdict of MODE,
  else with status 1:
- `proof`: STATUS is 0 and the output reports VERIFICATION SUCCESSFUL.
- `young-filler`, `old-filler`: the filler is dropped for young (old)
  requests; the output must report VERIFICATION FAILED and the first
  violated property (up to the next blank line) must mention
  `return the supplied filler`.
- `unmarked-old`: the card mark of the direct old-space allocation is
  removed; the violated property must mention
  `the old array is remembered before any filler store`.
*/

import fs
import host.file
import host.pipe
import system

MODES ::= ["proof", "young-filler", "old-filler", "unmarked-old"]

// Retain the actual arguments and receiver. Match the entire call so that a
// change to the composition requires a new check.
CALL ::= "Array::cast(result)->_initialize_no_write_barrier(length, filler);"
MARK ::= "GcMetadata::insert_into_remembered_set(address);"

main args:
  if args.size != 4 or (args[0] != "prepare" and args[0] != "verdict"):
    pipe.print-to-stderr "usage: array_allocation.toit prepare MODE SRC DIR | verdict MODE OUTPUT STATUS"
    exit 2
  mode := args[1]
  if not MODES.contains mode: error "unknown mode $mode"
  if args[0] == "prepare":
    prepare mode args[2] args[3]
  else:
    status := int.parse args[3] --if-error=: error "the status $args[3] is not an integer"
    if not verdict mode (read-utf8 args[2]) status: exit 1

prepare mode/string src/string dir/string -> none:
  source := read-utf8 (fs.join src "heap.cc")
  if (count source CALL) != 1: error "expected one array initialization call in heap.cc"
  filler := "filler"
  if mode == "young-filler": filler = "old_requests ? filler : nullptr"
  if mode == "old-filler": filler = "old_requests ? nullptr : filler"
  summary := "checked_array_init(Array::cast(result), length, $filler);"
  spaces := read-utf8 (fs.join src "third_party" "dartino" "two_space_heap.cc")
  if mode == "unmarked-old":
    if (count spaces MARK) != 1: error "expected one direct old-space allocation card mark"
    spaces = spaces.replace --all MARK ""
  model := fs.join (fs.dirname system.program-path) ".." "cxx" "annotated" "model"
  constants := [
    ["objects.render", "MAX_OBJECT_WORDS"],
    ["constants.h", "LAYOUT_ARRAY_LENGTH_WORD"],
    ["constants.h", "LAYOUT_ARRAY_ELEMENTS_WORD"],
  ].map: | entry | definition (read-utf8 (fs.join model entry[0])) entry[1]
  file.write-contents --path=(fs.join dir "process_array_heap.inc")
      (source.replace --all CALL summary) + (constants.join "\n") + "\n"
  file.write-contents --path=(fs.join dir "process_array_spaces.inc") spaces

/**
Whether ESBMC's $output (\r\n and \r are read as newlines) and exit $status
  are the expected verdict of $mode.
*/
verdict mode/string output/string status/int -> bool:
  output = (output.replace --all "\r\n" "\n").replace --all "\r" "\n"
  if mode == "proof":
    return status == 0 and output.contains "VERIFICATION SUCCESSFUL"
  // The text of the first violated property, up to the next blank line.
  violation := ""
  at := output.index-of "Violated property:"
  if at >= 0:
    violation = output[at + "Violated property:".size..]
    end := violation.index-of "\n\n"
    if end >= 0: violation = violation[..end]
  expected := mode == "unmarked-old"
      ? "the old array is remembered before any filler store"
      : "return the supplied filler"
  return output.contains "VERIFICATION FAILED" and violation.contains expected

/**
The line `#define NAME VALUE` of $text, where VALUE is a decimal or
  hexadecimal (0x) literal; it must occur exactly once.
*/
definition text/string name/string -> string:
  prefix := "#define $name "
  found := text.split "\n" --drop-empty=false
  found = found.filter: | line |
    line.starts-with prefix and (is-literal line[prefix.size..])
  if found.size != 1: error "expected one definition of $name, found $found.size"
  return found[0]

is-literal value/string -> bool:
  if value.starts-with "0x" and value.size > 2:
    return value[2..].to-byte-array.every: is-hex-digit it
  return value.size > 0 and (value.to-byte-array.every: '0' <= it <= '9')

is-hex-digit c/int -> bool:
  return '0' <= c <= '9' or 'a' <= c <= 'f' or 'A' <= c <= 'F'

/** The number of non-overlapping occurrences of $needle in $text. */
count text/string needle/string -> int:
  n := 0
  at := text.index-of needle
  while at >= 0:
    n++
    at = text.index-of needle (at + needle.size)
  return n

/** The contents of the file $path; throws when it is not valid UTF-8. */
read-utf8 path/string -> string:
  return (file.read-contents path).to-string

error message/string -> none:
  pipe.print-to-stderr "array_allocation: $message"
  exit 1
