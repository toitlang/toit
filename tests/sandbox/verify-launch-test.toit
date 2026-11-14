// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that programs launched as untrusted containers are always verified
// with the untrusted rules, independent of -Xverify/TOIT_VERIFY, and that a
// program the VM refuses never runs:
// - an untrusted snapshot that uses deep sleep (HALT 2) is rejected at launch,
// - an untrusted snapshot with a corrupted branch is rejected at launch,
// while the unmodified program runs as an untrusted container.

import expect show *
import host.file
import .sandbox-util show *

// Opcode numbers, from src/bytecodes.h.
BRANCH ::= 81
BRANCH-IF-TRUE ::= 82
BRANCH-IF-FALSE ::= 83

// The programs print the marker before anything else, so it shows up in the
// output if they run at all. The sources build it from two parts, so that
// the marker itself is not part of the snapshot's strings.
MARKER ::= "PROGRAM-RAN"

VALID-PROGRAM ::= """
main:
  print "PROGRAM-" + "RAN"
  sum := 0
  10.repeat: sum += it
  print sum
"""

DEEP-SLEEP-PROGRAM ::= """
import esp32
main:
  print "PROGRAM-" + "RAN"
  esp32.deep-sleep (Duration --ms=10)
"""

run-untrusted run/string snap/string -> RunResult:
  return run-process [run, "--untrusted", snap] --timeout-ms=60_000

main args:
  run := args[0]
  compiler := args[1]

  with-tmp-directory: | dir |
    valid := "$dir/valid.snapshot"
    write-file "$dir/valid.toit" VALID-PROGRAM
    compile-snapshot compiler "$dir/valid.toit" valid

    // The unmodified program passes the verifier and runs.
    result := run-untrusted run valid
    expect-equals 0 result.exit-code
    expect (result.output.contains MARKER)
    expect (result.output.contains "45")

    // Deep sleep is rejected when the program is launched untrusted.
    sleep-snap := "$dir/deep-sleep.snapshot"
    write-file "$dir/deep-sleep.toit" DEEP-SLEEP-PROGRAM
    compile-snapshot compiler "$dir/deep-sleep.toit" sleep-snap
    result = run-untrusted run sleep-snap
    expect-refused result "VERIFICATION_FAILED"
    expect (result.output.contains "HALT 2")

    // A verifier-rejected program never runs.
    test-patched-branch run valid dir

    print "verify-launch-test OK"

expect-refused result/RunResult error/string -> none:
  if result.exit-code != 1 or not result.output.contains error or result.output.contains MARKER:
    print result.output
  expect-equals 1 result.exit-code
  expect (result.output.contains error)
  expect-not (result.output.contains MARKER)

// Sets the offset of a branch in the program to zero (which the verifier
// rejects) and checks that the patched program is refused before it prints
// anything.
test-patched-branch run/string snap/string dir/string -> none:
  bytecodes-file := "$dir/bytecodes.bin"
  result := run-process [run, "--verify", "-q", "--emit-bytecodes=$bytecodes-file", snap]
  expect-equals 0 result.exit-code
  bytecodes := file.read-contents bytecodes-file
  snapshot-bytes := file.read-contents snap
  blob-offset := find-bytecodes snapshot-bytes bytecodes
  expect blob-offset >= 0

  branch-bci := -1
  for i := 0; i < bytecodes.size - 3; i++:
    op := bytecodes[i]
    if op == BRANCH or op == BRANCH-IF-TRUE or op == BRANCH-IF-FALSE:
      offset := bytecodes[i + 1] | (bytecodes[i + 2] << 8)
      if offset != 0:
        branch-bci = i
        break
  expect branch-bci >= 0

  patched := snapshot-bytes.copy
  patched[blob-offset + branch-bci + 1] = 0
  patched[blob-offset + branch-bci + 2] = 0
  patched-snap := "$dir/patched.snapshot"
  file.write-contents patched --path=patched-snap

  result = run-untrusted run patched-snap
  expect-refused result "VERIFICATION_FAILED"
  expect (result.output.contains "zero offset")
