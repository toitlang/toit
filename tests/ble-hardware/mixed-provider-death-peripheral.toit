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
    old/service.Session? := null
    old-request/service.Request? := null
    try:
      2.repeat: | cycle/int |
        client := fixture.Client
        clients.add client
        client.open --timeout=(Duration --s=10)
        if cycle == 0: client.wait 0
        else: client.signal 4
        session := client.configure --name="Toit HCI"
        session.add-service #[0xf0, 0xff]
        control := session.add-characteristic #[0xf1, 0xff] --write-command --value=#[0]
            --authenticated=authenticated
        if control != 12: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
        if pending:
          session.set-handler-timeout (Duration --s=5)
          value := session.add-characteristic #[0xf2, 0xff] --read --dynamic-read
              --authenticated=authenticated
          if value != 14: throw "MIXED_FIXTURE_LAYOUT_CHANGED"
        written := monitor.Latch
        ended := monitor.Latch
        worker/Task? := null
        try:
          session.start #[2, 1, 6]
          print "MIXED_PROVIDER_DEATH ACCEPT_READY cycle=$cycle"
          session.peer
          worker = task::
            error/any := null
            try:
              error = catch:
                session.serve
                    (: | request/service.Request |
                      if not pending or cycle != 0 or request.handle != 14: throw "MIXED_UNEXPECTED_READ"
                      old-request = request
                      print "MIXED_PROVIDER_PENDING PERIPHERAL_HANDLER_WAITING handle=14"
                      client.signal 7
                      written.set true
                      client.wait 15
                      throw "MIXED_HANDLER_UNEXPECTED_RETURN")
                    (: | request | request.reject 0x0e)
                    (: | handle/int value/ByteArray |
                      if handle != control or value != #[1] or written.has-value:
                        throw "MIXED_UNEXPECTED_ACK"
                      written.set true)
            finally:
              critical-do --no-respect-deadline:
                ended.set (error or true) --exception=(error != null)
          if authenticated:
            with-timeout --ms=15_000:
              while not session.security.authenticated: sleep --ms=1
            print "MIXED_AUTHENTICATED_DEATH PERIPHERAL cycle=$cycle authenticated=true"
          fixture.check-values: session.value 3
          if old:
            if (catch: old.value 3) != "GATT_REQUESTS_CLOSED": throw "MIXED_STALE_PERIPHERAL_REBOUND"
          if old-request:
            if (catch: old-request.reply #[99]) != "GATT_REQUEST_EXPIRED": throw "MIXED_STALE_REQUEST_REBOUND"
          client.signal 1
          written.get
          if cycle == 0:
            if not pending:
              if (catch: client.wait 15) != "NO_SUCH_PROCESS": throw "MIXED_PERIPHERAL_WAITER_NOT_FAILED"
            error := with-timeout --ms=3_000: catch: ended.get
            if (error != "NO_SUCH_PROCESS" and not (pending and worker.is-canceled)) or
                session.termination-reason != "NO_SUCH_PROCESS":
              throw "MIXED_PERIPHERAL_SERVE_NOT_FAILED"
            if pending:
              if (catch: old-request.reply #[99]) != "GATT_REQUEST_EXPIRED": throw "MIXED_REQUEST_NOT_EXPIRED"
              print "MIXED_PROVIDER_PENDING HANDLER_FAILED cause=NO_SUCH_PROCESS request=expired"
            if (catch: session.value 3) != "GATT_REQUESTS_CLOSED": throw "MIXED_PERIPHERAL_NOT_FAILED"
            old = session
            print "MIXED_PROVIDER_DEATH PERIPHERAL_FAILED error=NO_SUCH_PROCESS local=GATT_REQUESTS_CLOSED"
          else:
            client.wait 0
            session.close
            // Explicit local closure may wake the outstanding request pull.
            error := catch: ended.get
            if error and error != "GATT_REQUESTS_CLOSED": throw error
            client.signal 5
        finally:
          if worker: worker.cancel
      print "MIXED_PROVIDER_DEATH PERIPHERAL_COMPLETE local-reads=200 stale=invalid"
    finally:
      clients.do: it.close
