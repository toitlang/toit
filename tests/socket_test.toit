// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .tcp
import monitor show *
import writer show *

expect_error name [code]:
  exception := "$(catch code)"
  if (exception.index_of name) == -1:
    print "Expected '$name', found '$exception'"
    expect false


// Expectations for this test:
// * Networking can be started using -D<SSID> and -D<PASSWORD> if necessary.
main:
  connect_error_test
  blocking_send_test
  already_in_use_test
  print "done"
connect_error_test:
  // Port 47 is reserved/unassigned.
  socket := TcpSocket
  expect_error "onnect": socket.connect "127.0.0.1" 47  // Gives "Connection refused" or "Not connected"
  // This gives EPERM instead on some Linux desktops for some reason.
  // expect "Host name lookup failure": socket.connect "invalid." 8000  // RFC 6761 says this is always an invalid name

already_in_use_test:
  ready_to_close := Semaphore
  ready := Channel 1
  task:: listen_on_port ready ready_to_close
  // Wait until the other side is listening.
  port := ready.receive
  server := TcpServerSocket
  expect_error " in use": server.listen "" port
  ready_to_close.up // Terminate listener. No need to close the server since it isn't connected.

listen_on_port ready ready_to_close:
  server := TcpServerSocket
  server.listen "" 0
  // Tell the other side that we're listening on port.
  ready.send server.local_address.port
  // Pause and wait for main task to send to us.
  ready_to_close.down
  server.close

blocking_send_test:
  server := TcpServerSocket
  server.listen "" 0
  task:: sleepy_reader server.local_address.port
  socket := server.accept
  writer := Writer socket
  100.repeat:
    writer.write ""
    writer.write "Message for sleepy reader $it"
  socket.close_write
  while socket.read != null:
  socket.close
  server.close

sleepy_reader port:
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
      str += chunk.to_string
      expected := "Message for sleepy reader $index"
      while str.starts_with expected:
        index++
        str = str.copy expected.size
        expected = "Message for sleepy reader $index"
      expect str.size < expected.size
  print "End at $index"
  expect_equals index 100
  socket.close_write
