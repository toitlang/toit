// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Legacy Just Works in the pairing engine, against an emulated legacy peer
// (no Secure Connections bit) in both roles.

import crypto
import expect show *
import ble.experimental.smp-pairing as smp
import ble.experimental.smp-legacy as legacy

LOCAL ::= #[0, 1, 2, 3, 4, 5, 6]   // type, then big-endian address
PEER ::= #[1, 6, 5, 4, 3, 2, 1]

reverse bytes/ByteArray -> ByteArray: return ByteArray bytes.size: bytes[bytes.size - 1 - it]

// c1 with TK zero as the peer computes it: addresses least significant byte first.
confirm random/ByteArray preq/ByteArray pres/ByteArray initiating/ByteArray responding/ByteArray -> ByteArray:
  return legacy.c1 (ByteArray 16) random preq pres initiating[0] (reverse initiating[1..]) responding[0] (reverse responding[1..])

main:
  as-initiator
  as-responder
  wrong-confirm
  refused

as-initiator:
  session := smp.Session --initiator --io-capability=3 --no-require-authentication
      --local-address=LOCAL
      --peer-address=PEER
      --bond
  request := (session.start --now=0)[0]
  expect-equals #[1, 3, 0, 9, 16, 1, 1] request
  response := #[2, 3, 0, 1, 16, 1, 1]
  out := session.receive response --now=1
  expect-equals 1 out.size
  expect-equals 3 out[0][0]
  mconfirm := out[0][1..]
  srand := crypto.random --size=16
  sconfirm := confirm srand request response LOCAL PEER
  out = session.receive (#[3] + sconfirm) --now=2
  expect-equals 4 out[0][0]
  mrand := out[0][1..]
  expect-equals mconfirm (confirm mrand request response LOCAL PEER)
  out = session.receive (#[4] + srand) --now=3
  expect-equals [] out
  expect session.verified
  expect session.legacy
  expect (not session.authenticated)
  expect session.bonding
  expect-equals [true, true] session.legacy-key-distribution
  expect-equals (reverse (legacy.s1 (ByteArray 16) srand mrand)) session.key
  session.close

as-responder:
  session := smp.Session --no-initiator --io-capability=3 --no-require-authentication
      --local-address=LOCAL
      --peer-address=PEER
      --bond
  request := #[1, 3, 0, 1, 16, 1, 1]
  out := session.receive request --now=0
  expect-equals [#[2, 3, 0, 9, 16, 1, 1]] out
  response := out[0]
  mrand := crypto.random --size=16
  // The peer initiates: its address is the initiating one.
  mconfirm := confirm mrand request response PEER LOCAL
  out = session.receive (#[3] + mconfirm) --now=1
  expect-equals 3 out[0][0]
  sconfirm := out[0][1..]
  out = session.receive (#[4] + mrand) --now=2
  expect-equals 4 out[0][0]
  srand := out[0][1..]
  expect-equals sconfirm (confirm srand request response PEER LOCAL)
  expect session.verified
  expect session.legacy
  expect-equals (reverse (legacy.s1 (ByteArray 16) srand mrand)) session.key
  session.close

wrong-confirm:
  session := smp.Session --no-initiator --io-capability=3 --no-require-authentication
      --local-address=LOCAL
      --peer-address=PEER
  session.receive #[1, 3, 0, 0, 16, 0, 0] --now=0
  session.receive (#[3] + (ByteArray 16 --initial=7)) --now=1
  expect-equals [#[5, 4]] (session.receive (#[4] + (ByteArray 16 --initial=9)) --now=2)
  expect-equals "failed" session.state
  expect-equals 4 session.failure

refused:
  // A local authentication requirement cannot be met by legacy Just Works.
  session := smp.Session --initiator --io-capability=1 --require-authentication
      --local-address=LOCAL
      --peer-address=PEER
  session.start --now=0
  expect-equals [#[5, 3]] (session.receive #[2, 3, 0, 0, 16, 0, 0] --now=1)
  // A legacy peer wanting MITM with a keyboard would need Passkey Entry.
  session = smp.Session --no-initiator --io-capability=1 --no-require-authentication
      --local-address=LOCAL
      --peer-address=PEER
  expect-equals [#[5, 3]] (session.receive #[1, 2, 0, 4, 16, 0, 0] --now=0)
  // A short key is refused too.
  session = smp.Session --no-initiator --io-capability=3 --no-require-authentication
      --local-address=LOCAL
      --peer-address=PEER
  expect-equals [#[5, 6]] (session.receive #[1, 3, 0, 0, 7, 0, 0] --now=0)
