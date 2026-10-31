// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import expect show *
import monitor show Semaphore
import .wiring as wiring

// P1.01 acknowledges host-controlled ESP32 fixture commands. P1.00 is the
// signal under test; no test assumes the USB hosts run at fixed latency.
main:
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)
  pin := gpio.Pin 32 --input
  try:
    expect-equals "INVALID_ARGUMENT" (catch: gpio.Pin -1 --input)
    expect-equals "INVALID_ARGUMENT" (catch: gpio.Pin 48 --input)
    expect-equals "RESTRICTED_PIN" (catch: gpio.Pin 20 --input)
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 32 --input)
    request.call "CONFIG 13 IN 0"
    pin.configure --input --pull-up
    expect-equals 1 pin.get
    request.call "CHECK 13 1"
    pin.set-pull --down
    expect-equals 0 pin.get
    request.call "CHECK 13 0"
    pin.set-pull --up
    expect-equals 1 pin.get
    pin.set-pull --off
    request.call "CONFIG 13 OUT 1"
    expect-equals 1 pin.get
    request.call "CONFIG 13 OUT 0"
    expect-equals 0 pin.get
    request.call "CONFIG 13 IN 0"
    print "GPIO pulls and input PASS"

    pin.configure --output --value=1
    request.call "CHECK 13 1"
    pin.set 0
    request.call "CHECK 13 0"
    pin.configure --input --output
    request.call "CHECK 13 0"
    pin.set 1
    expect-equals 1 pin.get
    request.call "CHECK 13 1"
    pin.set-open-drain true
    pin.set-pull --up
    request.call "CONFIG 13 OUT 0"
    expect-equals 0 pin.get
    request.call "CONFIG 13 IN 0"
    expect-equals 1 pin.get
    pin.set 0
    request.call "CHECK 13 0"
    pin.set 1
    request.call "CHECK 13 1"
    pin.set-open-drain false
    pin.set-pull --off
    pin.set 0
    request.call "CHECK 13 0"
    pin.configure --input
    print "GPIO output and open-drain PASS"

    request.call "CONFIG 13 OUT 0"
    expect-equals DEADLINE-EXCEEDED-ERROR (catch: with-timeout --ms=50: pin.wait-for 1)
    [10, 2].do: | phase |
      request.call "PULSE 13 50 $phase"
      with-timeout --ms=5000:
        50.repeat:
          pin.wait-for 1
          pin.wait-for 0
      expect-equals DEADLINE-EXCEEDED-ERROR (catch: with-timeout --ms=100: pin.wait-for 1)
      print "GPIO interrupts phase=$phase PASS"

    done := Semaphore
    2.repeat:
      task::
        pin.wait-for 1
        done.up
    request.call "CONFIG 13 OUT 1"
    with-timeout --ms=1000:
      done.down
      done.down
    request.call "CONFIG 13 OUT 0"
    expect-equals DEADLINE-EXCEEDED-ERROR (catch: with-timeout --ms=50: pin.wait-for 1)
    print "GPIO concurrent waiters and cancellation PASS"

    task::
      pin.wait-for 1
      done.up
    sleep --ms=10
    pin.close
    with-timeout --ms=1000: done.down
    100.repeat:
      pin = gpio.Pin 32 --input
      expect-equals 0 pin.get
      pin.close
    request.call "PULSE 13 100 2"
    250.repeat:
      pin = gpio.Pin 32 --input
      error := catch: with-timeout --ms=1: pin.wait-for (pin.get ^ 1)
      if error and error != DEADLINE-EXCEEDED-ERROR: throw error
      pin.close
      sleep --ms=1
    sleep --ms=500
    request.call "CONFIG 13 IN 0"
    print "GPIO close under pulse traffic PASS"
    pin = gpio.Pin 8 --input
    request.call "CONFIG 18 OUT 0"
    request.call "PULSE 18 50 2"
    with-timeout --ms=5000:
      50.repeat:
        pin.wait-for 1
        pin.wait-for 0
    expect-equals DEADLINE-EXCEEDED-ERROR (catch: with-timeout --ms=100: pin.wait-for 1)
    request.call "CONFIG 18 IN 0"
    pin.close
    print "GPIO port 0 interrupts PASS"

    wiring.WIRES.do: | wire |
      number/int := wire[1] * 32 + wire[2]
      if number == 33: continue.do
      partner/int := wire[3]
      pin = gpio.Pin number --input --pull-up
      expect-equals 1 pin.get
      request.call "CHECK $partner 1"
      pin.set-pull --down
      expect-equals 0 pin.get
      request.call "CHECK $partner 0"
      pin.configure --output --value=1
      request.call "CHECK $partner 1"
      pin.set 0
      request.call "CHECK $partner 0"
      pin.close
    print "GPIO all wired pins PASS"

    // Intentionally leave this output open. The host checks that process
    // teardown releases it, independently of Pin.close and its finalizer.
    leaked := gpio.Pin 32 --output --value=1
    request.call "CHECK 13 1"
    expect-equals 32 leaked.num
    print "NRF5340 GPIO PASS"
  finally:
    pin.close
    ack.close
