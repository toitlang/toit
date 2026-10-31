// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Platform operations for Toit on Zephyr.

Reset causes are bit flags, not mutually exclusive enum values. Use a bitwise
  test such as `reset-reason & RESET-WATCHDOG != 0`. The supported flags depend
  on the board; see $supported-reset-reasons.
Zero means no reported cause, rather than a confirmed power-on reset.
*/

RESET-PIN ::= 1 << 0
RESET-SOFTWARE ::= 1 << 1
RESET-BROWNOUT ::= 1 << 2
RESET-POWER-ON ::= 1 << 3
RESET-WATCHDOG ::= 1 << 4
RESET-DEBUG ::= 1 << 5
RESET-SECURITY ::= 1 << 6
RESET-LOW-POWER-WAKE ::= 1 << 7
RESET-CPU-LOCKUP ::= 1 << 8
RESET-PARITY ::= 1 << 9
RESET-PLL ::= 1 << 10
RESET-CLOCK ::= 1 << 11
RESET-HARDWARE ::= 1 << 12
RESET-USER ::= 1 << 13
RESET-TEMPERATURE ::= 1 << 14
RESET-BOOTLOADER ::= 1 << 15
RESET-FLASH ::= 1 << 16

/**
Resets the device and does not return.

Stops the VM and releases its resources before requesting a hardware reset.
  After reboot, $reset-reason includes $RESET-SOFTWARE on the nRF5340.
*/
reset -> none:
  __reset__

/**
Stops the VM and enters System OFF without returning.

If $wake-pin is supplied, configures that pin as an input after releasing all
  VM resources. Its active level is high when $wake-high is true, otherwise low.
  $pull-up and $pull-down select an optional internal pull; they cannot both be
  enabled. An already-active level can cause an immediate wake.
The wake pin may currently belong to a peripheral: the VM closes it before
  configuring the wake input. Console and other board-reserved pins are rejected.

Wakeup restarts the device from boot and normally reports $RESET-LOW-POWER-WAKE
  for GPIO wake on nRF5340. Without a pin, wake requires another hardware source
  such as reset or debugger attachment. There is no RTC timer wake from System
  OFF on nRF5340; use $sleep-and-restart for a timed restart instead.
RAM contents are not retained. An attached debugger can emulate System OFF,
  so functional wake tests do not establish power consumption.
*/
power-off --wake-pin/int?=null --wake-high/bool=true --pull-up/bool=false --pull-down/bool=false -> none:
  flags := (wake-high ? 1 : 0) | (pull-up ? 2 : 0) | (pull-down ? 4 : 0)
  request := prepare-poweroff_ (wake-pin == null ? -1 : wake-pin) flags
  __deep-sleep__ request

/**
Stops the VM, sleeps for $duration in System ON, and reboots.

Accepts durations of 1 ms through 24 hours, in whole milliseconds. The duration
  starts after VM teardown. The console is suspended, but the Zephyr timebase
  and system RAM remain powered; this is not System OFF. Applications restart
  from boot with $RESET-SOFTWARE, and RAM contents are not preserved for Toit.
An armed watchdog is neither stopped nor fed and can reset the device earlier.
*/
sleep-and-restart duration/Duration -> none:
  request := validate-sleep_ duration.in-ms
  __deep-sleep__ request

prepare-poweroff_ pin/int flags/int -> int:
  #primitive.zephyr.prepare-poweroff

validate-sleep_ duration-ms/int -> int:
  #primitive.zephyr.validate-sleep

/**
Returns the reset-cause bit mask captured at boot.

The port clears the hardware's sticky flags immediately after capturing them,
  so subsequent resets do not accumulate previous causes. Every process reads
  the same cached value for the current boot.
*/
reset-reason -> int:
  #primitive.zephyr.reset-reason

/** Returns the bit mask of reset causes the hardware driver can report. */
supported-reset-reasons -> int:
  #primitive.zephyr.supported-reset-reasons
