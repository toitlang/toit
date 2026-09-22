// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.signaling
import encoding.hex
import system

main:
  run

run --peripheral/bool=false:
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  before := system.process-stats --gc
  retained := []
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --accept-parameter-requests
    print "PEER_PARAMETERS READY peripheral=$peripheral"
    link := peripheral
        ? (host.accept #[2, 1, 6] --timeout=(Duration --s=60))
        : (host.connect (hex.decode "98cdac63762e").reverse --address-type=0)
    [12, 40].do: | interval/int |
      with-timeout --ms=35_000:
        if peripheral:
          host.send link 5 (signaling.parameter-request interval --interval=interval)
          response := link.receive
          if response.channel != 5 or response.payload != #[0x13, interval, 2, 0, 0, 0]:
            throw "PARAMETER_REQUEST_NOT_ACCEPTED"
        else:
          request := link.receive
          if request.channel != 5 or request.payload != (signaling.parameter-request interval --interval=interval):
            throw "UNEXPECTED_PARAMETER_REQUEST"
          host.handle-signaling link request.payload
        while link.parameters.interval != interval or link.peer-parameters-pending:
          if link.peer-parameter-error: throw link.peer-parameter-error
          sleep --ms=1
        if link.parameters.latency != 0 or link.parameters.supervision-timeout != 400:
          throw "UNEXPECTED_APPLIED_PARAMETERS"
        print "PEER_PARAMETERS APPLIED interval=$interval latency=0 timeout=400"
        20.repeat: | sequence/int |
          payload := #[0x0b, interval, sequence]
          if peripheral:
            request := link.receive
            if request.channel != 4 or request.payload != #[0x0a, 1, 0]: throw "UNEXPECTED_READ"
            host.send link 4 payload
          else:
            host.send link 4 #[0x0a, 1, 0]
            response := link.receive
            if response.channel != 4 or response.payload != payload: throw "PAYLOAD_MISMATCH"
            payload = response.payload
          if sequence == 0: retained.add payload
          system.process-stats --gc
    if peripheral:
      with-timeout --ms=5_000: link.wait-disconnected
    else:
      host.disconnect link
    if retained.size != 2 or retained[0] != #[0x0b, 12, 0] or retained[1] != #[0x0b, 40, 0]:
      throw "RETAINED_VALUE_CHANGED"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if gcs < 40: throw "GC_NOT_OBSERVED"
  print "PEER_PARAMETERS COMPLETE peripheral=$peripheral updates=2 reads=40 retained=2 full-gcs=$gcs"
