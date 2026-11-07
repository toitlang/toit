// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import net
import system.storage
import .network-service show open-service test-network
import .service-provider show STATE

main arguments/List:
  expect-equals 1 arguments.size
  mode/string := arguments.first
  service := open-service
  network := net.open --service=service
  test-network network
  if mode == "shared":
    second := net.open --service=service
    network.close
    try:
      test-network second
    finally:
      second.close
      service.close
  else:
    socket := network.tcp-connect "echo.rp2040.test" 4242
    datagrams := network.udp-open
    expect (datagrams.local-address.port > 0)
    if mode == "hold":
      state := storage.Bucket.open --ram STATE
      state["holding"] = true
      // The coordinator terminates this container with its TCP read blocked.
      socket.in.read
      throw "Unexpected TCP EOF before container termination"
    expect-equals "abandon" mode
    // Deliberately retain live TCP, UDP and network resources at process exit.
  print "RP2040 ESP8285 container client $mode: PASS"
