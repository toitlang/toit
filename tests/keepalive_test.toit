// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .tcp
import monitor show *

main:
  test_keep_alive

test_keep_alive:
  with_server: | port |
    socket := TcpSocket
    socket.connect "localhost" port

    expect_equals false socket.keep_alive

    socket.set_keep_alive true
    expect_equals true socket.keep_alive

    socket.set_keep_alive false
    expect_equals false socket.keep_alive

    socket.close

with_server [code]:
  ready := Channel 1
  task:: simple_server ready
  port := ready.receive
  code.call port

simple_server ready:
  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  ready.send server.local_address.port
  socket := server.accept

  while data := socket.read:
    socket.write data;

  socket.close
  server.close
