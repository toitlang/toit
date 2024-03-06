// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .tcp
import monitor show *
import writer show *

import .io-data

expect-error name [code]:
  exception := "$(catch code)"
  if (exception.index-of name) == -1:
    print "Expected '$name', found '$exception'"
    expect false


// Expectations for this test:
// * Networking can be started using -D<SSID> and -D<PASSWORD> if necessary.
main:
  connect-error-test
  blocking-send-test
  already-in-use-test
  io-data-test
  print "done"

connect-error-test:
  // Port 47 is reserved/unassigned.
  socket := TcpSocket
  expect-error "onnect": socket.connect "127.0.0.1" 47  // Gives "Connection refused" or "Not connected"
  // This gives EPERM instead on some Linux desktops for some reason.
  // expect "Host name lookup failure": socket.connect "invalid." 8000  // RFC 6761 says this is always an invalid name

already-in-use-test:
  ready-to-close := Semaphore
  ready := Channel 1
  task:: listen-on-port ready ready-to-close
  // Wait until the other side is listening.
  port := ready.receive
  server := TcpServerSocket
  expect-error " in use": server.listen "" port
  ready-to-close.up // Terminate listener. No need to close the server since it isn't connected.

listen-on-port ready ready-to-close:
  server := TcpServerSocket
  server.listen "" 0
  // Tell the other side that we're listening on port.
  ready.send server.local-address.port
  // Pause and wait for main task to send to us.
  ready-to-close.down
  server.close

blocking-send-test:
  server := TcpServerSocket
  server.listen "" 0
  task:: sleepy-reader server.local-address.port
  socket := server.accept
  writer := Writer socket
  100.repeat:
    writer.write ""
    writer.write "Message for sleepy reader $it"
  socket.close-write
  while socket.read != null:
  socket.close
  server.close

io-data-test:
  ITERATIONS ::= 500
  2.repeat: | iteration |
    server := TcpServerSocket
    server.listen "" 0
    task:: sleepy-reader server.local-address.port --iterations=ITERATIONS
    socket := server.accept
    writer := Writer socket
    if iteration == 0:
      ITERATIONS.repeat:
        writer.write (FakeData "")
        writer.write (FakeData "Message for sleepy reader $it")
    else:
      data := ""
      ITERATIONS.repeat:
        data += "Message for sleepy reader $it"
      writer.write (FakeData data)
    socket.close-write
    while socket.read != null:
    socket.close
    server.close

sleepy-reader port --iterations/int=100:
  socket := TcpSocket
  socket.connect "localhost" port
  done := false
  index := 0
  str := ""
  waited := false
  while not done:
    if index > 10 and not waited:
      waited = true
      sleep --ms=1000
    chunk := socket.read
    if chunk == null:
      done = true
    else:
      str += chunk.to-string
      expected := "Message for sleepy reader $index"
      while str.starts-with expected:
        index++
        str = str.copy expected.size
        expected = "Message for sleepy reader $index"
      expect str.size < expected.size
  print "End at $index"
  expect-equals iterations index
  socket.close-write
