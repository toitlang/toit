// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.acl
import ble.experimental.att
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-pairing as smp
import ble.experimental.smp-features show PairingError
import expect show *
import monitor
import system
import .ble-hci-test as fixture
import .ble-multilink-test as wire
import .ble-security-test as pairing-fixture

class DelayedTransport extends fixture.FakeTransport:
  armed/bool := false
  entered/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch

  send-if packet/ByteArray [allowed] -> bool:
    if armed and packet[0] == 2 and packet[1] == 0x34:
      armed = false
      entered.set true
      release.get
    return super packet allowed

main:
  with-timeout --ms=10_000:
    [false, true].do: | native-wait/bool |
      [false, true].do: | refresh/bool | lost --native-wait=native-wait --refresh=refresh
    invalid-public-key
    invalid-public-key --delayed-completion
    invalid-public-key --delayed-completion --no-complete

invalid-public-key --delayed-completion/bool=false --complete/bool=true:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  peer := smp.Session --no-initiator --io-capability=3 --no-require-authentication
      --local-address=#[1, 6, 5, 4, 3, 2, 1]
      --peer-address=#[0, 1, 2, 3, 4, 5, 6]
  first/att.Client? := null
  second/att.Client? := null
  replacement/att.Client? := null
  waiter/Task? := null
  pairing-worker/Task? := null
  pairing-result := monitor.Latch
  failure-submitted := monitor.Latch
  release-completion := monitor.Latch
  pairing-ended := false
  waiting := monitor.Latch
  notification-result := monitor.Latch
  done := monitor.Latch
  responder := task::
    wire.establish transport 1 0x234
    wire.establish transport 2 0x235
    reassembler := acl.Reassembler 0x234 --limit=65
    request := pairing-fixture.take-smp transport reassembler
    pairing-fixture.send-smp transport (peer.receive request)
    public := pairing-fixture.take-smp transport reassembler
    expect-equals 65 public.size
    expect-equals 0x0c public[0]
    pairing-fixture.send-smp transport [#[0x0c] + (ByteArray 64)]
    // Reject the invalid point on the wire before aborting this link.
    if delayed-completion:
      packet := transport.sent.take.copy
      expect-equals 2 packet[0]
      packet[2] |= 0x20
      failed := reassembler.accept packet
      expect-equals 6 failed.channel
      expect-equals #[5, 0x0b] failed.payload
      failure-submitted.set true
      // A keeps its failure-packet credit while B exchanges an ATT request.
      expect-equals #[2, 0x35, 2, 7, 0, 3, 0, 4, 0, 0x0a, 1, 0] transport.sent.take
      wire.completed transport 0x235
      wire.incoming transport 0x235 #[2, 0, 4, 0, 0x0b, 41] --start
      release-completion.get
      if complete: wire.completed transport 0x234
    else:
      expect-equals #[5, 0x0b] (pairing-fixture.take-smp transport reassembler)
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    wire.ended transport 0x234
    expect-equals #[2, 0x35, 2, 7, 0, 3, 0, 4, 0, 0x0a, 1, 0] transport.sent.take
    wire.completed transport 0x235
    wire.incoming transport 0x235 #[2, 0, 4, 0, 0x0b, 42] --start
    wire.establish transport 3 0x236
    expect-equals #[2, 0x36, 2, 7, 0, 3, 0, 4, 0, 0x0a, 1, 0] transport.sent.take
    wire.completed transport 0x236
    wire.incoming transport 0x236 #[2, 0, 4, 0, 0x0b, 43] --start
    done.set true
  try:
    a := host.connect (wire.address 1) --address-type=1
    b := host.connect (wire.address 2) --address-type=1
    pairing := security.Pairing host a --local-address=#[6, 5, 4, 3, 2, 1]
        --io-capability=3
        --no-require-authentication
    first = att.Client host a --pairing=pairing
    second = att.Client host b
    waiter = task::
      waiting.set true
      error := catch: first.receive-notification
      notification-result.set error
    waiting.get
    pairing-worker = task::
      result := catch: pairing.run: unreachable
      pairing-ended = true
      pairing-result.set result
    if delayed-completion:
      failure-submitted.get
      expect-equals #[41] (second.read 1)
      expect (not pairing-ended and b.connected and not transport.closed)
      release-completion.set true
    error := pairing-result.get
    if complete:
      expect (error is PairingError)
      expect-equals 0x0b (error as PairingError).reason
    else:
      expect-equals DEADLINE-EXCEEDED-ERROR error
    expect-equals error notification-result.get
    expect (not a.connected and not a.encrypted)
    expect (not pairing.encrypted and not pairing.authenticated)
    expect-throw "SMP_IDENTITY_NOT_READY": pairing.peer-identity
    expect-throw "SMP_INVALID_STATE": pairing.run: unreachable
    system.process-stats --gc
    expect (b.connected and not transport.closed)
    expect-equals #[42] (second.read 1)
    c := host.connect (wire.address 3) --address-type=1
    replacement = att.Client host c
    expect-equals #[43] (replacement.read 1)
    done.get
    expect (b.connected and c.connected and not transport.closed)
  finally:
    if waiter: waiter.cancel
    if pairing-worker: pairing-worker.cancel
    if first: first.close
    if second: second.close
    if replacement: replacement.close
    responder.cancel
    peer.close
    host.close
    host.wait-closed

lost --native-wait/bool --refresh/bool:
  transport := DelayedTransport
  host := central.Central (hci.Controller transport) --link-limit=2 --acl-count=2
  sent := monitor.Latch
  queued := monitor.Latch
  send-result := monitor.Latch
  ended := monitor.Latch
  worker/Task? := null
  responder := task::
    wire.establish transport 1 0x234
    wire.establish transport 2 0x235
    if not native-wait:
      // Consume A's quota without returning its credit. The next PDU waits.
      expect-equals #[2, 0x34, 2, 5, 0, 1, 0, 4, 0, 1] transport.sent.take
      sent.set true
    fixture.status-reply transport #[1, 6, 4, 3, 0x34, 2, 0x13]
    wire.ended transport 0x234
    // No bytes from A's waiting PDU may appear before B's packet.
    expect-equals #[2, 0x35, 2, 5, 0, 1, 0, 4, 0, 3] transport.sent.take
    wire.completed transport 0x235
    ended.set true
  try:
    a := host.connect (wire.address 1) --address-type=1
    b := host.connect (wire.address 2) --address-type=1
    expect-throw "HCI_ENCRYPTION_NOT_ENABLED": a.require-encryption
    transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    while not a.encrypted: sleep --ms=1
    a.require-encryption
    // Successful refresh preserves the guard and the connection.
    transport.received.add #[4, 0x30, 3, 0, 0x34, 2]
    while not a.encryption-change.refresh: sleep --ms=1
    expect a.encrypted
    if native-wait:
      transport.armed = true
    else:
      host.send a 4 #[1]
      sent.get
    worker = task::
      queued.set true
      error := catch: host.send a 4 #[2]
      send-result.set error
    queued.get
    if native-wait: transport.entered.get
    if refresh:
      transport.received.add #[4, 0x30, 3, 5, 0x34, 2]
    else:
      transport.received.add #[4, 8, 4, 0, 0x34, 2, 0]
    a.wait-disconnected
    expect (not a.connected and not a.encrypted)
    expect b.connected
    transport.release.set true
    expect-equals (native-wait ? "HCI_ACL_NOT_SENT" : "HCI_ENCRYPTION_LOST") send-result.get
    host.send b 4 #[3]
    ended.get
    expect (b.connected and not transport.closed)
  finally:
    if worker: worker.cancel
    responder.cancel
    host.close
    host.wait-closed
