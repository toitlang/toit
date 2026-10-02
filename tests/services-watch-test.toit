// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.api.service-discovery

main:
  with-timeout --ms=5_000:
    discovery := service-discovery.ServiceDiscoveryServiceClient
    discovery.open
    try:
      10.repeat:
        child := spawn:: null
        while true:
          error := catch: child.priority
          if error:
            expect-equals "INVALID_ARGUMENT" error
            break
          yield
        // The discovery round trip follows the process stop notification in
        // the system process. Register only after that earlier work is handled.
        discovery.discover "db16bc46-6f44-46f5-a382-cc143ed95dd9" --no-wait
        handler := Terminated
        set-system-message-handler_ SYSTEM-RPC-NOTIFY-TERMINATED_ handler
        discovery.watch child.id
        expect-equals child.id handler.result.get
    finally:
      discovery.close

class Terminated implements SystemMessageHandler_:
  result/monitor.Latch ::= monitor.Latch
  on-message type/int gid/int pid/int message/any -> none:
    expect-equals SYSTEM-RPC-NOTIFY-TERMINATED_ type
    result.set message
