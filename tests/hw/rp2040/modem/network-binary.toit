// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285 UdpSocket
import log
import net
import net.udp as udp
import system
import uart

// Runs through the public adapter API on AT 2.2 with the UDP extension.
// The ordinary Wi-Fi helper supplies echo and queued boundary responders.
main:
  run

run --receive-timeout/bool=false:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  network := Esp8285 port.in port.out --logger=(log.default.with-level log.INFO-LEVEL)
  try:
    network.connect "toit-rp2040-test" "pico-bringup-test"
    address := net.SocketAddress (net.IpAddress.parse "200.200.200.1") 4242
    payloads := [
      "+++".to-byte-array,
      "\r\nAT+RST\r\n".to-byte-array,
      (ByteArray 1460: it & 0xff),
      (ByteArray 1460 --initial='+'),
      (ByteArray 1460 --initial='\\'),
      #[ '\\', '0', 0, '\\', '+', '+', '+', '\\' ],
    ]
    tcp := network.tcp-connect address
    try:
      payloads.do: | payload/ByteArray |
        with-timeout --ms=10_000:
          tcp.out.write payload
          system.process-stats --gc
          check (payload == (tcp.in.read-bytes payload.size))
        print "ESP8285 adapter TCP binary $(payload.size): PASS"
    finally:
      tcp.close
    socket := (network.udp-open) as UdpSocket
    try:
      socket.connect address
      payloads.do: | payload/ByteArray |
        with-timeout --ms=10_000:
          check ((socket.write payload) == payload.size)
          system.process-stats --gc
          packet := socket.receive
          check (packet.data == payload)
          check (packet.address == address)
        print "ESP8285 adapter UDP binary $(payload.size): PASS"
      if receive-timeout:
        // No echo remains queued. Exercise cleanup after a blocked receive.
        with-timeout --ms=1000: socket.receive
        throw "UNEXPECTED_RECOVERY_TEST_DATAGRAM"
      with-timeout --ms=5000:
        check ((socket.write #[]) == 0)
        packet := socket.receive
        check (packet.data == #[])
        check (packet.address == address)
      print "ESP8285 adapter UDP empty send: PASS"
    finally:
      socket.close
    socket = (network.udp-open) as UdpSocket
    try:
      target := net.SocketAddress address.ip 4246
      2.repeat: | cycle/int |
        with-timeout --ms=10_000:
          socket.send (udp.Datagram "burst".to-byte-array target)
          // Let the complete burst queue before reading from the adapter.
          sleep --ms=500
          sizes := [1009, 907, 0, 1460, 3]
          sizes.size.repeat: | index/int |
            size/int := sizes[index]
            packet := socket.receive
            check (packet.data == (ByteArray size: (it * 37 + size) & 0xff))
            check (packet.address.ip == address.ip)
            check (packet.address.port == (index == 4 or index % 2 == 1 ? 4247 : 4246))
          check (socket.dropped-datagrams == cycle + 1)
        print "ESP8285 adapter UDP boundary cycle $cycle: PASS"
    finally:
      socket.close
    check (port.errors == 0)
    print "ESP8285 adapter UART errors=0"
  finally:
    try:
      network.close
    finally:
      port.close
  print "RP2040 ESP8285 adapter binary: PASS"

check condition/bool:
  if not condition: throw "ESP8285_BINARY_CHECK_FAILED"
