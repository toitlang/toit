// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  udp-group := udp-init
  tcp-group := tcp-init
  socket := udp-create-socket udp-group
  try:
    // Host sockets only support four-byte IPv4 addresses.
    [0, 3, 5, 16, 64].do: | length |
      address := ByteArray length
      expect-throw "OUT_OF_BOUNDS": udp-bind udp-group address 0
      expect-throw "OUT_OF_BOUNDS": udp-bind-socket udp-group socket address 0
      expect-throw "OUT_OF_BOUNDS": udp-connect udp-group socket address 1234
      expect-throw "OUT_OF_BOUNDS": udp-send udp-group socket #[1] 0 1 address 1234
      expect-throw "OUT_OF_BOUNDS": tcp-connect tcp-group address 1234 0

    // Rejected addresses must leave the socket usable.
    udp-bind-socket udp-group socket #[127, 0, 0, 1] 0
  finally:
    udp-close udp-group socket

udp-init:
  #primitive.udp.init

udp-create-socket group:
  #primitive.udp.create_socket

udp-bind group address port:
  #primitive.udp.bind

udp-bind-socket group socket address port:
  #primitive.udp.bind_socket

udp-connect group socket address port:
  #primitive.udp.connect

udp-send group socket data from to address port:
  #primitive.udp.send

udp-close group socket:
  #primitive.udp.close

tcp-init:
  #primitive.tcp.init

tcp-connect group address port window-size:
  #primitive.tcp.connect
