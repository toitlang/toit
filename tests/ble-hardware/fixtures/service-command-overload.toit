// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import monitor
import .hci-echo as fixture

main:
  run

run --expected-overflow/string="HCI_QUEUE_OVERFLOW"
    --peer-address/ByteArray=#[0x3a, 0x0b, 0xa0, 3, 0xf7, 0x84] --authenticated/bool=false
    --expect-canceled/bool=true:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    exercise client --overload --expected-overflow=expected-overflow --peer-address=peer-address
        --authenticated=authenticated
        --expect-canceled=expect-canceled
    exercise client --no-overload --expected-overflow=expected-overflow --peer-address=peer-address
        --authenticated=authenticated
    print "COMMAND_OVERLOAD_APP COMPLETE"
  finally:
    client.close

exercise client/service.Client --overload/bool --expected-overflow/string="HCI_QUEUE_OVERFLOW"
    --peer-address/ByteArray=#[0x3a, 0x0b, 0xa0, 3, 0xf7, 0x84] --authenticated/bool=false
    --expect-canceled/bool=true:
  session := client.configure --handler-timeout=(Duration --s=5)
  uuid := fixture.wire-uuid (overload ? "9f6c6300-8e2a-4b13-9e97-94f353eeb001" : "9f6c6400-8e2a-4b13-9e97-94f353eeb001")
  session.add-service uuid
  handle := session.add-characteristic (fixture.wire-uuid "9f6c6201-8e2a-4b13-9e97-94f353eeb001")
      --read
      --write-command
      --encrypted=authenticated
      --authenticated=authenticated
      --value=#[7]
  print "COMMAND_OVERLOAD_APP ADVERTISING overload=$overload"
  session.start (#[2, 1, 6, 17, 7] + uuid)
  print "COMMAND_BURSTS_APP READY"
  if session.peer != [peer-address, 0]: throw "WRONG_PEER"
  received := 0
  retained := []
  before := system.process-stats --gc
  started := Time.monotonic-us
  ended := monitor.Latch
  error := null
  worker := task::
    try:
      error = catch:
        session.serve
            (: | _ | unreachable)
            (: | _ | unreachable)
            (: | actual/int value/ByteArray |
              if actual != handle or value != (fixture.payload received): throw "COMMAND_SEQUENCE_MISMATCH"
              received++
              if overload and received == 1: sleep --ms=2_000
              retained.add value
              if retained.size > 4: retained.remove --at=0
              system.process-stats --gc
              retained.size.repeat: | index/int |
                if retained[index] != (fixture.payload (received - retained.size + index)):
                  throw "RETAINED_COMMAND_CHANGED")
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    ended.get
  finally:
    if not ended.has-value: worker.cancel
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if overload:
    print "COMMAND_OVERLOAD_APP TERMINATED canceled=$(worker.is-canceled) reason=$(session.termination-reason) received=$received"
    if worker.is-canceled != expect-canceled or session.termination-reason != expected-overflow:
      throw "EXPECTED_COMMAND_QUEUE_OVERFLOW: $(session.termination-reason)"
    error = session.termination-reason
    if received != 1: throw "UNEXPECTED_OVERLOAD_CALLBACK_COUNT"
    print "COMMAND_OVERLOAD_APP OVERFLOW error=$error received=$received"
  else:
    if error: throw error
    if received != 64 or gcs < received: throw "COMMAND_RECOVERY_INCOMPLETE"
    print "COMMAND_OVERLOAD_APP RECOVERED received=$received retained=$(retained.size) full-gcs=$gcs"
