// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import net.wifi
import gpio
import net.udp as udp
import tls
import system.assets
import net.tcp as tcp
import .modem.dns-fixture as dns
import .modem.firmware-server as firmware-server
import ...tls-no-net-test as certificates

// A temporary, isolated network for Pico bring-up. GPIO4 is the verified
// recovery/UART wire to Pico GP17; leave it as an input with a weak pull-up.
main:
  recovery := gpio.Pin 4 --input
  recovery.set-pull --up
  network := wifi.establish --ssid="toit-rp2040-test" --password="pico-bringup-test"
  server := network.tcp-listen 4242
  datagrams := network.udp-open --port=4242
  udp-boundaries := network.udp-open --port=4246
  udp-second-sender := network.udp-open --port=4247
  resolver := network.udp-open --port=53
  burst-server := network.tcp-listen 4243
  tls-server := network.tcp-listen 4244
  firmware-listener/tcp.ServerSocket? := null
  firmware-task/Task? := null
  if image := assets.decode.get "firmware-gzip":
    size := int.parse assets.decode["firmware-size"].to-string
    pattern := assets.decode.contains "firmware-pattern"
    diagnose-memory := assets.decode.contains "firmware-memory-probe"
    window-size := int.parse (assets.decode.get "firmware-window" --init=(: "32768".to-byte-array)).to-string
    firmware-listener = network.tcp-listen 4245
    firmware-task = task::
      while true:
        socket := firmware-listener.accept
        if not socket: continue
        task::
          error := catch:
            if pattern:
              firmware-server.serve-pattern socket size
            else:
              firmware-server.serve socket image size
                  --window-size=window-size
                  --diagnose-memory=diagnose-memory
          if error: print "RP2040 WIFI PEER firmware ended: $error"
  tls-task := task::
    while true:
      socket := tls-server.accept
      if not socket: continue
      task::
        secure/tls.Socket? := null
        error := catch:
          try:
            secure = tls.Socket.server socket
                --certificate=(tls.Certificate certificates.TEST-LOCALHOST-CERT-DIRECTLY-SIGNED
                    certificates.TEST-LOCALHOST-KEY-DIRECTLY-SIGNED)
            with-timeout --ms=60_000:
              while data := secure.in.read:
                secure.out.write data
          finally:
            if secure: secure.close
            else: socket.close
        // Negative certificate tests intentionally terminate the handshake.
        if error: print "RP2040 WIFI PEER TLS ended: $error"
  dns-task := task::
    while true:
      packet := resolver.receive
      catch --trace:
        if response := dns.reply packet.data network.address:
          resolver.send (udp.Datagram response packet.address)
  burst-task := task::
    while true:
      socket := burst-server.accept
      if not socket: continue
      task::
        error := catch:
          try:
            position := 0
            while position < 65_537:
              count := min 1024 (65_537 - position)
              socket.out.write (ByteArray count: ((position + it) * 31 + 19) & 0xff)
              position += count
            print "RP2040 WIFI PEER burst sent 65537 bytes"
          finally:
            socket.close
        if error: print "RP2040 WIFI PEER burst ended: $error"
  udp-task := task::
    while true:
      packet := datagrams.receive
      datagrams.send packet
  udp-boundary-task := task::
    while true:
      packet := udp-boundaries.receive
      if packet.data != "burst".to-byte-array: continue
      sizes := [1009, 907, 0, 1460, 1461, 3]
      sizes.size.repeat: | index/int |
        size/int := sizes[index]
        data := ByteArray size: (it * 37 + size) & 0xff
        sender := index % 2 == 0 ? udp-boundaries : udp-second-sender
        sender.send (udp.Datagram data packet.address)
  try:
    print "RP2040 WIFI PEER READY $network.address"
    while true:
      socket := server.accept
      if not socket: continue
      task::
        // Client-abandon and forced-stop tests may reset the TCP connection.
        // End this handler without taking down DNS and the other listeners.
        error := catch:
          try:
            while data := socket.in.read:
              socket.out.write data
          finally:
            socket.close
        if error: print "RP2040 WIFI PEER echo ended: $error"
  finally:
    if firmware-task: firmware-task.cancel
    if firmware-listener: firmware-listener.close
    udp-task.cancel
    udp-boundary-task.cancel
    udp-boundaries.close
    udp-second-sender.close
    dns-task.cancel
    burst-task.cancel
    tls-task.cancel
    tls-server.close
    resolver.close
    burst-server.close
    datagrams.close
    server.close
    network.close
    recovery.close
