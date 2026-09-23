// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.smp-pairing as smp
import ble.experimental.sc-crypto as sc
import ble.experimental.sc-ecdh as ecdh
import encoding.hex
import expect show *
import system
import .ble-sc-ecdh-test as ecdh-fixture

main:
  [false, true].do: | numeric/bool |
    [false, true].do: | early/bool | success --numeric=numeric --early=early
    fresh-nonces --numeric=numeric
  failures
  security-request-during-feature-exchange
  bonding
  success --numeric --early --bond
  association-rounds
  [false, true].do: | initiator/bool |
    rejected-points initiator
    [0x40, 0x80, 0xc0].do: | rfu/int |
      peer-transcript initiator rfu
      peer-transcript initiator rfu --strip-check

association-rounds:
  [false, true].do: | initiator/bool |
    [1, 3].do: | own-io/int |
      5.repeat: | peer-io/int |
        nonces := []
        3.repeat:
          nonce := peer-transcript initiator 0 --own-io=own-io --peer-io=peer-io
          expect (not nonces.contains nonce)
          nonces.add nonce
    [1, 4].do: | peer-io/int |
      nonces := []
      3.repeat:
        nonce := peer-transcript initiator 0 --own-io=1 --peer-io=peer-io --numeric
        expect (not nonces.contains nonce)
        nonces.add nonce
    [0, 2, 3].do: | peer-io/int |
      session := smp.Session --initiator=initiator --io-capability=1
          --require-authentication
          --local-address=#[0, 1, 2, 3, 4, 5, 6]
          --peer-address=#[1, 6, 5, 4, 3, 2, 1]
      try:
        if initiator: expect-equals [#[1, 1, 0, 12, 16, 0, 0]] (session.start --now=0)
        expect-equals [#[5, 3]]
            session.receive #[initiator ? 2 : 1, peer-io, 0, 8, 16, 0, 0] --now=1
        expect-equals "failed" session.state
        expect (not session.verified and not session.authenticated)
        expect-throw "SMP_KEY_NOT_READY": session.key
      finally:
        session.close

security-request-during-feature-exchange:
  session := smp.Session --initiator --io-capability=3
      --no-require-authentication
      --local-address=#[0, 1, 2, 3, 4, 5, 6]
      --peer-address=#[0, 6, 5, 4, 3, 2, 1]
  try:
    session.start --now=1
    deadline := session.deadline
    [0, 4, 8, 0x0d, 0xff].do: | auth/int |
      expect-equals [] (session.receive #[0x0b, auth] --now=10)
      expect-equals "features" session.state
      expect-equals deadline session.deadline
      expect-equals null session.failure
      expect-throw "SMP_KEY_NOT_READY": session.key
    response := session.receive #[2, 3, 0, 8, 16, 0, 0] --now=11
    expect-equals 1 response.size
    expect-equals 65 response[0].size
    expect-equals 0x0c response[0][0]
    expect-equals "public" session.state
  finally:
    session.close

rejected-points initiator/bool:
  // Off-curve zero and out-of-field coordinates must receive the required
  // failure response in both roles, with no candidate key retained after GC.
  debug := ecdh-fixture.wire
      "20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6"
      "dc809c49652aeb6d63329abf5a52155c766345c28fed3024741c8ed01589d28b"
  cases := [[ByteArray 64, 0x0b], [(ByteArray 64 --initial=0xff), 0x0b], [null, 0x0b], [debug, 0x0a]]
  [true, false].do: | zero-y/bool |
    // Validate the generated point first, then ensure the mutation is off-curve.
    // Regenerate if a changed point happens to remain valid.
    attempts := 0
    while true:
      if attempts == 64: throw "INVALID_POINT_GENERATION_FAILED"
      attempts++
      peer := ecdh.generate
      // SM p30 section 4.8.1.3 requires an even tester private scalar. Check the
      // generated SEC1 encoding before examining its big-endian scalar's LSB.
      private := peer.private-key.der
      expect (private.size >= 39)
      expect-equals #[0x30] private[..1]
      expect (private[1] < 128)
      expect-equals #[2, 1, 1, 4, 32] private[2..7]
      if private[38] & 1 != 0: continue
      point := ecdh.public-key peer.public-key
      expect-equals 32 (ecdh.dhkey peer.private-key point).size
      if zero-y:
        32.repeat: point[32 + it] = 0
      else:
        point[32] ^= 1
      error := catch: ecdh.dhkey peer.private-key point
      if not error: continue
      expect-equals "SMP_INVALID_PUBLIC_KEY" error
      cases.add [point, 0x0b]
      break
  cases.do: | test/List |
    point/ByteArray? := test[0]
    reason/int := test[1]
    if point == null and not initiator: continue.do
    session := smp.Session --initiator=initiator --io-capability=3
        --no-require-authentication
        --local-address=#[0, 1, 2, 3, 4, 5, 6]
        --peer-address=#[0, 6, 5, 4, 3, 2, 1]
    try:
      if initiator: session.start --now=0
      output := session.receive #[initiator ? 2 : 1, 3, 0, 8, 16, 0, 0] --now=1
      if point == null:
        // Even a point with our own X must be validated before the reflection
        // guard: an out-of-field Y requires 0x0B, not Invalid Parameters.
        point = output[0][1..].copy
        32.repeat: point[32 + it] = 0xff
      response := session.receive (#[0x0c] + point) --now=2
      point.fill 0
      system.process-stats --gc
      expect-equals [#[5, reason]] response
      expect-equals "failed" session.state
      expect-equals reason session.failure
      expect-equals null session.deadline
      expect (not session.verified and not session.authenticated and not session.bonding)
      expect-throw "SMP_KEY_NOT_READY": session.key
      expect-throw "SMP_INVALID_STATE": session.receive #[0x0c]
    finally:
      session.close

peer-transcript initiator/bool rfu/int -> ByteArray
    --strip-check/bool=false --own-io/int=3 --peer-io/int=3 --numeric/bool=false:
  // SM.TS.p30 SCJW BV-03-C/BV-04-C: RFU bits are ignored for feature
  // selection but remain part of the exchanged AuthReq authenticated by f6.
  // Drive one real Session with an explicit peer transcript, rather than
  // changing a packet between two Sessions that both originated zero RFU bits.
  a := #[0, 1, 2, 3, 4, 5, 6]
  b := #[1, 6, 5, 4, 3, 2, 1]
  session := smp.Session --initiator=initiator --io-capability=own-io
      --require-authentication=numeric
      --local-address=(initiator ? a : b)
      --peer-address=(initiator ? b : a)
  peer := ecdh.generate
  public := ecdh.public-key peer.public-key
  nonce := ByteArray 16: it + 1
  try:
    own-auth := numeric ? 0x0c : 8
    peer-features := #[initiator ? 2 : 1, peer-io, 0, 8 | rfu, 16, 0, 0]
    own-public/ByteArray := ?
    own-nonce/ByteArray := ?
    own-check/ByteArray? := null
    if initiator:
      expect-equals [#[1, own-io, 0, own-auth, 16, 0, 0]] (session.start --now=0)
      own-public = (session.receive peer-features --now=1)[0][1..].copy
      expect-equals [] (session.receive (#[0x0c] + public) --now=2)
      confirm := sc.f4 (reverse public[..32]) (reverse own-public[..32]) nonce 0
      own-nonce = reverse (session.receive (#[3] + (reverse confirm)) --now=3)[0][1..]
      checks := session.receive (#[4] + (reverse nonce)) --now=4
      if numeric:
        expect-equals [] checks
      else:
        own-check = checks[0]
    else:
      expect-equals [#[2, own-io, 0, own-auth, 16, 0, 0]] (session.receive peer-features --now=0)
      messages := session.receive (#[0x0c] + public) --now=1
      own-public = messages[0][1..].copy
      own-nonce = reverse (session.receive (#[4] + (reverse nonce)) --now=2)[0][1..]
      confirm := sc.f4 (reverse own-public[..32]) (reverse public[..32]) own-nonce 0
      expect-equals (#[3] + (reverse confirm)) messages[1]
    peer-features.fill 0
    system.process-stats --gc
    na := initiator ? own-nonce : nonce
    nb := initiator ? nonce : own-nonce
    if numeric:
      ax := reverse (initiator ? own-public[..32] : public[..32])
      bx := reverse (initiator ? public[..32] : own-public[..32])
      expect-equals ((sc.g2 ax bx na nb) % 1_000_000) session.comparison-number
      expect (not session.verified and not session.authenticated)
      expect-throw "SMP_KEY_NOT_READY": session.key
      checks := session.approve true --now=4
      if initiator:
        own-check = checks[0]
      else:
        expect-equals [] checks
    keys := sc.f5 (ecdh.dhkey peer.private-key own-public) na nb a b
    check-auth := strip-check ? 8 : (8 | rfu)
    check := sc.f6 keys.mac-key nonce own-nonce (ByteArray 16)
        #[check-auth, 0, peer-io]
        (initiator ? b : a)
        (initiator ? a : b)
    result := session.receive (#[0x0d] + (reverse check)) --now=5
    if strip-check:
      expect-equals [#[5, 0x0b]] result
      expect (not session.verified)
      expect-throw "SMP_KEY_NOT_READY": session.key
    else:
      if initiator:
        expect-equals [] result
      else:
        own-check = result[0]
      expected := sc.f6 keys.mac-key own-nonce nonce (ByteArray 16)
          #[own-auth, 0, own-io]
          (initiator ? a : b)
          (initiator ? b : a)
      expect-equals (#[0x0d] + (reverse expected)) own-check
      expect session.verified
      expect-equals numeric session.authenticated
      expect-equals keys.ltk session.key
      expect (not session.bonding)
    return own-nonce.copy
  finally:
    session.close

reverse bytes/ByteArray -> ByteArray:
  return ByteArray bytes.size: bytes[bytes.size - 1 - it]

// SCJW BV-01-C/BV-02-C require three distinct Authentication Stage 1 nonces
// per role. Inspect actual Random PDUs, without logging their contents.
fresh-nonces --numeric/bool:
  initiator-nonces := []
  responder-nonces := []
  3.repeat:
    pair := Pair --numeric=numeric
    try:
      messages := pair.public-exchange
      expect-equals [] (pair.a.receive messages[0] --now=0)
      random := (pair.a.receive messages[1] --now=0)[0]
      expect-equals 17 random.size
      expect-equals 4 random[0]
      nonce := random[1..].copy
      expect (not initiator-nonces.contains nonce)
      initiator-nonces.add nonce
      reply := (pair.b.receive random --now=0)[0]
      expect-equals 17 reply.size
      expect-equals 4 reply[0]
      nonce = reply[1..].copy
      expect (not responder-nonces.contains nonce)
      responder-nonces.add nonce
      check := pair.a.receive reply --now=0
      system.process-stats --gc
      if numeric:
        expect-equals [] check
        expect-equals pair.a.comparison-number pair.b.comparison-number
        expect-equals [] (pair.b.approve true --now=1)
        check = pair.a.approve true --now=1
      response := pair.b.receive check[0] --now=2
      expect-equals [] (pair.a.receive response[0] --now=3)
      expect (pair.a.verified and pair.b.verified)
      expect-equals numeric pair.a.authenticated
      expect-equals numeric pair.b.authenticated
      expect-equals pair.a.key pair.b.key
      expect-equals 16 pair.a.key.size
    finally:
      pair.a.close
      pair.b.close
  expect-equals 3 initiator-nonces.size
  expect-equals 3 responder-nonces.size

class Pair:
  a/smp.Session
  b/smp.Session

  constructor --numeric/bool=false --bond/bool=false --a-identity/bool=true --b-identity/bool=true:
    a = smp.Session --initiator --io-capability=(numeric ? 1 : 3)
        --bond=bond
        --distribute-identity=(bond and a-identity)
        --request-identity=bond
        --require-authentication=numeric
        --local-address=#[0, 1, 2, 3, 4, 5, 6]
        --peer-address=#[1, 6, 5, 4, 3, 2, 1]
    b = smp.Session --no-initiator --io-capability=(numeric ? 1 : 3)
        --bond=bond
        --distribute-identity=(bond and b-identity)
        --request-identity=bond
        --require-authentication=numeric
        --local-address=#[1, 6, 5, 4, 3, 2, 1]
        --peer-address=#[0, 1, 2, 3, 4, 5, 6]

  // Returns the responder's public key and confirm, after feature exchange.
  public-exchange -> List:
    response := b.receive (a.start --now=0)[0] --now=0
    public := a.receive response[0] --now=0
    return b.receive public[0] --now=0

  random-exchange -> List:
    messages := public-exchange
    expect-equals [] (a.receive messages[0] --now=0)
    random := a.receive messages[1] --now=0
    reply := b.receive random[0] --now=0
    return a.receive reply[0] --now=0

success --numeric/bool --early/bool --bond/bool=false:
  pair := Pair --numeric=numeric --bond=bond
  check := pair.random-exchange
  expect (not pair.a.verified and not pair.b.verified)
  expect-throw "SMP_KEY_NOT_READY": pair.a.key
  expect-throw "SMP_KEY_NOT_READY": pair.b.key
  system.process-stats --gc
  if numeric:
    expect-equals [] check
    expect (0 <= pair.a.comparison-number < 1_000_000)
    expect-equals pair.a.comparison-number pair.b.comparison-number
    expect (not pair.a.authenticated and not pair.b.authenticated)
    if not early: expect-equals [] (pair.b.approve true --now=1)
    check = pair.a.approve true --now=1
  response := pair.b.receive check[0] --now=2
  if numeric and early:
    expect-equals [] response
    expect (not pair.b.verified)
    expect-throw "SMP_KEY_NOT_READY": pair.b.key
    response = pair.b.approve true --now=3
  expect pair.b.verified
  expect (not pair.a.verified)
  expect-equals [] (pair.a.receive response[0] --now=4)
  expect pair.a.verified
  expect-equals numeric pair.a.authenticated
  expect-equals numeric pair.b.authenticated
  expect-equals pair.a.key pair.b.key
  expect-equals 16 pair.a.key.size
  first := pair.a.key
  saved := first.copy
  first[0] ^= 1
  system.process-stats --gc
  expect-equals saved pair.a.key
  expect-equals null pair.a.deadline
  pair.a.close
  pair.b.close
  expect-throw "SMP_KEY_NOT_READY": pair.a.key

failures:
  pair := Pair
  messages := pair.public-exchange
  pair.a.receive messages[0] --now=0
  bad-confirm/ByteArray := messages[1].copy
  bad-confirm[1] ^= 1
  random := pair.a.receive bad-confirm --now=0
  reply := pair.b.receive random[0] --now=0
  expect-equals [#[5, 4]] (pair.a.receive reply[0] --now=0)
  expect-equals 4 pair.a.failure
  expect-throw "SMP_KEY_NOT_READY": pair.a.key
  expect-equals [] (pair.b.receive #[5, 4] --now=0)
  expect (not pair.b.verified)
  pair = Pair
  check := pair.random-exchange
  check[0][1] ^= 1
  expect-equals [#[5, 0x0b]] (pair.b.receive check[0] --now=0)
  expect-throw "SMP_KEY_NOT_READY": pair.b.key
  pair.a.close
  pair = Pair --numeric
  pair.random-exchange
  expect-equals [#[5, 0x0c]] (pair.a.approve false --now=1)
  expect (not pair.a.authenticated)
  pair.b.close
  pair = Pair --numeric
  pair.random-exchange
  early := pair.a.approve true --now=1
  expect-equals [] (pair.b.receive early[0] --now=2)
  expect-equals [#[5, 0x0a]] (pair.b.receive early[0] --now=3)
  expect-throw "SMP_KEY_NOT_READY": pair.b.key
  pair.a.close
  pair = Pair --numeric
  pair.random-exchange
  expect-throw "SMP_TIMEOUT": pair.a.approve true --now=30_000_000
  expect-throw "SMP_KEY_NOT_READY": pair.a.key
  pair.b.close
  [false, true].do: | negate/bool |
    pair = Pair
    public := (pair.a.receive (pair.b.receive (pair.a.start --now=0)[0] --now=0)[0] --now=0)[0]
    if negate:
      // Q and -Q are both valid points with the same X. Validate the alternate
      // point independently using ECDH before sending it to the session.
      original := public[1..].copy
      prime := hex.decode "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"
      borrow := 0
      32.repeat: | i/int |
        value := prime[31 - i] - public[33 + i] - borrow
        borrow = value < 0 ? 1 : 0
        public[33 + i] = value & 0xff
      expect-equals 0 borrow
      validator := ecdh.generate
      expect-equals (ecdh.dhkey validator.private-key original)
          (ecdh.dhkey validator.private-key public[1..])
      expect (original != public[1..])
    // Equal X requires DHKey Check Failed, even for valid curve points.
    expect-equals [#[5, 0x0b]] (pair.a.receive public --now=0)
    system.process-stats --gc
    expect-equals "failed" pair.a.state
    expect-equals null pair.a.deadline
    expect-throw "SMP_KEY_NOT_READY": pair.a.key
    pair.b.close
  pair = Pair
  pair.a.start --now=10
  expect-equals [] (pair.a.receive #[0xff] --now=20)
  expect-equals 30_000_010 pair.a.deadline
  expect-throw "SMP_TIMEOUT": pair.a.check-timeout --now=30_000_010
  expect-throw "SMP_INVALID_STATE": pair.a.receive #[2, 3, 0, 8, 16, 0, 0] --now=30_000_011
  pair.b.close
  pair = Pair
  pair.a.start --now=0
  // A peer without Secure Connections gets legacy Just Works: a confirm, not a refusal.
  legacy-start := pair.a.receive #[2, 3, 0, 0, 16, 0, 0] --now=0
  expect-equals 1 legacy-start.size
  expect-equals 17 legacy-start[0].size
  expect-equals 3 legacy-start[0][0]
  pair.b.close
  pair = Pair
  pair.a.start --now=0
  expect-equals [#[5, 0x0a]] (pair.a.receive #[4, 0] --now=0)
  pair.b.close

bonding:
  [false, true].do: | a-identity/bool |
    [false, true].do: | b-identity/bool |
      pair := Pair --bond --a-identity=a-identity --b-identity=b-identity
      expect (not pair.a.bonding)
      expect-throw "SMP_KEY_NOT_READY": pair.a.distribute-identity
      checks := pair.random-exchange
      response := pair.b.receive checks[0] --now=1
      pair.a.receive response[0] --now=2
      expect (pair.a.bonding and pair.b.bonding)
      expect-equals pair.a.key pair.b.key
      expect-equals a-identity pair.a.distribute-identity
      expect-equals a-identity pair.b.receive-identity
      expect-equals b-identity pair.b.distribute-identity
      expect-equals b-identity pair.a.receive-identity
      pair.a.close
      expect (not pair.a.bonding)
      expect-throw "SMP_KEY_NOT_READY": pair.a.receive-identity
      pair.b.close
  // An unbonded peer reduces the responder's plan to no distribution.
  peer := smp.Session --no-initiator --io-capability=3 --no-require-authentication
      --local-address=#[0, 1, 2, 3, 4, 5, 6]
      --peer-address=#[0, 6, 5, 4, 3, 2, 1]
      --bond
      --distribute-identity
      --request-identity
  expect-equals [#[2, 3, 0, 8, 16, 0, 0]] (peer.receive #[1, 3, 0, 8, 16, 0, 0] --now=0)
  peer.close

  // A responder may reduce offered directions, never add an unoffered one.
  pair := Pair --bond --no-a-identity
  pair.a.start --now=0
  expect-equals [#[5, 0x0a]] (pair.a.receive #[2, 3, 0, 9, 16, 2, 2] --now=0)
  expect (not pair.a.bonding)
  pair.a.close
  pair.b.close
