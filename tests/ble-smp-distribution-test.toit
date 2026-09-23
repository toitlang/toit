// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.smp-distribution as distribution
import ble.experimental.smp-identity as identity
import ble.experimental.smp-legacy as legacy
import ble.experimental.smp-features show PairingError
import expect show *
import system
import .ble-smp-identity-test as fixture

main:
  [false, true].do: | central-key/bool |
    [false, true].do: | peripheral-key/bool |
      exchange central-key peripheral-key
  failures
  [false, true].do: | central-key/bool |
    [false, true].do: | peripheral-key/bool |
      [false, true].do: | identities/bool |
        legacy-exchange central-key peripheral-key --identities=identities
  legacy-failures

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

legacy-exchange central-key/bool peripheral-key/bool --identities/bool:
  security := fixture.Security
  central-id := identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  peripheral-id := identity.Identity (ByteArray 16 --initial=2) #[1, 2, 3, 4, 5, 0xc6] 1
  central-ltk := legacy.LegacyKey.random
  peripheral-ltk := legacy.LegacyKey.random
  central := distribution.Exchange security --initiator
      --local=(identities ? central-id : null)
      --receive-identity=identities
      --local-key=(central-key ? central-ltk : null)
      --receive-key=peripheral-key
  peripheral := distribution.Exchange security --no-initiator
      --local=(identities ? peripheral-id : null)
      --receive-identity=identities
      --local-key=(peripheral-key ? peripheral-ltk : null)
      --receive-key=central-key
  per-side := identities ? 2 : 0
  peripheral-packets := peripheral.start
  expect-equals (per-side + (peripheral-key ? 2 : 0)) peripheral-packets.size
  central-packets := central.start
  expects := peripheral-key or identities
  expect-equals (expects ? 0 : per-side + (central-key ? 2 : 0)) central-packets.size
  // Keys come first, then identities; the central issues after the last one.
  if peripheral-key:
    expect-equals 6 peripheral-packets[0][0]
    expect-equals 7 peripheral-packets[1][0]
    if identities: expect-equals 8 peripheral-packets[2][0]
  peripheral-packets.do: | packet/ByteArray |
    expect-equals [] central-packets
    central-packets = central.receive packet
  if expects:
    expect-equals (per-side + (central-key ? 2 : 0)) central-packets.size
  if peripheral-key:
    expect-equals peripheral-ltk.ltk central.peer-legacy-key.ltk
    expect-equals peripheral-ltk.ediv central.peer-legacy-key.ediv
    expect-equals peripheral-ltk.rand central.peer-legacy-key.rand
  else:
    expect-null central.peer-legacy-key
  if identities: expect-equals peripheral-id.irk central.peer-identity.irk
  central-packets.do: expect-equals [] (peripheral.receive it)
  if central-key:
    expect-equals central-ltk.ltk peripheral.peer-legacy-key.ltk
  else:
    expect-null peripheral.peer-legacy-key
  if identities: expect-equals central-id.irk peripheral.peer-identity.irk
  central.close
  peripheral.close

legacy-failures:
  security := fixture.Security
  key := legacy.LegacyKey.random
  packets := key.packets security
  // Central Identification before Encryption Information is a protocol error.
  owner := distribution.Exchange security --initiator --no-receive-identity --receive-key
  expect-equals [] owner.start
  expect ((catch: owner.receive packets[1]) is PairingError)
  expect-throw "SMP_DISTRIBUTION_INVALID_STATE": owner.peer-legacy-key
  // A key from a peer that did not negotiate one is a protocol error.
  unrequested := distribution.Exchange security --initiator --no-receive-identity
  expect-equals [] unrequested.start
  expect ((catch: unrequested.receive packets[0]) is PairingError)
  // Truncated packets are rejected and close the receiver.
  receiver := legacy.LegacyKeyReceiver security
  expect ((catch: receiver.receive packets[0][..16]) is PairingError)
  expect-throw "SMP_IDENTITY_CLOSED": receiver.key
  // Key packets need an encrypted, paired link.
  security.encrypted = false
  expect-throw "SMP_IDENTITY_NOT_ENCRYPTED": key.packets security
  security.encrypted = true
