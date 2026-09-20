// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals
import gpio
import i2c
import uart

import .wiring as wiring

/** ESP32 I2C target and UART control peer for i2c-controller-rp2350.toit. */

ADDRESS ::= 0x42
TIMEOUT-MS ::= 60_000

main:
  control := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=115_200
  target/i2c.Target? := null
  stuck/gpio.Pin? := null
  first-command := true
  print "i2c-target-esp32: waiting for RP2350"
  try:
    while true:
      // OTA transfer plus the controller's startup delay can exceed the
      // normal per-command timeout. Only the initial rendezvous needs the
      // wider bound.
      line := read-line control --timeout-ms=(first-command ? 180_000 : TIMEOUT-MS)
      first-command = false
      parts := line.split " "
      command := parts[0]
      if command == "ARM" and parts.size == 3:
        if target: target.close
        if stuck: stuck.close
        stuck = null
        controller := int.parse parts[1]
        size := int.parse parts[2]
        pins := target-pins controller
        error := catch:
          target = i2c.Target
              --sda=pins[0]
              --scl=pins[1]
              --address=ADDRESS
              --receive-buffer-size=4096
              --default-response=(pattern size 7)
              --pull-up
        if error:
          send-line control "ERROR $error"
          continue
        send-line control "READY"
      else if command == "CHECK" and parts.size == 2:
        size := int.parse parts[1]
        expect-equals (pattern size 23) (with-timeout --ms=2_000: target.read)
        send-line control "OK"
      else if command == "STATUS" and parts.size == 2:
        expected-size := int.parse parts[1]
        dropped := target.dropped-receive-count
        received/ByteArray? := null
        receive-error := catch:
          received = with-timeout --ms=2_000: target.read
        if receive-error:
          send-line control "expected=$expected-size dropped=$dropped error=$receive-error"
        else:
          mismatch := -1
          received.size.repeat:
            if mismatch < 0 and received[it] != ((it * 31 + 23) & 0xff): mismatch = it
          tail-size := min 32 received.size
          tail := (List tail-size: received[received.size - tail-size + it]).join "":
            "$(%02x it)"
          suffix := mismatch < 0 ? 0 : received.size - mismatch
          send-line control "expected=$expected-size dropped=$dropped received=$(received.size) mismatch=$mismatch suffix=$suffix tail=$tail"
      else if command == "CLOSE" and parts.size == 1:
        if target: target.close
        target = null
        send-line control "OK"
      else if command == "STUCK" and parts.size == 2:
        if target: target.close
        target = null
        if stuck: stuck.close
        controller := int.parse parts[1]
        pins := target-pins controller
        stuck = gpio.Pin pins[1] --output --value=0
        send-line control "READY"
      else if command == "RELEASE" and parts.size == 1:
        if stuck: stuck.close
        stuck = null
        send-line control "OK"
      else if command == "QUIT" and parts.size == 1:
        if target: target.close
        target = null
        send-line control "BYE"
        return
      else:
        throw "invalid I2C test command '$line'"
  finally:
    if target: target.close
    if stuck: stuck.close
    control.close

target-pins controller/int -> List:
  if controller == 0: return [19, 27]  // RP GP4/5.
  if controller == 1: return [32, 33]  // RP GP10/11.
  throw "invalid controller $controller"

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

read-line port/uart.Port --timeout-ms/int=TIMEOUT-MS -> string:
  return with-timeout --ms=timeout-ms:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]
