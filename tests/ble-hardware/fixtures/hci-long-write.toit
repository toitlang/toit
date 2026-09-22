// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning
import ble.experimental.transport
import .hci-echo as fixture

main args/List:
  if not 1 <= args.size <= 2: throw "Usage: hci-long-write.toit <adapter index> [MTU limit]"
  mtu-limit := args.size == 2 ? (int.parse args[1]) : 23
  run (linux.LinuxTransport (int.parse args[0])) --mtu-limit=mtu-limit
      --exchange=(args.size == 2)
      --early-acl-timeout=(Duration --ms=20)

run radio/transport.Transport --mtu-limit/int=23 --exchange/bool=false
    --early-acl-timeout/Duration?=null:
  controller := hci.Controller radio
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=early-acl-timeout
        --receive-limit=(max 65 mtu-limit)
    uuid := fixture.wire-uuid "9f6c3000-8e2a-4b13-9e97-94f353eeb001"
    peer/advertising.Report? := null
    with-timeout --ms=10_000:
      scanning.scan controller: | report/advertising.Report |
        if not (report.has-service uuid): continue.scan true
        peer = report
        false
    link := host.connect peer.address --address-type=peer.address-type
    client = att.Client host link --mtu-limit=mtu-limit
    if exchange:
      if client.exchange-mtu != mtu-limit: throw "UNEXPECTED_NEGOTIATED_MTU"
      print "HCI_LONG_WRITE mtu=$(client.mtu)"
    service := fixture.find-uuid (gatt.services client) uuid
    value := fixture.find-uuid (gatt.characteristics client service)
        fixture.wire-uuid "9f6c3001-8e2a-4b13-9e97-94f353eeb001"
    if (client.read value.handle) != #[7]: throw "UNEXPECTED_INITIAL_VALUE"
    [(ByteArray 512: it % 251), #[]].do: | expected/ByteArray |
      client.write-long value.handle expected
      if (client.read-long value.handle) != expected: throw "LONG_WRITE_MISMATCH"
      print "HCI_LONG_WRITE bytes=$(expected.size) exact=true"
    host.disconnect link
    print "HCI_LONG_WRITE COMPLETE writes=2"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
