// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor show *
import net
import net.modules.tcp
import net.tcp show Socket

main:
  network := net.open
  close-server-socket-test network
  close-connected-socket network
  close-connected-socket-after-write network

close-server-socket-test network/net.Client:
  server := tcp.TcpServerSocket network
  server.listen "127.0.0.1" 0
  server.close
  server.close

with-server network/net.Client [code]:
  ready := Channel 1
  task:: simple-server network ready
  port := ready.receive
  code.call port

close-connected-socket network/net.Client:
  with-server network: | port |
    socket := tcp.TcpSocket network
    socket.connect "127.0.0.1" port
    socket.out.close
    socket.in.drain
    socket.close

close-connected-socket-after-write network/net.Client:
  with-server network: | port |
    socket := tcp.TcpSocket network
    socket.connect "127.0.0.1" port
    socket.out.write "hammer fedt"
    socket.out.close
    socket.in.drain
    socket.close

simple-server network/net.Client ready:
  server := tcp.TcpServerSocket network
  server.listen "127.0.0.1" 0
  ready.send server.local-address.port
  socket/Socket := server.accept

  reader := socket.in
  writer := socket.out
  while data := reader.read:
    writer.write data

  socket.close
  server.close
