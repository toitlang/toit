// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import rpc

TYPE ::= 100  // Don't overlap with system messages.
EXTERNAL-PID ::= pid-for-external-id_ "toit.io/external-test"

main:
  print "starting"
  handler := MessageHandler
  set-system-message-handler_ (TYPE + 1) handler
  expect-not-equals EXTERNAL-PID Process.current.id

  test-rpc handler #[42]
  e := catch:
    test-rpc handler #[99, 99]
  expect-equals "EXTERNAL-ERROR" e

  test handler #[1]
  test handler #[1, 2, 3, 4]
  test handler #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
  test handler (ByteArray 3: it)
  test handler (ByteArray 319: it)
  test handler (ByteArray 3197: it)
  test handler (ByteArray 31971: it)
  test handler #[99, 99]

test-rpc handler/MessageHandler data/ByteArray:
  copy := data.copy  // Data can be neutered as part of the transfer.
  print "calling RPC"
  response := rpc.invoke 0 EXTERNAL-PID copy
  expect-bytes-equal copy response

test handler/MessageHandler data/ByteArray:
  copy := data.copy  // Data can be neutered as part of the transfer.
  process-send_ EXTERNAL-PID TYPE data
  print "receiving"
  result := handler.receive
  print "received $result.size"
  expect-bytes-equal copy result

class MessageHandler implements SystemMessageHandler_:
  messages_ ::= monitor.Channel 1

  on-message type/int gid/int pid/int argument -> none:
    expect-equals EXTERNAL-PID pid
    expect-equals (TYPE + 1) type
    messages_.send argument

  receive -> any:
    return messages_.receive
