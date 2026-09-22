// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.transport
import monitor
import system

main:
  with-timeout --ms=300_000: run

run radio/transport.Transport=(esp32.Esp32Transport):
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    database := attributes.Database.with-defaults --name="Toit HCI"
    database.add-service #[0xf0, 0xff]
    value := database.add-characteristic #[0xf2, 0xff] --read --authenticated --value="Toit HCI".to-byte-array
    if value != 12: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
    2.repeat: | cycle/int |
      print "MIXED_SECURE_PEER READY cycle=$cycle"
      link := host.accept #[2, 1, 6] --timeout=(Duration --s=100)
      pairing := security.Pairing host link --local-address=info.address
          --io-capability=1
          --require-authentication
      server := gatt.Server host link database --pairing=pairing
      ended := monitor.Latch
      worker := task::
        error := catch: server.serve: unreachable
        ended.set (error or true) --exception=(error != null)
      try:
        pairing.run: | number/int |
          print "MIXED_SECURE_PEER NUMERIC cycle=$cycle value=$number fixture-approval=true"
          true
        if not pairing.encrypted or not pairing.authenticated: throw "MIXED_SECURITY_NOT_READY"
        system.process-stats --gc
        print "MIXED_SECURE_PEER SECURED cycle=$cycle encrypted=true authenticated=true"
        ended.get
        print "MIXED_SECURE_PEER CYCLE_COMPLETE cycle=$cycle"
      finally:
        worker.cancel
        server.close
    print "MIXED_SECURE_PEER COMPLETE cycles=2"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
