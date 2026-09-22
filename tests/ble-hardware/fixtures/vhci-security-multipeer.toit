// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.att
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.security
import encoding.hex
import system
import .hci-echo as fixture

// ESP32 Board1 uses values 42/43; Board2 uses 82/83. Both run Numeric Comparison.
main:
  with-timeout --ms=60_000:
    run (hex.decode "98cdac63762e").reverse (hex.decode "98cdac60e0ae").reverse

run first/ByteArray second/ByteArray:
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  clients := []
  links := []
  pairings := []
  handles := []
  retained := []
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --link-limit=2
    [first, second].do: | address/ByteArray |
      index := clients.size
      link := host.connect address --address-type=0
      links.add link
      pairing := security.Pairing host link --local-address=info.address
          --io-capability=1
          --require-authentication
      pairings.add pairing
      client := att.Client host link --pairing=pairing
      clients.add client
      service/gatt.Service := fixture.find-uuid (gatt.services client)
          (fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001")
      characteristics := gatt.characteristics client service
      encrypted/gatt.Characteristic := fixture.find-uuid characteristics
          (fixture.wire-uuid "9f6c4001-8e2a-4b13-9e97-94f353eeb001")
      authenticated/gatt.Characteristic := fixture.find-uuid characteristics
          (fixture.wire-uuid "9f6c4002-8e2a-4b13-9e97-94f353eeb001")
      handles.add [encrypted.handle, authenticated.handle]
      handles.last.do: | handle/int |
        error := catch: client.read handle
        if not (error is att.AttributeError) or error.code != 5: throw "EXPECTED_PROTECTED_DENIAL"
      print "SECURITY_MULTIPEER BEFORE peer=$index protected-denied=true"
      pairing.run: | number/int |
        // Fixture-only approval. Compare each fresh number with its peer log.
        print "SECURITY_MULTIPEER NUMERIC peer=$index value=$number fixture-approval=true"
        true
      require-security pairing
      retained.add [client.read encrypted.handle, client.read authenticated.handle]
    if links[0].info.handle == links[1].info.handle: throw "DUPLICATE_LINK_HANDLE"
    print "SECURITY_MULTIPEER CONNECTED encrypted=2 authenticated=2"
    before := system.process-stats --gc
    50.repeat: | cycle/int |
      2.repeat: | index/int |
        require-security pairings[index]
        read-values clients[index] handles[index] (42 + index * 40)
      if cycle % 5 == 4:
        check-retained retained
        print "SECURITY_MULTIPEER BOTH cycles=$(cycle + 1)"
    host.disconnect links[0]
    if links[0].connected or pairings[0].encrypted or pairings[0].authenticated:
      throw "DISCONNECTED_SECURITY_RETAINED"
    require-security pairings[1]
    print "SECURITY_MULTIPEER FIRST_DISCONNECTED survivor-encrypted=true"
    20.repeat:
      require-security pairings[1]
      read-values clients[1] handles[1] 82
      check-retained retained
    host.disconnect links[1]
    after := system.process-stats --gc
    full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if full-gcs < 30: throw "GC_COUNT_DID_NOT_ADVANCE"
    print "SECURITY_MULTIPEER COMPLETE first-reads=102 second-reads=142 retained=4 full-gcs=$full-gcs"
  finally:
    clients.do: it.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

require-security pairing/security.Pairing:
  if not pairing.encrypted or not pairing.authenticated: throw "EXPECTED_AUTHENTICATED_ENCRYPTION"

read-values client/att.Client handles/List base/int:
  if (client.read handles[0]) != #[base]: throw "ENCRYPTED_VALUE_MISMATCH"
  if (client.read handles[1]) != #[base + 1]: throw "AUTHENTICATED_VALUE_MISMATCH"

check-retained retained/List:
  system.process-stats --gc
  2.repeat: | index/int |
    base := 42 + index * 40
    if retained[index][0] != #[base] or retained[index][1] != #[base + 1]:
      throw "RETAINED_VALUE_CHANGED"
