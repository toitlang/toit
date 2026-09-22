// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import expect show *
import system

// Runs in a dedicated process: the managed heap limit applies to this fixture.
main:
  slots := List 4096
  database := server.Database --value-limit=512 --mtu-limit=247
  database.add-service #[0xf0, 0xff]
  handle := database.add-characteristic #[0xf1, 0xff] --read --write --value=#[7]
  prepare := ByteArray 205 --initial=42
  prepare[0] = 0x16
  prepare[1] = handle
  prepare[2] = 0
  prepare[3] = 0
  prepare[4] = 0
  execute := #[0x18, 1]
  negotiate := #[2, 247, 0]
  expected := prepare.copy
  expected[0] = 0x17
  set-max-heap-size_ (256 * 1024)
  failures := 0
  opened := 0
  with-timeout --ms=60_000:
    64.repeat: | trial/int |
      session := database.session
      session.request negotiate
      session.response-sent
      filled := 0
      failure := catch:
        while filled < slots.size:
          slots[filled] = ByteArray 64 --initial=42
          filled++
      if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
        throw "PRESSURE_NOT_REACHED"
      (trial + 1).repeat: slots[filled - 1 - it] = null
      response/ByteArray? := null
      error := catch: response = session.request prepare
      slots.fill null
      system.process-stats --gc
      if error:
        if error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
        failures++
        session.request execute
        if (database.value handle) != #[7]: throw "FAILED_PREPARE_RETAINED"
        session.writes-do: | _ _ | throw "FAILED_PREPARE_CALLBACK"
      else:
        expect-equals expected response
        expect-equals #[7] (database.value handle)
        expect-equals #[0x19] (session.request #[0x18, 0])
        opened++
      // Every pressure attempt must leave this same session usable.
      expect-equals expected (session.request prepare)
      expect-equals #[0x19] (session.request execute)
      expect-equals prepare[5..] (database.value handle)
      writes := 0
      session.writes-do: | written/int value/ByteArray |
        expect-equals handle written
        expect-equals prepare[5..] value
        writes++
      expect-equals 1 writes
      session.close
      database.set-value handle #[7]
      print "ATTRIBUTE_WRITE_PRESSURE ROUND trial=$trial error=$error"
    if failures == 0 or opened == 0: throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "ATTRIBUTE_WRITE_PRESSURE COMPLETE failures=$failures accepted=$opened"
