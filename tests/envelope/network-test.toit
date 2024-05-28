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
  server.local-address
  task::
    connection := server.accept
    data := #[]
    while chunk := connection.in.read:
      data += chunk
      if data.size >= 5:
        break
    expect-equals "hello".to-byte-array data

  client := network.tcp-connect server.local-address
  client.out.write "hello"
  client.out.close
