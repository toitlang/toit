// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.smp-distribution as distribution
import ble.experimental.smp-identity as identity
import ble.experimental.smp-features show PairingError
import expect show *
import system
import .ble-smp-identity-test as fixture

main:
  [false, true].do: | central-key/bool |
    [false, true].do: | peripheral-key/bool |
      exchange central-key peripheral-key
  failures

exchange central-key/bool peripheral-key/bool:
  security := fixture.Security
  central-id := identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  peripheral-id := identity.Identity (ByteArray 16 --initial=2) #[1, 2, 3, 4, 5, 0xc6] 1
  central := distribution.Exchange security --initiator
      --local=(central-key ? central-id : null)
      --receive-identity=peripheral-key
  peripheral := distribution.Exchange security --no-initiator
      --local=(peripheral-key ? peripheral-id : null)
      --receive-identity=central-key
  central-packets := central.start
  peripheral-packets := peripheral.start
  expect-equals ((central-key and not peripheral-key) ? 2 : 0) central-packets.size
  expect-equals (peripheral-key ? 2 : 0) peripheral-packets.size
  if peripheral-key:
    expect-equals [] (central.receive peripheral-packets[0])
    expect-null central.peer-identity
    expect (not central.local-identity-issued)
    system.process-stats --gc
    central-packets = central.receive peripheral-packets[1]
    expect-equals (central-key ? 2 : 0) central-packets.size
    expect-equals peripheral-id.irk central.peer-identity.irk
    expect-equals peripheral-id.address central.peer-identity.address
  if central-key:
    central-packets.do: expect-equals [] (peripheral.receive it)
    expect-equals central-id.irk peripheral.peer-identity.irk
    expect-equals central-id.address peripheral.peer-identity.address
  expect-equals central-key central.local-identity-issued
  expect-equals peripheral-key peripheral.local-identity-issued
  // Issued flags require no credits or supposed delivery notification.
  central.close
  peripheral.close
  expect-throw "SMP_DISTRIBUTION_INVALID_STATE": central.peer-identity

failures:
  security := fixture.Security
  local := identity.Identity (ByteArray 16) (ByteArray 6) 0
  packet := (local.packets security)[0]
  owner := distribution.Exchange security --initiator --local=local --receive-identity
  expect-throw "SMP_DISTRIBUTION_INVALID_STATE": owner.receive packet
  expect-equals [] owner.start
  expect-throw "SMP_DISTRIBUTION_INVALID_STATE": owner.start
  owner.receive packet
  expect ((catch: owner.receive packet) is PairingError)
  expect-throw "SMP_DISTRIBUTION_INVALID_STATE": owner.peer-identity
  unrequested := distribution.Exchange security --no-initiator --no-receive-identity
  expect-equals [] unrequested.start
  expect ((catch: unrequested.receive packet) is PairingError)
  lost := distribution.Exchange security --initiator --local=local --receive-identity
  lost.start
  lost.receive packet
  security.encrypted = false
  expect-throw "SMP_IDENTITY_NOT_ENCRYPTED": lost.peer-identity
  security.encrypted = true
  expect-throw "SMP_DISTRIBUTION_INVALID_STATE": lost.peer-identity
  early := distribution.Exchange security --no-initiator --local=local --no-receive-identity
  security.paired = false
  expect-throw "SMP_IDENTITY_NOT_ENCRYPTED": early.start
