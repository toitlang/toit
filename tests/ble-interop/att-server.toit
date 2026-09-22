// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as server
import encoding.hex
import io
import system

// Test-only ATT bearer: one hexadecimal PDU per line, with GC on every request.
main args/List:
  if not args.is-empty and args != ["type-pages"]: throw "INVALID_ARGUMENT"
  database := server.Database --value-limit=512 --mtu-limit=517
  database.add-service #[0xf0, 0xff]
  handle := database.add-characteristic #[0xf1, 0xff] --read --write --notify --value=#[7]
  if args == ["type-pages"]:
    database.add-characteristic #[0xf1, 0xff] --read --write --value=#[8]
  session := database.session
  input := io.stdin
  try:
    while line := input.read-line:
      if line.starts-with "@notify ":
        database.set-value handle (hex.decode line[8..])
        notification := session.notification handle --no-truncate
        // The outgoing snapshot survives replacement of the stored value.
        database.set-value handle #[9]
        system.process-stats --gc
        if notification: print (hex.encode notification)
        print (notification ? "@sent" : "@suppressed")
        continue
      packet := hex.decode line
      if packet.size > 517: throw "ATT_FIXTURE_OVERSIZE"
      response := session.request packet
      packet.fill 0
      system.process-stats --gc
      print (response ? (hex.encode response) : "-")
      session.response-sent
  finally:
    session.close
