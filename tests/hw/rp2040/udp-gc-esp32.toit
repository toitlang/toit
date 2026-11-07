// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import net.modules.udp as udp
import net.wifi

// Requires the lwIP backend. Injects a cached GC request whose global request
// may already have been serviced by another socket.
main:
  recovery := gpio.Pin 4 --input
  recovery.set-pull --up
  network := wifi.establish --ssid="toit-rp2040-test" --password="pico-bringup-test"
  client := udp.Socket network "127.0.0.1" 0
  peer := udp.Socket network "127.0.0.1" 0
  try:
    client.connect peer.local-address
    peer.connect client.local-address
    with-timeout --ms=5000:
      3.repeat: | round |
        bytes := ByteArray 513: (it * 37 + round) & 0xff
        client.state_.state_ |= udp.TOIT-UDP-NEEDS-GC_
        expect-equals bytes.size (client.write bytes)
        expect-equals 0 (client.state_.state_ & udp.TOIT-UDP-NEEDS-GC_)
        expect-equals bytes peer.read
        client.state_.state_ |= udp.TOIT-UDP-NEEDS-GC_
        responder := task::
          sleep --ms=5
          peer.write bytes
        try:
          expect-equals bytes client.read
          expect-equals 0 (client.state_.state_ & udp.TOIT-UDP-NEEDS-GC_)
        finally:
          responder.cancel
    print "RP2040 helper UDP GC event: PASS"
  finally:
    peer.close
    client.close
    network.close
    recovery.close
