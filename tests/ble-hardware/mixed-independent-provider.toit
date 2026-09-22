// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-service-provider as fixture

// S3 Board1 owns both roles; S3 Board2 is its outgoing peer and Bumble connects
// to its peripheral service. Keep the original ESP32 available to other tests.
main:
  print "MIXED_INDEPENDENT CONFIG receive-acl-packets=4 central-peer=84f703a00b3a"
  [false, true].do: | peripheral-first/bool |
    with-timeout --ms=160_000:
      fixture.run peripheral-first (Provider)
          --central-peer=#[0x3a, 0x0b, 0xa0, 0x03, 0xf7, 0x84]
  print "MIXED_PROVIDER COMPLETE rounds=2"

class Provider extends fixture.Provider:
  receive-acl-packets -> int: return 4
