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
Checks the native array constructor (heap.cc) with ESBMC, using the
  verified initializer's postcondition in place of the initializer: the
  `process-array-allocation` jobs of verified/cxx/annotated/run.sh.

Usage: toit run array_allocation.toit -- MODE BITS SRC SCRATCH HARNESS ESBMC [FLAG]...

Writes, in a fresh directory under SCRATCH, `process_array_heap.inc` (SRC's
  heap.cc with its one array initialization call replaced by
  `checked_array_init`, plus the model's layout constants) and
  `process_array_spaces.inc` (SRC's third_party/dartino/two_space_heap.cc),
  runs ESBMC on HARNESS with them, prints ESBMC's output (stdout and stderr
  together) and exits with status 0 when the run has its expected verdict:
- `proof`: ESBMC exits with status 0 and reports VERIFICATION SUCCESSFUL.
- `young-filler`, `old-filler`: the filler is dropped for young (old)
  requests; ESBMC must report VERIFICATION FAILED with a violated property
  that mentions `return the supplied filler`.
- `unmarked-old`: the card mark of the direct old-space allocation is
  removed; the violated property must mention
  `the old array is remembered before any filler store`.
Otherwise exits with status 1, also when the call or the card mark no
  longer occurs exactly once (a change to the composition needs a new check)
  or a model constant is not defined exactly once.
*/

import fs
import host.directory
import host.file
import host.pipe
import io
import monitor
import system

MODES ::= ["proof", "young-filler", "old-filler", "unmarked-old"]

// Retain the actual arguments and receiver. Match the entire call so that a
// change to the composition requires a new check.
CALL ::= "Array::cast(result)->_initialize_no_write_barrier(length, filler);"
MARK ::= "GcMetadata::insert_into_remembered_set(address);"

main args:
  if args.size < 6:
    pipe.print-to-stderr "usage: array_allocation.toit MODE BITS SRC SCRATCH HARNESS ESBMC [FLAG]..."
    exit 2
  mode := args[0]
  bits := args[1]
  src := args[2]
  scratch := args[3]
  harness := args[4]
  esbmc := args[5]
  flags := args[6..]
  if not MODES.contains mode: error "unknown mode $mode"
  source := read-utf8 (fs.join src "heap.cc")
  if (count source CALL) != 1: error "expected one array initialization call in heap.cc"
  filler := "filler"
  if mode == "young-filler": filler = "old_requests ? filler : nullptr"
  if mode == "old-filler": filler = "old_requests ? nullptr : filler"
  summary := "checked_array_init(Array::cast(result), length, $filler);"
  space-dir := fs.join src "third_party" "dartino"
  spaces := read-utf8 (fs.join space-dir "two_space_heap.cc")
  if mode == "unmarked-old":
    if (count spaces MARK) != 1: error "expected one direct old-space allocation card mark"
    spaces = spaces.replace --all MARK ""
  model := fs.join (fs.dirname system.program-path) ".." "cxx" "annotated" "model"
  constants := [
    ["objects.render", "MAX_OBJECT_WORDS"],
    ["constants.h", "LAYOUT_ARRAY_LENGTH_WORD"],
    ["constants.h", "LAYOUT_ARRAY_ELEMENTS_WORD"],
  ].map: | entry | definition (read-utf8 (fs.join model entry[0])) entry[1]
  tmp := directory.mkdtemp "$scratch/array-allocation-"
  output/string := ""
  code/int := -1
  try:
    file.write-contents --path=(fs.join tmp "process_array_heap.inc")
        (source.replace --all CALL summary) + (constants.join "\n") + "\n"
    file.write-contents --path=(fs.join tmp "process_array_spaces.inc") spaces
    command := [esbmc, harness, "-I$tmp"] + flags
        + ["-I$space-dir", "--std", "c++11", "--$bits", "-DCXXV_WORD_BITS=$bits", "--overflow-check"]
    result := run-merged command
    code = result[0]
    output = result[1]
  finally:
    directory.rmdir --recursive tmp
  print output
  if mode != "proof":
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
    if not output.contains "VERIFICATION FAILED" or not violation.contains expected: exit 1
  else if code != 0 or not output.contains "VERIFICATION SUCCESSFUL":
    exit 1

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

/**
Runs $command with stdout and stderr in one pipe (in the order they are
  written, as `2>&1` does) and returns its exit status (128 + the signal
  for a signal) and its output with \r\n and \r read as newlines.
*/
run-merged command/List -> List:
  process := pipe.fork "/bin/sh" ["/bin/sh", "-c", "exec \"\$@\" 2>&1", "sh"] + command
      --create-stdout
  buffer := io.Buffer
  reader := process.stdout.in
  while chunk := reader.read: buffer.write chunk
  process.wait
  code := process.exit-signal ? 128 + process.exit-signal : process.exit-code
  output := buffer.bytes.to-string
  output = (output.replace --all "\r\n" "\n").replace --all "\r" "\n"
  return [code, output]

read-utf8 path/string -> string:
  return (file.read-contents path).to-string

error message/string -> none:
  pipe.print-to-stderr "array_allocation: $message"
  exit 1
