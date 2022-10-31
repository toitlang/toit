// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .udp as udp
import net
import net.udp as net
import monitor
import .dns as dns

BROADCAST_ADDRESS ::= net.IpAddress.parse "255.255.255.255"

main:
  print "TOIT: ping_ping_test"
  ping_ping_test
  print "TOIT: ping_ping_timeout_test"
  ping_ping_timeout_test
  print "TOIT: broadcast_test"
  broadcast_test
  print "TOIT: close_test"
  close_test
  print "DONE"

ping_ping_test:
  times := 10

  ready := monitor.Channel 1
  task:: echo_responder times ready
  port := ready.receive

  socket := udp.Socket "127.0.0.1" 0

  socket.connect
    net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      port

  for i := 0; i < times; i++:
    socket.write "testing"
    expect_equals "testing" socket.read.to_string
  print "TOIT: sender: close"
  socket.close
  print "TOIT: sender: closed"

echo_responder times ready:
  socket := udp.Socket "127.0.0.1" 0
  ready.send socket.local_address.port

  for i := 0; i < times; i++:
    msg := socket.receive
    socket.send msg
  print "TOIT: responder: close"
  socket.close
  print "TOIT: responder: closed"

class Timer:
  string_ := ?
  socket_ := ?
  resent := false

  constructor .string_ .socket_:

  call:
    resent = true
    return this

ping_ping_timeout_test:
  times := 10

  ready := monitor.Channel 1
  task:: echo_resend_responder times ready
  port := ready.receive

  socket := udp.Socket "127.0.0.1" 0

  socket.connect
    net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      port

  for i := 0; i < times; i++:
    timer := Timer "testing" socket
    socket.write "testing"
    e := catch:
      with_timeout --ms=100:
        data := socket.read
        expect_equals "testing" data.to_string

    if (i & 1) == 0:
      expect_null e
    else:
      expect e != null

echo_resend_responder times ready:
  socket := udp.Socket "127.0.0.1" 0
  ready.send socket.local_address.port

  for i := 0; i < times; i++:
    msg := socket.receive
    if (i & 1) == 0:
      socket.send msg

  socket.close

broadcast_test:
  times := 10

  ready := monitor.Channel 1
  task:: broadcast_receiver ready
  port := ready.receive

  socket := udp.Socket "0.0.0.0" 0

  socket.broadcast = true

  msg := net.Datagram
    "hello world".to_byte_array
    net.SocketAddress
      BROADCAST_ADDRESS
      port

  for i := 0; i < times; i++:
    socket.send msg

  socket.close

broadcast_receiver ready:
  socket := udp.Socket "0.0.0.0" 0
  socket.broadcast = true

  ready.send socket.local_address.port

  datagram := socket.receive

  expect_equals "hello world" datagram.data.to_string

  socket.close


close_test:
  ready := monitor.Channel 1

  socket := udp.Socket "0.0.0.0" 0

  task::
    packet := socket.receive
    ready.send packet
    // While we are in this `receive` a different task closes the socket.
    // Test that we don't throw an exception, but just get a null.
    packet = socket.receive
    expect_equals null packet

  socket.send
    net.Datagram #['f', 'o', 'o']
      net.SocketAddress
        net.IpAddress.parse "127.0.0.1"
        socket.local_address.port

  ready.receive
  sleep --ms=100
  socket.close
