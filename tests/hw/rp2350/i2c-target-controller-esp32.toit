// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2c
import uart

import .wiring as wiring

ADDRESS ::= 0x42
ARM ::= 0x10
READ ::= 0x11
WRITE ::= 0x12
WRITE-READ ::= 0x13
STRETCH ::= 0x14
QUIT ::= 0xff
OK ::= 0x5a
FAIL ::= 0xee

/** ESP32 controller peer for i2c-target-rp2350.toit. */
main:
  control := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=115_200
  bus/i2c.Bus? := null
  device/i2c.Device? := null
  try:
    // Ignore reset-line noise before the first framed command. Commands after
    // this synchronization remain strict so protocol failures are visible.
    while control.in.peek-byte != ARM: control.in.read-byte
    while true:
      command := control.in.read-byte
      if command == ARM:
        controller := control.in.read-byte
        address-bits := control.in.read-byte
        address := read-u16 control
        if device: device.close
        if bus: bus.close
        pins := controller == 0 ? [19, 27] : [32, 33]
        bus = i2c.Bus --sda=pins[0] --scl=pins[1] --frequency=100_000 --pull-up
        device = bus.device address
            --address-bit-size=address-bits
            --timeout-us=2_000_000
        reply control #[OK]
      else if command == READ:
        length := read-u16 control
        result/ByteArray? := null
        error := catch: result = device.read length
        if error: print "ESP I2C READ length=$length error=$error"
        reply control (error ? #[FAIL] : #[OK] + result)
      else if command == WRITE:
        bytes := read-bytes control (read-u16 control)
        error := catch: device.write bytes
        if error: print "ESP I2C WRITE length=$(bytes.size) error=$error"
        reply control (error ? #[FAIL] : #[OK])
      else if command == WRITE-READ:
        tx := read-bytes control (read-u16 control)
        rx-length := read-u16 control
        result/ByteArray? := null
        error := catch: result = device.write-read tx rx-length
        if error:
          print "ESP I2C WRITE-READ tx=$(tx.size) rx=$rx-length error=$error"
        reply control (error ? #[FAIL] : #[OK] + result)
      else if command == STRETCH:
        // The teardown fixture intentionally exits while this transaction is
        // stretched. Consume either completion or timeout without leaving a
        // reply byte for the next RP2350 application.
        length := read-u16 control
        error := catch: device.read length
        if error: print "ESP I2C STRETCH length=$length ended=$error"
      else if command == QUIT:
        reply control #[OK]
        print "i2c-target-controller-esp32: PASS"
        return
      else:
        throw "bad I2C target test command $command"
  finally:
    if device: device.close
    if bus: bus.close
    control.close

read-u16 port/uart.Port -> int:
  return (port.in.read-byte << 8) | port.in.read-byte

read-bytes port/uart.Port length/int -> ByteArray:
  result := ByteArray length
  length.repeat: result[it] = port.in.read-byte
  return result

reply port/uart.Port bytes/ByteArray -> none:
  port.out.write bytes
  port.out.flush
