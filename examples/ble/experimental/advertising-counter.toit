// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble
import ble.experimental.service.client as service

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    initial := advertisement 0
    client.with-advertising initial.to-raw: | advertiser/service.Advertising |
      9.repeat: | index/int |
        sleep --ms=1_000
        next := advertisement (index + 1)
        advertiser.update next.to-raw
      sleep --ms=1_000
    // Scope exit stops advertising and closes its handle.
  finally:
    client.close

advertisement counter/int -> ble.Advertisement:
  return ble.Advertisement --name="Toit counter"
      --manufacturer-specific=#[0xff, 0xff, counter]
