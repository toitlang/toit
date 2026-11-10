// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Helpers for the interpreter-hardening tests: compiling programs to
// snapshots, running them, and patching the bytecodes of a snapshot.

import host.directory
import host.file
import host.pipe

with-tmp-directory [block]:
  tmp-dir := directory.mkdtemp "/tmp/toit-sandbox-test-"
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive --force tmp-dir

/** The result of running a process: its merged output and raw exit value. */
class RunResult:
  output/string
  exit-value/int
  constructor .output .exit-value:

  exit-code -> int?: return pipe.exit-code exit-value
  exit-signal -> int?: return pipe.exit-signal exit-value

/**
Runs $args, capturing merged stdout+stderr. If $timeout-ms is given and the
  process does not exit in time, it is killed (and the result signal is set).
*/
run-process args/List --timeout-ms/int?=null -> RunResult:
  process := pipe.fork
      --use-path
      --create-stdout
      --create-stderr
      args[0]
      args
  stdout-bytes/ByteArray? := null
  stderr-bytes/ByteArray? := null
  exit-value/int := 0
  timed-out := false
  Task.group [
    :: stdout-bytes = process.stdout.in.read-all,
    :: stderr-bytes = process.stderr.in.read-all,
    ::
      if timeout-ms:
        exception := catch: with-timeout --ms=timeout-ms: exit-value = process.wait
        if exception:
          timed-out = true
          process.kill --wait --hard-after-ms=500
          exit-value = process.wait
      else:
        exit-value = process.wait,
  ]
  output := ""
  if stdout-bytes: output += stdout-bytes.to-string-non-throwing
  if stderr-bytes: output += stderr-bytes.to-string-non-throwing
  return RunResult output exit-value

/** Compiles $source to a snapshot at $out using the compiler at $compiler. */
compile-snapshot compiler/string source/string out/string -> none:
  result := run-process [compiler, "-w", out, source]
  if result.exit-code != 0:
    throw "compilation failed: $result.output"

/** Writes $content to a new file $path. */
write-file path/string content/string -> none:
  file.write-contents content --path=path

/**
Finds the offset of the bytecodes inside the snapshot $snapshot-bytes, given
  the raw $bytecodes of the program (as decoded by tools/snapshot.toit or
  emitted by `toit.run --verify --emit-bytecodes`).
Returns -1 if not found.
*/
find-bytecodes snapshot-bytes/ByteArray bytecodes/ByteArray -> int:
  if bytecodes.size == 0 or bytecodes.size > snapshot-bytes.size: return -1
  first := bytecodes[0]
  last-start := snapshot-bytes.size - bytecodes.size
  i := 0
  while i <= last-start:
    start := snapshot-bytes.index-of first --from=i --to=(last-start + 1)
    if start < 0: return -1
    matches := true
    for j := 1; j < bytecodes.size; j++:
      if snapshot-bytes[start + j] != bytecodes[j]:
        matches = false
        break
    if matches: return start
    i = start + 1
  return -1
