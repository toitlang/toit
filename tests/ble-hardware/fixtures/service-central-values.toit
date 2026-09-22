// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

// Runs against the authorized Linux BlueZ reference server in another process.
main: run

run --indications/bool=false --commands/bool=false
    --reference-address/ByteArray=#[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]:
  if indications and commands: throw "INVALID_ARGUMENT"
  if reference-address.size != 6: throw "INVALID_ARGUMENT"
  reference-address = reference-address.copy
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    if not client.capabilities.gatt-central: throw "CENTRAL_UNSUPPORTED"
    uuid := fixture.wire-uuid "9f6c3000-8e2a-4b13-9e97-94f353eeb001"
    value-uuid := fixture.wire-uuid "9f6c3001-8e2a-4b13-9e97-94f353eeb001"
    peer/service.ScanReport? := null
    client.scan --duration=(Duration --s=20) --service-uuid=uuid: | report/service.ScanReport |
      if report.address != reference-address or report.address-type != 0: continue.scan true
      peer = report
      false
    if not peer: throw "CENTRAL_REFERENCE_NOT_FOUND"
    client.with-connection peer.address --address-type=peer.address-type --mtu-limit=517: | connection/service.Connection |
      if connection.info[2] != 517: throw "UNEXPECTED_MTU"
      services := connection.database.discover-services
      found := services.filter: it.uuid == uuid
      if found.size != 1: throw "REFERENCE_SERVICE_NOT_FOUND"
      values := found[0].characteristics.filter: it.uuid == value-uuid
      if values.size != 1: throw "REFERENCE_VALUE_NOT_FOUND"
      characteristic/service.CharacteristicRecord := values[0]
      if commands and (characteristic.properties & 0x0c) != 0x04:
        throw "EXPECTED_COMMAND_ONLY_CHARACTERISTIC"
      if indications:
        receive-indications characteristic
        continue.with-connection
      if characteristic.read != #[7]: throw "INITIAL_VALUE_MISMATCH"
      retained/ByteArray? := null
      [(ByteArray 512: it % 251), #[]].do: | expected/ByteArray |
        if commands: characteristic.write-command expected
        else: characteristic.write expected
        actual := characteristic.read
        if actual != expected: throw "CENTRAL_VALUE_MISMATCH"
        if actual.size == 512: retained = actual
        system.process-stats --gc
        if actual != expected or retained != (ByteArray 512: it % 251): throw "RETAINED_VALUE_CHANGED"
        print "SERVICE_CENTRAL bytes=$(actual.size) exact=true mtu=517"
    print "SERVICE_CENTRAL COMPLETE indications=$indications commands=$commands retained=true disconnected=true"
  finally:
    client.close

receive-indications characteristic/service.CharacteristicRecord:
  if characteristic.read != #[0]: throw "INITIAL_COUNT_MISMATCH"
  before := system.process-stats --gc
  retained := []
  characteristic.subscribe --indications: | stream/service.Subscription |
    100.repeat: | sequence/int |
      value := with-timeout --ms=10_000: stream.receive
      if value != (ByteArray 512: (sequence + it) % 251): throw "INDICATION_MISMATCH"
      if sequence % 10 == 0: retained.add value
      system.process-stats --gc
    with-timeout --ms=3_000:
      while characteristic.read != #[100]: sleep --ms=1
  retained.size.repeat: | index/int |
    if retained[index] != (ByteArray 512: (index * 10 + it) % 251): throw "RETAINED_VALUE_CHANGED"
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if gcs < 100: throw "GC_FIXTURE_INCOMPLETE"
  print "SERVICE_CENTRAL_INDICATIONS received=100 bytes=512 mtu=517 retained=$(retained.size) full-gcs=$gcs unsubscribed=true"
