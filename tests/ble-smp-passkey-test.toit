// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Passkey Entry in the SMP engine: two engines pair with each other for every
// IO capability combination, over Secure Connections and legacy pairing,
// including the rounds that fail on a mistyped passkey.

import expect show *
import ble.experimental.smp-features as features
import ble.experimental.smp-pairing as smp

INITIATOR ::= #[0, 1, 2, 3, 4, 5, 6]
RESPONDER ::= #[1, 6, 5, 4, 3, 2, 0xc1]

main:
  roles
  [true, false].do: | secure-connections/bool |
    5.repeat: | a/int |
      5.repeat: | b/int |
        exchange a b --secure-connections=secure-connections
    wrong-passkey --secure-connections=secure-connections
    refused-entry --secure-connections=secure-connections
  expected-authentication-failure

// Table 2.8: who types; null means the pair cannot use Passkey Entry.
roles:
  expect-equals [false, true] (features.passkey-roles 0 2)
  expect-equals [false, true] (features.passkey-roles 4 2)
  expect-equals [true, false] (features.passkey-roles 2 0)
  expect-equals [true, false] (features.passkey-roles 2 4)
  expect-equals [true, true] (features.passkey-roles 2 2)
  expect-equals [false, true] (features.passkey-roles 0 4)
  expect-equals [true, false] (features.passkey-roles 4 1)
  expect-equals [false, true] (features.passkey-roles 4 4)
  expect-null (features.passkey-roles 0 1)
  expect-null (features.passkey-roles 3 4)

session --initiator/bool --io/int --secure-connections/bool --authenticate/bool=false -> smp.Session:
  return smp.Session --initiator=initiator --io-capability=io --require-authentication=authenticate
      --local-address=(initiator ? INITIATOR : RESPONDER)
      --peer-address=(initiator ? RESPONDER : INITIATOR)
      --secure-connections=secure-connections
      --bond

/**
Pairs an initiator with IO capability $a and a responder with $b and checks
  the method. Both ask for MITM protection when the pair can provide it.
*/
exchange a/int b/int --secure-connections/bool --typed/int?=null -> List:
  roles := features.passkey-roles a b
  numeric := secure-connections and (a == 1 or a == 4) and (b == 1 or b == 4)
  passkey := roles != null and not numeric
  authenticate := passkey or numeric
  initiator := session --initiator --io=a --secure-connections=secure-connections --authenticate=authenticate
  responder := session --no-initiator --io=b --secure-connections=secure-connections --authenticate=authenticate
  // Both-keyboard pairs type the same number the users agree on.
  shared := 123456
  to-responder := initiator.start
  to-initiator := []
  rounds := 0
  while (not to-responder.is-empty or not to-initiator.is-empty or initiator.passkey-requested or responder.passkey-requested) and rounds < 200:
    rounds++
    next-to-initiator := []
    to-responder.do: | packet/ByteArray | next-to-initiator.add-all (responder.receive packet)
    next-to-responder := []
    to-initiator.do: | packet/ByteArray | next-to-responder.add-all (initiator.receive packet)
    to-initiator = next-to-initiator
    to-responder = next-to-responder
    // Users read one screen and type into the other device, once it shows
    // something; with keyboards on both sides they agree on a number.
    both := roles and roles[0] and roles[1]
    if initiator.passkey-requested:
      shown := typed or (both ? shared : responder.passkey-display)
      if shown: to-responder.add-all (initiator.enter-passkey shown)
    if responder.passkey-requested:
      shown := typed or (both ? shared : initiator.passkey-display)
      if shown: to-initiator.add-all (responder.enter-passkey shown)
  if numeric:
    // Numeric Comparison waits for approval; not this test's subject.
    expect-equals "approval" initiator.state
    return [initiator, responder]
  if typed != null: return [initiator, responder]
  expect initiator.verified
  expect responder.verified
  expect-equals initiator.key responder.key
  expect-equals passkey initiator.authenticated
  expect-equals passkey responder.authenticated
  expect-equals (not secure-connections) initiator.legacy
  return [initiator, responder]

// A wrong passkey fails the first round in which a bit differs (Confirm Value Failed).
wrong-passkey --secure-connections/bool:
  // Keyboard-only on both sides: each user types a different number.
  initiator := session --initiator --io=2 --secure-connections=secure-connections --authenticate
  responder := session --no-initiator --io=2 --secure-connections=secure-connections --authenticate
  to-responder := initiator.start
  to-initiator := []
  typed := false
  failures := []
  20.repeat:
    next-to-initiator := []
    to-responder.do: | packet/ByteArray | next-to-initiator.add-all (responder.receive packet)
    next-to-responder := []
    to-initiator.do: | packet/ByteArray | next-to-responder.add-all (initiator.receive packet)
    to-initiator = next-to-initiator
    to-responder = next-to-responder
    if not typed and initiator.passkey-requested and responder.passkey-requested:
      typed = true
      to-responder.add-all (initiator.enter-passkey 1)
      to-initiator.add-all (responder.enter-passkey 3)
  expect (not initiator.verified)
  expect (not responder.verified)
  expect (initiator.failure == 4 or responder.failure == 4)

// A user who does not type ends the exchange with Passkey Entry Failed.
refused-entry --secure-connections/bool:
  initiator := session --initiator --io=0 --secure-connections=secure-connections --authenticate
  responder := session --no-initiator --io=2 --secure-connections=secure-connections --authenticate
  packets := initiator.start
  10.repeat:
    if responder.passkey-requested:
      expect-equals [#[5, 1]] responder.reject-passkey
      expect-equals 1 responder.failure
      return
    replies := []
    packets.do: replies.add-all (responder.receive it)
    packets = []
    replies.do: packets.add-all (initiator.receive it)
  throw "PASSKEY_NEVER_REQUESTED"

// A required authentication fails when no side can type.
expected-authentication-failure:
  initiator := smp.Session --initiator --io-capability=1 --require-authentication
      --local-address=INITIATOR
      --peer-address=RESPONDER
      --secure-connections=false
  responder := session --no-initiator --io=0 --secure-connections=false
  request := initiator.start
  response := responder.receive request[0]
  expect-equals [#[5, 3]] (initiator.receive response[0])
