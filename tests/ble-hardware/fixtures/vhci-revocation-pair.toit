// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.att
import ble.experimental.bond
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.security
import .vhci-bond-revocation-peer as fixture

// Fresh on-air pairing, with public fixture approval of Numeric Comparison.
// The campaign verifier must compare the central and peer numbers.
pair --first-peer/ByteArray?=null --receive-acl-packets/int=0 -> List:
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  candidates := []
  try:
    info := hci.initialize controller --receive-acl-packets=receive-acl-packets
    if info.address != fixture.central-address: throw "REVOKE_PAIR_WRONG_BOARD"
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    2.repeat: | index/int |
      address := index == 0 and first-peer ? first-peer : (fixture.peer-address index)
      link := host.connect address --address-type=0
      pairing := security.Pairing host link --local-address=info.address --io-capability=1 --require-authentication --bond
      client := att.Client host link --pairing=pairing
      try:
        denied := catch: client.read 12
        if not denied: throw "REVOKE_PAIR_UNPROTECTED"
        // Preserve transport failures instead of misreporting them as access grants.
        if denied is not att.AttributeError or denied.code != 5: throw denied
        pairing.run
            (: | number/int |
              print "REVOKE_PAIR NUMERIC peer=$index value=$number fixture-approval=true"
              true)
            --candidate=: | saved/bond.Candidate |
              if not saved.authenticated or saved.peer.address != address:
                throw "REVOKE_PAIR_BAD_CANDIDATE"
              candidates.add saved
        if not pairing.authenticated or not pairing.encrypted: throw "REVOKE_PAIR_SECURITY"
        if (client.read 12) != #[42 + index]: throw "REVOKE_PAIR_VALUE"
        host.disconnect link
      finally:
        client.close
        client.wait-closed
    if candidates.size != 2: throw "REVOKE_PAIR_MISSING_CANDIDATES"
    print "REVOKE_PAIR COMPLETE authenticated-candidates=2"
    return candidates
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
