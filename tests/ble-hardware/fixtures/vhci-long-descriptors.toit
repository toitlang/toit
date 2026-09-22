// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.esp32
import ble.experimental.security
import ble.experimental.scanning
import ble.experimental.transport
import .hci-echo as fixture

main: run (esp32.Esp32Transport)

run radio/transport.Transport --encrypted/bool=false --authenticated/bool=false --expect-denied/bool=false:
  if expect-denied and (not encrypted or authenticated): throw "INVALID_ARGUMENT"
  controller := hci.Controller radio
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    uuid := fixture.wire-uuid "9f6c6000-8e2a-4b13-9e97-94f353eeb001"
    peer/advertising.Report? := null
    with-timeout --ms=10_000:
      scanning.scan controller: | report/advertising.Report |
        if not (report.has-service uuid): continue.scan true
        peer = report
        false
    link := host.connect peer.address --address-type=peer.address-type
    pairing := encrypted or authenticated
        ? (security.Pairing host link --local-address=info.address
            --io-capability=(authenticated ? 1 : 3)
            --require-authentication=authenticated)
        : null
    client = att.Client host link --pairing=pairing
    service := fixture.find-uuid (gatt.services client) uuid
    value := fixture.find-uuid (gatt.characteristics client service)
        fixture.wire-uuid "9f6c6001-8e2a-4b13-9e97-94f353eeb001"
    descriptor := fixture.find-uuid (gatt.descriptors client value)
        fixture.wire-uuid "9f6c6002-8e2a-4b13-9e97-94f353eeb001"
    if pairing:
      error := catch: client.read descriptor.handle
      require-denied error
      error = catch: client.write descriptor.handle #[99]
      require-denied error
      error = catch: client.write-long descriptor.handle (ByteArray 512 --initial=99)
      require-denied error
      print "VHCI_LONG_DESCRIPTORS BEFORE read-denied=true write-denied=true prepare-denied=true"
      with-timeout --ms=45_000:
        pairing.run: | number/int |
          if not authenticated: throw "UNEXPECTED_NUMERIC_COMPARISON"
          // Fixture-only approval; verify equal values from both fresh logs.
          print "VHCI_LONG_DESCRIPTORS NUMERIC value=$number fixture-approval=true"
          true
      if not pairing.encrypted or not link.encrypted: throw "EXPECTED_ENCRYPTION"
      if pairing.authenticated != authenticated: throw "UNEXPECTED_AUTHENTICATION"
      print "VHCI_LONG_DESCRIPTORS SECURITY encrypted=true authenticated=$(pairing.authenticated)"
    if expect-denied:
      error := catch: client.read descriptor.handle
      require-denied error
      error = catch: client.write descriptor.handle #[99]
      require-denied error
      error = catch: client.write-long descriptor.handle (ByteArray 512 --initial=99)
      require-denied error
      if (client.read value.handle) != #[7]: throw "EXPECTED_UNCHANGED_VALUE"
      host.disconnect link
      print "VHCI_LONG_DESCRIPTORS COMPLETE writes=0 encrypted=true authenticated=false denied=true"
      return
    if (client.read descriptor.handle) != #[7]: throw "UNEXPECTED_INITIAL_VALUE"
    [(ByteArray 512: it % 251), #[]].do: | expected/ByteArray |
      client.write-long descriptor.handle expected
      if (client.read-long descriptor.handle) != expected: throw "LONG_WRITE_MISMATCH"
      print "VHCI_LONG_DESCRIPTORS bytes=$(expected.size) exact=true"
    host.disconnect link
    print "VHCI_LONG_DESCRIPTORS COMPLETE writes=2"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

require-denied error -> none:
  if not (error is att.AttributeError) or error.code != 0x05:
    throw "EXPECTED_DESCRIPTOR_SECURITY_DENIAL"
