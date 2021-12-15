// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .dns
import net

main:
  expect_equals "127.0.0.1" (dns_lookup "localhost").stringify

  addr := net.IpAddress [
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 1
  ]
  expect_equals "0:0:0:0:0:0:0:1" addr.stringify

  addr = net.IpAddress [
    1, 2, 3, 4, 5, 6, 7, 8,
    9, 10, 11, 12, 13, 14, 15, 16
  ]
  expect_equals "102:304:506:708:90a:b0c:d0e:f10" addr.stringify
