// Tests HTTPS (TLS) connection over cellular on EC618.

import net
import net.x509
import tls
import certificate-roots

main:
  certificate-roots.install-common-trusted-roots

  print "Opening network..."
  network := net.open
  try:
    print "Network address: $network.address"

    host := "example.com"
    port := 443
    print "Connecting to $host:$port..."
    tcp := network.tcp-connect host port
    try:
      socket := tls.Socket.client tcp
          --server-name=host
      try:
        request := "GET / HTTP/1.0\r\nHost: $host\r\nConnection: close\r\n\r\n"
        socket.out.write request
        print "Request sent, reading response..."

        total := 0
        while chunk := socket.in.read:
          total += chunk.size

        print "Received $total bytes over TLS"
        if total < 100: throw "response too small"
        print "HTTPS TEST PASSED"
      finally:
        socket.close
    finally:
      tcp.close
  finally:
    network.close
