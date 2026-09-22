// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.smp-identity as identity
import ble.experimental.smp-features show PairingError
import ble.experimental.security-state show SecurityState
import expect show *
import system

main:
  replay-identities
  security := Security
  key := ByteArray 16: it + 1
  address := #[1, 2, 3, 4, 5, 6]
  local := identity.Identity key address 0
  packets := local.packets security
  expect-equals (#[8] + (ByteArray 16: 16 - it)) packets[0]
  expect-equals #[9, 0, 1, 2, 3, 4, 5, 6] packets[1]
  receiver := identity.Receiver security
  receiver.receive packets[0]
  expect-null receiver.identity
  packets[0].fill 0
  system.process-stats --gc
  receiver.receive packets[1]
  peer := receiver.identity
  expect-equals key peer.irk
  expect-equals address peer.address
  expect peer.has-resolving-key
  key.fill 0
  address.fill 0
  packets[1].fill 0
  peer.irk.fill 0
  peer.address.fill 0
  expect-equals (ByteArray 16: it + 1) peer.irk
  expect-equals #[1, 2, 3, 4, 5, 6] peer.address
  expect (not (identity.Identity (ByteArray 16) (ByteArray 6) 0).has-resolving-key)
  valid := local.packets security
  [#[9, 0, 1, 2, 3, 4, 5, 6], #[8], (ByteArray 18), #[]].do: | packet/ByteArray |
    broken := identity.Receiver security
    failure := catch: broken.receive packet
    expect (failure is PairingError)
    expect-equals 0x0a failure.reason
    expect-throw "SMP_IDENTITY_CLOSED": broken.identity
  [valid[0], #[9], #[9, 2, 1, 2, 3, 4, 5, 6],
   #[9, 1, 1, 2, 3, 4, 5, 0x40], #[9, 1, 0, 0, 0, 0, 0, 0xc0]].do: | packet/ByteArray |
    broken := identity.Receiver security
    broken.receive valid[0]
    expect ((catch: broken.receive packet) is PairingError)
    expect-throw "SMP_IDENTITY_CLOSED": broken.identity
  expect ((catch: receiver.receive valid[1]) is PairingError)
  expect-throw "SMP_IDENTITY_CLOSED": receiver.identity
  static-identity := identity.Identity (ByteArray 16) #[1, 0, 0, 0, 0, 0xc0] 1
  expect-equals #[9, 1, 1, 0, 0, 0, 0, 0xc0] (static-identity.packets security)[1]
  [false, true].do: | after-first/bool |
    broken := identity.Receiver security
    security.encrypted = true
    if after-first: broken.receive valid[0]
    security.encrypted = false
    expect-throw "SMP_IDENTITY_NOT_ENCRYPTED": broken.receive valid[after-first ? 1 : 0]
    expect-throw "SMP_IDENTITY_CLOSED": broken.identity
    expect-throw "SMP_IDENTITY_NOT_ENCRYPTED": local.packets security
  security.encrypted = true
  complete := identity.Receiver security
  valid.do: complete.receive it
  security.encrypted = false
  expect-throw "SMP_IDENTITY_NOT_ENCRYPTED": complete.identity
  security.encrypted = true
  expect-throw "SMP_IDENTITY_CLOSED": complete.identity
  abandoned := identity.Receiver security
  abandoned.receive valid[0]
  abandoned.close
  expect-throw "SMP_IDENTITY_CLOSED": abandoned.receive valid[1]
  expect-throw "SMP_IDENTITY_CLOSED": abandoned.identity
  security.paired = false
  expect-throw "SMP_IDENTITY_NOT_ENCRYPTED": local.packets security

// Saved synthetic identities, never captured peer keys. Mutate every byte
// through all octet values, including valid key/address changes.
replay-identities:
  key-packet := #[8] + (ByteArray 16: it + 1)
  addresses := [#[9, 0, 1, 2, 3, 4, 5, 6], #[9, 1, 1, 2, 3, 4, 5, 0xc6]]
  [key-packet, addresses[0], addresses[1]].do: | seed/ByteArray |
    is-key := seed[0] == 8
    seed.size.repeat: | offset/int |
      256.repeat: | value/int |
        changed := seed.copy
        changed[offset] = value
        replay-identity (is-key ? changed : key-packet)
            is-key ? addresses[0] : changed
    seed.size.repeat: | length/int |
      shortened := seed[..length].copy
      replay-identity (is-key ? shortened : key-packet)
          is-key ? addresses[0] : shortened
    replay-identity (is-key ? seed + #[0] : key-packet)
        is-key ? addresses[0] : seed + #[0]
  // Static addresses exclude all-zero/all-one random portions.
  [#[0, 0, 0, 0, 0, 0xc0], #[255, 255, 255, 255, 255, 255]].do:
    replay-identity key-packet (#[9, 1] + it)

replay-identity key-packet/ByteArray address-packet/ByteArray:
  key-valid := key-packet.size == 17 and key-packet[0] == 8
  address-valid := address-packet.size == 8 and address-packet[0] == 9 and
      address-packet[1] <= 1
  if address-valid and address-packet[1] == 1:
    random-bits := address-packet[7] & 0x3f
    all-ones := random-bits == 0x3f
    5.repeat: | index/int |
      random-bits |= address-packet[index + 2]
      all-ones = all-ones and address-packet[index + 2] == 255
    address-valid = address-packet[7] & 0xc0 == 0xc0 and
        random-bits != 0 and not all-ones
  receiver := identity.Receiver Security
  key-copy := key-packet.copy
  address-copy := address-packet.copy
  failure := catch:
    receiver.receive key-copy
    expect-null receiver.identity
    expect-equals key-packet key-copy
    key-copy.fill 0
    system.process-stats --gc
    receiver.receive address-copy
  expect-equals address-packet address-copy
  if not key-valid: expect-equals key-packet key-copy
  if not key-valid or not address-valid:
    expect (failure is PairingError)
    expect-equals 0x0a failure.reason
    expect-throw "SMP_IDENTITY_CLOSED": receiver.identity
    expect-throw "SMP_IDENTITY_CLOSED": receiver.receive key-packet
  else:
    expect-null failure
    address-copy.fill 0
    system.process-stats --gc
    peer := receiver.identity
    expect-equals (ByteArray 16: key-packet[16 - it]) peer.irk
    expect-equals address-packet[2..] peer.address
    expect-equals address-packet[1] peer.address-type
  receiver.close
  expect-throw "SMP_IDENTITY_CLOSED": receiver.identity

class Security implements SecurityState:
  paired/bool := true
  encrypted/bool := true
  authenticated -> bool: return false
