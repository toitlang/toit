// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.provider as rpc
import ble.experimental.transport
import monitor
import system
import system.containers
import .mixed-service-client as client-fixture
import .mixed-service-provider as fixture

main:
  with-timeout --ms=160_000: run

run --pending/bool=false:
  provider := Provider
  provider.install
  central/containers.Container? := null
  peripheral/containers.Container? := null
  retained := ByteArray 64 --initial=42
  collector := task --background::
    while true:
      sleep --ms=500
      system.process-stats --gc
      retained.do: if it != 42: throw "MIXED_PROVIDER_RETAINED_VALUE_CHANGED"
  try:
    peripheral = fixture.start "mixed-periph" []
    provider.wait 0
    2.repeat: | cycle/int |
      (pending ? [true, false] : [false]).do: | initiating/bool |
        radio := provider.radio as DiagnosticRadio
        radio.pending-start = initiating ? monitor.Latch : null
        central = fixture.start "mixed-central" [initiating ? -1 : cycle]
        if initiating: radio.pending-start.get
        else: provider.wait (cycle * 4 + 1)
        before := Time.monotonic-us
        if central.stop != 0: throw "MIXED_CENTRAL_STOP"
        with-timeout --ms=4_000:
          while not provider.last-central.is-released: sleep --ms=1
        if (provider.events[14] as monitor.Latch).has-value: throw "MIXED_DEATH_COOPERATIVE_CLEANUP"
        print "MIXED_CENTRAL_DEATH_PROVIDER KILLED cycle=$cycle initiating=$initiating cleanup-us=$(Time.monotonic-us - before)"
        central.close
        central = null
      provider.publish (cycle * 4 + 2)
      // Linux acknowledges only after100 more reads on its original link.
      provider.wait (cycle * 4 + 3)
    if peripheral.wait != 0: throw "MIXED_PERIPHERAL_EXIT"
    peripheral.close
    peripheral = null
    with-timeout --ms=4_000:
      while not provider.last-peripheral.is-released: sleep --ms=1
    if provider.opens != 1 or provider.radio.closes != 1: throw "MIXED_CONTROLLER_LIFETIME"
    if provider.radio.read-requests != 400 or not provider.radio.command-errors.is-empty:
      throw "MIXED_RADIO_COUNTS"
    radio := provider.radio as DiagnosticRadio
    if pending:
      print "MIXED_PENDING_DEATH COUNTS initiated=$(radio.initiations) cancel-replies=$(radio.cancellations) cancelled=$(radio.cancelled)"
    if pending and (radio.initiations != 4 or radio.cancellations != 2 or radio.cancelled != 2):
      throw "MIXED_INITIATION_COUNTS"
    print "MIXED_CENTRAL_DEATH_PROVIDER COMPLETE kills=$(pending ? 4 : 2) central-reads=200 peer-reads=400 opens=1 closes=1"
    if pending: print "MIXED_PENDING_DEATH COMPLETE initiated=4 cancel-replies=2 cancelled=2"
  finally:
    collector.cancel
    if central:
      if not central.is-closed: central.stop
      central.close
    if peripheral:
      if not peripheral.is-closed: peripheral.stop
      peripheral.close
    provider.uninstall

class Provider extends fixture.Provider:
  last-central/rpc.Session? := null

  constructor:
    super
    7.repeat: events.add monitor.Latch

  open-transport -> transport.Transport:
    opens++
    radio = DiagnosticRadio
    return radio

  create-connection client/int arguments/List -> rpc.Session:
    last-central = super client arguments
    return last-central

  publish event/int:
    (events[event] as monitor.Latch).set true

  handle index/int arguments/any --gid/int --client/int -> any:
    // Unlike the peripheral-death fixture, these acknowledgements require
    // the peripheral resource to remain alive.
    if index == client-fixture.SIGNAL:
      event/int := arguments
      if not 0 <= event < events.size: throw "INVALID_ARGUMENT"
      publish event
      return null
    return super index arguments --gid=gid --client=client

class DiagnosticRadio extends fixture.Radio:
  pending-start/monitor.Latch? := null
  initiations/int := 0
  cancellations/int := 0
  cancelled/int := 0

  receive -> ByteArray:
    packet := super
    if packet.size == 7 and packet[..3] == #[4, 15, 4] and packet[5..] == #[0x43, 0x20]:
      print "MIXED_RADIO INITIATION_STATUS $packet"
      if packet[3] != 0: throw "MIXED_INITIATION_STATUS"
      initiations++
      if pending-start and not pending-start.has-value: pending-start.set true
    if packet.size == 7 and packet[..3] == #[4, 14, 4] and packet[4..] == #[0x0e, 0x20, 0]:
      // Num_HCI_Command_Packets is controller credit, not a fixed value of one.
      print "MIXED_RADIO CANCEL_COMPLETE $packet"
      cancellations++
    if packet.size >= 5 and packet[..4] == #[4, 0x3e, 31, 0x0a] and packet[4] == 2:
      cancelled++
    // Record only connection completion/disconnection events, never key data.
    if packet.size >= 4 and packet[0] == 4 and
        (packet[1] == 5 or (packet[1] == 0x3e and packet[3] == 0x0a)):
      print "MIXED_RADIO LINK_EVENT $packet"
    return packet
