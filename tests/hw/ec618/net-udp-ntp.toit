// Tests a UDP connection over cellular on EC618 by querying an NTP server.

import net
import net.udp

main:
  print "Opening network..."
  network := net.open
  try:
    print "Network address: $network.address"

    host := "pool.ntp.org"
    addresses := network.resolve host
    if addresses.is-empty: throw "no address for $host"
    server := addresses[0]
    print "NTP server: $server"

    socket := network.udp-open
    try:
      // NTP request: 48 bytes, first byte = 0x1B (version 3, mode 3 client).
      request := ByteArray 48
      request[0] = 0x1b

      datagram := udp.Datagram request (net.SocketAddress server 123)
      socket.send datagram

      // Wait for response.
      with-timeout (Duration --s=5):
        response := socket.receive
        print "Received NTP response: $response.data.size bytes"
        if response.data.size != 48: throw "unexpected NTP response size"
        // Extract seconds since 1900 from bytes 40-43.
        seconds := 0
        4.repeat: | i | seconds = seconds * 256 + response.data[40 + i]
        // Convert to unix epoch (NTP epoch is 2208988800 seconds before unix).
        unix := seconds - 2208988800
        print "NTP time: $unix (unix epoch seconds)"
        if unix < 1700000000: throw "NTP time looks wrong"
      print "UDP/NTP TEST PASSED"
    finally:
      socket.close
  finally:
    network.close
