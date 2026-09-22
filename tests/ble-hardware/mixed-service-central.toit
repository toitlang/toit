// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-service-client as fixture

main args/List:
  if args.is-empty: run
  else if args.size == 1: run --peer-address=args[0]
  else: throw "INVALID_ARGUMENT"

run --secure/bool=false --peer-address/ByteArray=#[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
    --value-handle/int?=null:
  handle := value-handle or (secure ? 12 : 3)
  with-timeout --ms=140_000:
    client := fixture.Client
    client.open --timeout=(Duration --s=10)
    try:
      if not client.capabilities.mixed-roles: throw "MIXED_CAPABILITY_MISSING"
      client.with-connection peer-address --timeout=(Duration --s=30)
          --require-authentication=secure: | connection |
        fixture.check-values:
          if secure and not connection.security.authenticated: throw "MIXED_SECURITY_LOST"
          connection.read handle
        client.signal 0
        2.repeat: | cycle/int |
          client.wait (cycle * 4 + 1)
          fixture.check-values:
            if secure and not connection.security.authenticated: throw "MIXED_SECURITY_LOST"
            connection.read handle
          client.signal (cycle * 4 + 2)
          client.wait (cycle * 4 + 3)
          fixture.check-values:
            if secure and not connection.security.authenticated: throw "MIXED_SECURITY_LOST"
            connection.read handle
          client.signal (cycle * 4 + 4)
          print "MIXED_CENTRAL CYCLE cycle=$cycle reads=$((cycle + 1) * 200 + 100)"
      print "MIXED_CENTRAL COMPLETE reads=500"
    finally:
      client.close
