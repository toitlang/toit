// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net.modules.tcp
import net.udp
import monitor show Semaphore

class LoopbackNetwork implements udp.Interface:
  udp-open --port/int?=null -> udp.Socket:
    unreachable

main:
  network := LoopbackNetwork
  server := tcp.TcpServerSocket network
  server.listen "127.0.0.1" 0

  done := Semaphore
  client-error := null
  client-response := null
  task::
    client-error = catch:
      try:
        client := tcp.TcpSocket network
        try:
          client.connect "127.0.0.1" server.local-address.port
          if client.no-delay:
            throw "TCP_NODELAY unexpectedly enabled on connected socket"
          client.out.write "request"
          client-response = client.in.read
        finally:
          client.close
      finally:
        done.up

  accepted := server.accept
  try:
    if accepted.no-delay:
      throw "TCP_NODELAY unexpectedly enabled on accepted socket"
    request := accepted.in.read
    if request.to-string != "request":
      throw "unexpected request: $request"
    accepted.out.write "response"
  finally:
    accepted.close
    server.close

  done.down
  if client-error: throw client-error
  if client-response.to-string != "response":
    throw "unexpected response: $client-response"

  print "tcp-nagle: PASS connected and accepted loopback sockets"
