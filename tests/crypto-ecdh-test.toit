// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.ec
import expect show *
import system

main:
  curves := [ec.EcKey.CURVE-SECP256R1, ec.EcKey.CURVE-SECP384R1, ec.EcKey.CURVE-SECP521R1]
  sizes := [32, 48, 66]
  curves.size.repeat: | index/int |
    first := ec.EcKeyPair.generate --curve=curves[index]
    second := ec.EcKeyPair.generate --curve=curves[index]
    expected := second.compute-shared-secret first.public-key
    expect-equals sizes[index] expected.size
    retained := []
    12.repeat:
      secret := first.compute-shared-secret second.public-key
      expect-equals expected secret
      retained.add secret
      system.process-stats --gc
      retained.do: expect-equals expected it
    // A later result is independent of all retained secrets and key material.
    changed := first.compute-shared-secret second.public-key
    changed[0] ^= 1
    expect (changed != expected)
    system.process-stats --gc
    retained.do: expect-equals expected it
    expect-equals expected (first.compute-shared-secret second.public-key)
