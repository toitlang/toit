// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import encoding.hex
import io
import system
import ble.experimental.security-state show SecurityState

class Evidence implements SecurityState:
  paired/bool := false
  encrypted/bool := false
  authenticated/bool := false

// Pipe-only permission evidence. This does not perform pairing or encryption.
main:
  database := server.Database --value-limit=512 --mtu-limit=517
  database.add-service #[0xf0, 0xff]
  value := database.add-characteristic #[0xf1, 0xff] --read
  database.add-descriptor value #[0xf2, 0xff] --write --encrypted --value=#[7]
  database.add-descriptor value #[0xf3, 0xff] --write --authenticated --value=#[7]
  database.add-descriptor value #[1, 0x29] --write --authenticated --value=#[65]
  evidence := Evidence
  session := database.session --security=evidence
  try:
    while line := io.stdin.read-line:
      if line.starts-with "@security ":
        state := int.parse line[10..]
        if not 0 <= state <= 2: throw "INVALID_ARGUMENT"
        evidence.paired = state > 0
        evidence.encrypted = state > 0
        evidence.authenticated = state == 2
        print "@security $state"
        continue
      packet := hex.decode line
      if packet.size > 517: throw "ATT_FIXTURE_OVERSIZE"
      response := session.request packet
      packet.fill 0
      system.process-stats --gc
      print (response ? (hex.encode response) : "-")
      session.response-sent
      session.writes-do: | _ _ | null
  finally:
    session.close
