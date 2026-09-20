// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import gpio.dac as dac
import pulse-counter
import uart
import .control
import .wiring

main:
  // The reserved crystal net must remain high impedance.
  reserved := gpio.Pin 25 --input
  port := uart.Port --rx=HELPER-RX --tx=HELPER-TX --baud-rate=115200
  pins := {:}
  analog/dac.Dac? := null
  try:
    while true:
      // H2 sleep transitions may produce partial UART characters. Only accept
      // complete framed commands; the checksum also guards pin selection.
      if port.in.read-byte != 0x93: continue
      if port.in.read-byte != 0x7a: continue
      op := port.in.read-byte
      pin := port.in.read-byte
      value := port.in.read-byte
      if port.in.read-byte != (op ^ pin ^ value ^ 0xff): continue
      if op != PING and op != DONE and op != ECHO:
        if not [12, 14, 26, 32, 13, 33].contains pin: throw "Unsafe helper pin: $pin"
      if [INPUT, OUTPUT, DAC, COUNT].contains op:
        old := pins.get pin
        pins.remove pin
        if old: old.close
        if pin == HELPER-DAC and analog:
          analog.close
          analog = null
      if op == INPUT:
        pins[pin] = gpio.Pin pin --input --pull-up=(value == 1) --pull-down=(value == 2)
      else if op == OUTPUT:
        pins[pin] = gpio.Pin pin --output --value=value
      else if op == DAC:
        if pin != HELPER-DAC: throw "Invalid DAC pin"
        analog = dac.Dac pin --initial-voltage=(value / 100.0)
      port.out.write-byte ACK
      port.out.flush
      if op == READ:
        port.out.write-byte pins[pin].get
      else if op == PULSES:
        value.repeat:
          pins[pin].set 1
          sleep --ms=1
          pins[pin].set 0
          sleep --ms=1
        port.out.write-byte ACK
      else if op == DELAYED-OUTPUT:
        sleep --ms=1000
        pins[pin].set value
      else if op == ECHO:
        data := port.in.read-bytes ((pin << 8) | value)
        port.out.write data
      else if op == COUNT:
        unit := pulse-counter.Unit pin
        sleep --ms=200
        port.out.little-endian.write-uint16 unit.value
        unit.close
      else if op == DONE:
        break
      else if not [PING, INPUT, OUTPUT, DAC].contains op:
        throw "Unknown helper command: $op"
  finally:
    pins.values.do: it.close
    if analog: analog.close
    reserved.close
    port.close
  print "All tests done"
