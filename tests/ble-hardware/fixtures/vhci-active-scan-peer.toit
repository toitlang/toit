// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as clients
import .vhci-advertising-provider show Provider

main: run

run --duration/Duration=(Duration --ms=15_000):
  if not 0 < duration.in-us <= 10_800_000_000: throw "INVALID_ARGUMENT"
  provider := Provider
  provider.install
  client := clients.Client
  client.open
  try:
    // The name exists only in the scan response, the service only in the AD.
    data := #[2, 1, 6, 3, 3, 0xf0, 0xff]
    response := #[11, 9, 'T', 'o', 'i', 't', 'A', 'c', 't', 'i', 'v', 'e']
    client.with-advertising data --scan-response=response --scannable --interval=80:
      print "ACTIVE_SCAN_PEER READY service=fff0 name=ToitActive"
      sleep duration
    print "ACTIVE_SCAN_PEER COMPLETE"
  finally:
    client.close
    provider.uninstall
