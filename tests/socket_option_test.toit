// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// This test does not work on LwIP, which does not support setting the window
// size on a per-socket basis.

import expect show *

import .tcp
import monitor show *

main:
  test_window_size

test_window_size:
  default := null
  with_server: | port |
    socket := TcpSocket
    socket.connect "localhost" port
    default = socket.window_size
    socket.close

  with_server: | port |
    socket := TcpSocket 4096
    socket.connect "localhost" port
    expect default != socket.window_size
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
