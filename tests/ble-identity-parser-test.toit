// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.smp-features show PairingError
import ble.experimental.smp-identity as identity
import expect show *
import system
import .ble-smp-identity-test as fixture

main:
  security := fixture.Security
  local := identity.Identity (ByteArray 16: it) #[1, 2, 3, 4, 5, 0xc1] 1
  packets := local.packets security
  2.repeat: | phase/int |
    base/ByteArray := packets[phase]
    base.size.repeat: | position/int |
      256.repeat: | value/int |
        changed := base.copy
        changed[position] = value
        check-identity security packets phase changed
    // Every truncation and one trailing byte must poison the receiver.
    base.size.repeat: | size/int |
      check-identity security packets phase base[..size].copy --must-fail
    check-identity security packets phase (base + #[0]) --must-fail

  candidate := bond.Candidate (ByteArray 16 --initial=42) local local --no-authenticated
  encoded := candidate.encode
  encoded.size.repeat: | position/int |
    256.repeat: | value/int |
      changed := encoded.copy
      changed[position] = value
      check-record changed
  encoded.size.repeat: | size/int |
    check-record encoded[..size].copy --must-fail
  check-record (encoded + #[0]) --must-fail

check-identity security/fixture.Security packets/List phase/int changed/ByteArray --must-fail/bool=false:
  receiver := identity.Receiver security
  original := changed.copy
  failure := catch:
    if phase == 1: receiver.receive packets[0]
    receiver.receive changed
  expect-equals original changed
  if failure:
    expect (failure is PairingError)
    expect-equals 0x0a failure.reason
    expect-throw "SMP_IDENTITY_CLOSED": receiver.identity
    expect-throw "SMP_IDENTITY_CLOSED": receiver.receive packets[1]
  else:
    expect (not must-fail)
    if phase == 0:
      expect-equals null receiver.identity
      receiver.receive packets[1]
    result := receiver.identity
    changed.fill 0
    // Validate ownership after mutation; sample full GC at deterministic points.
    if original.last == 255: system.process-stats --gc
    expected := phase == 0 ? [original, packets[1]] : [packets[0], original]
    expect-equals expected (result.packets security)
    receiver.close
    expect-throw "SMP_IDENTITY_CLOSED": receiver.identity

check-record bytes/ByteArray --must-fail/bool=false:
  original := bytes.copy
  decoded/bond.Candidate? := null
  failure := catch: decoded = bond.Candidate.decode bytes
  expect-equals original bytes
  if failure:
    expect-equals "BLE_INVALID_BOND_RECORD" failure
    expect-equals null decoded
  else:
    expect (not must-fail)
    bytes.fill 0
    if original.last == 255: system.process-stats --gc
    expect-equals original decoded.encode
