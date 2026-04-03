// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the UDP reuse-port option works on all platforms.

On Linux and BSD this maps to SO_REUSEPORT.
On Windows this maps to SO_REUSEADDR, which already provides port-reuse
  semantics.

Note: this test only verifies socket creation and port binding.  Actual
  multicast send/receive requires OS-level multicast routing which is not
  configured on all CI runners.
*/

import expect show *
import net
import net.modules.udp as impl

MULTICAST-ADDRESS ::= net.IpAddress.parse "239.1.2.3"

main:
  network := net.open
  try:
    test-multicast-reuse-port network
  finally:
    network.close

/**
Tests that two multicast sockets can bind to the same port when
  reuse-port is enabled.
*/
test-multicast-reuse-port network/net.Client:
  port := 15432

  socket1 := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  // A second socket should be able to bind to the same port.
  socket2 := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  addr1 := socket1.local-address
  addr2 := socket2.local-address
  expect-equals port addr1.port
  expect-equals port addr2.port

  socket2.close
  socket1.close
