// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .tcp
import monitor show *

main:
  close_server_socket_test
  close_connected_socket
  close_connected_socket_after_write

close_server_socket_test:
  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  server.close
  server.close

with_server [code]:
  ready := Channel 1
  task:: simple_server ready
  port := ready.receive
  code.call port

close_connected_socket:
  with_server: | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    socket.close_write
    while socket.read:
    socket.close

close_connected_socket_after_write:
  with_server: | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    socket.write "hammer fedt"
    socket.close_write
    while socket.read:
    socket.close

simple_server ready:
  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  ready.send server.local_address.port
  socket := server.accept

  while data := socket.read:
    socket.write data

  socket.close
  server.close
