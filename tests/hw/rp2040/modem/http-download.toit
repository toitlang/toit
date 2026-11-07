// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285
import crypto.sha256 show Sha256
import expect show *
import http
import io
import log
import system.assets
import uart

// Isolates the OTA sender and HTTP reader from flash writes and service RPC.
main:
  expected/ByteArray := assets.decode["sha256"]
  size := int.parse assets.decode["size"].to-string
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  network := Esp8285 port.in port.out --logger=(log.default.with-level log.INFO-LEVEL)
  try:
    network.connect "toit-rp2040-test" "pico-bringup-test"
    error := catch: download network port "/truncated.bin" size
    expect-equals io.Reader.UNEXPECTED-END-OF-READER error
    print "ESP8285 HTTP: rejected truncated body"
    corrupt := download network port "/corrupt.bin" size
    expect (corrupt != expected)
    expect-equals expected (download network port "/firmware.bin" size)
    expect-equals 0 port.errors
    print "RP2040 ESP8285 HTTP download: PASS"
  finally:
    network.close
    port.close

download network/Esp8285 port/uart.Port path/string size/int -> ByteArray:
  client := http.Client network
  total := 0
  next-progress := 65_536
  started := Time.monotonic-us
  last-progress := started
  phase := "headers"
  observer := task::
    while true:
      sleep --ms=5000
      idle-ms := (Time.monotonic-us - last-progress) / 1000
      if idle-ms >= 10_000:
        print "ESP8285 HTTP: idle-ms=$idle-ms bytes=$total phase=$phase path=$path uart-errors=$(port.errors)"
  try:
    print "ESP8285 HTTP: start path=$path uart-errors=$(port.errors)"
    return with-timeout --ms=180_000:
      response := client.get "200.200.200.1" --port=4245 path
      expect-equals 200 response.status-code
      expect-equals size response.content-length
      phase = "body"
      hash := Sha256
      while bytes := response.body.read --max-size=1024:
        hash.add bytes
        total += bytes.size
        last-progress = Time.monotonic-us
        if total >= next-progress:
          print "ESP8285 HTTP: bytes=$total path=$path"
          next-progress += 65_536
      expect-equals size total
      print "ESP8285 HTTP: complete path=$path elapsed-ms=$((Time.monotonic-us - started) / 1000)"
      hash.get
  finally:
    observer.cancel
    print "ESP8285 HTTP: final bytes=$total phase=$phase path=$path uart-errors=$(port.errors)"
    client.close
