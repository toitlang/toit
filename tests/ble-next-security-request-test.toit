// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Pairing started by a peripheral application: request-security sends the
// central a Security Request with the provider's AuthReq, the central pairs
// (Just Works) and encrypts, and the call returns the level reached. A
// provider that does not pair refuses.

import expect show *
import monitor
import ble.experimental.acl
import ble.experimental.encryption
import ble.experimental.hci
import ble.v2 as ble
import ble.experimental.smp-pairing as smp
import ble.experimental.transport
import ble.experimental.service.gatt-provider as providers
import ble.experimental.service.pairing as pairing
import .ble-fixture as fixture
import .ble-key-reply-test as keys
import .ble-next-peripheral-test as peripheral
import .ble-security-test as wire

main:
  with-timeout --ms=10_000:
    pairs
    refuses

/** Our side as the fake controller knows it, and the central's: type, then the address reversed. */
context type/int address/ByteArray -> ByteArray:
  return #[type] + (ByteArray 6: address[5 - it])

pairs:
  provider := PairingProvider
  provider.install
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radios.receive
      fixture.initialize-replies radio
      peripheral.accept radio
      event := fixture.connection-event
      central := smp.Session --initiator --io-capability=3 --no-require-authentication
          --local-address=(context event[8] event[9..15])
          --peer-address=(context 0 #[1, 2, 3, 4, 5, 6])
      reassembler := acl.Reassembler 0x234 --limit=65
      // Secure Connections, no bonding, no MITM: the provider's policy.
      expect-equals #[0x0b, 0x08] (wire.take-smp radio reassembler)
      wire.send-smp radio central.start
      while not central.verified:
        wire.send-smp radio (central.receive (wire.take-smp radio reassembler))
      radio.received.add keys.request
      fixture.reply radio (hci.command-packet 0x201a (encryption.reply-parameters 0x234 central.key)) #[0x34, 2]
      radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
      provider.secured.get
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  adapter := ble.Adapter
  try:
    server := ble.GattServer
    role := adapter.peripheral server --advertisement=peripheral.ADVERTISEMENT
    connection := role.accept
    expect-equals ble.SECURITY-NONE connection.security
    expect-equals ble.SECURITY-ENCRYPTED connection.request-security
    // Already encrypted: nothing is sent again.
    expect-equals ble.SECURITY-ENCRYPTED connection.request-security
    // Just Works cannot reach authenticated.
    expect-throw "BLE_INSUFFICIENT_SECURITY": connection.request-security ble.SECURITY-AUTHENTICATED
    provider.secured.set true
    expect-equals ble.DisconnectReason.REMOTE-USER connection.wait-closed.code
    connection.close
    role.close
    ended.get
  finally:
    adapter.close
    responder.cancel
    provider.uninstall

refuses:
  provider := peripheral.Provider
  provider.install
  checked := monitor.Latch
  ended := monitor.Latch
  responder := task::
    try:
      radio := provider.radios.receive
      fixture.initialize-replies radio
      peripheral.accept radio
      checked.get
      radio.received.add #[4, 5, 4, 0, 0x34, 2, 0x13]
    finally:
      critical-do --no-respect-deadline: ended.set true
  adapter := ble.Adapter
  try:
    server := ble.GattServer
    role := adapter.peripheral server --advertisement=peripheral.ADVERTISEMENT
    connection := role.accept
    expect-throw "BLE_UNSUPPORTED": connection.request-security
    checked.set true
    connection.wait-closed
    connection.close
    role.close
    ended.get
  finally:
    adapter.close
    responder.cancel
    provider.uninstall

class PairingProvider extends peripheral.Provider with pairing.Support:
  secured/monitor.Latch ::= monitor.Latch
  constructor: super
  pairing-io-capability -> int?: return 3
