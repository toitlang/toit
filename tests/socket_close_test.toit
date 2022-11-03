// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .tcp
import expect show *
import monitor show *

main:
  close_server_socket_test
  close_connected_socket
  close_connected_socket_after_write
  pop_out_of_read_on_close_write
  own_end_close
  read_after_close_write_end_close

close_server_socket_test:
  server := TcpServerSocket
  server.listen "127.0.0.1" 0
  server.close
  server.close

with_server --server_lambda/Lambda [code]:
  ready := Channel 1
  task::
    server := TcpServerSocket
    server.listen "127.0.0.1" 0
    ready.send server.local_address.port
    server_lambda.call server
  port := ready.receive
  code.call port

close_connected_socket:
  with_server --server_lambda=(:: server_read_then_close_write it): | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    socket.close_write
    while socket.read:
    //socket.close

close_connected_socket_after_write:
  with_server --server_lambda=(:: server_read_then_close_write it): | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    socket.write "hammer fedt"
    socket.close_write
    while socket.read:
    socket.close

server_read_then_close_write server:
  socket := server.accept

  while data := socket.read:
    socket.write data

  socket.close_write
  sleep --ms=100
  server.close

server_try_to_write_after_read_null server:
  socket := server.accept

  while data := socket.read:
    socket.write data

  socket.write "Surprise!"
  socket.close_write

  sleep --ms=100
  server.close

pop_out_of_read_on_close_write:
  with_server --server_lambda=(:: server_read_then_close_write it): | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    task::
      // Should harmlessly stop without an exception.
      while data := socket.read:
        null

    sleep --ms=100

    // Close_write should cause the server to also close_write,
    // doing an orderly shutdown of the socket.
    socket.close_write

    sleep --ms=1000

own_end_close:
  with_server --server_lambda=(:: server_read_then_close_write it): | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    task::
      error := catch:
        while data := socket.read:
          null
      expect error == "NOT_CONNECTED"
      print error

    sleep --ms=100

    // Shutdown the socket in both directions while a different task is waiting
    // on read at our end of the socket.
    socket.close

    sleep --ms=100

read_after_close_write_end_close:
  with_server --server_lambda=(:: server_try_to_write_after_read_null it): | port |
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    latch := Latch
    got_data := false
    task::
      while data := socket.read:
        got_data = true
        latch.set data

    // Shutdown in write direction.  After this our reader should still be able
    // to receive data.
    expect_not got_data
    socket.close_write

    data := latch.get
    expect got_data
    print "Got data"
