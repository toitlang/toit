// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Controller-based address resolution: loading the resolving list, decoding
// Enhanced Connection Complete for resolved and unresolved peers, and
// connecting to a bonded peer by its identity, directly and through the
// application API.

import expect show *
import monitor
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.hci
import ble.experimental.resolving-list as resolving
import ble.experimental.transport
import ble as package
import ble.v2 as ble
import ble.experimental.service.gatt-provider as providers
import .ble-fixture as fixture

IDENTITY ::= #[1, 2, 3, 4, 5, 0xc6]                 // static random identity, HCI order
IRK ::= ByteArray 16: it + 0x10                      // most significant byte first
ON-AIR ::= #[0x11, 0x22, 0x33, 0x44, 0x55, 0x66]     // the peer's current RPA, HCI order

main:
  with-timeout --ms=10_000:
    decoding
    direct
    through-api
    through-package

/** The commands that load one entry, as the fake controller sees them. */
expect-configuration radio/fixture.FakeTransport:
  fixture.reply radio #[1, 0x2a, 0x20, 0] #[8]
  fixture.reply radio #[1, 0x2d, 0x20, 1, 0] #[]
  fixture.reply radio #[1, 0x29, 0x20, 0] #[]
  irk-on-air := ByteArray 16: IRK[15 - it]
  fixture.reply radio (#[1, 0x27, 0x20, 39, 1] + IDENTITY + irk-on-air + (ByteArray 16)) #[]
  fixture.reply radio (#[1, 0x4e, 0x20, 8, 1] + IDENTITY + #[1]) #[]
  fixture.reply radio #[1, 0x2e, 0x20, 2, 0x84, 0x03] #[]
  fixture.reply radio #[1, 0x2d, 0x20, 1, 1] #[]
  fixture.reply radio #[1, 1, 0x20, 8, 0x5f, 0x0a, 0, 0, 0, 0, 0, 0] #[]

/** Enhanced Connection Complete for the peer, resolved from its RPA to its identity. */
enhanced-event --resolved/bool -> ByteArray:
  event := ByteArray 34
  event.replace 0 #[4, 0x3e, 31, 0x0a, 0, 0x34, 2, 0, resolved ? 3 : 1]
  event.replace 9 (resolved ? IDENTITY : ON-AIR)
  if resolved: event.replace 21 ON-AIR
  event.replace 27 #[24, 0, 0, 0, 0x90, 1, 0]
  return event

decoding:
  resolved := connection.decode-completion (enhanced-event --resolved)
  expect-equals ON-AIR resolved.address
  expect-equals 1 resolved.address-type
  expect-equals IDENTITY resolved.identity-address
  expect-equals 1 resolved.identity-address-type
  plain := connection.decode-completion (enhanced-event --no-resolved)
  expect-equals ON-AIR plain.address
  expect-null plain.identity-address
  // A peer on its identity address has no separate RPA.
  own := enhanced-event --resolved
  own.replace 21 (ByteArray 6)
  on-identity := connection.decode-completion own
  expect-equals IDENTITY on-identity.address
  expect-equals IDENTITY on-identity.identity-address
  // An unresolved peer cannot also report a resolved RPA.
  malformed := enhanced-event --no-resolved
  malformed.replace 21 ON-AIR
  expect-throw "HCI_MALFORMED_CONNECTION_EVENT": connection.decode-completion malformed

direct:
  radio := fixture.FakeTransport
  radio.auto-disconnect = true
  controller := hci.Controller radio
  responder := task::
    fixture.initialize-replies radio --privacy
    expect-configuration radio
    // Connecting by identity: address type 3 (random identity).
    fixture.status-reply radio (hci.command-packet 0x200d (connection.create-parameters IDENTITY --address-type=3))
    radio.received.add (enhanced-event --resolved)
  host/central.Central? := null
  try:
    info := hci.initialize controller
    expect (resolving.supported info)
    resolving.configure controller info [resolving.Entry --address-type=1 --address=IDENTITY --irk=IRK]
    host = central.Central controller
    link := host.connect IDENTITY --address-type=3
    // Pairing and bond resumption keep working with the on-air address.
    expect-equals ON-AIR link.info.address
    expect-equals IDENTITY link.info.identity-address
    host.abort link
  finally:
    responder.cancel
    if host: host.close
    controller.close

through-api:
  provider := Provider
  provider.install
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      fixture.initialize-replies radio --privacy
      expect-configuration radio
      fixture.status-reply radio (hci.command-packet 0x200d (connection.create-parameters IDENTITY --address-type=3))
      radio.received.add (enhanced-event --resolved)
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    finally:
      critical-do --no-respect-deadline: ended.set true
  adapter := ble.Adapter
  try:
    peer := ble.Address IDENTITY --type=ble.Address.RANDOM-IDENTITY
    expect peer.is-identity
    connection := adapter.connect peer --mtu=23
    expect-equals peer connection.peer
    info := connection.central_.link-info
    expect-equals ON-AIR info[8]
    expect-equals IDENTITY info[10]
    connection.close
    ended.get
  finally:
    adapter.close
    responder.cancel
    provider.uninstall

/** The `ble` package lists the provider's bonded peers and connects to one by identity. */
through-package:
  provider := Provider
  provider.install
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radio
      fixture.initialize-replies radio --privacy
      expect-configuration radio
      fixture.status-reply radio (hci.command-packet 0x200d (connection.create-parameters IDENTITY --address-type=3))
      radio.received.add (enhanced-event --resolved)
      fixture.status-reply radio #[1, 6, 4, 3, 0x34, 2, 0x13]
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x16]
    finally:
      critical-do --no-respect-deadline: ended.set true
  adapter := package.Adapter
  try:
    adapter.set-preferred-mtu 23
    central := adapter.central
    peers := central.bonded-peers
    expect-equals [#[3] + IDENTITY] peers
    device := central.connect peers[0]
    device.close
    ended.get
  finally:
    adapter.close
    responder.cancel
    provider.uninstall

class Provider extends providers.Provider:
  radio/fixture.FakeTransport := fixture.FakeTransport
  constructor: super
  open-transport -> transport.Transport: return radio
  bonded-peers -> List: return [[3, IDENTITY]]
  resolving-list -> List?:
    return [resolving.Entry --address-type=1 --address=IDENTITY --irk=IRK]
