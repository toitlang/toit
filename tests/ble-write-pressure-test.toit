// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import expect show *
import system

main arguments:
  modes := arguments.is-empty ? ["write", "command", "execute", "cccd", "cccd-execute"] : arguments
  set-max-heap-size_ (256 * 1024)
  with-timeout --ms=60_000:
    modes.do: run it

run mode/string --released-offset/int=1 --ballast-size/int=64:
  subscription := mode == "cccd" or mode == "cccd-execute"
  executing := mode == "execute" or mode == "cccd-execute"
  slots := List 4096
  database := server.Database --value-limit=512 --mtu-limit=247
  database.add-service #[0xf0, 0xff]
  value-handle := database.add-characteristic #[0xf1, 0xff] --read --write --write-command --notify=subscription --value=#[7]
  handle := subscription ? value-handle + 1 : value-handle
  write := subscription ? #[0x12, handle, 0, 1, 0] : (ByteArray 203 --initial=42)
  write[0] = mode == "command" ? 0x52 : 0x12
  write[1] = handle
  write[2] = 0
  prepare := #[0x16, handle, 0, 0, 0] + write[3..]
  execute := #[0x18, 1]
  request := executing ? execute : write
  failures := 0
  successes := 0
  64.repeat: | trial/int |
    session := database.session
    session.request #[2, 247, 0]
    session.response-sent
    enabled-before := subscription and trial % 2 == 1
    if subscription:
      // Alternate inserting a subscription and replacing an existing entry.
      write[3] = enabled-before ? 0 : 1
      prepare[5] = write[3]
      if enabled-before:
        expect-equals #[0x13] (session.request #[0x12, handle, 0, 1, 0])
        verify-write session database handle #[1, 0] --subscription
    if executing: session.request prepare
    filled := 0
    failure := catch:
      while filled < slots.size:
        slots[filled] = ByteArray ballast-size --initial=42
        filled++
    if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
      throw "PRESSURE_NOT_REACHED"
    (trial + released-offset).repeat: slots[filled - 1 - it] = null
    response/ByteArray? := null
    error := catch: response = session.request request
    slots.fill null
    system.process-stats --gc
    if error:
      if error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
      failures++
      if (database.value value-handle) != #[7]: throw "FAILED_WRITE_COMMITTED $mode $trial"
      if subscription:
        expect-equals enabled-before (session.subscribed value-handle)
        expect-equals (enabled-before ? #[0x1b, value-handle, 0, 7] : null)
            session.notification value-handle
      session.writes-do: | _ _ | throw "FAILED_WRITE_CALLBACK"
      // OOM may precede request dispatch, so explicitly cancel any pending
      // transaction before checking empty execution and subsequent recovery.
      expect-equals #[0x19] (session.request #[0x18, 0])
      expect-equals #[0x19] (session.request execute)
      expect-equals #[7] (database.value value-handle)
      if subscription: expect-equals enabled-before (session.subscribed value-handle)
    else:
      successes++
      expect-equals (mode == "command" ? null : (executing ? #[0x19] : #[0x13])) response
      verify-write session database handle write[3..] --subscription=subscription
    // A fresh transaction on this session must still commit exactly once.
    session.request prepare
    expect-equals #[0x19] (session.request execute)
    verify-write session database handle write[3..] --subscription=subscription
    session.close
    database.set-value value-handle #[7]
    print "WRITE_PRESSURE ROUND mode=$mode trial=$trial error=$error"
  if failures == 0 or successes == 0: throw "PRESSURE_BOUNDARY_NOT_COVERED"
  print "WRITE_PRESSURE COMPLETE mode=$mode failures=$failures successes=$successes"

verify-write session/server.Session database/server.Database handle/int expected/ByteArray --subscription/bool=false:
  if subscription:
    enabled := expected[0] == 1
    expect-equals enabled (session.subscribed (handle - 1))
    expect-equals #[7] (database.value (handle - 1))
    expect-equals (enabled ? #[0x1b, handle - 1, 0, 7] : null)
        session.notification (handle - 1)
  else:
    expect-equals expected (database.value handle)
  count := 0
  session.writes-do: | written/int value/ByteArray |
    expect-equals handle written
    expect-equals expected value
    count++
  expect-equals 1 count
