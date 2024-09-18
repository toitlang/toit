// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import net
import net.modules.tcp
import monitor show *

main:
  network := net.open
  test-keep-alive network

test-keep-alive network/net.Client:
  with-server network: | port |
    socket := tcp.TcpSocket network
    socket.connect "localhost" port

    expect-equals false socket.keep-alive

    socket.keep-alive = true
    expect-equals true socket.keep-alive

    socket.keep-alive = false
    expect-equals false socket.keep-alive

    socket.close

with-server network/net.Client [code]:
  ready := Channel 1
  task:: simple-server network ready
  port := ready.receive
  code.call port

simple-server network/net.Client ready:
  server := tcp.TcpServerSocket network
  server.listen "127.0.0.1" 0
  ready.send server.local-address.port
  socket := server.accept

  while data := socket.read:
    socket.write data;

  socket.close
  server.close
