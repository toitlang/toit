// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import crypto.sha256 as crypto
import crypto.sha1 as crypto
import crypto.adler32 as crypto
import crypto.aes as crypto

main:
  test_leaks

test_leaks:
  50_000.repeat:
    a := ByteArray 96
    s := crypto.Sha256
    s1 := crypto.Sha1
    adler := crypto.Adler32
    aes := crypto.AesCbc.encryptor (ByteArray 32) (ByteArray 16)

    s.add a
    s1.add a
    adler.add a
    aes.encrypt a
    // Finalizers don't run unless we yield.
    if it & 0xff == 0: sleep --ms=1
