// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.api
import ble.experimental.service.provider as rpc
import ble.experimental.service.shared-host as shared
import expect show *
import monitor
import system
import .ble-connect-isolation-test as connect
import .ble-service-init-pressure-test as pressure
import .ble-service-mixed-test as mixed
import .ble-service-multiclient-test as wire

main:
  run-all

run-all --heap-size/int=(256 * 1024) --slot-count/int=16384:
  failures := 0
  96.repeat: | slack/int |
    if (with-timeout --ms=2_000: unused slack --heap-size=heap-size --slot-count=slot-count): failures++
  expect (0 < failures < 96)
  print "CENTRAL_START_PRESSURE COMPLETE failures=$failures workers=$(96 - failures)"
  with-timeout --ms=5_000: active --slot-count=slot-count

unused slack/int --heap-size/int=(256 * 1024) --slot-count/int=16384 -> bool:
  provider := Provider --slot-count=slot-count
  provider.slack = slack
  provider.pressurize = true
  set-max-heap-size_ heap-size
  session/rpc.Session? := null
  error := catch:
    session = provider.create-connection 1 [#[1, 2, 3, 4, 5, 6], 0, 1_000_000, 23]
  provider.slots.fill null
  system.process-stats --gc
  if error:
    expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
    expect-null session
  else:
    expect-throw "PROBE_OPEN_REACHED": session.invoke api.CENTRAL-READY []
    session.close
    while not session.is-released: sleep --ms=1
  count := 0
  provider.resources-do: count++
  expect (count <= 1)
  // Map removal may itself fail under exhaustion. After releasing ballast,
  // the provider's ordinary client cleanup must be able to finish removal.
  provider.resources-do: it.close
  remaining := 0
  provider.resources-do: remaining++
  expect-equals 0 remaining
  expect provider.retained.released
  prior := provider.retained
  provider.pressurize = false
  next := provider.reserve-shared-host
  expect (next != prior)
  next.release
  print "CENTRAL_START_PRESSURE slack=$slack failed=$(error != null) retried=$count resources=0 released=true"
  return error != null

active --slot-count/int=16384:
  provider := Provider --slot-count=slot-count
  provider.use-radio = true
  release := monitor.Latch
  survived := monitor.Latch
  survived-after := monitor.Latch
  done := monitor.Latch
  responder := task::
    radio := provider.radio
    mixed.initialize radio
    host := provider.ready.get
    mixed.peripheral radio
    release.get
    mixed.read-peripheral radio
    survived.set true
    connect.establish radio host 3 0x234 --extended-mode
    wire.sent radio 0x234 #[0x0a, 3, 0]
    wire.incoming radio 0x234 #[0x0b, 43]
    wire.disconnect radio 0x234
    mixed.read-peripheral radio
    survived-after.set true
    wire.disconnect radio 0x235
    done.set true
  survivor := provider.create-session 1
  try:
    survivor.invoke api.PEER []
    provider.pressurize = true
    error := catch: provider.create-connection 2 [#[2, 2, 3, 4, 5, 6], 1, 1_000_000, 23]
    provider.slots.fill null
    system.process-stats --gc
    expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
    // Retry failed constructor removal just as closing that client would.
    provider.resources-do: | resource/rpc.Session |
      if resource.owner-client == 2: resource.close
    count := 0
    provider.resources-do: count++
    expect-equals 1 count
    expect (not provider.retained.released)
    expect (not provider.radio.closed)
    release.set true
    survived.get
    provider.pressurize = false
    next := provider.create-connection 2 [#[3, 2, 3, 4, 5, 6], 1, 1_000_000, 23]
    next.invoke api.CENTRAL-READY []
    expect-equals [true, #[43]] (next.invoke api.CENTRAL-READ [3])
    next.invoke api.CENTRAL-STOP []
    next.close
    survived-after.get
    survivor.close
    done.get
    while not survivor.is-released: sleep --ms=1
    expect provider.retained.released
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
    print "CENTRAL_START_PRESSURE ACTIVE survivor=true replacement=true opens=1 closes=1"
  finally:
    provider.slots.fill null
    provider.resources-do: it.close
    responder.cancel

class Provider extends mixed.Provider:
  slots/List ::= ?
  retained/shared.Host? := null
  slack/int := 0
  pressurize/bool := false
  use-radio/bool := false

  constructor --slot-count/int=16384:
    slots = List slot-count
    super

  reserve-shared-host -> shared.Host:
    retained = super
    if not pressurize: return retained
    pressure.warm-stack 64
    filled := 0
    error := catch:
      while filled < slots.size:
        slots[filled] = ByteArray 8 --initial=42
        filled++
    if error != "OUT_OF_MEMORY" and error != "ALLOCATION_FAILED": throw "PRESSURE_NOT_REACHED"
    (min filled slack).repeat:
      filled--
      slots[filled] = null
    return retained

  open-transport -> mixed.Radio:
    if not use-radio: throw "PROBE_OPEN_REACHED"
    return super
