// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net

main:
  socket_address1 := net.SocketAddress (net.IpAddress.parse "127.0.0.1") 80
  socket_address2 := net.SocketAddress (net.IpAddress.parse "127.0.0.1") 80
  socket_address3 := net.SocketAddress (net.IpAddress.parse "10.0.0.1") 80
  expect_equals socket_address1 socket_address1
  expect_equals socket_address1 socket_address2
  expect_equals socket_address2 socket_address1
  expect_not_equals socket_address1 socket_address3
