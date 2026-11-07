// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.service show Esp8285ServiceProvider
import expect show *
import log
import net
import system
import system.api.network show NetworkService NetworkServiceClient
import uart

provider -> Esp8285ServiceProvider:
  return Esp8285ServiceProvider "toit-rp2040-test" "pico-bringup-test"
      --tx=0
      --rx=1
      --dns-server=(net.IpAddress.parse "200.200.200.1")
      --logger=(log.default.with-level log.INFO-LEVEL)

open-service -> NetworkServiceClient:
  selector := NetworkService.SELECTOR.restrict.allow --tag="esp8285"
  return ((NetworkServiceClient selector).open --timeout=(Duration --s=10)) as NetworkServiceClient

main:
  service-provider := provider
  service-provider.install
  try:
    2.repeat:
      service := open-service
      first := net.open --service=service
      second := net.open --service=service
      try:
        expect-equals first.address second.address
        first.close
        test-network second
      finally:
        first.close
        second.close
        service.close
      // Closing the last network must release the physical UART.
      (uart.Port --tx=0 --rx=1 --baud-rate=115_200).close
  finally:
    service-provider.uninstall

  service-provider = provider
  service-provider.install
  spawn::
    service := open-service
    network := net.open --service=service
    test-network network
    // Deliberately leave a live socket and network behind on process exit.
    network.tcp-connect "echo.rp2040.test" 4242
    print "ESP8285 separate network client: PASS"
  service-provider.uninstall --wait
  (uart.Port --tx=0 --rx=1 --baud-rate=115_200).close
  print "RP2040 ESP8285 network service: PASS"

test-network network/net.Interface:
  helper := net.IpAddress.parse "200.200.200.1"
  expect-equals [helper] (network.resolve "echo.rp2040.test")
  tcp := network.tcp-connect "echo.rp2040.test" 4242
  udp := network.udp-open
  try:
    expect-equals network.address tcp.local-address.ip
    expect-equals 4242 tcp.peer-address.port
    payload := ByteArray 3001: (it * 37 + 11) & 0xff
    tcp.out.write payload
    system.process-stats --gc
    expect-equals payload (tcp.in.read-bytes payload.size)
    udp.connect (net.SocketAddress helper 4242)
    expect-equals 257 (udp.write payload 0 257)
    packet := udp.receive
    expect-equals payload[..257] packet.data
    expect-equals helper packet.address.ip
    expect-equals 4242 packet.address.port
  finally:
    udp.close
    tcp.close
