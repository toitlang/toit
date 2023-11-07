// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .tcp
import monitor show *
import writer show *

PACKET-SIZE := 1024
PACKAGES := 128

main:
  run-test

run-test:
  print "RUN"

  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  task:: run-client server.local-address.port
  socket := server.accept

  done := Channel 1
  task:: reader socket 100 done
  task:: writer socket 100 done
  server.close

  done.receive
  done.receive
  socket.close

run-client port:
  socket := TcpSocket
  socket.connect "127.0.0.1" port

  done := Channel 1
  task:: reader socket 0 done
  task:: writer socket 0 done

  done.receive
  done.receive
  socket.close

writer socket delay done:
  sleep --ms=delay

  writer := Writer socket
  array := ByteArray PACKET-SIZE
  for i := 0; i < PACKAGES; i++:
    writer.write array

  print "DONE WRITER"
  socket.close-write
  done.send null

reader socket delay done:
  sleep --ms=delay

  count := 0

  while count < PACKET-SIZE * PACKAGES:
    data := socket.read
    count += data.size

  while true:
    data := socket.read
    if data == null:  break
    expect data.size == 0

  print "DONE READER $count"
  done.send null
