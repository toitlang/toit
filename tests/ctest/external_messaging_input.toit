// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect
import monitor

TYPE ::= 100  // Don't overlap with system messages.
EXTERNAL_PID ::= 0

main:
  handler := MessageHandler
  set_system_message_handler_ (TYPE + 1) handler
  expect.expect (Process.id != EXTERNAL_PID)

  test handler #[]
  test handler #[1, 2, 3, 4]
  test handler #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
  test handler (ByteArray 3: it)
  test handler (ByteArray 319: it)
  test handler (ByteArray 3197: it)
  test handler (ByteArray 31971: it)

test handler/MessageHandler data/ByteArray:
  copy := data.copy  // Data can be neutered as part of the transfer.
  process_send_ EXTERNAL_PID TYPE data
  result := handler.receive
  expect.expect_bytes_equal copy result

class MessageHandler implements SystemMessageHandler_:
  messages_ ::= monitor.Channel 1

  on_message type/int gid/int pid/int argument -> none:
    expect.expect_equals EXTERNAL_PID pid
    expect.expect_equals (TYPE + 1) type
    messages_.send argument

  receive -> any:
    return messages_.receive
