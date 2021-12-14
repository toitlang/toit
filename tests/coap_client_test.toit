// Copyright (C) 2019 Toitware ApS. All rights reserved.

import coap
import coap.message as coap
import coap.transport as coap
import bytes
import expect show *

// Inject known token id, as the token is random.
TOKEN_ID_ ::= ByteArray 4: it + 42

expect_exception exception [code]:
  expect_equals
    exception
    catch code

main:
  test_close_on_error
  test_abort_on_disconnect
  test_abort_on_disconnect_delayed

  test_error_response

test_close_on_error:
  t := TestTransport
  client := coap.Client t --auto_run=false

  task::
    expect_exception "MY_ERROR": client.run

  t.set_error "MY_ERROR"

test_abort_on_disconnect:
  t := TestTransport
  client := coap.Client t

  for i := 0; i < 10; i++:
    task::
      expect_exception coap.CLOSED_ERROR:
        client.get "/test"

  t.close

  expect_exception coap.CLOSED_ERROR:
        client.get "/test"

test_abort_on_disconnect_delayed:
  t := TestTransport
  client := coap.Client t

  for i := 0; i < 10; i++:
    task::
      expect_exception coap.CLOSED_ERROR:
        client.get "/test"

  sleep --ms=10

  t.close

test_error_response:
  t := TestTransport
  client := coap.Client t

  token := #[1,2,3,4]
  msg := coap.Message
  msg.token = coap.Token token
  msg.payload = bytes.Reader "my error".to_byte_array
  // Delay setting the response until the request is issued.
  task::
    t.set_response
      coap.Response.message msg

  expect_exception "COAP ERROR 0: my error":
    client.get "/" --token_id=token

  t.close

monitor TestTransport implements coap.Transport:
  expect_ := null
  return_ := null

  closed_ := false
  error_ := null
  response_ := null

  instruct .expect_ .return_:

  set_response .response_:
  set_error .error_:

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

  new_message --reliable=true -> coap.Message:
    return TestMessage

  reliable: return true

  mtu: return 1500

class TestMessage extends coap.Message:
