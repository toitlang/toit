// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.external show External

EXTERNAL-ID ::= "toit.io/external-test"

incoming-notifications/monitor.Channel := monitor.Channel 1

main:
  print "starting"
  c-lib := External.get EXTERNAL-ID
  c-lib.set-notification-handler:: incoming-notifications.send it

  test-rpc c-lib #[42]
  e := catch:
    test-rpc c-lib #[99, 99]
  expect-equals "EXTERNAL-ERROR" e

  test c-lib #[1]
  test c-lib #[1, 2, 3, 4]
  test c-lib #[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
  test c-lib (ByteArray 3: it)
  test c-lib (ByteArray 319: it)
  test c-lib (ByteArray 3197: it)
  test c-lib (ByteArray 31971: it)
  test c-lib #[99, 99]

  c-lib.close

test-rpc c-lib/External data/ByteArray:
  print "calling RPC"
  response := c-lib.request 0 data
  expect-bytes-equal data response

test c-lib/External data/ByteArray:
  print "sending notification"
  expect-equals 0 incoming-notifications.size
  c-lib.notify data
  print "receiving"
  result := incoming-notifications.receive
  print "received $result.size"
  expect-equals 0 incoming-notifications.size
  expect-bytes-equal data result
