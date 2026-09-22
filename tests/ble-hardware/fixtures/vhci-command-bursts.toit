// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.esp32
import ble.experimental.scanning
import ble.experimental.transport
import .hci-echo as fixture

main: run (esp32.Esp32Transport)

run radio/transport.Transport:
  controller := hci.Controller radio
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    uuid := fixture.wire-uuid "9f6c6200-8e2a-4b13-9e97-94f353eeb001"
    peer/advertising.Report? := null
    with-timeout --ms=10_000:
      scanning.scan controller: | report/advertising.Report |
        if not (report.has-service uuid): continue.scan true
        peer = report
        false
    link := host.connect peer.address --address-type=peer.address-type
    client = att.Client host link
    service := fixture.find-uuid (gatt.services client) uuid
    value := fixture.find-uuid (gatt.characteristics client service)
        fixture.wire-uuid "9f6c6201-8e2a-4b13-9e97-94f353eeb001"
    if (value.properties & 0x0c) != 4: throw "EXPECTED_COMMAND_ONLY"
    if (client.read value.handle) != #[7]: throw "INITIAL_VALUE_MISMATCH"
    started := Time.monotonic-us
    64.repeat: | burst/int |
      8.repeat: | index/int |
        client.write-command value.handle (fixture.payload (burst * 8 + index))
      // The read follows the commands on the ATT bearer. It is an application
      // progress barrier, not an acknowledgement added to Write Command.
      if (client.read value.handle) != (fixture.payload (burst * 8 + 7)):
        throw "COMMAND_BURST_READBACK_MISMATCH"
    host.disconnect link
    print "COMMAND_BURSTS_PEER COMPLETE sent=512 bursts=64 exact=true elapsed-us=$(Time.monotonic-us - started)"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
