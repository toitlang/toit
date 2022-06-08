// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import coap
import coap.tcp as coap
import coap.message as coap
import expect show *
import reader show Reader

// Inject known token id, as the token is random.
TOKEN_ID_ ::= ByteArray 4: it + 42

expect_exception exception [code]:
  expect_equals
    exception
    catch code

main:
  test_get
  test_observe
  test_settings_message
  test_error_result
  test_timeout_while_reading

test_get:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send_csm=false

  // Test the empty path/response.
  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[0b0000_0100, 69, 42, 43, 44, 45]

  msg := client.get "/" --token_id=TOKEN_ID_
  expect_equals coap.CODE_CONTENT msg.code
  expect_equals "" msg.read_payload.to_string

  // Test with path and content.
  socket.instruct
    #[0b0100_0100, 1, 42, 43, 44, 45, 177, 97, 1, 98]
    #[0b0110_0100, 69, 42, 43, 44, 45, 255, 72, 101, 108, 108, 111]

  msg = client.get "/a/b" --token_id=TOKEN_ID_
  expect_equals coap.CODE_CONTENT msg.code
  expect_equals "Hello" msg.read_payload.to_string

  client.close

test_observe:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send_csm=false

  // Test observe two notifications and a "stop".
  socket.instruct
    #[0b0001_0100, 1, 42, 43, 44, 45, 96]
    #[0b0011_0100, 69, 42, 43, 44, 45, 96, 0xff, 97,
      0b0100_0100, 69, 42, 43, 44, 45, 97, 1, 0xff, 98,
      0b0000_0100, coap.CODE_NOT_FOUND, 42, 43, 44, 45]

  response := ""
  expect_exception "COAP ERROR 132: ":
    client.observe "/" --token_id=TOKEN_ID_:
      expect_equals coap.CODE_CONTENT it.code
      response += it.read_payload.to_string
  expect_equals "ab" response

  client.close

test_settings_message:
  socket := TestSocket

  // Expect configuration package.
  socket.instruct
    #[0b0000_0000, 0b1110_0001]
    #[0b0000_0100, 0b1110_0001, 42, 43, 44, 45]

  client := coap.Client
    coap.TcpTransport socket

  // Follow up with a simple req/res.
  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[0b0000_0100, 69, 42, 43, 44, 45]

  msg := client.get "/" --token_id=TOKEN_ID_
  expect_equals coap.CODE_CONTENT msg.code
  expect_equals "" msg.read_payload.to_string

  client.close

test_error_result:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send_csm=false

  // Test the empty path/response.
  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[0b0110_0100, 0b101_00000, 42, 43, 44, 45,
      255, 72, 101, 108, 108, 111]

  e := catch: client.get "/" --token_id=TOKEN_ID_
  expect_equals "COAP ERROR 160: Hello" e

  client.close

test_timeout_while_reading:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send_csm=false

  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[0b0110_0100, 69, 42, 43, 44, 45, 255]

  r := client.get "/" --token_id=TOKEN_ID_
  e := catch:
    with_timeout --ms=10:
      r.read_payload
  expect_equals "DEADLINE_EXCEEDED" e

  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[]

  // The transport should be closed by now.
  e = catch: client.get "/" --token_id=TOKEN_ID_
  expect_equals "TRANSPORT_CLOSED" e

monitor TestSocket implements Reader:
  expect_ := null
  return_value_ := null

  closed_ := false

  instruct expect/ByteArray return_value/ByteArray:
    await: not expect_ and not return_value_
    expect_ = expect
    return_value_ = return_value


  close: closed_ = true

  write data from=0 to=data.size:
    expect_bytes_equal
      expect_
      data.copy from to
    expect_ = null
    return to - from

  read:
    await: closed_ or (expect_ == null and return_value_)
    if closed_: return null
    r := return_value_
    return_value_ = null
    return ByteArray r.size: r[it]

  // Ignore value, as it's only relevant if the implementation has Nagle implemented.
  no_delay -> bool: return false
  no_delay= value/bool -> none: // Do nothing.
