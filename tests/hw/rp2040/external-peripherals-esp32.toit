// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio.dac show Dac
import i2c
import spi
import uart

import .external-protocol show *

ADDRESS ::= 0x42

main:
  port := uart.Port --tx=4 --rx=34 --baud-rate=115_200
  dac/Dac? := null
  target/i2c.Target? := null
  bus/i2c.Bus? := null
  device/i2c.Device? := null
  try:
    send port "START"
    while true:
      parts := (receive port).split " "
      command := parts[0]
      if command == "DAC":
        level := int.parse parts[1]
        expect (0 <= level <= 6)
        if not dac: dac = Dac 25
        dac.set (level * 0.5)
        sleep --ms=20
      else if command == "DAC-CLOSE":
        dac.set 0.0
        dac.close
        dac = null
      else if command == "CONTROLLER":
        expect (not target and not bus)
        size := int.parse parts[1]
        target = i2c.Target
            --sda=19
            --scl=27
            --address=ADDRESS
            --receive-buffer-size=4096
            --default-response=(pattern size 7)
            --pull-up
      else if command == "CHECK":
        size := int.parse parts[1]
        expect-equals (pattern size 23) (with-timeout --ms=2_000: target.read)
      else if command == "TARGET":
        expect (not target and not bus)
        bus = i2c.Bus --sda=19 --scl=27 --frequency=(int.parse parts[1]) --pull-up
        device = bus.device ADDRESS --timeout-us=2_000_000
      else if command == "TRANSFER":
        size := int.parse parts[1]
        expect-equals (pattern size 7) (device.write-read (pattern size 23) size)
      else if command == "CLOSE":
        if target: target.close
        target = null
        if device: device.close
        device = null
        if bus: bus.close
        bus = null
      else if command == "SPI-CONTROLLER":
        expect (not dac and not target and not bus)
        spi-target port (int.parse parts[1]) (int.parse parts[2])
      else if command == "SPI-TARGET":
        expect (not dac and not target and not bus)
        seed := parts.size == 4 ? int.parse parts[3] : 7
        spi-controller port (int.parse parts[1]) (int.parse parts[2]) seed
      else if command == "SPI-TARGET-PAUSE":
        expect (not dac and not target and not bus)
        spi-controller-pause port (int.parse parts[1])
      else if command == "SPI-BUFFER":
        expect (not dac and not target and not bus)
        spi-buffer-controller port (int.parse parts[1]) (int.parse parts[2])
      else if command == "SPI-PARTIAL":
        expect (not dac and not target and not bus)
        spi-partial-controller port (int.parse parts[1]) (int.parse parts[2])
      else if command == "QUIT":
        expect (not dac and not target and not bus)
        send port "OK"
        print "external-peripherals-esp32: PASS"
        return
      else:
        throw "Unexpected command $parts"
      send port "OK"
  finally:
    if dac:
      dac.set 0.0
      dac.close
    if target: target.close
    if device: device.close
    if bus: bus.close
    port.close

spi-target port/uart.Port mode/int size/int:
  target := spi.Target
      --mosi=23
      --miso=19
      --clock=18
      --cs=27
      --mode=mode
      --max-transfer-size=size
      --no-dma
  try:
    data := with-timeout --ms=5_000:
      target.transfer (pattern size 7)
          --receive-size=size
          --when-armed=(: send port "OK")
    expect-equals (pattern size 23) data
  finally:
    target.close

spi-controller port/uart.Port mode/int size/int seed/int:
  bus := spi.Bus --mosi=19 --miso=23 --clock=18
  try:
    device := bus.device --cs=27 --frequency=400_000 --mode=mode
    try:
      send port "OK"
      expect-equals "CLOCK" (receive port)
      send port "CLOCKING"
      data := pattern size 23
      with-timeout --ms=3_000: device.transfer data --read
      expect-equals (pattern size seed) data
    finally:
      device.close
  finally:
    bus.close

spi-controller-pause port/uart.Port mode/int:
  bus := spi.Bus --mosi=19 --miso=23 --clock=18
  try:
    device := bus.device --cs=27 --frequency=400_000 --mode=mode
    try:
      send port "OK"
      expect-equals "CLOCK" (receive port)
      device.with-reserved-bus:
        data := pattern 3 23
        device.transfer data --read --keep-cs-active
        expect-equals (pattern 3 199) data
        send port "ACTIVE"
        expect-equals "RELEASE" (receive port)
        // The RP2040 has retired the transfer before this final release byte.
        // It must not be retained as part of the next transaction.
        device.write #[0]
    finally:
      device.close
  finally:
    bus.close

spi-buffer-controller port/uart.Port mode/int capacity/int:
  bus := spi.Bus --mosi=19 --miso=23 --clock=18
  try:
    device := bus.device --cs=27 --frequency=400_000 --mode=mode
    try:
      send port "OK"
      expect-equals "CLOCK" (receive port)
      response := pattern capacity 7
      spi-buffer-exchange device 3 23 response
      spi-buffer-exchange device (capacity + 7) 41 response
      spi-buffer-exchange device 7 59 response
      send port "MIXED"
      expect-equals "NEXT" (receive port)
      // The next response can still contain prefetched bytes from before the
      // update. The transaction after it must expose the updated response.
      device.write (pattern 1 99)
      sleep --ms=1
      send port "WARMED"
      expect-equals "FLOOD" (receive port)
      response = pattern capacity 113
      response[capacity - 1] ^= 0xff
      6.repeat: | index/int |
        spi-buffer-exchange device 7 (100 + index) response
      send port "FLOODED"
      expect-equals "RECOVER" (receive port)
      spi-buffer-exchange device capacity 205 response
      send port "RECOVERED"
      expect-equals "FINISH" (receive port)
    finally:
      device.close
  finally:
    bus.close

spi-buffer-exchange device/spi.Device size/int seed/int response/ByteArray:
  bytes := pattern size seed
  with-timeout --ms=2_000: device.transfer bytes --read
  count := min size response.size
  expect-equals response[..count] bytes[..count]
  // Leave a bounded idle interval for the target's native completion handler.
  sleep --ms=1

spi-partial-controller port/uart.Port mode/int bits/int:
  bus := spi.Bus --mosi=19 --miso=23 --clock=18
  try:
    // Use the ESP32 command phase to generate a precise number of clocks.
    device := bus.device --cs=27 --frequency=100_000 --mode=mode --command-bits=bits
    try:
      send port "OK"
      expect-equals "CLOCK" (receive port)
      send port "CLOCKING"
      with-timeout --ms=2_000:
        device.transfer #[] --command=(0xa7f9 >> (16 - bits))
    finally:
      device.close
  finally:
    bus.close
