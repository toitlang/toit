// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net

// Test that written data is not lost when a socket is closed normally.

main:
  network := net.open
  port := start_server network
  run_client network port

  port2 := start_server network
  run_client network port2 --keep_writing

run_client network port/int --keep_writing=false -> none:
  socket := network.tcp_connect "127.0.0.1" port
  socket.write "Hello, World!"
  socket.no_delay = true
  if keep_writing:
    sleep --ms=1000
    print
        socket.read
    print "Writing more"
    socket.write "Hello, again!"
  socket.close

start_server network -> int:
  server_socket := network.tcp_listen 0
  port := server_socket.local_address.port
  task::
    while socket := server_socket.accept:
      print "Got connection"
      message := #[]
      while message.size < 13:
        data := socket.read
        if not data: break
        message += data
      print "Got message size $message.size"
      expect_equals 13 message.size
      socket.close
  return port
