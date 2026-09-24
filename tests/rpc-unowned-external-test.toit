// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rpc
import rpc.broker show RpcBroker
import system show process-stats

PROCEDURE-KEEP/int ::= 500

// Sending an external byte array that the process doesn't own (here the RTC
// user bytes) must copy it. Sending it by pointer used to empty the sender's
// array and make the receiver free() memory it didn't own when collecting it.
main:
  kept := null
  broker := RpcBroker
  broker.install
  broker.register-procedure PROCEDURE-KEEP:: | bytes |
    kept = bytes
    null  // Don't send the array back.

  bytes := rtc-user-bytes_
  size := bytes.size
  expect size > 0
  bytes[0] = 42
  rpc.invoke Process.current.id PROCEDURE-KEEP bytes
  expect-equals size bytes.size
  expect-equals size kept.size
  expect-equals 42 kept[0]

  kept = null
  process-stats --gc  // Collects the received copy.

rtc-user-bytes_ -> ByteArray:
  #primitive.core.rtc-user-bytes
