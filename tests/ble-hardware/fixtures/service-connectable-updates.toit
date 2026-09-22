// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble
import ble.experimental.service.client as service

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    session := client.configure --name="Toit counter"
    session.add-service #[0xf0, 0xff]
    counter := session.add-characteristic #[0xf1, 0xff] --read --value=#[0]
    session.start (advertisement 0).to-raw
    for value := 1; value <= 10; value++:
      sleep --ms=1_000
      if not (session.update-advertising (advertisement value).to-raw): break
      session.set-value counter #[value]
    print "Peer: $session.peer"
    session.serve
        (: | _ | unreachable)
        (: | _ | unreachable)
        (: | _ _ | unreachable)
  finally:
    client.close

advertisement counter/int -> ble.Advertisement:
  return ble.Advertisement --name="Toit counter"
      --manufacturer-specific=#[0xff, 0xff, counter]
