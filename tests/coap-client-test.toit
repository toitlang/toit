// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import coap
import coap.message as coap
import coap.transport as coap
import io
import expect show *

// Inject known token id, as the token is random.
TOKEN-ID_ ::= ByteArray 4: it + 42

expect-exception exception [code]:
  expect-equals
    exception
    catch code

main:
  test-close-on-error
  test-abort-on-disconnect
  test-abort-on-disconnect-delayed

  test-error-response

test-close-on-error:
  t := TestTransport
  client := coap.Client t --auto-run=false

  task::
    expect-exception "MY_ERROR": client.run

  t.set-error "MY_ERROR"

test-abort-on-disconnect:
  t := TestTransport
  client := coap.Client t

  for i := 0; i < 10; i++:
    task::
      expect-exception coap.CLOSED-ERROR:
        client.get "/test"

  t.close

  expect-exception coap.CLOSED-ERROR:
        client.get "/test"

test-abort-on-disconnect-delayed:
  t := TestTransport
  client := coap.Client t

  for i := 0; i < 10; i++:
    task::
      expect-exception coap.CLOSED-ERROR:
        client.get "/test"

  sleep --ms=10

  t.close

test-error-response:
  t := TestTransport
  client := coap.Client t

  token := #[1,2,3,4]
  msg := coap.Message
  msg.token = coap.Token token
  msg.payload = io.Reader "my error".to-byte-array
  // Delay setting the response until the request is issued.
  task::
    t.set-response
      coap.Response.message msg

  expect-exception "COAP ERROR 0: my error":
    client.get "/" --token-id=token

  t.close

monitor TestTransport implements coap.Transport:
  expect_ := null
  return_ := null

  closed_ := false
  error_ := null
  response_ := null

  instruct expect return-value:
    expect_ = expect
    return_ = return-value

  set-response response: response_ = response
  set-error error: error_ = error

  write msg/coap.Message:

  ping token/coap.Token:

  read -> coap.Response?:
    await: closed_ or error_ or response_
    if closed_: return null
    if error_: throw error_
    if response_:
      r := response_
      response_ = null
      return r
    unreachable

  close:
    closed_ = true

  new-message --reliable=true -> coap.Message:
    return TestMessage

  reliable: return true

  mtu: return 1500

class TestMessage extends coap.Message:
