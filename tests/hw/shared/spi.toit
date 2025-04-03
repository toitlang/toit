// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import monitor
import spi

/**
Tests the SPI interface.

The $create-device block is called with the cpol/cpha mode integer. It should
  use a relatively low frequency (ideally as low as possible).
The $slave simulates an SPI slave. Its pins should be connected to the corresponding SPI pins.
  The SPI mosi and miso pins should be connected with a 5k+ resistor. If the test pins
  are configured as input, the SPI should thus loop back.
*/
test-spi --slave/Slave --run-slave-receive/bool=true [--create-device]:
  [0, 1].do: | cpol |
    [0, 1].do: | cpha |
      test
          --cpol=cpol
          --cpha=cpha
          --slave=slave
          --run-slave-receive=run-slave-receive
          --create-device=create-device

test
    --cpol/int
    --cpha/int
    --slave/Slave
    --run-slave-receive/bool
    [--create-device]:

  print "Running cpol=$cpol cpha=$cpha"

  slave.reset
  mode := cpol << 1 | cpha
  device/spi.Device := create-device.call mode

  // Start with slave-miso as input. The mosi and miso pins are connected with a
  // 5k resistor, and by setting the miso pin as input the spi output is now
  // read as input.

  payload := "hello".to-byte-array
  data := payload.copy
  device.transfer --read data
  expect-equals payload data

  // Now drive the input to 0 or 1.
  slave.set-miso 0
  data = payload.copy
  device.transfer --read data
  expect-equals (ByteArray payload.size --initial=0) data

  slave.set-miso 1
  data = payload.copy
  device.transfer --read data
  expect-equals (ByteArray payload.size --initial=0xff) data

  idle-clk-level := cpol
  on-from-idle-edge := cpha == 0
  //expect-equals idle-clk-level slave-sclk.get

  if run-slave-receive:
    slave.prepare-receive 24 --cpol=cpol --cpha=cpha
    MESSAGE ::= #['O', 'K', '!']
    device.write MESSAGE
    response := with-timeout --ms=3_000: slave.receive
    expected-bits := 0
    MESSAGE.do: | c/int |
      expected-bits = (expected-bits << 8) | c
    expect-equals expected-bits response

  print "OK"
  device.close

interface Slave:
  reset -> none
  prepare-receive bit-count/int --cpol/int --cpha/int -> none
  receive -> int
  set-miso value/int? -> none

class SlaveBitBang implements Slave:
  cs/gpio.Pin
  sclk/gpio.Pin
  mosi/gpio.Pin
  miso/gpio.Pin

  received-latch/monitor.Latch? := null

  constructor --.cs --.sclk --.mosi --.miso:
    reset

  reset:
    cs.configure --input
    sclk.configure --input
    mosi.configure --input
    miso.configure --input

  set-miso value/int?:
    if value == null:
      miso.configure --input
    else:
      miso.configure --output
      miso.set value

  prepare-receive bit-count/int --cpol/int --cpha/int -> none:
    ready-latch := monitor.Latch
    received-latch = monitor.Latch

    task::
      ready-latch.set true
      start-receiving_ bit-count --cpol=cpol --cpha=cpha

    ready-latch.get

  start-receiving_ bit-count --cpol --cpha:
    if bit-count > 30: throw "INVALID_ARGUMENT"
    idle-clk-level := cpol
    on-from-idle-edge := cpha == 0

    while cs.get == 1:  // By default CS is active low.
      yield

    received := 0
    bit-count.repeat:
      // Wait for the clock to go to non-idle.
      while sclk.get == idle-clk-level:


      if on-from-idle-edge:
        received = (received << 1) | mosi.get

      // Wait for the clock to go to idle.
      while sclk.get != idle-clk-level:

      if not on-from-idle-edge:
        received = (received << 1) | mosi.get

    received-latch.set received

  receive -> int:
    result := received-latch.get
    received-latch = null
    return result
