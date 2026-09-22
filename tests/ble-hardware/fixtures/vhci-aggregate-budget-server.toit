// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as clients
import monitor
import system.containers
import .vhci-service-handler-budget show Provider

main arguments:
  with-timeout --ms=45_000:
    if arguments is Map:
      application
    else:
      provider := Provider
      provider.install
      try:
        child := containers.start containers.current {"application": true}
        try:
          if child.wait != 0: throw "AGGREGATE_APPLICATION_FAILED"
          print "AGGREGATE_SERVER COMPLETE client-exit=0"
        finally:
          child.close
      finally:
        provider.uninstall

application:
  client := clients.Client
  client.open
  try:
    session := client.configure --handler-timeout=(Duration --s=7)
    session.add-service #[0xf0, 0xff]
    first := session.add-characteristic #[0xf1, 0xff] --write --validate-write --value=#[1]
    second := session.add-characteristic #[0xf2, 0xff] --write --validate-write --value=#[2]
    print "AGGREGATE_SERVER READY handles=$first,$second"
    session.start #[2, 1, 6]
    entered := 0
    completed := 0
    unwound := 0
    started := monitor.Latch
    ended := monitor.Latch
    saved/clients.Request? := null
    worker := task::
      try:
        session.serve
            (: | request/clients.Request | unreachable)
            (: | request/clients.Request |
              entered++
              saved = request
              if entered == 2: started.set true
              try:
                sleep --ms=6_000
                request.accept
                completed++
              finally:
                unwound++)
            (: | handle/int value/ByteArray | throw "UNEXPECTED_COMMIT")
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      started.get
      if (session.value first) != #[1] or (session.value second) != #[2]: throw "EARLY_COMMIT"
      ended.get
      if not worker.is-canceled or entered != 2 or completed != 1 or unwound != 2:
        throw "AGGREGATE_CLEANUP_FAILED"
      error := catch: saved.accept
      if error != "GATT_REQUEST_EXPIRED": throw "STALE_APPROVAL_ACCEPTED"
      print "AGGREGATE_SERVER EXPIRED entered=2 completed=1 unwound=2 stale-reply=invalid"
    finally:
      worker.cancel
      session.close
    fresh := client.configure
    fresh.add-service #[0xf0, 0xff]
    handle := fresh.add-characteristic #[0xf1, 0xff] --read --value=#[44]
    print "AGGREGATE_SERVER REPLACEMENT handle=$handle"
    fresh.start #[2, 1, 6]
    fresh.serve
        (: | request/clients.Request | unreachable)
        (: | request/clients.Request | unreachable)
        (: | handle/int value/ByteArray | unreachable)
    print "AGGREGATE_SERVER RECOVERED"
  finally:
    client.close
