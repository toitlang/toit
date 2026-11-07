// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import crypto
import crypto.ec
import crypto.rsa
import expect show *
import rp2040
import system
import system.storage
import ...crypto-rsa-async-test-slow as rsa-tests

main:
  a := crypto.random --size=32
  b := crypto.random --size=32
  if a == b: print "crypto-rp2040: FAIL repeated random output"
  expect (a != b)
  [0, 1, 31, 32, 33, 64, 65, 1024, 1025, 4097].do: | size/int |
    bytes := crypto.random --size=size
    expect-equals size bytes.size
    if size >= 32: expect (bytes != (crypto.random --size=size))
  [32, 65, 2057].do: | size/int |
    bytes := ByteArray size --initial=0xa5
    tls-random_ bytes
    expect (bytes != (ByteArray size --initial=0xa5))
  bucket := storage.Bucket.open --flash "toit-rp2040-test/crypto"
  try:
    before := bucket.get "before-reset"
    if not before:
      bucket["before-reset"] = a
      print "crypto-rp2040: resetting to check fresh output"
      rp2040.reset
    expect (before != a)
    bucket.remove "before-reset"
  finally:
    bucket.close
  print "crypto-rp2040: PASS random sizes, TLS random and reset"
  ticks := 0
  background := task::
    while true:
      crypto.random --size=1025
      system.process-stats --gc
      ticks++
      sleep --ms=10
  try:
    print "crypto-rp2040: generating test RSA key"
    // A small test key keeps the hardware regression short; not an application
    // recommendation. Generation runs on the native asynchronous worker.
    pair := rsa.RsaKey.generate --bits=1024
    message := "RP2040 crypto regression"
    expect (pair.verify message (pair.sign message))
    expect (ticks > 0)
    print "crypto-rp2040: PASS asynchronous RSA, concurrent RNG, GC and timers"
    rsa-tests.test-close-pending-generation
    print "crypto-rp2040: PASS abandoned and queued RSA generation"
    [ec.EcKey.CURVE-SECP256R1, ec.EcKey.CURVE-SECP384R1, ec.EcKey.CURVE-SECP521R1].do: | curve/string |
      first := ec.EcKeyPair.generate --curve=curve
      second := ec.EcKeyPair.generate --curve=curve
      expect (first.private-key.der != second.private-key.der)
      signature := first.sign message
      expect (first.verify message signature)
      expect (not (first.verify "$message changed" signature))
      expect (not (second.verify message signature))
      expect-equals (first.compute-shared-secret second.public-key) (second.compute-shared-secret first.public-key)
      print "crypto-rp2040: PASS $curve ECDSA and ECDH"
  finally:
    background.cancel
  print "crypto-rp2040: PASS"

tls-random_ bytes/ByteArray -> none:
  #primitive.tls.get-random
