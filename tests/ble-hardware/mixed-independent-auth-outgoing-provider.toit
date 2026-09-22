// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-service-provider as fixture
import .mixed-secure-provider as secure

main:
  print "MIXED_INDEPENDENT CONFIG receive-acl-packets=4 central-peer=8a884ba356a9"
  [false, true].do: | peripheral-first/bool |
    provider := Provider
    with-timeout --ms=160_000:
      fixture.run peripheral-first provider --peer-reads=202
          --central-peer=#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a]
    secure.check-security provider peripheral-first
  print "MIXED_PROVIDER COMPLETE rounds=2"

class Provider extends secure.Provider:
  receive-acl-packets -> int: return 4
