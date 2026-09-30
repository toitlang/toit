// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Board central for tests/ble-hardware/private-resolve.sh, beside
// private-resolving-provider.toit: finds the private peripheral by its
// identity in resolved scan reports, then connects again by identity alone
// while the peripheral advertises from a fresh resolvable private address.

import ble.experimental.next as ble
import .private-resolving-provider show PEER-IDENTITY

HEART-RATE ::= ble.BleUuid "180d"
MEASUREMENT ::= ble.BleUuid "2a37"

main:
  adapter := ble.Adapter
  try:
    identity := ble.Address PEER-IDENTITY --type=ble.Address.PUBLIC-IDENTITY
    report := adapter.find --service=HEART-RATE --duration=(Duration --s=20)
    if not report: throw "PRIVATE_NOT_FOUND"
    print "PRIVATE_CENTRAL found $report.peer"
    if report.peer != identity: throw "PRIVATE_NOT_RESOLVED $report.peer"
    measure adapter identity
    // No scan: the controller recognizes the peripheral's next RPA itself.
    measure adapter identity
    print "PRIVATE_CENTRAL COMPLETE"
  finally:
    adapter.close

measure adapter/ble.Adapter identity/ble.Address -> none:
  adapter.with-connection identity --timeout=(Duration --s=10): | connection/ble.Connection |
    print "PRIVATE_CENTRAL connected $connection.peer"
    if connection.peer != identity: throw "PRIVATE_WRONG_PEER $connection.peer"
    characteristic := (connection.discover-service HEART-RATE).characteristic MEASUREMENT
    characteristic.subscribe: | values/ble.Values |
      print "PRIVATE_CENTRAL heart-rate=$values.receive[1]"
    connection.disconnect
