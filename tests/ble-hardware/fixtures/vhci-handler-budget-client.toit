// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt
import ble.experimental.hci
import encoding.hex
import .hci-echo as fixture

main:
  with-timeout --ms=30_000:
    controller := hci.Controller (esp32.Esp32Transport)
    host/central.Central? := null
    client/att.Client? := null
    try:
      info := hci.initialize controller
      host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
      link := host.connect (hex.decode "f412fac150fe").reverse --address-type=0
      client = att.Client host link
      service := fixture.find-uuid (gatt.services client) #[0xf0, 0xff]
      characteristics := gatt.characteristics client service
      input := fixture.find-uuid characteristics #[0xf1, 0xff]
      output := fixture.find-uuid characteristics #[0xf2, 0xff]
      if (client.read output.handle) != #[42]: throw "FIRST_READ_FAILED"
      client.write input.handle #[43]
      if (client.read output.handle) != #[43]: throw "WRITTEN_HOOK_FAILED"
      error := catch: client.read output.handle
      if error is not att.AttributeError or error.code != 0x0e: throw "EXPECTED_EXPIRED_READ"
      print "HANDLER_BUDGET_CLIENT EXPIRED att-error=14"
      if (client.read output.handle) != #[44]: throw "POST_EXPIRY_READ_FAILED"
      host.disconnect link
      print "HANDLER_BUDGET_CLIENT COMPLETE values=42,43,44 expired=1"
    finally:
      if client: client.close
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
