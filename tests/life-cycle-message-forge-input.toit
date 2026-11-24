// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The program of life-cycle-message-forge-test-compiler.toit: tries to send
// the TERMINATED and SPAWNED notices that only the VM may send, both to the
// system process and to itself.

main:
  self := Process.current.id
  [SYSTEM-TERMINATED_, SYSTEM-SPAWNED_].do: | type/int |
    [-1, self].do: | pid/int |
      exception := catch: process-send_ pid type 42
      print "$type $pid: $exception"
  // A forged TERMINATED notice that reached the system process stops the
  // program with the forged exit code. Give the system time to handle it.
  sleep --ms=200
  print "done"
