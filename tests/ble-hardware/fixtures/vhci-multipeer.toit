// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt
import ble.experimental.hci
import encoding.hex
import monitor
import system

import .hci-echo as fixture
import .vhci-central-provider as diagnostics

// Public Bluetooth addresses of the two lab peripherals; see board-matrix.md.
main:
  with-timeout --ms=60_000:
    run (hex.decode "98cdac63762e").reverse (hex.decode "84f703a00b3a").reverse

run first/ByteArray second/ByteArray --check-delay/bool=false --receive-acl-packets/int=0
    --trace/bool=false --reconnect-first/bool=false:
  radio := esp32.Esp32Transport
  controller := hci.Controller (trace ? (diagnostics.Diagnostics radio) : radio)
  host/central.Central? := null
  clients := []
  try:
    info := hci.initialize controller --receive-acl-packets=receive-acl-packets
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --link-limit=2
    links := []
    inputs := []
    echoes := []
    [first, second].do: | address/ByteArray |
      link := host.connect address --address-type=0
      links.add link
      client := att.Client host link
      clients.add client
      service/gatt.Service := fixture.find-uuid (gatt.services client)
          (fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001")
      characteristics := gatt.characteristics client service
      inputs.add (fixture.find-uuid characteristics (fixture.wire-uuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001"))
      echoes.add (fixture.find-uuid characteristics (fixture.wire-uuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001"))
      if (client.read echoes.last.handle) != #[0x70, 0x17]: throw "INITIAL_VALUE_MISMATCH"
    if links[0].info.handle == links[1].info.handle: throw "DUPLICATE_LINK_HANDLE"
    print "MULTIPEER CONNECTED handles=$(links[0].info.handle),$(links[1].info.handle)"
    before := system.process-stats --gc
    retained := []
    extra := 0
    gatt.with-notifications clients[1] echoes[1]: | b/att.Subscription |
      gatt.with-notifications clients[0] echoes[0]: | a/att.Subscription |
        if check-delay:
          check-isolation clients[0] echoes[0].handle a clients[1] inputs[1].handle b
          extra = 3
        100.repeat: | sequence/int |
          if not links[0].connected or not links[1].connected: throw "EARLY_DISCONNECT"
          value-a := exchange clients[0] inputs[0].handle a sequence
          value-b := exchange clients[1] inputs[1].handle b (1000 + extra + sequence)
          if sequence % 25 == 0:
            retained.add [sequence, value-a]
            retained.add [1000 + extra + sequence, value-b]
          if sequence % 10 == 9:
            check-retained retained
            print "MULTIPEER BOTH count=$(sequence + 1)"
        if a.dropped != 0: throw "NOTIFICATION_OVERFLOW"
      if (clients[0].read echoes[0].handle) != (fixture.payload 99): throw "FIRST_READBACK_MISMATCH"
      host.disconnect links[0]
      if links[0].connected or not links[1].connected: throw "DISCONNECT_NOT_ISOLATED"
      print "MULTIPEER FIRST_DISCONNECTED survivor=$(links[1].info.handle)"
      if reconnect-first:
        replacement := host.connect first --address-type=0
        if replacement.info.handle != links[0].info.handle: throw "EXPECTED_REUSED_HANDLE"
        if not links[1].connected: throw "SURVIVOR_DISCONNECTED"
        print "MULTIPEER REUSED_HANDLE handle=$(replacement.info.handle) survivor=$(links[1].info.handle)"
        client := att.Client host replacement
        clients.add client
        service := fixture.find-uuid (gatt.services client)
            fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
        characteristics := gatt.characteristics client service
        input := fixture.find-uuid characteristics
            fixture.wire-uuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001"
        echo := fixture.find-uuid characteristics
            fixture.wire-uuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001"
        if (client.read echo.handle) != #[0x70, 0x17]: throw "REPLACEMENT_INITIAL_VALUE_MISMATCH"
        gatt.with-notifications client echo: | a/att.Subscription |
          if check-delay:
            check-isolation client echo.handle a clients[1] inputs[1].handle b
                --sequence-base=(1100 + extra)
            extra += 3
          100.repeat: | sequence/int |
            value-a := exchange client input.handle a sequence
            value-b := exchange clients[1] inputs[1].handle b (1100 + extra + sequence)
            if sequence % 25 == 0:
              retained.add [sequence, value-a]
              retained.add [1100 + extra + sequence, value-b]
            if sequence % 10 == 9: check-retained retained
          if a.dropped != 0: throw "NOTIFICATION_OVERFLOW"
        extra += 100
        if (client.read echo.handle) != (fixture.payload 99): throw "REPLACEMENT_READBACK_MISMATCH"
        host.disconnect replacement
        if replacement.connected or not links[1].connected: throw "DISCONNECT_NOT_ISOLATED"
      20.repeat: | sequence/int |
        exchange clients[1] inputs[1].handle b (1100 + extra + sequence)
        if not links[1].connected: throw "SURVIVOR_DISCONNECTED"
        check-retained retained
      if b.dropped != 0: throw "NOTIFICATION_OVERFLOW"
    if (clients[1].read echoes[1].handle) != (fixture.payload (1119 + extra)): throw "SURVIVOR_READBACK_MISMATCH"
    host.disconnect links[1]
    after := system.process-stats --gc
    full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if full-gcs < 30: throw "GC_COUNT_DID_NOT_ADVANCE"
    if receive-acl-packets > 0:
      sample := radio.diagnostics
      if not sample or sample.fault: throw "MULTIPEER_NATIVE_QUEUE_FAULT"
      print "MULTIPEER RECEIVE_QUEUE credits=$receive-acl-packets high-water=$(sample.high-water) capacity=$(sample.capacity)"
    print "MULTIPEER COMPLETE first=$(reconnect-first ? 200 : 100) second=$(120 + extra) retained=$(retained.size) full-gcs=$full-gcs"
  finally:
    clients.do: it.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

// One task owns the outstanding read for the duration of this probe. The
// subscription blocks remain scoped in the caller and never escape into it.
check-isolation client/att.Client handle/int a/att.Subscription second/att.Client input/int b/att.Subscription
    --sequence-base/int=1000:
  finished := monitor.Latch
  done := false
  reader := task::
    result := client.read handle
    done = true
    finished.set result
  try:
    marker := with-timeout --ms=3_000: a.receive
    if marker != #[0x70, 0x17]: throw "DELAY_MARKER_MISMATCH"
    if done: throw "DELAY_ALREADY_FINISHED"
    3.repeat: | sequence/int |
      exchange second input b (sequence-base + sequence)
      if done: throw "OTHER_LINK_DID_NOT_PROGRESS_DURING_DELAY"
    print "MULTIPEER DELAY_PROGRESS echoes=3 read-pending=true"
    if (with-timeout --ms=3_000: finished.get) != #[0x70, 0x17]: throw "DELAY_READ_MISMATCH"
  finally:
    reader.cancel

exchange client/att.Client handle/int subscription/att.Subscription sequence/int -> ByteArray:
  expected := fixture.payload sequence
  client.write handle expected
  value := with-timeout --ms=3_000: subscription.receive
  if value != expected: throw "MULTIPEER_ECHO_MISMATCH"
  return value

check-retained retained/List:
  system.process-stats --gc
  retained.do: | sample/List |
    if sample[1] != (fixture.payload sample[0]): throw "RETAINED_VALUE_CHANGED"
