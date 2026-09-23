// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Legacy Just Works pairing and bonding through the security owner against
// an emulated legacy peer, in both roles, and resumption of the stored bond.

import ble.experimental.acl
import ble.experimental.att
import ble.experimental.bond
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-identity as identity
import ble.experimental.smp-legacy as legacy
import crypto
import expect show *
import monitor
import system
import .ble-fixture as fixture
import .ble-security-test as wire
import .ble-key-reply-test as keys
import .ble-peripheral-test as peripheral-fixture
import .ble-smp-identity-test as identity-fixture

// HCI order (least significant byte first); the peer is static random.
LOCAL-ADDRESS ::= #[6, 5, 4, 3, 2, 1]
PEER-ADDRESS ::= #[1, 2, 3, 4, 5, 0xc6]

reverse bytes/ByteArray -> ByteArray: return ByteArray bytes.size: bytes[bytes.size - 1 - it]

main:
  with-timeout --ms=10_000:
    [false, true].do: | peripheral/bool |
      [false, true].do: | peer-key/bool |
        candidate := pair --peripheral=peripheral --peer-key=peer-key
        resume candidate --peripheral=peripheral
        resume candidate --peripheral=(not peripheral)
    no-keys

/**
Pairs with a legacy peer that sends the given features and returns the bond.

The peer requests EncKey in both directions when $peer-key is set; otherwise
  only this side distributes a key.
*/
pair --peripheral/bool --peer-key/bool -> bond.Candidate:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  host := central.Central (hci.Controller radio)
  // Key distribution fields: [initiator sends, responder sends]. Without a
  // peer key only this side's direction is set.
  peer-features := #[3, 0, 1, 16, (peer-key or not peripheral) ? 1 : 0, (peer-key or peripheral) ? 1 : 0]
  peer-key-material := legacy.LegacyKey.random
  received-local/legacy.LegacyKey? := null
  stk/ByteArray? := null
  ended := monitor.Latch
  responder := task::
    try:
      reassembler := acl.Reassembler 0x234 --limit=65
      request/ByteArray? := null
      response/ByteArray? := null
      peer-random := crypto.random --size=16
      // The peer's view: the initiator's address comes first in c1.
      initiating-type := peripheral ? 1 : 0
      initiating := peripheral ? PEER-ADDRESS : LOCAL-ADDRESS
      responding-type := peripheral ? 0 : 1
      responding := peripheral ? LOCAL-ADDRESS : PEER-ADDRESS
      confirm := : | random/ByteArray |
        legacy.c1 (ByteArray 16) random request response initiating-type initiating responding-type responding
      connect radio --peripheral=peripheral
      if peripheral:
        request = #[1] + peer-features
        wire.send-smp radio [request]
        response = wire.take-smp radio reassembler
        expect-equals 2 response[0]
        wire.send-smp radio [#[3] + (confirm.call peer-random)]
        local-confirm := wire.take-smp radio reassembler
        expect-equals 3 local-confirm[0]
        wire.send-smp radio [#[4] + peer-random]
        local-random := wire.take-smp radio reassembler
        expect-equals 4 local-random[0]
        expect-equals local-confirm[1..] (confirm.call local-random[1..])
        stk = reverse (legacy.s1 (ByteArray 16) local-random[1..] peer-random)
      else:
        request = wire.take-smp radio reassembler
        expect-equals 1 request[0]
        response = #[2] + peer-features
        wire.send-smp radio [response]
        local-confirm := wire.take-smp radio reassembler
        expect-equals 3 local-confirm[0]
        wire.send-smp radio [#[3] + (confirm.call peer-random)]
        local-random := wire.take-smp radio reassembler
        expect-equals 4 local-random[0]
        expect-equals local-confirm[1..] (confirm.call local-random[1..])
        wire.send-smp radio [#[4] + peer-random]
        stk = reverse (legacy.s1 (ByteArray 16) peer-random local-random[1..])
      if peripheral:
        radio.received.add keys.request
        fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 stk)) #[0x34, 2]
      else:
        fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 stk))
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      take-local := :
        receiver := legacy.LegacyKeyReceiver identity-fixture.Security
        receiver.receive (wire.take-smp radio reassembler)
        expect-null receiver.key
        receiver.receive (wire.take-smp radio reassembler)
        received-local = receiver.key
      // The responder distributes first.
      if peripheral:
        take-local.call
        if peer-key: wire.send-smp radio (peer-key-material.packets identity-fixture.Security)
      else:
        if peer-key: wire.send-smp radio (peer-key-material.packets identity-fixture.Security)
        take-local.call
      fixture.gatt-reply radio #[0x0a, 1, 0] #[0x0b, 42]
    finally:
      critical-do --no-respect-deadline: ended.set true
  client/att.Client? := null
  retained/bond.Candidate? := null
  try:
    link := peripheral
        ? (host.accept #[2, 1, 6])
        : (host.connect PEER-ADDRESS --address-type=1)
    pairing := security.Pairing host link --local-address=LOCAL-ADDRESS --io-capability=3 --no-require-authentication --bond
    client = att.Client host link --pairing=pairing
    pairing.run (: | number/int | throw "UNEXPECTED_CONFIRMATION") --candidate=: | candidate/bond.Candidate |
      retained = candidate
    expect pairing.encrypted
    expect (not pairing.authenticated)
    expect-equals #[42] (client.read 1)
    expect (retained != null)
    expect retained.legacy
    expect-equals (ByteArray 16) retained.key
    expect (retained.local-legacy != null)
    expect-equals received-local.ltk retained.local-legacy.ltk
    expect-equals received-local.ediv retained.local-legacy.ediv
    expect-equals received-local.rand retained.local-legacy.rand
    if peer-key:
      expect-equals peer-key-material.ltk retained.peer-legacy.ltk
      expect-equals peer-key-material.ediv retained.peer-legacy.ediv
      expect-equals peer-key-material.rand retained.peer-legacy.rand
    else:
      expect-null retained.peer-legacy
    expect-equals LOCAL-ADDRESS retained.local.address
    expect-equals PEER-ADDRESS retained.peer.address
    // The record survives a round trip through storage encoding.
    decoded := bond.Candidate.decode retained.encode
    expect-equals retained.encode decoded.encode
    client.close
    ended.get
    return decoded
  finally:
    if client: client.close
    responder.cancel
    host.close
    host.wait-closed

/** Resumes a legacy bond: central with the peer's key, peripheral with its own. */
resume candidate/bond.Candidate --peripheral/bool:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  host := central.Central (hci.Controller radio)
  key := peripheral ? candidate.local-legacy : candidate.peer-legacy
  started := monitor.Latch
  ended := monitor.Latch
  responder := task::
    try:
      connect radio --peripheral=peripheral
      started.get
      if key == null:
        while radio.disconnects == 0: sleep --ms=1
      else:
        if peripheral:
          // A request with foreign identifiers is refused, the bond's answered.
          radio.received.add (key-request (ByteArray 8 --initial=9) 7)
          keys.negative radio
          radio.received.add (key-request key.rand key.ediv)
          fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 key.key)) #[0x34, 2]
        else:
          parameters := encryption.enable-parameters 0x234 key.key --random=key.rand --ediv=key.ediv
          expect-equals key.rand parameters[2..10]
          fixture.status-reply radio (hci.command-packet 0x2019 parameters)
        radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
        fixture.gatt-reply radio #[0x0a, 1, 0] #[0x0b, 42]
    finally:
      critical-do --no-respect-deadline: ended.set true
  client/att.Client? := null
  try:
    link := peripheral
        ? (host.accept #[2, 1, 6])
        : (host.connect PEER-ADDRESS --address-type=1)
    if key == null:
      expect-throw "BLE_BOND_NO_LEGACY_KEY":
        bond-resume.Resume host link candidate --local-address=LOCAL-ADDRESS
      host.abort link --error="TEST_DONE"
      started.set true
      fixture.wait-ended link
      ended.get
      return
    resume := bond-resume.Resume host link candidate --local-address=LOCAL-ADDRESS
    client = att.Client host link --pairing=resume
    started.set true
    resume.run --timeout=(Duration --s=2)
    expect resume.encrypted
    expect (not resume.authenticated)
    expect-equals #[42] (client.read 1)
    client.close
    ended.get
  finally:
    if client: client.close
    responder.cancel
    host.close
    host.wait-closed

/** Emulates the controller's side of a connection to the static random peer. */
connect radio/fixture.FakeTransport --peripheral/bool:
  event := fixture.connection-event.copy
  event.replace 9 PEER-ADDRESS
  if peripheral:
    peripheral-fixture.setup radio
    event[7] = 1
    radio.received.add event
    peripheral-fixture.reply radio 0x200a #[0]
  else:
    command := fixture.create-command.copy
    command.replace 10 PEER-ADDRESS
    fixture.status-reply radio command
    radio.received.add event

key-request random/ByteArray ediv/int -> ByteArray:
  return #[4, 0x3e, 13, 5, 0x34, 2] + random + #[ediv & 0xff, ediv >> 8]

/** A legacy peer that bonds but distributes no key in either direction yields no bond. */
no-keys:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  host := central.Central (hci.Controller radio)
  ended := monitor.Latch
  responder := task::
    try:
      reassembler := acl.Reassembler 0x234 --limit=65
      connect radio --no-peripheral
      request := wire.take-smp radio reassembler
      response := #[2, 3, 0, 1, 16, 0, 0]
      wire.send-smp radio [response]
      peer-random := crypto.random --size=16
      confirm := : | random/ByteArray |
        legacy.c1 (ByteArray 16) random request response 0 LOCAL-ADDRESS 1 PEER-ADDRESS
      local-confirm := wire.take-smp radio reassembler
      wire.send-smp radio [#[3] + (confirm.call peer-random)]
      local-random := wire.take-smp radio reassembler
      wire.send-smp radio [#[4] + peer-random]
      stk := reverse (legacy.s1 (ByteArray 16) peer-random local-random[1..])
      fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 stk))
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      while radio.disconnects == 0: sleep --ms=1
    finally:
      critical-do --no-respect-deadline: ended.set true
  client/att.Client? := null
  try:
    link := host.connect PEER-ADDRESS --address-type=1
    pairing := security.Pairing host link --local-address=LOCAL-ADDRESS --io-capability=3 --no-require-authentication --bond
    client = att.Client host link --pairing=pairing
    calls := 0
    error := catch:
      pairing.run (: | number/int | throw "UNEXPECTED_CONFIRMATION") --candidate=: | candidate/bond.Candidate |
        calls++
    expect-equals "SMP_BOND_KEYS_REQUIRED" error
    expect-equals 0 calls
    fixture.wait-ended link
    ended.get
  finally:
    if client: client.close
    responder.cancel
    host.close
    host.wait-closed
