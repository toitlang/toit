// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import expect show *
import system
import .ble-fixture as fixture
import .ble-multilink-test as links

main:
  codecs
  with-timeout --ms=5_000: routing

codecs:
  key := ByteArray 16: it
  enabled := encryption.enable-parameters 0x234 key
  expect-equals #[0x34, 2] enabled[..2]
  expect-equals (ByteArray 10) enabled[2..12]
  expect-equals (ByteArray 16: 15 - it) enabled[12..]
  expect-equals (#[0x34, 2] + enabled[12..]) (encryption.reply-parameters 0x234 key)
  expect-equals #[0x34, 2] (encryption.negative-parameters 0x234)
  key[0] = 99
  expect-equals 0 enabled[27]
  expect-throw "INVALID_ARGUMENT": encryption.enable-parameters 0x234 (ByteArray 15)
  expect-throw "INVALID_ARGUMENT": encryption.reply-parameters 0xffff key
  expect-throw "INVALID_ARGUMENT": encryption.negative-parameters -1
  [#[4, 8, 4, 0, 0x34, 2, 1], #[4, 0x59, 5, 0, 0x34, 2, 1, 0xff]].do: | packet/ByteArray |
    change := encryption.decode-change packet
    expect change.enabled
    expect-equals 0x234 change.handle
    expect (not change.refresh)
  change := encryption.decode-change #[4, 0x30, 3, 0, 0x34, 2]
  expect (change.enabled and change.refresh)
  change = encryption.decode-change #[4, 8, 4, 5, 0x34, 2, 0xff]
  expect-equals 5 change.status
  expect (not change.enabled)
  expect (not (encryption.decode-change #[4, 8, 4, 0, 0x34, 2, 0]).enabled)
  expect-equals null (encryption.decode-change fixture.connection-event)
  [#[4, 8, 3, 0, 0x34, 2], #[4, 8, 4, 0, 0xff, 0xff, 1],
   #[4, 8, 4, 0, 0x34, 2, 2]].do: | packet/ByteArray |
    expect-throw "HCI_MALFORMED_ENCRYPTION_EVENT": encryption.decode-change packet
  request := #[4, 0x3e, 13, 5, 0x34, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  decoded := encryption.decode-key-request request
  expect decoded.secure-connections
  request[6] = 1
  request[14] = 2
  system.process-stats --gc
  expect decoded.secure-connections
  decoded = encryption.decode-key-request request
  expect (not decoded.secure-connections)
  expect-equals 2 decoded.ediv
  expect-equals 1 decoded.random[0]
  expect-equals null (encryption.decode-key-request fixture.connection-event)
  malformed := request.copy
  malformed[4] = 0xff
  malformed[5] = 0xff
  expect-throw "HCI_MALFORMED_ENCRYPTION_EVENT": encryption.decode-key-request malformed
  malformed = request[..15].copy
  malformed[2] = 12
  expect-throw "HCI_MALFORMED_ENCRYPTION_EVENT": encryption.decode-key-request malformed

routing:
  transport := fixture.FakeTransport
  host := central.Central (hci.Controller transport) --link-limit=2
  responder := task::
    links.establish transport 1 0x234
    links.establish transport 2 0x235
  try:
    a := host.connect (links.address 1) --address-type=1
    b := host.connect (links.address 2) --address-type=1
    expect (not a.encrypted and not b.encrypted)
    40.repeat:
      previous := a.encryption-change
      transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      while a.encryption-change == previous: sleep --ms=1
      expect a.encrypted
      expect (not b.encrypted)
    transport.received.add #[4, 0x30, 3, 0, 0x35, 2]
    while not b.encrypted: sleep --ms=1
    transport.received.add #[4, 8, 4, 5, 0x34, 2, 1]
    while a.encrypted: sleep --ms=1
    expect-equals 5 a.encryption-change.status
    expect b.encrypted
    transport.received.add #[4, 8, 4, 0, 0x35, 2, 0]
    while b.encrypted: sleep --ms=1
    transport.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    while not a.encrypted: sleep --ms=1
    links.ended transport 0x234
    a.wait-disconnected
    expect (not a.encrypted)
    expect b.connected
  finally:
    responder.cancel
    host.close
    host.wait-closed
