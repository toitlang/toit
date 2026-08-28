// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net.wifi
import encoding.tison
import system.assets

connection/wifi.Client? := null
payload/ByteArray? := null

main:
  encoded/ByteArray := assets.decode["config"]
  config/Map := tison.decode encoded
  use-wifi/bool := config.get "use-wifi" --if-absent=: false

  // Keep a small, identical application payload alive in both comparisons.
  payload = ByteArray 1_024: (it * 17 + 23) & 0xff

  if use-wifi:
    connection = wifi.open null
    print "JAGUAR-MEMORY-PROBE-WIFI-READY"
  else:
    print "JAGUAR-MEMORY-PROBE-NO-WIFI-READY"

  while true:
    sleep --ms=1_000
