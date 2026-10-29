// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import gpio.adc show Adc
import i2c
import spi
import uart
import zephyr
import system.assets
import system.containers

main:
  ack := gpio.Pin 33 --input --pull-down
  phase-pin := gpio.Pin 32 --input
  phase := phase-pin.get
  phase-pin.close
  sleep --ms=100
  sequence := 0
  request := : |command/string|
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  failure := assets.decode["failure"].to-string
  critical := (containers.images.filter: it.name == "critical").first
  ordinary := (containers.images.filter: it.name == "ordinary").first
  expect-equals 2 (critical.flags & 3)
  expect-equals 0 (ordinary.flags & 3)
  // The fixture's other phase outputs share UART pins; release them before use.
  request.call "CONFIG 32 IN 0"
  request.call "CONFIG 33 IN 0"
  request.call "CONFIG 26 DOWN 0"
  if phase == 0:
    [
      [critical, {"operation": "exit", "code": 0}, 0],
      [ordinary, {"operation": "exit", "code": 23}, 23],
      [ordinary, {"operation": "throw"}, 1],
    ].do: |test|
      worker := containers.start test[0].id test[1]
      with-timeout --ms=5000: expect-equals test[2] worker.wait
      worker.close
      request.call "CHECK 26 0"
      pin := gpio.Pin 5 --output
      pin.close
      adc := Adc 4
      adc.get
      adc.close
    worker := containers.start critical.id {"operation": "hold"}
    request.call "WAIT 26 1"
    expect-equals 0 worker.stop
    worker.close
    request.call "CHECK 26 0"
    sleep --ms=1200
    print "LIFECYCLE ordinary errors, critical success/stop and resource reuse PASS"

    // Keep resources in two processes alive when a different container fails.
    child := spawn::
      port := uart.Port --tx=36 --rx=37 --baud-rate=115200
      indicator := gpio.Pin 5 --output --value=1
      while true: port.in.read
    request.call "WAIT 26 1"
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 36 --output)
    adc := Adc 4
    adc.get
    spi-bus := spi.Bus --clock=8 --mosi=9 --miso=10
    device := spi-bus.device --cs=11 --frequency=1000000
    device.transfer #[1, 2, 3, 4]
    bus := i2c.Bus --sda=34 --scl=35 --frequency=100000 --pull-up
    target := bus.device 0x42
    request.call "CONFIG 13 OUT 1"
    request.call "CONFIG 22 OUT 0"
    pending := true
    task::
      catch: target.read 17
      pending = false
    sleep --ms=10
    expect pending
    print "LIFECYCLE pending I2C, UART child, SPI and ADC ready"
    worker = containers.start critical.id {"operation": "critical-failure", "failure": failure}
    worker.wait
    throw "critical failure did not stop the system"

  expect-equals 1 phase
  expect (zephyr.reset-reason & zephyr.RESET-SOFTWARE != 0)
  request.call "CHECK 26 0"
  request.call "CONFIG 22 IN 0"
  // Exercise the peripherals after restart, not just their constructors.
  request.call "UART_OPEN 32 33 115200 1"
  port := uart.Port --tx=36 --rx=37 --baud-rate=115200
  payload := #[0, 1, 127, 128, 254, 255]
  port.out.write payload --flush
  received := #[]
  with-timeout --ms=2000:
    while received.size < payload.size: received += port.in.read
  expect-bytes-equal payload received
  port.close
  request.call "UART_CLOSE"
  bus := i2c.Bus --sda=34 --scl=35 --frequency=100000 --pull-up
  request.call "I2C_OPEN 21 22 17"
  expect-bytes-equal (ByteArray 17: (it * 73 + 7) & 255) ((bus.device 0x42).read 17)
  bus.close
  request.call "I2C_CLOSE"
  spi-bus := spi.Bus --clock=8 --mosi=9 --miso=10
  device := spi-bus.device --cs=11 --frequency=1000000
  request.call "SPI_ARM 18 23 19 4 0 32 BOTH 0"
  data := ByteArray 32: (it * 73 + 23) & 255
  device.transfer data --read
  expect-bytes-equal (ByteArray 32: (it * 73 + 7) & 255) data
  request.call "SPI_CHECK"
  device.close
  spi-bus.close
  request.call "ADC_DAC 1500 0"
  adc := Adc 4
  expect ((adc.get - 1.5).abs < 0.2)
  adc.close
  request.call "IDLE"
  request.call "CONFIG 26 DOWN 0"
  indicator := gpio.Pin 5 --output --value=1
  request.call "WAIT 26 1"
  print "NRF5340 LIFECYCLE $failure PASS: restart and peripheral recovery"
