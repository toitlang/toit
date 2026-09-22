// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.scanning
import system
import .hci-echo as fixture

main:
  run

run --local-close/bool=false --update-parameters/bool=false:
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  client/att.Client? := null
  before := system.process-stats --gc
  received := 0
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count --receive-limit=517
        --link-limit=(local-close ? 2 : 1)
    uuid := fixture.wire-uuid "9f6c3000-8e2a-4b13-9e97-94f353eeb001"
    peer/advertising.Report? := null
    with-timeout --ms=15_000:
      scanning.scan controller: | report/advertising.Report |
        if report.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8] or not (report.has-service uuid):
          continue.scan true
        peer = report
        false
    link := host.connect peer.address --address-type=peer.address-type
    client = att.Client host link --mtu-limit=517
    if client.exchange-mtu != 517: throw "UNEXPECTED_NEGOTIATED_MTU"
    if update-parameters:
      applied := host.update-parameters link --interval-min=12 --interval-max=12
      if applied.interval != 12 or applied.latency != 0 or applied.supervision-timeout != 400:
        throw "UNEXPECTED_APPLIED_PARAMETERS"
      print "VHCI_PARAMETER_UPDATE applied interval=$(applied.interval) latency=$(applied.latency) timeout=$(applied.supervision-timeout)"
    service := fixture.find-uuid (gatt.services client) uuid
    value := fixture.find-uuid (gatt.characteristics client service)
        fixture.wire-uuid "9f6c3001-8e2a-4b13-9e97-94f353eeb001"
    if value.properties & 0x30 != 0x20: throw "EXPECTED_INDICATION_ONLY"
    cccd := fixture.find-uuid (gatt.descriptors client value) #[2, 0x29]
    if (client.read value.handle) != #[0]: throw "UNEXPECTED_INITIAL_COUNT"
    retained := []
    client.subscribe value.handle --cccd=cccd.handle --indications: | stream/att.Subscription |
      100.repeat: | sequence/int |
        bytes/ByteArray := with-timeout --ms=10_000: stream.receive
        if bytes != (ByteArray 512: (sequence + it) % 251): throw "INDICATION_MISMATCH"
        if sequence % 10 == 0: retained.add bytes
        system.process-stats --gc
        received++
      with-timeout --ms=3_000:
        while (client.read value.handle) != #[100]: sleep --ms=1
    retained.size.repeat: | index/int |
      if retained[index] != (ByteArray 512: (index * 10 + it) % 251): throw "RETAINED_VALUE_CHANGED"
    if update-parameters:
      applied := host.update-parameters link --interval-min=40 --interval-max=40
      if applied.interval != 40: throw "UNEXPECTED_APPLIED_PARAMETERS"
      if (client.read value.handle) != #[100]: throw "POST_UPDATE_READ_FAILED"
      print "VHCI_PARAMETER_UPDATE COMPLETE updates=2 interval=$(applied.interval) post-update-read=true"
    if local-close:
      client.close
      client.wait-closed
      if link.connected: throw "LOCAL_CLOSE_STILL_CONNECTED"
      reason := link.wait-disconnected
      if (controller.command hci.READ-ADDRESS) != info.address: throw "POST_CLOSE_CONTROLLER_FAILED"
      print "VHCI_LOCAL_CLOSE COMPLETE link-limit=2 post-close-command=true reason=$reason"
    else:
      host.disconnect link
    print "VHCI_INDICATION_CLIENT received=$received mtu=$(client.mtu) retained=$(retained.size)"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if received != 100 or gcs < 100: throw "INDICATION_CLIENT_INCOMPLETE"
  print "VHCI_INDICATION_CLIENT COMPLETE received=$received full-gcs=$gcs"
