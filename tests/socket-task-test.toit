// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import monitor show *
import net
import net.modules.tcp
import net.tcp show Socket

PACKET-SIZE := 1024
PACKAGES := 128

main:
  network := net.open
  run-test network

run-test network/net.Client:
  print "RUN"

  server := tcp.TcpServerSocket network
  server.listen "127.0.0.1" 0
  task:: run-client network server.local-address.port
  socket := server.accept

  done := Channel 1
  task:: reader socket 100 done
  task:: writer socket 100 done
  server.close

  done.receive
  done.receive
  socket.close

run-client network/net.Client port:
  socket := tcp.TcpSocket network
  socket.connect "127.0.0.1" port

  done := Channel 1
  task:: reader socket 0 done
  task:: writer socket 0 done

  done.receive
  done.receive
  socket.close

writer socket/Socket delay done:
  sleep --ms=delay

  writer := socket.out
  array := ByteArray PACKET-SIZE
  for i := 0; i < PACKAGES; i++:
    writer.write array

  print "DONE WRITER"
  writer.close
  done.send null

reader socket/Socket delay done:
  sleep --ms=delay

  count := 0

  reader := socket.in
  while count < PACKET-SIZE * PACKAGES:
    data := reader.read
    count += data.size

  while true:
    data := reader.read
    if data == null:  break
    expect data.size == 0

  print "DONE READER $count"
  done.send null
