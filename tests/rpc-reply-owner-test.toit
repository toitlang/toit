// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rpc

main:
  with-timeout --ms=5_000:
    peer := Peer
    set-system-message-handler_ SYSTEM-RPC-REQUEST_ peer
    3.repeat: | mode/int |
      expect-equals 42 (rpc.invoke Process.current.id 123 mode)

class Peer implements SystemMessageHandler_:
  on-message type/int gid/int pid/int message/any -> none:
    expect-equals SYSTEM-RPC-REQUEST_ type
    id/int := message[0]
    if message[1] == 124:
      // The attacker's preceding reply has already been delivered to the same
      // recipient. Only now send the legitimate reply from the expected PID.
      process-send_ Process.current.id SYSTEM-RPC-REPLY_ [message[2], false, 42]
    else:
      expect-equals 123 message[1]
      target := Process.current.id
      mode/int := message[2]
      if mode == 2:
        // Malformed envelopes from even the expected peer must not kill the
        // caller or consume its pending request before a valid reply arrives.
        [null, [], ["bad", false, 666], [id, 0, 666],
            [id, true, "missing trace"]].do:
          process-send_ target SYSTEM-RPC-REPLY_ it
        process-send_ target SYSTEM-RPC-REPLY_ [id, false, 42]
      else:
        spawn::
          forged := mode == 1 ? [id, true, "FORGED_ERROR", null] : [id, false, 666]
          process-send_ target SYSTEM-RPC-REPLY_ forged
          process-send_ target SYSTEM-RPC-REQUEST_ [-777, 124, id]
