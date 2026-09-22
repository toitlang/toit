// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import ble.experimental.bond
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.smp-identity
import expect show *
import monitor
import .ble-hci-test as wire
import .ble-key-reply-test as keys
import .ble-hardware.central-fresh-bond as probe

main:
  with-timeout --ms=2_000:
    [false, true].do: | on-request/bool |
      [false, true].do: | disconnect/bool |
        [false, true].do: | authenticated/bool |
          [0x29, 0x2d].do:
            if not (disconnect and it == 0x2d and not authenticated):
              exercise disconnect on-request authenticated it
    [false, true].do: wait-cleanup it

exercise disconnect/bool on-request/bool authenticated/bool authreq/int:
  reject := authreq & 4 != 0 and not authenticated
  radio := GuardRadio
  host := central.Central (hci.Controller radio)
  candidate := bond.Candidate keys.KEY
      (smp-identity.Identity (ByteArray 16 --initial=1) probe.IDENTITY 1)
      (smp-identity.Identity (ByteArray 16 --initial=2) probe.PEER 0)
      --authenticated=authenticated
  entered := monitor.Latch
  done := monitor.Latch
  link/central.Link? := null
  owner/probe.DelayedResume? := null
  worker/Task? := null
  start := 0
  responder := task::
    wire.reply radio (hci.command-packet 0x2005 probe.IDENTITY) #[]
    wire.status-reply radio (hci.command-packet 0x200d
        (connection.create-parameters probe.PEER --address-type=0 --own-address-type=1))
    event := wire.connection-event.copy
    event[8] = 0
    event.replace 9 probe.PEER
    radio.received.add event
    entered.get
    sleep --ms=1
    expect-equals 2 radio.sent-count
    if disconnect:
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
      expect-equals 0x13 link.wait-disconnected
    owner.receive (ByteArray 2: it == 0 ? 0x0b : authreq)
    expect (not owner.encrypted and not owner.authenticated)
    if not disconnect and not reject:
      wire.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 keys.KEY))
      if not on-request: expect (Time.monotonic-us - start >= 50_000)
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
  try:
    link = host.connect probe.PEER --address-type=0 --local-random-address=probe.IDENTITY
    owner = probe.DelayedResume host link candidate 50 --on-request=on-request
    start = Time.monotonic-us
    worker = task:: done.set (catch: owner.run)
    entered.set true
    expected := disconnect ? "HCI_LINK_DISCONNECTED" : (reject ? "BLE_BOND_INSUFFICIENT_AUTHENTICATION" : null)
    expect-equals expected done.get
    expect-equals (reject ? 1 : 0) radio.rejections
    expect-equals (disconnect ? 2 : 3) radio.sent-count
    expect-equals (not disconnect and not reject) owner.encrypted
    expect-equals (not disconnect and not reject and authenticated) owner.authenticated
  finally:
    if worker: worker.cancel
    responder.cancel
    host.close
    host.wait-closed

class GuardRadio extends wire.FakeTransport:
  rejections/int := 0

  send packet/ByteArray -> none:
    if packet[0] == 2:
      expect-equals #[2, 0x34, 2, 6, 0, 2, 0, 6, 0, 5, 5] packet
      rejections++
    super packet

wait-cleanup cancel/bool:
  radio := wire.FakeTransport
  host := central.Central (hci.Controller radio)
  candidate := bond.Candidate keys.KEY
      (smp-identity.Identity (ByteArray 16 --initial=1) probe.IDENTITY 1)
      (smp-identity.Identity (ByteArray 16 --initial=2) probe.PEER 0)
      --no-authenticated
  entered := monitor.Latch
  ended := monitor.Latch
  worker/Task? := null
  responder := task::
    wire.reply radio (hci.command-packet 0x2005 probe.IDENTITY) #[]
    wire.status-reply radio (hci.command-packet 0x200d
        (connection.create-parameters probe.PEER --address-type=0 --own-address-type=1))
    event := wire.connection-event.copy
    event[8] = 0
    event.replace 9 probe.PEER
    radio.received.add event
  try:
    link := host.connect probe.PEER --address-type=0 --local-random-address=probe.IDENTITY
    owner := probe.DelayedResume host link candidate 1_000 --on-request
    if cancel:
      worker = task::
        try:
          entered.set true
          owner.run
        finally:
          critical-do --no-respect-deadline: ended.set true
      entered.get
      worker.cancel
      ended.get
    else:
      expect-throw "DEADLINE_EXCEEDED": owner.run --timeout=(Duration --ms=10)
    expect radio.closed
    expect (not link.connected and not owner.encrypted and not owner.authenticated)
    // Neither a missing request nor cancellation permits timer fallback.
    expect-equals 2 radio.sent-count
  finally:
    if worker: worker.cancel
    responder.cancel
    host.close
    host.wait-closed
