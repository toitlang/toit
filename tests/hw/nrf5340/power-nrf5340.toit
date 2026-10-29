// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import gpio.adc show Adc
import i2c
import spi
import uart
import zephyr
import zephyr.watchdog

main:
  run

run --edge-cases/bool=false:
  ack := gpio.Pin 33 --input --pull-down
  phase-pins := [36, 37].map: gpio.Pin it --input
  phase := phase-pins[0].get | (phase-pins[1].get << 1)
  phase-pins.do: it.close
  sleep --ms=100
  sequence := 0
  request := : |command/string|
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  print "POWER phase=$phase cause=$(zephyr.reset-reason)"
  request.call "CONFIG 19 DOWN 0"
  request.call "CHECK 19 0"
  request.call "CONFIG 22 IN 0"

  if phase == 0:
    [-2, 0, 2, 18, 20, 22, 48, 64].do: |pin|
      expect-equals "INVALID_ARGUMENT" (catch: zephyr.power-off --wake-pin=pin)
    expect-equals "INVALID_ARGUMENT" (catch: zephyr.power-off --wake-pin=32 --pull-up --pull-down)
    expect-equals "INVALID_ARGUMENT" (catch: zephyr.power-off --pull-up)
    [-1, 0, 86400001].do: |ms|
      expect-equals "INVALID_ARGUMENT" (catch: zephyr.sleep-and-restart (Duration --ms=ms))
    expect-equals 1 (validate-sleep 1)
    expect-equals 86400000 (validate-sleep 86400000)
    expect-equals -1 (prepare-poweroff -1 0)
    expect-equals -270 (prepare-poweroff 32 5)
    print "POWER validation and duration bounds PASS"
  else if phase < 3:
    expect (zephyr.reset-reason & zephyr.RESET-LOW-POWER-WAKE != 0)
    expect-equals 0 (zephyr.reset-reason & zephyr.RESET-SOFTWARE)
  else:
    expected := edge-cases ? zephyr.RESET-WATCHDOG : zephyr.RESET-SOFTWARE
    expect (zephyr.reset-reason & expected != 0)
    expect-equals 0 (zephyr.reset-reason & zephyr.RESET-LOW-POWER-WAKE)

  if phase < 3:
    high := phase != 1
    active := edge-cases and phase < 2
    level := active == high ? 1 : 0
    request.call "CONFIG 13 OUT $level"
    request.call "CONFIG 23 OUT 1"
    // The wake pin is deliberately still owned by an ordinary GPIO resource.
    wake := gpio.Pin 32 --input
    child := spawn::
      port := uart.Port --tx=8 --rx=9 --baud-rate=115200
      indicator := gpio.Pin 10 --output --value=1
      while true: port.in.read
    request.call "WAIT 19 1"
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 8 --output)
    adc := Adc 4
    adc.get
    bus := i2c.Bus --sda=34 --scl=35 --frequency=100000 --pull-up
    target := bus.device 0x42
    request.call "CONFIG 32 OUT $((phase + 1) & 1)"
    request.call "CONFIG 33 OUT $((phase + 1) >> 1)"
    request.call "CONFIG 22 OUT 0"
    pending := true
    task::
      catch: target.read 17
      pending = false
    sleep --ms=10
    expect pending
    expect-equals level wake.get
    print "POWER pending I2C, UART child and ADC ready phase=$phase"
    if phase < 2:
      zephyr.power-off --wake-pin=32 --wake-high=high --pull-down=high --pull-up=(not high)
    else:
      if edge-cases: watchdog.watchdog-start --timeout=(Duration --ms=2000)
      zephyr.sleep-and-restart (Duration --ms=(edge-cases ? 5000 : 750))
    throw "power operation returned"

  // Check usable peripherals after both System OFF wakes and the timed restart.
  request.call "UART_OPEN 18 23 115200 1"
  port := uart.Port --tx=8 --rx=9 --baud-rate=115200
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
  request.call "CONFIG 19 DOWN 0"
  indicator := gpio.Pin 10 --output --value=1
  request.call "WAIT 19 1"
  if edge-cases:
    print "NRF5340 POWER EDGE PASS: already-active GPIO wake and watchdog during timed sleep"
  else:
    print "NRF5340 POWER PASS: GPIO wake, timed restart, teardown and peripheral recovery"

// Validate long durations and reset-only power-off without actually sleeping.
validate-sleep duration-ms/int -> int:
  #primitive.zephyr.validate-sleep

prepare-poweroff pin/int flags/int -> int:
  #primitive.zephyr.prepare-poweroff
