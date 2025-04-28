// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net
import net.tcp
import .util show EnvelopeTest with-test

main args:
  network := net.open

  server := network.tcp-listen 0
  task::
    connection := server.accept
    data := #[]
    while chunk := connection.in.read:
      data += chunk
      if data.size >= 5:
        break
    expect-equals "hello".to-byte-array data

  // On Windows, the server.local-address doesn't have a valid IP address,
  // so we just hard-code it to 127.0.0.1.
  ip-address := net.IpAddress.parse "127.0.0.1"
  address := net.SocketAddress ip-address server.local-address.port
  client := network.tcp-connect address
  client.out.write "hello"
  client.out.close
