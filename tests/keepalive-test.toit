// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .tcp
import monitor show *

main:
  test-keep-alive

test-keep-alive:
  with-server: | port |
    socket := TcpSocket
    socket.connect "localhost" port

    expect-equals false socket.keep-alive

    socket.keep-alive = true
    expect-equals true socket.keep-alive

    socket.keep-alive = false
    expect-equals false socket.keep-alive

    socket.close

with-server [code]:
  ready := Channel 1
  task:: simple-server ready
  port := ready.receive
  code.call port

simple-server ready:
  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  ready.send server.local-address.port
  socket := server.accept

  while data := socket.read:
    socket.write data;

  socket.close
  server.close
