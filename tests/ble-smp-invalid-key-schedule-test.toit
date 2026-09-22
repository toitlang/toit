// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.pairing-attempts as retry
import ble.experimental.sc-ecdh as ecdh
import ble.experimental.smp-pairing as smp
import expect show *
import system
import .ble-smp-pairing-test as fixture

// SM p30 4.8.1.3/Table 4.9, rounds 1–4 with FKC=1. Session generates a new
// key pair for every accepted feature exchange. Only a central exposes its
// public key before invalid-key rejection, so freshness is observed in that
// role. Retry spacing uses the real policy with a trusted synthetic clock;
// this is not a physical timing or official tester verdict. Round 5 has its
// separate valid same-X regression and unresolved tester-scalar precondition.
main:
  with-timeout --ms=30_000:
    [false, true].do: schedule it

schedule initiator/bool:
  policy := retry.Attempts
  local := initiator ? #[0, 1, 2, 3, 4, 5, 6] : #[1, 6, 5, 4, 3, 2, 1]
  peer := initiator ? #[1, 6, 5, 4, 3, 2, 1] : #[0, 1, 2, 3, 4, 5, 6]
  now := 0
  last-failure/int? := null
  last-gap := 0
  public-keys := []
  failed := 0
  // Defaults documented by Attempts: 1, 2, 4, 8, 16, 32, then 60 seconds.
  delays := [1, 2, 4, 8, 16, 32]
  [1, 2, 3, 4].do: | round/int |
    (round == 1 ? 20 : 1).repeat:
      point := tester-point round
      expect-throw "INVALID_PEER_POINT":
        policy.with-attempt peer --clock=(: now):
          session := smp.Session --initiator=initiator --io-capability=3
              --no-require-authentication
              --local-address=local
              --peer-address=peer
          try:
            if initiator:
              if last-failure != null:
                gap := now - last-failure
                expect (gap >= last-gap)
                last-gap = gap
              expect-equals [#[1, 3, 0, 8, 16, 0, 0]] (session.start --now=now)
            // The tester peripheral distributes no responder keys, as required
            // by the procedure. Both sides advertise Secure Connections.
            output := session.receive #[initiator ? 2 : 1, 3, 0, 8, 16, 0, 0] --now=now
            if initiator:
              expect-equals 1 output.size
              public/ByteArray := output[0]
              expect-equals 65 public.size
              expect-equals 0x0c public[0]
              expect (not public-keys.contains public)
              public-keys.add public.copy
            else:
              expect-equals [#[2, 3, 0, 8, 16, 0, 0]] output
            now += 10
            packet := #[0x0c] + point
            expected := packet.copy
            response := session.receive packet --now=now
            expect-equals expected packet
            packet.fill 0xff
            point.fill 0xff
            system.process-stats --gc
            expect-equals [#[5, 0x0b]] response
            expect-equals "failed" session.state
            expect-equals 0x0b session.failure
            expect-null session.deadline
            expect (not session.verified and not session.authenticated and not session.bonding)
            expect-throw "SMP_KEY_NOT_READY": session.key
            expect-throw "SMP_KEY_NOT_READY": session.distribute-identity
            expect-throw "SMP_KEY_NOT_READY": session.receive-identity
            last-failure = now
            // The policy charges the actual rejected attempt, not a separate
            // synthetic failure unrelated to the cryptographic exchange.
            throw "INVALID_PEER_POINT"
          finally:
            session.close
      delay/int := (failed < delays.size ? delays[failed] : 60) * 1_000_000
      failed++
      now += delay - 1
      called := false
      expect-throw "SMP_REPEATED_ATTEMPTS":
        policy.with-attempt peer --clock=(: now): called = true
      expect (not called)
      now++
  expect-equals 23 failed
  expect-equals (initiator ? 23 : 0) public-keys.size
  // A valid exchange is admitted at the final boundary with the same identity.
  policy.with-attempt peer --clock=(: now): fixture.peer-transcript initiator 0
  print "INVALID_KEY_SCHEDULE role=$(initiator ? "central" : "peripheral") failures=$failed fresh-public-keys=$(public-keys.size) recovered=true"

tester-point round/int -> ByteArray:
  64.repeat:
    pair := ecdh.generate
    scalar := pair.private-key.der
    expect (scalar.size >= 39 and scalar[0] == 0x30 and scalar[1] < 128)
    expect-equals #[2, 1, 1, 4, 32] scalar[2..7]
    if scalar[38] & 1 != 0: continue.repeat
    original := ecdh.public-key pair.public-key
    expect-equals 32 (ecdh.dhkey pair.private-key original).size
    point := original.copy
    if round <= 2:
      32.repeat: point[32 + it] = 0
    else if round == 3:
      point[32] ^= 1
    else:
      point.fill 0
    error := catch: ecdh.dhkey pair.private-key point
    if not error: continue.repeat
    expect-equals "SMP_INVALID_PUBLIC_KEY" error
    return point
  throw "INVALID_POINT_GENERATION_FAILED"
