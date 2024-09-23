// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// This test does not work on LwIP, which does not support setting the window
// size on a per-socket basis.

import expect show *

import monitor show *
import net
import net.modules.tcp
import net.tcp show Socket

main:
  network := net.open
  test-window-size network
  print "done"

test-window-size network/net.Client:
  default := null
  with-server network: | port |
    socket := tcp.TcpSocket network
    socket.connect "localhost" port
    default = socket.window-size
    socket.close

  with-server network: | port |
    socket := tcp.TcpSocket network 4096
    socket.connect "localhost" port
    expect default != socket.window-size
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
  socket/Socket := server.accept

  reader := socket.in
  writer := socket.out
  while data := reader.read:
    writer.write data;

  socket.close
  server.close
