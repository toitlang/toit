// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.api.service-discovery show ServiceDiscoveryServiceClient
import .sandbox

/**
Characterizes what a sandbox learns about processes it may not talk to.
  This test documents an open design gap (see "Threats tested" in
  docs/sandbox-policy.md); it asserts the current behavior and must be
  updated when the gap is closed.

The message gate doesn't reveal whether a pid exists: sends to an
  existing process (the driver) and to a pid that doesn't exist both fail
  with PERMISSION_DENIED.

The watch method of the discovery service does: the system process
  answers a watch of a pid that doesn't exist (anymore) right away with a
  SYSTEM_RPC_NOTIFY_TERMINATED message, and remembers a watch of a live
  process, which tells the sandbox when that process terminates. A
  sandbox can therefore probe which pids exist and observe the lifetime
  of any process, although it can't send to them.
*/

NO-SUCH-PID ::= 1_000_000

class Observer_ implements SystemMessageHandler_:
  terminated := {}
  on-message type/int gid/int pid/int message/any -> none:
    if pid == SYSTEM-PROCESS-ID_: terminated.add message

main args:
  sandbox-test args --error="DONE" --prepare=(:: {"driver-pid": Process.current.id}): | arguments/Map |
    driver := arguments["driver-pid"]

    // The message gate: no difference.
    expect-throw "PERMISSION_DENIED": process-send_ driver 100 "hello"
    expect-throw "PERMISSION_DENIED": process-send_ NO-SUCH-PID 100 "hello"

    // The watch method: a difference.
    observer := Observer_
    set-system-message-handler_ SYSTEM-RPC-NOTIFY-TERMINATED_ observer
    discovery := ServiceDiscoveryServiceClient
    discovery.open
    discovery.watch driver
    discovery.watch NO-SUCH-PID
    sleep --ms=500
    discovery.close
    // GAP: the sandbox learns that NO-SUCH-PID doesn't exist and that the
    // driver does.
    expect-equals {NO-SUCH-PID} observer.terminated
    throw "DONE"
