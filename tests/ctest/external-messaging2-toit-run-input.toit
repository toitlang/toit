// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import monitor
import system.external

EXTERNAL-ID0 ::= "toit.io/external-test0"
EXTERNAL-ID1 ::= "toit.io/external-test1"

incoming-notifications := [
  monitor.Channel 1,
  monitor.Channel 1,
]

main:
  clients := [
    external.Client.open EXTERNAL-ID0,
    external.Client.open EXTERNAL-ID1,
  ]
  clients.size.repeat: | i |
    client/external.Client := clients[i]
    client.set-on-notify:: incoming-notifications[i].send it

  test-id clients

  test-rpc clients #[42]
  test-rpc clients "foobar"
  test-rpc-fail clients
  test-gc clients

  test-notification clients #[1]
  test-notification clients #[1, 2, 3, 4]
  test-notification clients #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
  test-notification clients (ByteArray 3: it)
  test-notification clients (ByteArray 319: it)
  test-notification clients (ByteArray 3197: it)
  test-notification clients (ByteArray 31971: it)
  test-notification clients ""
  test-notification clients "foobar"
  test-notification clients "foobar"[3..]
  test-notification clients "foobar" * 100
  test-notification clients #[99, 99]

  clients.do: it.close

test-id clients/List:
  clients.size.repeat: | i |
    id := i
    client/external.Client := clients[i]
    response := client.request 0 #[0xFF]  // Request for id.
    expect-equals 1 response.size
    expect-equals id response[0]

test-rpc clients/List data/io.Data:
  clients.do: | client/external.Client |
    response := client.request 0 data
    bytes := ByteArray.from data
    expect-equals bytes response

test-rpc-fail clients/List:
  clients.do: | client/external.Client |
    e := catch:
      client.request 0 #[99, 99]
    expect-equals "EXTERNAL_ERROR" e

test-gc clients/List:
  clients.do: | client/external.Client |
    response := client.request 0 #[0xFE]  // Request for GC.
    expect-equals 1 response.size
    expect-equals 0 response[0]

test-notification clients/List data/io.Data:
  clients.size.repeat: | i |
    client/external.Client := clients[i]
    client.notify data
    result := incoming-notifications[i].receive
    bytes := ByteArray.from data
    expect-equals bytes result
