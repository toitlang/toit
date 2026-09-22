// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.attribute-server as server

main:
  with-timeout --ms=30_000:
    database := server.Database --value-limit=512
    database.add-service #[0xf0, 0xff]
    handle := database.add-characteristic #[0xf1, 0xff] --read --write --value=#[7]
    cycle database handle
    stats := system.process-stats --gc
    baseline := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    peak := baseline
    50.repeat:
      20.repeat: cycle database handle
      system.process-stats --gc stats
      peak = max peak stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    print "prepared-lifetime cycles=1000 baseline=$baseline peak=$peak"
    expect (peak <= baseline + 4096)

cycle database/server.Database handle/int:
  database.set-value handle #[7]
  first := database.session
  second := database.session
  try:
    // Fill the first session's prepared queue without committing. Its budget
    // and staged bytes must not be visible through the other session.
    29.repeat: | index/int |
      offset := index * 18
      payload := ByteArray (index == 28 ? 8 : 18) --initial=index
      packet := #[0x16, handle, 0, offset & 255, offset >> 8] + payload
      echo := packet.copy
      echo[0] = 0x17
      expect-equals echo (first.request packet)
    expect-equals #[1, 0x16, handle, 0, 9] (first.request #[0x16, handle, 0, 0, 0])
    expect-equals #[0x19] (second.request #[0x18, 1])
    expect-equals #[7] (database.value handle)
    first.close
    expect-throw "ATT_SERVER_CLOSED": first.request #[0x18, 1]
    first.writes-do: | _ _ | unreachable
    // The surviving session still has its full budget and can commit normally.
    expect-equals #[0x17, handle, 0, 0, 0, 99] (second.request #[0x16, handle, 0, 0, 0, 99])
    expect-equals #[0x19] (second.request #[0x18, 1])
    expect-equals #[99] (database.value handle)
    // Closure discards an accepted callback that has not yet been delivered.
    second.close
    second.writes-do: | _ _ | unreachable
    next := database.session
    try:
      expect-equals #[0x19] (next.request #[0x18, 1])
      next.writes-do: | _ _ | unreachable
      expect-equals #[99] (database.value handle)
    finally:
      next.close
  finally:
    first.close
    second.close
