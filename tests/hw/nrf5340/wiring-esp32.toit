// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import gpio.dac
import uart
import i2c
import spi
import monitor show Latch
import expect show *

import .wiring as wiring
import .pwm-measure-esp32 as pwm-probe

// A USB-console-controlled fixture. The initial wiring commands use weak pulls.
// CONFIG and PULSE also support paired peripheral tests after wiring verification.
main:
  pins := {:}
  dacs := []
  pulse-task/Task? := null
  uart-task/Task? := null
  uart-sender/Task? := null
  port/uart.Port? := null
  uart-pins := []
  target/i2c.Target? := null
  i2c-pins := []
  spi-target/spi.Target? := null
  spi-task/Task? := null
  spi-done/Latch? := null
  spi-pins := []
  pwm-capture/pwm-probe.Capture? := null
  console := uart.Port.console
  close-pwm := ::
    if pwm-capture:
      number := pwm-capture.number
      pwm-capture.close
      pwm-capture = null
      pins[number] = gpio.Pin number --input --pull-down
  close-spi := ::
    if spi-task:
      spi-task.cancel
      spi-task = null
    if spi-target:
      spi-target.close
      spi-target = null
    spi-pins.do: pins[it] = gpio.Pin it --input
    spi-pins.clear
  close-i2c := ::
    if target:
      target.close
      target = null
    i2c-pins.do: pins[it] = gpio.Pin it --input
    i2c-pins.clear
  close-uart := ::
    if uart-sender:
      uart-sender.cancel
      uart-sender = null
    if uart-task:
      uart-task.cancel
      uart-task = null
    if port:
      port.close
      port = null
    uart-pins.do: pins[it] = gpio.Pin it --input
    uart-pins.clear
  release := ::
    close-pwm.call
    close-spi.call
    close-i2c.call
    close-uart.call
    if pulse-task:
      pulse-task.cancel
      pulse-task = null
    pins.values.do: it.close
    pins.clear
    dacs.do: it.close
    dacs.clear
  inputs := : | selected/int value/int |
    release.call
    wiring.WIRES.do: | wire |
      n/int := wire[3]
      active := selected == -1 or selected == n
      pins[n] = gpio.Pin n --input
          --pull-up=(active and value == 1)
          --pull-down=(active and value == 0)
  inputs.call -1 -1
  print "RIG READY"
  try:
    while line := console.in.read-line:
      error := catch:
        fields := line.trim.split " "
        command := fields[0]
        if command == "PING":
          print "RIG READY"
        else if command == "IDLE":
          inputs.call -1 -1
          print "RIG OK"
        else if command == "UART_OPEN" or command == "UART_FLOW_OPEN":
          close-uart.call
          rx := int.parse fields[1]
          tx := int.parse fields[2]
          baud := int.parse fields[3]
          parity := int.parse fields[4]
          rts/int? := command == "UART_FLOW_OPEN" ? (int.parse fields[5]) : null
          cts/int? := command == "UART_FLOW_OPEN" ? (int.parse fields[6]) : null
          selected := [rx, tx]
          if rts != null: selected.add rts
          if cts != null: selected.add cts
          selected.do: | n |
            if not pins.contains n: throw "Unknown UART pin"
            pins[n].close
            pins.remove n
            uart-pins.add n
          port = uart.Port --rx=rx --tx=tx --rts=rts --cts=cts
              --baud-rate=baud
              --parity=parity
              --large-buffers
          uart-task = task::
            while data := port.in.read:
              port.out.write data --flush
          print "RIG OK"
        else if command == "I2C_OPEN" or command == "I2C_QUEUE":
          close-i2c.call
          sda := int.parse fields[1]
          scl := int.parse fields[2]
          size := int.parse fields[3]
          queued := command == "I2C_QUEUE"
          if size < 1 or size > (queued ? 4096 : 32): throw "Invalid I2C response size"
          [sda, scl].do: | n |
            if not pins.contains n: throw "Unknown I2C pin"
            pins[n].close
            pins.remove n
            i2c-pins.add n
          target = i2c.Target --sda=sda --scl=scl --address=0x42
              --send-buffer-size=8192
              --receive-buffer-size=8192
              --default-response=(ByteArray (min size 32): (it * 73 + 7) & 0xff)
              --pull-up
          if queued:
            expect-equals size (target.try-write (ByteArray size: (it * 73 + 7) & 0xff))
          print "RIG OK"
        else if command == "SPI_ARM":
          close-spi.call
          clock := int.parse fields[1]
          mosi := int.parse fields[2]
          miso := int.parse fields[3]
          cs := int.parse fields[4]
          mode := int.parse fields[5]
          size := int.parse fields[6]
          kind := fields[7]
          prefix := int.parse fields[8]
          if not ["BOTH", "RX", "TX"].contains kind: throw "Invalid SPI direction"
          if size < 1 or size > 32768: throw "Invalid SPI transfer size"
          if not [0, 1, 3].contains prefix: throw "Invalid SPI prefix"
          // Use the exact capacity so a missing final DMA word is visible.
          capture-size := size
          selected := [clock, cs]
          if kind != "TX": selected.add mosi
          if kind != "RX": selected.add miso
          selected.do: | n |
            if not pins.contains n: throw "Unknown SPI pin"
            pins[n].close
            pins.remove n
            spi-pins.add n
          spi-target = spi.Target --clock=clock --cs=cs
              --mosi=(kind == "TX" ? null : mosi)
              --miso=(kind == "RX" ? null : miso)
              --mode=mode
              --max-transfer-size=capture-size
              --dma=(kind != "BOTH")
          spi-done = Latch
          spi-task = task::
            failure := catch:
              data := kind == "RX" ? #[ ] : (ByteArray size: (it * 73 + 7) & 0xff)
              received := spi-target.transfer data --receive-size=(kind == "TX" ? 0 : capture-size)
                  --when-armed=(: print "RIG OK")
              if kind != "TX":
                expected := ByteArray size - prefix: (it * 73 + 23) & 0xff
                if prefix == 1: expected = #[0x0b] + expected
                if prefix == 3: expected = #[0xa5, 0x12, 0x34] + expected
                check-spi-payload expected received
            spi-done.set failure
        else if command == "SPI_CHECK":
          if not spi-done: throw "SPI target is closed"
          failure := with-timeout --ms=5000: spi-done.get
          close-spi.call
          if failure: throw failure
          print "RIG OK"
        else if command == "SPI_CLOSE":
          close-spi.call
          print "RIG OK"
        else if command == "I2C_CHECK":
          if not target: throw "I2C target is closed"
          size := int.parse fields[1]
          received := with-timeout --ms=2000: target.read
          expect-equals (ByteArray size: (it * 73 + 23) & 0xff) received
          print "RIG OK"
        else if command == "I2C_CLOSE":
          close-i2c.call
          print "RIG OK"
        else if command == "UART_CLOSE":
          close-uart.call
          print "RIG OK"
        else if command == "UART_BAUD":
          if not port: throw "UART is closed"
          port.baud-rate = int.parse fields[1]
          print "RIG OK"
        else if command == "UART_SEND":
          if not port: throw "UART is closed"
          size := int.parse fields[1]
          if size < 1 or size > 32768: throw "Invalid UART transfer size"
          if uart-sender: uart-sender.cancel
          uart-sender = task::
            sleep --ms=100
            data := ByteArray size: (it * 73 + size) & 0xff
            port.out.write data --flush
            print "RIG UART SENT $size"
          print "RIG OK"
        else if command == "PULL":
          pin := int.parse fields[1]
          if not pins.contains pin: throw "Unknown pin or DAC active"
          inputs.call pin (int.parse fields[2])
          print "RIG OK"
        else if command == "BIAS":
          inputs.call -1 (int.parse fields[1])
          print "RIG OK"
        else if command == "PATTERN":
          mask := int.parse fields[1]
          release.call
          wiring.WIRES.size.repeat: | index |
            wire := wiring.WIRES[index]
            n/int := wire[3]
            high := mask & (1 << index) != 0
            pins[n] = gpio.Pin n --input --pull-up=high --pull-down=(not high)
          print "RIG OK"
        else if command == "CONFIG":
          n := int.parse fields[1]
          mode := fields[2]
          value := int.parse fields[3]
          if not pins.contains n: throw "Unknown pin or DAC active"
          if not ["IN", "UP", "DOWN", "OUT", "OD"].contains mode: throw "Unknown GPIO mode"
          pins[n].close
          if mode == "OUT" or mode == "OD":
            pins[n] = gpio.Pin n --input --output --open-drain=(mode == "OD") --value=value
          else:
            pins[n] = gpio.Pin n --input --pull-up=(mode == "UP") --pull-down=(mode == "DOWN")
          print "RIG OK"
        else if command == "PWM_ARM":
          number := int.parse fields[1]
          if pwm-capture: throw "PWM capture already armed"
          if not pins.contains number: throw "Unknown PWM probe pin or peripheral active"
          pins[number].close
          pins.remove number
          pwm-capture = pwm-probe.Capture number
          print "RIG OK"
        else if command == "PWM_STATIC" or command == "PWM_TRAIN":
          number := int.parse fields[1]
          if not pwm-capture or pwm-capture.number != number: throw "PWM capture not armed"
          try:
            if command == "PWM_STATIC":
              pwm-capture.check-static (int.parse fields[2])
            else:
              pwm-capture.check-pulsing
          finally:
            close-pwm.call
          print "RIG OK"
        else if ["PWM_HZ", "PWM_DUTY", "PWM_LEVEL", "PWM_RELEASE"].contains command:
          number := int.parse fields[1]
          if not pins.contains number: throw "Unknown PWM probe pin or peripheral active"
          if pulse-task:
            pulse-task.cancel
            pulse-task = null
          pins[number].close
          pins.remove number
          try:
            if command == "PWM_HZ":
              pwm-probe.check-frequency number (int.parse fields[2])
            else if command == "PWM_DUTY":
              pwm-probe.check-duty number (int.parse fields[2])
            else if command == "PWM_LEVEL":
              pwm-probe.check-level number (int.parse fields[2])
            else:
              pwm-probe.check-released number
          finally:
            pins[number] = gpio.Pin number --input --pull-down
          print "RIG OK"
        else if command == "PULSE":
          n := int.parse fields[1]
          count := int.parse fields[2]
          phase := int.parse fields[3]
          if not pins.contains n or count < 1 or count > 1000 or phase < 1:
            throw "Invalid pulse arguments"
          pins[n].close
          pulse-pin := gpio.Pin n --input --output --value=0
          pins[n] = pulse-pin
          if pulse-task: pulse-task.cancel
          pulse-task = task::
            sleep --ms=100
            count.repeat:
              pulse-pin.set 1
              sleep --ms=phase
              pulse-pin.set 0
              sleep --ms=phase
            print "RIG PULSES DONE"
          print "RIG OK"
        else if command == "READ":
          readable := wiring.WIRES.filter: pins.contains it[3]
          values := readable.map: | wire |
            n/int := wire[3]
            "$n=$(pins[n].get)"
          print "RIG READ $(values.join " ")"
        else if command == "WAIT":
          n := int.parse fields[1]
          value := int.parse fields[2]
          with-timeout --ms=2000: pins[n].wait-for value
          print "RIG OK"
        else if command == "DAC" or command == "ADC_DAC":
          first := int.parse fields[1]
          second := int.parse fields[2]
          if first < 0 or first > 3000 or second < 0 or second > 3000:
            throw "DAC range is 0..3000 mV"
          if command == "DAC":
            release.call
          else:
            // Keep the paired-test handshake and other peripherals alive.
            dacs.do: it.close
            dacs.clear
            [25, 26].do: | pin |
              if pins.contains pin:
                pins[pin].close
                pins.remove pin
          dacs.add (dac.Dac 25 --initial-voltage=first / 1000.0)
          dacs.add (dac.Dac 26 --initial-voltage=second / 1000.0)
          print "RIG OK"
        else:
          throw "Unknown command"
      if error:
        inputs.call -1 -1
        print "RIG ERROR $error"
  finally:
    release.call
    console.close

check-spi-payload expected/ByteArray received/ByteArray:
  if expected.size != received.size:
    throw "SPI length: expected $(expected.size), received $(received.size)"
  first := -1
  mismatches := 0
  expected.size.repeat: |index|
    if expected[index] != received[index]:
      if first < 0: first = index
      mismatches++
  if first >= 0:
    start := max 0 (first - 4)
    end := min expected.size (first + 12)
    throw "SPI mismatch: first=$first count=$mismatches size=$(expected.size) expected=$(expected[start..end]) received=$(received[start..end])"
