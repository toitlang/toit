// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import expect show *
import system

main:
  [false, true].do: run --available=it

run --available/bool:
  slots := List 16384
  set-max-heap-size_ (256 * 1024)
  failures := 0
  completed := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      pool := acl.ControllerCredits 1
      account := acl.Credits 1 --pool=pool
      if not available: account.take
      filled := 0
      failure := catch:
        while filled < slots.size:
          slots[filled] = ByteArray 8 --initial=42
          filled++
      if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
        throw "PRESSURE_NOT_REACHED"
      (trial * 16).repeat: slots[filled - 1 - it] = null
      error := catch:
        with-timeout --ms=(available ? 100 : 10): account.take
      slots.fill null
      system.process-stats --gc
      if error == "ALLOCATION_FAILED" or error == "OUT_OF_MEMORY": failures++
      else if available and not error: completed++
      else if not available and error == DEADLINE-EXCEEDED-ERROR: completed++
      else: throw "UNEXPECTED_CREDIT_WAIT_RESULT $error"
      expect-equals 0 pool.waiting-count
      expected := available and error ? 0 : 1
      expect-equals expected pool.outstanding
      if expected != 0: account.complete 1
      with-timeout --ms=100: account.take
      expect-equals 1 pool.outstanding
      expect-equals 0 pool.waiting-count
      account.complete 1
      account.fail "DONE"
      expect-equals 0 pool.outstanding
      print "CREDIT_WAIT_PRESSURE ROUND available=$available trial=$trial error=$error"
    if failures == 0 or completed == 0: throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "CREDIT_WAIT_PRESSURE COMPLETE available=$available failures=$failures completed=$completed"
