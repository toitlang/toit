// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net

main:
  socket-address1 := net.SocketAddress (net.IpAddress.parse "127.0.0.1") 80
  socket-address2 := net.SocketAddress (net.IpAddress.parse "127.0.0.1") 80
  socket-address3 := net.SocketAddress (net.IpAddress.parse "10.0.0.1") 80
  expect-equals socket-address1 socket-address1
  expect-equals socket-address1 socket-address2
  expect-equals socket-address2 socket-address1
  expect-not-equals socket-address1 socket-address3
