// Copyright (C) 2026 Toit contributors.

import ec618

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
EC618 half of the PAD42 deep-sleep wake regression.

Run with `enabled`, then with `disabled`, while
  wakeup-pad42-esp32.toit stays running on the ESP32 helper.

The first run arms physical PAD42 and must reboot from the helper's rising
  edge. The second run requires that preceding pad wake, explicitly disables
  PAD42, and must ignore the same pulse until the RTC timer wakes it. This
  proves that a wake configuration does not leak into the next deep sleep.

ESP32 IO13 also controls the BMP280 supply on this rig. The sensor may remain
  connected: the helper deliberately holds that supply/net low between the
  short wake pulses, and no I2C transaction runs concurrently.
*/

CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 15_000
EXPECT-REBOOT-WAKE-TAG ::= "[ec618-test] expect-reboot-wake="

main args:
  if args.size != 1 or (args[0] != "enabled" and args[0] != "disabled"):
    throw "expected one argument: enabled or disabled"
  mode := args[0]
  if mode == "disabled" and ec618.wakeup-cause != ec618.WAKEUP-PAD:
    throw "the disabled phase must immediately follow a successful pad wake"
  if ec618.console-uart-id == 1:
    throw "the test needs UART1 for its ESP32 control channel"

  pin := ec618.Ec618.pad wiring.EC618-WAKE-PAD
  control-owner := rig.ec618-uart 1 CONTROL-BAUD
  control := FramedChannel control-owner.port

  try:
    control.send "WAKE $mode"
    control.expect "READY $mode" --timeout-ms=CONTROL-TIMEOUT-MS

    ec618.configure-wakeup-pad pin --pos-edge --pull-down
    if mode == "disabled": ec618.disable-wakeup-pad pin

    // This must be the final console line before deep sleep. The host changes
    // to the reboot baud as soon as it receives the expected-cause marker.
    expected := mode == "enabled" ? "pad" : "rtc"
    print "$EXPECT-REBOOT-WAKE-TAG$expected"
    control.send "ARM $mode"
    control.expect "ARMED $mode" --timeout-ms=CONTROL-TIMEOUT-MS
  finally:
    control-owner.close
    pin.close

  ec618.deep-sleep (Duration --s=(mode == "enabled" ? 5 : 3))
  throw "deep sleep returned"
