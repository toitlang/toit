// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

/**
Malformed RPC and trace messages don't kill the receiver.

The sandbox may send the RPC message types (and trace messages to the
  system process). The handlers of these messages run in whatever task of
  the receiver processes its messages, so an exception in a handler used to
  kill that task and with it the receiver: a single malformed
  SYSTEM_RPC_REQUEST or SYSTEM_TRACE took down the system process and the
  whole VM. The receivers now drop malformed messages.
*/

PAYLOADS ::= [
  null, 42, "string", #[1, 2, 3], [], [1], ["id", 0, null], [1, "name", null],
  [1.5, 0, null], [-1, 0, null], [1, 0], [[1], [2], [3]],
]

TYPES ::= [
  SYSTEM-RPC-REQUEST_,
  SYSTEM-RPC-REPLY_,
  SYSTEM-RPC-CANCEL_,
  SYSTEM-RPC-NOTIFY-RESOURCE_,
]

main args:
  sandbox-test args --error="DONE": | arguments/Map |
    sibling := discover-pid SiblingService.SELECTOR.uuid
    if sibling != arguments["sibling-pid"]: throw "WRONG_PROVIDER"
    PAYLOADS.do: | payload |
      process-send_ -1 SYSTEM-TRACE_ payload
      TYPES.do: | type |
        process-send_ -1 type payload
        process-send_ sibling type payload
    sleep --ms=200
    // The system process (discovery) and the sibling still work.
    if (discover-pid SiblingService.SELECTOR.uuid) != sibling: throw "WRONG_PROVIDER"
    client := SiblingClient
    client.open
    if (client.ping 7) != 8: throw "WRONG_PING"
    client.close
    throw "DONE"
