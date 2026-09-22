// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import .services-notify-test as fixture

main:
  with-timeout --ms=5_000:
    check true
    check false

check resource-notification/bool:
  provider := fixture.ResourceServiceProvider
  provider.install
  client := fixture.ResourceServiceClient
  client.open
  resource := Resource client "victim"
  barrier := Barrier
  set-system-message-handler_ 64 barrier
  try:
    target := Process.current.id
    client-id := client.id
    handle := resource.raw-handle
    spawn::
      if resource-notification:
        [null, [], [client-id], [client-id, "bad", 666]].do:
          process-send_ target SYSTEM-RPC-NOTIFY-RESOURCE_ it
        process-send_ target SYSTEM-RPC-NOTIFY-RESOURCE_ [client-id, handle, 666]
      else:
        // Only the system process may report another process's termination.
        process-send_ target SYSTEM-RPC-NOTIFY-TERMINATED_ "bad"
        process-send_ target SYSTEM-RPC-NOTIFY-TERMINATED_ target
      // Same sender and recipient: delivery of the forged message precedes
      // this barrier, so the legitimate operation cannot race ahead of it.
      process-send_ target 64 null
    barrier.received.get
    resource.notify 42
    expect-equals 42 resource.notification
  finally:
    resource.close
    client.close
    provider.uninstall

class Resource extends fixture.ResourceProxy:
  constructor client/fixture.ResourceServiceClient key/string: super client key
  raw-handle -> int: return handle_

class Barrier implements SystemMessageHandler_:
  received/monitor.Latch ::= monitor.Latch
  on-message type/int gid/int pid/int message/any -> none:
    expect-equals 64 type
    received.set true
