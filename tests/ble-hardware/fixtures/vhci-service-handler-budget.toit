// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as providers
import system
import system.containers

main arguments:
  with-timeout --ms=40_000:
    if arguments is Map:
      application
    else:
      provider := Provider
      provider.install
      try:
        child := containers.start containers.current {"application": true}
        try:
          result := child.wait
          if result != 0: throw "HANDLER_BUDGET_APPLICATION_FAILED"
          print "HANDLER_BUDGET PROVIDER_COMPLETE client-exit=0"
        finally:
          child.close
      finally:
        provider.uninstall

application:
  client := clients.Client
  client.open
  try:
    session := client.configure --handler-timeout=(Duration --s=2)
    session.add-service #[0xf0, 0xff]
    input := session.add-characteristic #[0xf1, 0xff] --write --validate-write
    output := session.add-characteristic #[0xf2, 0xff] --read --dynamic-read --value=#[42]
    session.start #[2, 1, 6, 3, 3, 0xf0, 0xff]
    print "HANDLER_BUDGET READY timeout-ms=2000"
    reads := 0
    validations := 0
    writes := 0
    expired := 0
    retained/ByteArray? := null
    before := system.process-stats --gc
    session.serve
        (: | request/clients.Request |
          if request.handle != output: throw "UNEXPECTED_READ"
          reads++
          if reads == 1: sleep --ms=1200
          if reads == 3:
            sleep --ms=2200
            error := catch: request.reply #[99]
            if error != "GATT_REQUEST_EXPIRED": throw "LATE_REPLY_ACCEPTED"
            expired++
            print "HANDLER_BUDGET EXPIRED late-reply-rejected=true"
          else:
            request.reply (reads == 4 ? #[44] : (session.value output))
          system.process-stats --gc)
        (: | request/clients.Request |
          if request.handle != input or request.value != #[43]: throw "UNEXPECTED_VALIDATION"
          sleep --ms=1200
          validations++
          request.accept)
        (: | handle/int value/ByteArray |
          if handle != input or value != #[43]: throw "UNEXPECTED_WRITE"
          sleep --ms=1200
          retained = value
          session.set-value output value
          writes++)
    after := system.process-stats --gc
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if reads != 4 or validations != 1 or writes != 1 or expired != 1 or retained != #[43] or gcs < 4:
      throw "HANDLER_BUDGET_INCOMPLETE"
    print "HANDLER_BUDGET COMPLETE reads=$reads validations=$validations writes=$writes expired=$expired retained=true full-gcs=$gcs"
  finally:
    client.close

class Provider extends providers.Provider:
  constructor: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
