// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Passkey Entry through the pairing owner: the owner displays or types the
// passkey through its callbacks, against a peer engine on the other side of
// the fake controller, over Secure Connections and legacy pairing.

import ble.experimental.acl
import ble.experimental.att
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-pairing as smp
import expect show *
import monitor
import .ble-fixture as fixture
import .ble-security-test as wire
import .ble-key-reply-test as keys
import .ble-security-legacy-test as legacy-fixture

LOCAL-ADDRESS ::= legacy-fixture.LOCAL-ADDRESS
PEER-ADDRESS ::= legacy-fixture.PEER-ADDRESS

main:
  with-timeout --ms=20_000:
    [true, false].do: | secure-connections/bool |
      [false, true].do: | peripheral/bool |
        pair --peripheral=peripheral --owner-displays --secure-connections=secure-connections
        pair --peripheral=peripheral --no-owner-displays --secure-connections=secure-connections
      refused --secure-connections=secure-connections

/**
Pairs the owner with a peer engine. With $owner-displays the owner shows the
  passkey (display only) and the peer types it (keyboard only); otherwise
  the other way round.
*/
pair --peripheral/bool --owner-displays/bool --secure-connections/bool:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  host := central.Central (hci.Controller radio)
  shown := monitor.Latch
  ended := monitor.Latch
  peer := smp.Session --initiator=peripheral --io-capability=(owner-displays ? 2 : 0)
      --require-authentication
      --local-address=(#[1] + PEER-ADDRESS.reverse)
      --peer-address=(#[0] + LOCAL-ADDRESS.reverse)
      --secure-connections=secure-connections
  responder := task::
    try:
      legacy-fixture.connect radio --peripheral=peripheral
      reassembler := acl.Reassembler 0x234 --limit=65
      if peripheral: wire.send-smp radio peer.start
      while not peer.verified:
        // The peer's user reads the owner's display and types it; meanwhile
        // the fake controller keeps serving the owner.
        if peer.passkey-requested and shown.has-value:
          wire.send-smp radio (peer.enter-passkey shown.get)
          continue
        incoming/ByteArray? := null
        catch: with-timeout --ms=20: incoming = wire.take-smp radio reassembler
        if incoming: wire.send-smp radio (peer.receive incoming)
        if not owner-displays and peer.passkey-display and not shown.has-value:
          shown.set peer.passkey-display
      if peripheral:
        radio.received.add keys.request
        fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 peer.key)) #[0x34, 2]
      else:
        fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 peer.key))
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      fixture.gatt-reply radio #[0x0a, 1, 0] #[0x0b, 42]
    finally:
      critical-do --no-respect-deadline: ended.set true
  client/att.Client? := null
  try:
    link := peripheral
        ? (host.accept #[2, 1, 6])
        : (host.connect PEER-ADDRESS --address-type=1)
    pairing := security.Pairing host link --local-address=LOCAL-ADDRESS
        --io-capability=(owner-displays ? 0 : 2)
        --require-authentication
    client = att.Client host link --pairing=pairing
    pairing.run (: throw "UNEXPECTED_COMPARISON")
        --display=(:: | passkey/int |
          expect owner-displays
          expect (0 <= passkey <= 999_999)
          shown.set passkey)
        --input=(::
          expect (not owner-displays)
          shown.get)
    expect pairing.encrypted
    expect pairing.authenticated
    expect-equals #[42] (client.read 1)
    client.close
    ended.get
  finally:
    if client: client.close
    responder.cancel
    peer.close
    host.close
    host.wait-closed

/** An owner whose user gives up ends the exchange with Passkey Entry Failed. */
refused --secure-connections/bool:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  host := central.Central (hci.Controller radio)
  peer := smp.Session --no-initiator --io-capability=0 --require-authentication
      --local-address=(#[1] + PEER-ADDRESS.reverse)
      --peer-address=(#[0] + LOCAL-ADDRESS.reverse)
      --secure-connections=secure-connections
  failed := monitor.Latch
  responder := task::
    legacy-fixture.connect radio --no-peripheral
    reassembler := acl.Reassembler 0x234 --limit=65
    while peer.state != "failed":
      packet := wire.take-smp radio reassembler
      if packet == #[5, 1]:
        failed.set true
        break
      wire.send-smp radio (peer.receive packet)
  client/att.Client? := null
  try:
    link := host.connect PEER-ADDRESS --address-type=1
    pairing := security.Pairing host link --local-address=LOCAL-ADDRESS --io-capability=2
        --require-authentication
    client = att.Client host link --pairing=pairing
    error := catch:
      pairing.run (: throw "UNEXPECTED_COMPARISON") --input=(:: null)
    expect error != null
    expect-equals 1 pairing.failure-reason
    failed.get
    expect (not pairing.encrypted)
  finally:
    if client: client.close
    responder.cancel
    peer.close
    host.close
    host.wait-closed
