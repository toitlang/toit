// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import monitor
import .mixed-service-client as fixture

main args/List:
  pending/bool := args.size > 0 and args[0]
  authenticated/bool := args.size > 1 and args[1]
  with-timeout --ms=140_000:
    clients := []
    old/service.Connection? := null
    try:
      2.repeat: | cycle/int |
        client := fixture.Client
        clients.add client
        client.open --timeout=(Duration --s=10)
        if cycle == 1:
          client.signal 3
          client.wait 1
        connection := client.connect #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
            --timeout=(Duration --s=40)
            --require-authentication=authenticated
        fixture.check-values:
          if authenticated and not connection.security.authenticated: throw "MIXED_AUTHENTICATION_LOST"
          connection.read 3
        if authenticated: print "MIXED_AUTHENTICATED_DEATH CENTRAL cycle=$cycle reads=100 authenticated=true"
        if old:
          if (catch: old.read 3) != "NO_SUCH_PROCESS": throw "MIXED_STALE_CENTRAL_REBOUND"
        client.signal 0
        if cycle == 0:
          if pending:
            pending-read client connection
          else:
            if (catch: client.wait 15) != "NO_SUCH_PROCESS": throw "MIXED_CENTRAL_WAITER_NOT_FAILED"
          if (catch: connection.read 3) != "NO_SUCH_PROCESS": throw "MIXED_CENTRAL_NOT_FAILED"
          old = connection
          print "MIXED_PROVIDER_DEATH CENTRAL_FAILED error=NO_SUCH_PROCESS"
        else:
          client.wait 5
          connection.disconnect
          client.signal 6
      print "MIXED_PROVIDER_DEATH CENTRAL_COMPLETE reads=200 stale=invalid"
    finally:
      clients.do: it.close

pending-read client/fixture.Client connection/service.Connection:
  // Wait until the incoming dynamic handler is blocked before starting the
  // outgoing transaction, keeping both within the fixture handler deadlines.
  client.wait 7
  result := monitor.Latch
  reader/Task? := null
  verified := false
  try:
    error := catch:
      connection.subscribe 12 --cccd=13: | subscription/service.Subscription |
        reader = task:: result.set (catch: connection.read 12)
        if subscription.receive != #[77]: throw "MIXED_PENDING_MARKER"
        if result.has-value: throw "MIXED_READ_NOT_PENDING"
        print "MIXED_PROVIDER_PENDING CENTRAL_READ_WAITING marker=77"
        if (catch: client.wait 15) != "NO_SUCH_PROCESS": throw "MIXED_CENTRAL_WAITER_NOT_FAILED"
        with-timeout --ms=3_000:
          if result.get != "NO_SUCH_PROCESS": throw "MIXED_CENTRAL_READ_NOT_FAILED"
        verified = true
    // CCCD cleanup observes the provider's already-confirmed death.
    if error and error != "NO_SUCH_PROCESS": throw error
    if not verified: throw "MIXED_PENDING_INCOMPLETE"
    print "MIXED_PROVIDER_PENDING CENTRAL_READ_FAILED error=NO_SUCH_PROCESS"
  finally:
    if reader: reader.cancel
