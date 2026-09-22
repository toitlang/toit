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
import ble.experimental.security
import .hci-echo as fixture

main:
  run (esp32.Esp32Transport) --overload
  run (esp32.Esp32Transport) --no-overload
  print "COMMAND_OVERLOAD_PEER COMPLETE"

run radio/transport.Transport --overload/bool --authenticated/bool=false:
  controller := hci.Controller radio
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    uuid := fixture.wire-uuid (overload ? "9f6c6300-8e2a-4b13-9e97-94f353eeb001" : "9f6c6400-8e2a-4b13-9e97-94f353eeb001")
    peer/advertising.Report? := null
    with-timeout --ms=10_000:
      scanning.scan controller: | report/advertising.Report |
        if not (report.has-service uuid): continue.scan true
        peer = report
        false
    link := host.connect peer.address --address-type=peer.address-type
    pairing/security.Pairing? := null
    if authenticated:
      pairing = security.Pairing host link --local-address=info.address --io-capability=1 --require-authentication
    client = att.Client host link --pairing=pairing
    if pairing:
      pairing.run: | number/int |
        print "COMMAND_OVERLOAD_PEER NUMERIC value=$number fixture-approval=true"
        true
      if not pairing.encrypted or not pairing.authenticated: throw "EXPECTED_AUTHENTICATED_SECURITY"
      print "COMMAND_OVERLOAD_PEER AUTHENTICATED encrypted=true authenticated=true"
    service := fixture.find-uuid (gatt.services client) uuid
    value := fixture.find-uuid (gatt.characteristics client service)
        fixture.wire-uuid "9f6c6201-8e2a-4b13-9e97-94f353eeb001"
    if (value.properties & 0x0c) != 4: throw "EXPECTED_COMMAND_ONLY"
    if (client.read value.handle) != #[7]: throw "INITIAL_VALUE_MISMATCH"
    started := Time.monotonic-us
    if overload:
      submitted := 0
      error := catch:
        with-timeout --ms=15_000:
          256.repeat: | index/int |
            client.write-command value.handle (fixture.payload index)
            submitted++
          client.read value.handle
      if error == DEADLINE-EXCEEDED-ERROR:
        // The send's three-second deadline precedes four-second supervision.
        // Require its explicit abort and completed local cleanup, not merely
        // an arbitrary timeout or an assumption about remote delivery.
        cause := catch: with-timeout --ms=3_000: link.wait-disconnected
        if cause != "HCI_ACL_SEND_ABORTED" or link.connected:
          throw "EXPECTED_SEND_ABORT: $cause"
        host.wait-closed
        if not 0 < submitted < 256: throw "EXPECTED_PARTIAL_SUBMISSION"
        print "COMMAND_OVERLOAD_PEER ABORTED cause=$cause submitted=$submitted elapsed-us=$(Time.monotonic-us - started)"
      else:
        if error != "HCI_LINK_DISCONNECTED": throw "EXPECTED_OVERLOAD_DISCONNECT: $error"
        print "COMMAND_OVERLOAD_PEER DISCONNECTED error=$error"
      return
    8.repeat: | burst/int |
      8.repeat: | index/int |
        client.write-command value.handle (fixture.payload (burst * 8 + index))
      if (client.read value.handle) != (fixture.payload (burst * 8 + 7)):
        throw "COMMAND_BURST_READBACK_MISMATCH"
    host.disconnect link
    print "COMMAND_OVERLOAD_PEER RECOVERED sent=64 bursts=8 exact=true elapsed-us=$(Time.monotonic-us - started)"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
