// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .tcp
import monitor show *
import net.tcp show Socket

main:
  close-server-socket-test
  close-connected-socket
  close-connected-socket-after-write

close-server-socket-test:
  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  server.close
  server.close

with-server [code]:
  ready := Channel 1
  task:: simple-server ready
  port := ready.receive
  code.call port

close-connected-socket:
  with-server: | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    socket.out.close
    socket.in.drain
    socket.close

close-connected-socket-after-write:
  with-server: | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    socket.out.write "hammer fedt"
    socket.out.close
    socket.in.drain
    socket.close

simple-server ready:
  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  ready.send server.local-address.port
  socket/Socket := server.accept

  reader := socket.in
  writer := socket.out
  while data := reader.read:
    writer.write data

  socket.close
  server.close
