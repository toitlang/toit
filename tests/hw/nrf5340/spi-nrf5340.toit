// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import spi
import expect show *
import monitor show Semaphore

main:
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  bus := spi.Bus --clock=8 --mosi=9 --miso=10
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 8 --output)
  expect-equals "ALREADY_IN_USE" (catch: spi.Bus --clock=36 --mosi=37 --miso=34)
  free-pin := gpio.Pin 36 --input
  free-pin.close
  expect-equals "INVALID_ARGUMENT" (catch: bus.device --cs=11 --frequency=10000)
  expect-equals "INVALID_ARGUMENT" (catch: bus.device --cs=11 --frequency=1000000 --command-bits=1)
  expect-equals "UNIMPLEMENTED" (catch: bus.device --cs=11 --frequency=1000000 --cs-setup-cycles=1)

  4.repeat: | mode |
    device := bus.device --cs=11 --frequency=1000000 --mode=mode
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 11 --output)
    [1, 2, 3, 17, 32, 63, 64].do: | size |
      request.call "SPI_ARM 18 23 19 4 $mode $size BOTH 0"
      data := pattern size 23
      device.transfer data --read
      expect-equals (pattern size 7) data
      request.call "SPI_CHECK"
    device.close
  print "SPI full-duplex modes 0..3 and short lengths PASS"

  [125000, 500000, 4000000].do: | frequency |
    device := bus.device --cs=11 --frequency=frequency
    request.call "SPI_ARM 18 23 19 4 0 32 BOTH 0"
    data := pattern 32 23
    device.transfer data --read
    expect-equals (pattern 32 7) data
    request.call "SPI_CHECK"
    device.close
  print "SPI clock rates PASS"

  device := bus.device --cs=11 --frequency=1000000
  request.call "SPI_ARM 18 23 19 4 0 32 BOTH 0"
  data := #[0xaa, 0xbb] + (pattern 32 23) + #[0xcc]
  device.transfer data --from=2 --to=34 --read
  expect-equals (#[0xaa, 0xbb] + (pattern 32 7) + #[0xcc]) data
  request.call "SPI_CHECK"

  request.call "SPI_ARM 18 23 19 4 0 64 BOTH 0"
  device.with-reserved-bus:
    first := pattern 32 23
    second := pattern 32 (23 + 32 * 73)
    device.transfer first --read --keep-cs-active
    device.transfer second --read
    expect-equals (pattern 32 7) first
    expect-equals (pattern 32 (7 + 32 * 73)) second
  request.call "SPI_CHECK"
  request.call "SPI_ARM 18 23 19 4 0 32 BOTH 0"
  expect-equals "reservation-exit" (catch:
    device.with-reserved-bus:
      device.transfer (pattern 32 23) --keep-cs-active
      throw "reservation-exit")
  request.call "SPI_CHECK"
  device.close
  print "SPI slices and reserved CS cleanup PASS"

  [1, 3].do: | prefix |
    device = bus.device --cs=11 --dc=32 --frequency=1000000
        --command-bits=8
        --address-bits=(prefix == 3 ? 16 : 0)
    size := 32 + prefix
    request.call "SPI_ARM 18 23 19 4 0 $size BOTH $prefix"
    data = pattern 32 23
    device.transfer data --read --command=(prefix == 3 ? 0xa5 : 0x0b) --address=0x1234 --dc=1
    expect-equals (pattern 32 (7 + prefix * 73)) data
    request.call "SPI_CHECK"
    request.call "CHECK 13 1"
    device.close
    request.call "CONFIG 13 DOWN 0"
    request.call "CHECK 13 0"
  print "SPI command/address prefix and DC PASS"

  device = bus.device --cs=11 --frequency=1000000 --command-bits=4 --address-bits=4
  request.call "SPI_ARM 18 23 19 4 0 33 BOTH 1"
  data = pattern 32 23
  device.transfer data --read --command=0 --address=0x0b
  expect-equals (pattern 32 (7 + 73)) data
  request.call "SPI_CHECK"
  device.close

  first-device := bus.device --cs=11 --frequency=1000000 --mode=0
  second-device := bus.device --cs=32 --frequency=1000000 --mode=3
  4.repeat: | iteration |
    alternate := iteration % 2 == 1
    cs := alternate ? 13 : 4
    mode := alternate ? 3 : 0
    request.call "SPI_ARM 18 23 19 $cs $mode 32 BOTH 0"
    data = pattern 32 23
    (alternate ? second-device : first-device).transfer data --read
    expect-equals (pattern 32 7) data
    request.call "SPI_CHECK"
  second-device.close
  first-device.close
  print "SPI multiple devices and mode switching PASS"

  device = bus.device --cs=11 --frequency=125000
  request.call "SPI_ARM 18 23 19 4 0 4096 RX 0"
  ticks := 0
  ticker := task::
    while true:
      ticks++
      sleep --ms=5
  device.transfer (pattern 4096 23)
  ticker.cancel
  expect ticks >= 3
  request.call "SPI_CHECK"
  request.call "SPI_ARM 18 23 19 4 0 4096 TX 0"
  data = pattern 4096 23
  device.transfer data --read
  expect-equals (pattern 4096 7) data
  request.call "SPI_CHECK"
  request.call "SPI_ARM 18 23 19 4 0 4096 TX 0"
  data = pattern 4096 23
  expect-equals DEADLINE-EXCEEDED-ERROR (catch:
    with-timeout --ms=2: device.transfer data --read)
  expect-equals (pattern 4096 23) data
  request.call "SPI_CHECK"
  request.call "SPI_ARM 18 23 19 4 0 32 BOTH 0"
  data = pattern 32 23
  device.transfer data --read
  expect-equals (pattern 32 7) data
  request.call "SPI_CHECK"
  // Cross the ESP32 receiver's DMA descriptor boundaries without truncating
  // or ignoring any bytes. The fixture checks the actual received length.
  [4088, 4092, 4096, 4100, 4104, 8192].do: |size|
    request.call "SPI_ARM 18 23 19 4 0 $size RX 0"
    device.transfer (pattern size 23)
    request.call "SPI_CHECK"
    request.call "SPI_ARM 18 23 19 4 0 $size TX 0"
    data = ByteArray size
    device.transfer data --read
    expect-equals (pattern size 7) data
    request.call "SPI_CHECK"
  print "SPI DMA descriptor boundaries through 8192 bytes PASS"
  device.close
  bus.close
  print "SPI large DMA, runnable VM, cancellation and recovery PASS"

  bus = spi.Bus --clock=8 --mosi=9
  device = bus.device --cs=11 --frequency=1000000
  request.call "SPI_ARM 18 23 19 4 0 1024 RX 0"
  device.transfer (pattern 1024 23)
  request.call "SPI_CHECK"
  bus.close
  bus = spi.Bus --clock=8 --miso=10
  device = bus.device --cs=11 --frequency=1000000
  request.call "SPI_ARM 18 23 19 4 0 1024 TX 0"
  data = ByteArray 1024
  device.transfer data --read
  expect-equals (pattern 1024 7) data
  request.call "SPI_CHECK"
  bus.close
  print "SPI transmit-only and receive-only buses PASS"

  bus = spi.Bus --clock=8 --mosi=9 --miso=10
  manual-cs := gpio.Pin 11 --output --value=1
  device = bus.device --frequency=1000000
  request.call "SPI_ARM 18 23 19 4 0 32 BOTH 0"
  data = pattern 32 23
  manual-cs.set 0
  device.transfer data --read
  manual-cs.set 1
  expect-equals (pattern 32 7) data
  request.call "SPI_CHECK"
  device.close
  manual-cs.close
  bus.close
  print "SPI externally controlled CS PASS"

  64.repeat: | cycle |
    alternate := cycle % 2 == 1
    mode := (cycle / 2).to-int % 4
    bus = spi.Bus --clock=(alternate ? 36 : 8) --mosi=(alternate ? 37 : 9) --miso=(alternate ? 34 : 10)
    device = bus.device --cs=(alternate ? 35 : 11) --frequency=1000000 --mode=mode
    clk := alternate ? 32 : 18
    mosi := alternate ? 33 : 23
    miso := alternate ? 21 : 19
    cs := alternate ? 22 : 4
    request.call "SPI_ARM $clk $mosi $miso $cs $mode 32 BOTH 0"
    data = pattern 32 23
    device.transfer data --read
    expect-equals (pattern 32 7) data
    request.call "SPI_CHECK"
    bus.close
    request.call "CONFIG $clk DOWN 0"
    request.call "CONFIG $cs DOWN 0"
    request.call "CHECK $clk 0"
    request.call "CHECK $cs 0"
  print "SPI 64 close and remap cycles PASS"

  // The host verifies this entire payload after process cleanup, before
  // checking that CS no longer drives high.
  bus = spi.Bus --clock=8 --mosi=9 --miso=10
  device = bus.device --cs=11 --frequency=125000
  request.call "SPI_ARM 18 23 19 4 0 4096 RX 0"
  final-payload := pattern 4096 23
  started := Semaphore
  task::
    started.up
    device.transfer final-payload
  started.down
  sleep --ms=10
  print "NRF5340 SPI PASS"
  ack.close

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 73 + seed) & 0xff
