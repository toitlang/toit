// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.esp32
import ble.experimental.service.mixed-provider as mixed
import ble.experimental.service.provider as rpc
import ble.experimental.transport
import monitor
import system
import system.containers
import .bounded-radio as radio-fixture
import .mixed-service-client as fixture

main:
  [false, true].do: | peripheral-first/bool |
    with-timeout --ms=160_000: run peripheral-first
  print "MIXED_PROVIDER COMPLETE rounds=2"

run peripheral-first/bool provider/Provider=(Provider) --peer-reads/int=200 --central-peer/ByteArray?=null:
  provider.install
  central/containers.Container? := null
  peripheral/containers.Container? := null
  retained := ByteArray 64 --initial=42
  before := system.process-stats
  collector := task --background::
    while true:
      sleep --ms=500
      system.process-stats --gc
      retained.do: if it != 42: throw "MIXED_PROVIDER_RETAINED_VALUE_CHANGED"
  try:
    print "MIXED_PROVIDER ROUND peripheral-first=$peripheral-first"
    if peripheral-first:
      peripheral = start "mixed-periph" [0]
      provider.wait 1
      central = start "mixed-central" (central-peer ? [central-peer] : [])
    else:
      central = start "mixed-central" (central-peer ? [central-peer] : [])
      provider.wait 0
      peripheral = start "mixed-periph" [0]
    provider.wait 4
    if peripheral.wait != 0: throw "MIXED_PERIPHERAL_EXIT"
    peripheral.close
    peripheral = start "mixed-periph" [1]
    provider.wait 8
    if peripheral.wait != 0: throw "MIXED_PERIPHERAL_EXIT"
    if central.wait != 0: throw "MIXED_CENTRAL_EXIT"
    if provider.opens != 1 or provider.radio.closes != 1: throw "MIXED_CONTROLLER_LIFETIME"
    if provider.radio.read-requests != peer-reads or not provider.radio.command-errors.is-empty:
      throw "MIXED_RADIO_COUNTS"
    after := system.process-stats --gc
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 2: throw "MIXED_PROVIDER_GC_COUNT"
    print "MIXED_PROVIDER ROUND_COMPLETE peripheral-first=$peripheral-first opens=1 closes=1 peer-reads=$peer-reads full-gcs=$gcs"
  finally:
    collector.cancel
    if peripheral: peripheral.close
    if central: central.close
    provider.uninstall

start name/string arguments/List -> containers.Container:
  images := containers.images.filter: it.name == name
  if images.size != 1: throw "MIXED_CONTAINER_IMAGE_MISSING"
  return containers.start images.first.id arguments

class Radio extends radio-fixture.ObservedTransport:
  closes/int := 0
  constructor: super (esp32.Esp32Transport)
  close -> none:
    closes++
    super

class Provider extends mixed.Provider:
  events/List ::= List 9
  opens/int := 0
  radio/Radio? := null
  last-peripheral/rpc.Session? := null

  constructor:
    super
    events.size.repeat: events[it] = monitor.Latch

  open-transport -> transport.Transport:
    opens++
    radio = Radio
    return radio

  create-builder client/int name/string -> rpc.Session:
    last-peripheral = super client name
    return last-peripheral

  create-bounded-builder client/int name/string value-limit/int mtu-limit/int -> rpc.Session:
    last-peripheral = super client name value-limit mtu-limit
    return last-peripheral

  wait event/int:
    (events[event] as monitor.Latch).get

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == fixture.SIGNAL or index == fixture.WAIT:
      event/int := arguments
      if not 0 <= event < events.size: throw "INVALID_ARGUMENT"
      if index == fixture.WAIT: return wait event
      if event == 3 or event == 7:
        with-timeout --ms=4_000:
          while not last-peripheral.is-released: sleep --ms=1
      (events[event] as monitor.Latch).set true
      return null
    return super index arguments --gid=gid --client=client
