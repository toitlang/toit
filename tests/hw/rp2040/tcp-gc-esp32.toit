// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import net.modules.tcp as tcp
import net.wifi

// Requires the lwIP backend: the host TCP GC primitive is intentionally absent.
// Injects the readiness bit, not an allocation failure, to check consumption of
// an event even when another socket has already serviced the global GC request.
main:
  recovery := gpio.Pin 4 --input
  recovery.set-pull --up
  network := wifi.establish --ssid="toit-rp2040-test" --password="pico-bringup-test"
  server := tcp.TcpServerSocket network
  server.listen "127.0.0.1" 0
  client := tcp.TcpSocket network
  client.connect "127.0.0.1" server.local-address.port
  peer := server.accept
  try:
    with-timeout --ms=5000:
      3.repeat: | round |
        bytes := ByteArray 513: (it * 37 + round) & 0xff
        client.state_.state_ |= tcp.TOIT-TCP-NEEDS-GC_
        client.out.write bytes
        expect-equals 0 (client.state_.state_ & tcp.TOIT-TCP-NEEDS-GC_)
        expect-equals bytes (peer.in.read-bytes bytes.size)
        client.state_.state_ |= tcp.TOIT-TCP-NEEDS-GC_
        responder := task::
          sleep --ms=5
          peer.out.write bytes
        try:
          expect-equals bytes (client.in.read-bytes bytes.size)
          expect-equals 0 (client.state_.state_ & tcp.TOIT-TCP-NEEDS-GC_)
        finally:
          responder.cancel
    print "RP2040 helper TCP GC event: PASS"
  finally:
    peer.close
    client.close
    server.close
    network.close
    recovery.close
