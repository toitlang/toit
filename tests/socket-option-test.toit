// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// This test does not work on LwIP, which does not support setting the window
// size on a per-socket basis.

import expect show *

import .tcp
import monitor show *
import net.tcp show Socket

main:
  test-window-size
  print "done"

test-window-size:
  default := null
  with-server: | port |
    socket := TcpSocket
    socket.connect "localhost" port
    default = socket.window-size
    socket.close

  with-server: | port |
    socket := TcpSocket 4096
    socket.connect "localhost" port
    expect default != socket.window-size
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
  socket/Socket := server.accept

  reader := socket.in
  writer := socket.out
  while data := reader.read:
    writer.write data;

  socket.close
  server.close
