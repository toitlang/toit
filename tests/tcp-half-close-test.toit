// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import net
import net.modules.tcp

// Tests peer-initiated connection teardown.
//
// A clean close must surface as end-of-stream (null) on the read path; a
// reset must throw.
//
// The clean-close case also covers the handshake where the peer closes first
// and we only half-close our own side (close the writer, keep reading). On
// lwIP-based platforms this is the only sequence that makes the stack deliver
// ERR_CLSD to the error callback: the pcb is freed underneath the socket
// while the Toit side still considers it healthy. The socket must keep
// behaving sanely afterwards; in particular state queries must not crash
// the VM.
main:
  network := net.open
  test-clean-close network
  test-reset network

test-clean-close network/net.Client:
  port-latch := monitor.Latch

  task::
    server := tcp.TcpServerSocket network
    server.listen "127.0.0.1" 0
    port-latch.set server.local-address.port
    socket := server.accept
    // Close first, so the peer sees a clean end-of-stream while its
    // connection is still open.
    socket.close
    server.close

  client := tcp.TcpSocket network
  client.connect "127.0.0.1" port-latch.get

  // The peer closed cleanly: reading must signal end-of-stream with null.
  expect-null client.in.read

  // Half-close the write side. This sends our FIN; the peer's final ACK
  // completes the handshake and (on lwIP) frees the pcb with ERR_CLSD.
  client.out.close

  // Give the stack time to deliver the final ACK.
  sleep --ms=200

  // Reads must keep signaling end-of-stream.
  expect-null client.in.read

  // State queries must return a value or throw cleanly, not crash.
  exception := catch: client.local-address
  print "local-address after close handshake: $(exception ? "threw '$exception'" : "ok")"

  exception = catch: client.no-delay
  print "no-delay after close handshake: $(exception ? "threw '$exception'" : "ok")"

  client.close

test-reset network/net.Client:
  port-latch := monitor.Latch

  task::
    server := tcp.TcpServerSocket network
    server.listen "127.0.0.1" 0
    port-latch.set server.local-address.port
    socket := server.accept
    // Let the client's data arrive, then close without reading it. Closing
    // with unread data makes the stack send a reset instead of a FIN.
    sleep --ms=300
    socket.close
    server.close

  client := tcp.TcpSocket network
  client.connect "127.0.0.1" port-latch.get
  client.out.write "data the server never reads"

  // A reset is an error, not an end-of-stream: the read must throw.
  exception := catch: client.in.read
  print "read on reset connection: threw '$exception'"
  expect-not-null exception

  client.close
