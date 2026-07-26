// Copyright (C) 2026 Toit contributors.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 command server for the EC618 PAD42 wake regression.

UART1 synchronizes each phase. IO13 is held low while the EC618 prepares and receives one short rising-edge pulse only after it acknowledges that it is about to enter deep sleep. This removes the old 60-second blind delay and repeated pulse window.

IO13 also supplies the rig's BMP280. The sensor remains connected but powered down between pulses; the wake test does not use its I2C bus.
*/

CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 120_000
ARM-DELAY ::= Duration --ms=1_000
PULSE-WIDTH ::= Duration --ms=250

main:
  control-owner := rig.esp32-uart 1 CONTROL-BAUD
  control := FramedChannel control-owner.port
  pin := gpio.Pin wiring.ESP32-WAKE-PIN --output --value=0

  try:
    while true:
      message := control.receive --timeout-ms=CONTROL-TIMEOUT-MS
      parts := message.split " "
      if parts.size != 2 or parts[0] != "WAKE" or
          (parts[1] != "enabled" and parts[1] != "disabled"):
        throw "unexpected wake command '$message'"
      mode := parts[1]
      pin.set 0
      control.send "READY $mode"
      control.expect "ARM $mode" --timeout-ms=15_000
      control.send "ARMED $mode"

      sleep ARM-DELAY
      print "wakeup-pad42-esp32: pulsing PAD42 for the $mode phase"
      pin.set 1
      sleep PULSE-WIDTH
      pin.set 0
  finally:
    pin.close
    control-owner.close
