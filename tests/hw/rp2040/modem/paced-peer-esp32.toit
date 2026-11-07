// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import gpio
import net.tcp as tcp
import net.wifi

SIZE ::= 602_116

main:
  recovery := gpio.Pin 4 --input --pull-up
  network := wifi.establish --ssid="toit-rp2040-test" --password="pico-bringup-test"
  baseline := network.tcp-listen 4243
  paced := network.tcp-listen 4246
  larger := network.tcp-listen 4247
  worker := task:: accept paced 300 2048
  larger-worker := task:: accept larger 600 4096
  try:
    print "RP2040 paced TCP peer: READY $network.address"
    accept baseline 0 1024
  finally:
    worker.cancel
    larger-worker.cancel
    larger.close
    paced.close
    baseline.close
    network.close
    recovery.close

accept server/tcp.ServerSocket pause-ms/int burst-size/int:
  while true:
    socket := server.accept
    if not socket: continue
    task::
      error := catch:
        try:
          print "RP2040 paced TCP peer: start pause-ms=$pause-ms"
          with-timeout --ms=180_000:
            position := 0
            while position < SIZE:
              count := min 1024 (SIZE - position)
              socket.out.write (ByteArray count: ((position + it) * 31 + 19) & 0xff)
              position += count
              if pause-ms and position % burst-size == 0: sleep --ms=pause-ms
          print "RP2040 paced TCP peer: sent $SIZE pause-ms=$pause-ms"
        finally:
          socket.close
      if error: print "RP2040 paced TCP peer: ended pause-ms=$pause-ms error=$error"
