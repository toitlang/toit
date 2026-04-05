// Tests a TCP connection over cellular on EC618 by making an HTTP GET.

import net
import net.tcp

main:
  print "Opening network..."
  network := net.open
  try:
    print "Network address: $network.address"

    // Connect to example.com on port 80.
    host := "example.com"
    port := 80
    print "Connecting to $host:$port..."
    socket := network.tcp-connect host port
    try:
      // Send a simple HTTP GET request.
      request := "GET / HTTP/1.0\r\nHost: $host\r\nConnection: close\r\n\r\n"
      socket.out.write request
      print "Request sent, reading response..."

      total := 0
      while chunk := socket.in.read:
        total += chunk.size

      print "Received $total bytes"
      if total < 100: throw "response too small"
      print "TCP TEST PASSED"
    finally:
      socket.close
  finally:
    network.close
