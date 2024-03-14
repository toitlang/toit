// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import coap
import coap.tcp as coap
import coap.message as coap
import expect show *
import io

// Inject known token id, as the token is random.
TOKEN-ID_ ::= ByteArray 4: it + 42

expect-exception exception [code]:
  expect-equals
    exception
    catch code

main:
  test-get
  test-observe
  test-settings-message
  test-error-result
  test-timeout-while-reading

test-get:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send-csm=false

  // Test the empty path/response.
  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[0b0000_0100, 69, 42, 43, 44, 45]

  msg := client.get "/" --token-id=TOKEN-ID_
  expect-equals coap.CODE-CONTENT msg.code
  expect-equals "" msg.read-payload.to-string

  // Test with path and content.
  socket.instruct
    #[0b0100_0100, 1, 42, 43, 44, 45, 177, 97, 1, 98]
    #[0b0110_0100, 69, 42, 43, 44, 45, 255, 72, 101, 108, 108, 111]

  msg = client.get "/a/b" --token-id=TOKEN-ID_
  expect-equals coap.CODE-CONTENT msg.code
  expect-equals "Hello" msg.read-payload.to-string

  client.close

test-observe:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send-csm=false

  // Test observe two notifications and a "stop".
  socket.instruct
    #[0b0001_0100, 1, 42, 43, 44, 45, 96]
    #[0b0011_0100, 69, 42, 43, 44, 45, 96, 0xff, 97,
      0b0100_0100, 69, 42, 43, 44, 45, 97, 1, 0xff, 98,
      0b0000_0100, coap.CODE-NOT-FOUND, 42, 43, 44, 45]

  response := ""
  expect-exception "COAP ERROR 132: ":
    client.observe "/" --token-id=TOKEN-ID_:
      expect-equals coap.CODE-CONTENT it.code
      response += it.read-payload.to-string
  expect-equals "ab" response

  client.close

test-settings-message:
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

  msg := client.get "/" --token-id=TOKEN-ID_
  expect-equals coap.CODE-CONTENT msg.code
  expect-equals "" msg.read-payload.to-string

  client.close

test-error-result:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send-csm=false

  // Test the empty path/response.
  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[0b0110_0100, 0b101_00000, 42, 43, 44, 45,
      255, 72, 101, 108, 108, 111]

  e := catch: client.get "/" --token-id=TOKEN-ID_
  expect-equals "COAP ERROR 160: Hello" e

  client.close

test-timeout-while-reading:
  socket := TestSocket
  client := coap.Client
    coap.TcpTransport socket --send-csm=false

  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[0b0110_0100, 69, 42, 43, 44, 45, 255]

  r := client.get "/" --token-id=TOKEN-ID_
  e := catch:
    with-timeout --ms=10:
      r.read-payload
  expect-equals "DEADLINE_EXCEEDED" e

  socket.instruct
    #[4, 1, 42, 43, 44, 45]
    #[]

  // The transport should be closed by now.
  e = catch: client.get "/" --token-id=TOKEN-ID_
  expect-equals "TRANSPORT_CLOSED" e

class TestSocket extends Object with io.CloseableInMixin io.CloseableOutMixin:
  coordinator_ := TestSocketCoordinator_

  // Ignore value, as it's only relevant if the implementation has Nagle implemented.
  no-delay -> bool: return false
  no-delay= value/bool -> none: // Do nothing.

  instruct expect/ByteArray return-value/ByteArray:
    coordinator_.instruct expect return-value

  read_ -> ByteArray?:
    return coordinator_.read

  try-write_ bytes/ByteArray? from/int to/int -> int:
    return coordinator_.write bytes from to

  close -> none:
    coordinator_.close

  close-writer_ -> none:
    // TODO(florian): should we do something here?

  close-reader_ -> none:
    coordinator_.close

monitor TestSocketCoordinator_:
  expect_ := null
  return-value_ := null

  closed_ := false

  instruct expect/ByteArray return-value/ByteArray:
    await: not expect_ and not return-value_
    expect_ = expect
    return-value_ = return-value

  close: closed_ = true

  write data from to:
    expect-bytes-equal
      expect_
      data.copy from to
    expect_ = null
    return to - from

  read:
    await: closed_ or (expect_ == null and return-value_)
    if closed_: return null
    r := return-value_
    return-value_ = null
    return ByteArray r.size: r[it]
