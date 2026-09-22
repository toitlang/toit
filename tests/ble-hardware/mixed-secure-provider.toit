// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.transport
import .mixed-service-provider as fixture

main:
  [false, true].do: | peripheral-first/bool |
    provider := Provider
    with-timeout --ms=160_000: fixture.run peripheral-first provider --peer-reads=202
    check-security provider peripheral-first
  print "MIXED_PROVIDER COMPLETE rounds=2"

check-security provider/Provider peripheral-first/bool:
  if provider.paired != [1, 2] or provider.confirmed != [1, 2]: throw "MIXED_PAIRING_COUNTS"
  provider.owners.do:
    if (it as Owner).encrypted: throw "MIXED_SECURITY_RETAINED_AFTER_CLOSE"
  print "MIXED_SECURE_PROVIDER ROUND_SECURITY peripheral-first=$peripheral-first pairings=3"

class Provider extends fixture.Provider:
  paired/List ::= [0, 0]
  confirmed/List ::= [0, 0]
  owners/List ::= []

  open-transport -> transport.Transport:
    opens++
    radio = Radio
    return radio

  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return create-owner host link info

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return create-owner host link info

  create-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner:
    owner := security.Pairing host link --local-address=info.address
        --io-capability=1
        --require-authentication
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
    owners.add owner
    return owner

  run-central-security-owner selected/Owner -> none: secure selected 0
  run-security-owner selected/Owner -> none: secure selected 1

  secure selected/Owner role/int:
    (selected as security.Pairing).run: | number/int |
      confirmed[role]++
      print "MIXED_SECURE_PROVIDER NUMERIC role=$role value=$number fixture-approval=true"
      true
    if not selected.encrypted or not selected.authenticated: throw "MIXED_SECURITY_NOT_READY"
    paired[role]++
    print "MIXED_SECURE_PROVIDER SECURED role=$role encrypted=true authenticated=true"

class Radio extends fixture.Radio:
  receive -> ByteArray:
    packet := super
    if packet.size >= 4 and packet[0] == 4 and
        (packet[1] == 5 or (packet[1] == 0x3e and packet[3] == 0x0a)):
      print "MIXED_SECURE_RADIO LINK_EVENT $packet"
    // Count protected value reads, including the two pre-pairing denials.
    if packet.size == 12 and packet[0] == 2 and packet[2] & 0x30 != 0x10 and
        packet[5..] == #[3, 0, 4, 0, 0x0a, 12, 0]:
      read-requests++
    return packet
