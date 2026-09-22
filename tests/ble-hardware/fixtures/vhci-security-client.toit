// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.smp-features show PairingError
import encoding.hex
import system
import .hci-echo as fixture

// Lab S3 Board2, running vhci-numeric-pairing.toit.
main:
  run (hex.decode "84f703a00b3a").reverse

run peer/ByteArray --reject-numeric/bool=false --expect-rejection/bool=false:
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    link := host.connect peer --address-type=0
    pairing := security.Pairing host link --local-address=info.address
        --io-capability=1
        --require-authentication
    client = att.Client host link --pairing=pairing
    service/gatt.Service := fixture.find-uuid (gatt.services client)
        (fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001")
    characteristics := gatt.characteristics client service
    encrypted/gatt.Characteristic := fixture.find-uuid characteristics
        (fixture.wire-uuid "9f6c4001-8e2a-4b13-9e97-94f353eeb001")
    authenticated/gatt.Characteristic := fixture.find-uuid characteristics
        (fixture.wire-uuid "9f6c4002-8e2a-4b13-9e97-94f353eeb001")
    error := catch: client.read encrypted.handle
    if not (error is att.AttributeError) or error.code != 0x05: throw "EXPECTED_PAIRING_DENIAL"
    error = catch: client.read authenticated.handle
    if not (error is att.AttributeError) or error.code != 0x05: throw "EXPECTED_AUTHENTICATION_DENIAL"
    print "SECURITY_CLIENT BEFORE encrypted-denied=true authenticated-denied=true"
    pairing-error := catch: with-timeout --ms=45_000:
      pairing.run: | number/int |
        // Fixture-only approval. Check both fresh serial numbers after the run.
        // A product must ask its user to compare and approve the numbers.
        print "SECURITY_CLIENT NUMERIC value=$number fixture-approval=$(not reject-numeric)"
        not reject-numeric
    if reject-numeric or expect-rejection:
      if not (pairing-error is PairingError) or pairing-error.reason != 0x0c:
        throw "EXPECTED_NUMERIC_REJECTION"
      if pairing.encrypted or pairing.authenticated or link.encrypted: throw "REJECTED_PAIRING_ENCRYPTED"
      error = catch: with-timeout --ms=3_000: client.read authenticated.handle
      if not error or error == DEADLINE-EXCEEDED-ERROR: throw "REJECTED_VALUE_NOT_DENIED"
      host.disconnect link
      print "SECURITY_CLIENT REJECTED reason=12 encrypted=false protected-read-denied=true"
      return
    if pairing-error: throw pairing-error
    if not pairing.encrypted or not pairing.authenticated: throw "EXPECTED_AUTHENTICATED_ENCRYPTION"
    retained := [client.read encrypted.handle, client.read authenticated.handle]
    before := system.process-stats --gc
    10.repeat:
      if (client.read encrypted.handle) != #[42]: throw "ENCRYPTED_VALUE_MISMATCH"
      if (client.read authenticated.handle) != #[43]: throw "AUTHENTICATED_VALUE_MISMATCH"
      system.process-stats --gc
      if retained[0] != #[42] or retained[1] != #[43]: throw "RETAINED_VALUE_CHANGED"
    after := system.process-stats
    full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if full-gcs < 10: throw "GC_COUNT_DID_NOT_ADVANCE"
    host.disconnect link
    print "SECURITY_CLIENT COMPLETE encrypted=true authenticated=true retained=2 full-gcs=$full-gcs"
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
