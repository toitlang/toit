// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-service-provider as fixture
import .mixed-secure-provider as secure

main:
  print "MIXED_INDEPENDENT CONFIG receive-acl-packets=4 central-peer=84f703a00b3a"
  [false, true].do: | peripheral-first/bool |
    provider := Provider
    with-timeout --ms=160_000:
      fixture.run peripheral-first provider --peer-reads=202
          --central-peer=#[0x3a, 0x0b, 0xa0, 0x03, 0xf7, 0x84]
    secure.check-security provider peripheral-first
  print "MIXED_PROVIDER COMPLETE rounds=2"

class Provider extends secure.Provider:
  receive-acl-packets -> int: return 4
