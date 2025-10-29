// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import net
import net.modules.dns
import net.modules.udp
import net.udp as net
import system

import .io-utils

BROADCAST-ADDRESS ::= net.IpAddress.parse "255.255.255.255"

main:
  network := net.open
  ping-ping-test network
  ping-ping-timeout-test network
  io-data-test network
  broadcast-test network
  close-test network

ping-ping-test network/net.Client:
  times := 10

  ready := monitor.Channel 1
  task:: echo-responder network times ready
  port := ready.receive

  socket := udp.Socket network "127.0.0.1" 0

  socket.connect
      net.SocketAddress
          net.IpAddress.parse "127.0.0.1"
          port

  for i := 0; i < times; i++:
    socket.write "testing"
    expect-equals "testing" socket.read.to-string
  socket.close

echo-responder network/net.Client times ready:
  socket := udp.Socket network "127.0.0.1" 0
  ready.send socket.local-address.port

  for i := 0; i < times; i++:
    msg := socket.receive
    socket.send msg

  socket.close

class Timer:
  string_ := ?
  socket_ := ?
  resent := false

  constructor .string_ .socket_:

  call:
    resent = true
    return this

ping-ping-timeout-test network/net.Client:
  times := 10

  ready := monitor.Channel 1
  task:: echo-resend-responder network times ready
  port := ready.receive

  socket := udp.Socket network "127.0.0.1" 0

  socket.connect
      net.SocketAddress
          net.IpAddress.parse "127.0.0.1"
          port

  for i := 0; i < times; i++:
    timer := Timer "testing" socket
    socket.write "testing"
    e := catch:
      with-timeout --ms=100:
        data := socket.read
        expect-equals "testing" data.to-string

    if (i & 1) == 0:
      expect-null e
    else:
      expect e != null

io-data-test network/net.Client:
  times := 10

  ready := monitor.Channel 1
  // Also echo the large message after the loop.
  task:: echo-responder network (times + 1) ready
  port := ready.receive

  socket := udp.Socket network "127.0.0.1" 0

  socket.connect
      net.SocketAddress
          net.IpAddress.parse "127.0.0.1"
          port

  for i := 0; i < times; i++:
    socket.write (FakeData "testing")
    expect-equals "testing" socket.read.to-string

  data := "testing" * 700
  socket.write (FakeData data)
  expect-equals data socket.read.to-string

  socket.close

echo-resend-responder network/net.Client times ready:
  socket := udp.Socket network "127.0.0.1" 0
  ready.send socket.local-address.port

  for i := 0; i < times; i++:
    msg := socket.receive
    if (i & 1) == 0:
      socket.send msg

  socket.close

broadcast-test network/net.Client:
  // Apple clamped down on udp broadcast in macOS 15 Sequoia, and
  // it's not possible to run this test on GitHub runners anymore.
  // https://developer.apple.com/forums/thread/663875.
  if system.platform == system.PLATFORM-MACOS: return
  times := 10

  ready := monitor.Channel 1
  task:: broadcast-receiver network ready
  port := ready.receive

  socket := udp.Socket network "0.0.0.0" 0

  socket.broadcast = true

  msg := net.Datagram
    "hello world".to-byte-array
    net.SocketAddress
      BROADCAST-ADDRESS
      port

  for i := 0; i < times; i++:
    socket.send msg

  socket.close

broadcast-receiver network/net.Client ready:
  socket := udp.Socket network "0.0.0.0" 0
  socket.broadcast = true

  ready.send socket.local-address.port

  datagram := socket.receive

  expect-equals "hello world" datagram.data.to-string

  socket.close

close-test network/net.Client:
  ready := monitor.Channel 1

  socket := udp.Socket network "0.0.0.0" 0

  task::
    packet := socket.receive
    ready.send packet
    // While we are in this `receive` a different task closes the socket.
    // Test that we don't throw an exception, but just get a null.
    packet = socket.receive
    expect-equals null packet

  socket.send
      net.Datagram #['f', 'o', 'o']
          net.SocketAddress
              net.IpAddress.parse "127.0.0.1"
              socket.local-address.port

  ready.receive
  sleep --ms=100
  socket.close
