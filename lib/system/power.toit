// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system
import esp32
import ec618
import zephyr

/**
Controls device reset and sleep.

Reset reasons are a bit mask on every supported platform. Zero means unknown;
  test individual flags rather than comparing the entire mask.
Sleep ends the current VM and wakes into a fresh boot. Supported wake sources
  and minimum durations depend on the platform. Hosts throw `UNIMPLEMENTED`.
*/

/** Reset triggered by the external reset pin. */
RESET-PIN ::= 1 << 0
/** Reset requested by software. */
RESET-SOFTWARE ::= 1 << 1
/** Reset caused by a supply-voltage drop or power glitch. */
RESET-BROWNOUT ::= 1 << 2
/** Reset caused by powering on the device. */
RESET-POWER-ON ::= 1 << 3
/** Reset caused by an expired watchdog timer. */
RESET-WATCHDOG ::= 1 << 4
/** Reset triggered by a debugger or debug interface. */
RESET-DEBUG ::= 1 << 5
/** Reset caused by a security violation. */
RESET-SECURITY ::= 1 << 6
/** Reset caused by waking from a low-power state. */
RESET-LOW-POWER-WAKE ::= 1 << 7
/** Reset caused by a detected CPU lockup. */
RESET-CPU-LOCKUP ::= 1 << 8
/** Reset caused by a parity error. */
RESET-PARITY ::= 1 << 9
/** Reset caused by a phase-locked loop (PLL) error. */
RESET-PLL ::= 1 << 10
/** Reset caused by a clock error. */
RESET-CLOCK ::= 1 << 11
/** Reset reported as a hardware fault or platform-specific fatal error. */
RESET-HARDWARE ::= 1 << 12
/** Reset reported by the platform as a user reset. */
RESET-USER ::= 1 << 13
/** Reset caused by an unsafe temperature. */
RESET-TEMPERATURE ::= 1 << 14
/** Reset caused by entering or leaving the bootloader. */
RESET-BOOTLOADER ::= 1 << 15
/** Reset caused by a flash error-correcting code (ECC) error. */
RESET-FLASH ::= 1 << 16

/**
Stops all containers, releases their native resources, and resets the device.

This terminates the entire VM, including containers other than the caller.
  It does not unwind Toit stacks or run application shutdown code. Flush
  buffered application data and coordinate any application cleanup beforehand.
On nRF5340, resource cleanup disconnects pins owned by VM peripherals before
  requesting the hardware reset. This does not reset external devices attached
  to those pins.
Does not return.
*/
reset -> none:
  if not embedded_: throw "UNIMPLEMENTED"
  __reset__

/**
Enters deep sleep and wakes into a fresh boot.

ESP32 and EC618 require $duration; their platform libraries document minimum
  durations and provide additional wake-source configuration.
On nRF5340, supplying $duration stops the VM, waits in System ON, and reboots.
  Durations of 1 ms through 24 hours are supported. The wait starts after VM
  teardown; booting and starting containers take additional time. An armed
  watchdog remains active and can reset the device earlier.
Omit $duration on nRF5340 to enter System OFF. Timed sleep consumes more power:
  Nordic's reference configurations use approximately 1.5-2.1 microamps with
  an RTC, compared with approximately 1 microamp in System OFF. These are
  chip-level typical figures, not a measured bound for this firmware. Board
  configuration, powered RAM, and peripherals can increase the difference.
  See https://docs.nordicsemi.com/r/bundle/ps_nrf5340/page/chapters/current_consumption/doc/current_consumption.html.
Container termination has the same cleanup semantics as $reset.

The optional integer $wake-pin and its $wake-high level are supported on
  nRF5340 when $duration is omitted. Combining a duration with GPIO wake
  configuration throws `UNIMPLEMENTED`. The pin is configured after releasing
  VM resources. $pull-up and $pull-down select its bias and cannot both be
  enabled. Without a pin or duration, waking requires another hardware source
  such as reset.
*/
deep-sleep duration/Duration?=null
    --wake-pin/int?=null --wake-high/bool=true
    --pull-up/bool=false --pull-down/bool=false -> none:
  if system.platform == system.PLATFORM-ZEPHYR:
    if duration:
      if wake-pin != null or pull-up or pull-down or not wake-high:
        throw "UNIMPLEMENTED"
      zephyr.deep-sleep duration
    zephyr.power-off --wake-pin=wake-pin --wake-high=wake-high
        --pull-up=pull-up
        --pull-down=pull-down
  if wake-pin != null or pull-up or pull-down or not wake-high:
    throw "UNIMPLEMENTED"
  if (system.architecture.starts-with "esp32"):
    if not duration: throw "INVALID_ARGUMENT"
    esp32.deep-sleep duration
  if system.architecture == system.ARCHITECTURE-EC618:
    if not duration: throw "INVALID_ARGUMENT"
    ec618.deep-sleep duration
  throw "UNIMPLEMENTED"

/**
Returns whether $deep-sleep accepts a duration on this platform.

This describes timer wake support, not a particular hardware power state or
  current consumption. On nRF5340, timed sleep uses System ON.
*/
supports-timed-deep-sleep -> bool:
  return (system.architecture.starts-with "esp32") or
      system.architecture == system.ARCHITECTURE-EC618 or
      system.platform == system.PLATFORM-ZEPHYR

/**
Returns the normalized reset-cause bit mask.

Platform-specific detail remains available from the platform libraries.
On nRF5340, all reported causes are preserved; on ESP32 and EC618 the reported
  enum value is mapped to the corresponding common flag.
*/
reset-reason -> int:
  if system.platform == system.PLATFORM-ZEPHYR: return zephyr.reset-reason
  if (system.architecture.starts-with "esp32"):
    return esp32-reasons_.get esp32.reset-reason --if-absent=: 0
  if system.architecture == system.ARCHITECTURE-EC618:
    return ec618-reasons_.get ec618.reset-reason --if-absent=: 0
  throw "UNIMPLEMENTED"

embedded_ -> bool:
  return (system.architecture.starts-with "esp32") or
      system.architecture == system.ARCHITECTURE-EC618 or
      system.platform == system.PLATFORM-ZEPHYR

esp32-reasons_ ::= {
  esp32.RESET-POWER-ON: RESET-POWER-ON,
  esp32.RESET-EXTERNAL: RESET-PIN,
  esp32.RESET-SOFTWARE: RESET-SOFTWARE,
  esp32.RESET-PANIC: RESET-HARDWARE,
  esp32.RESET-INTERRUPT-WATCHDOG: RESET-WATCHDOG,
  esp32.RESET-TASK-WATCHDOG: RESET-WATCHDOG,
  esp32.RESET-OTHER-WATCHDOG: RESET-WATCHDOG,
  esp32.RESET-DEEPSLEEP: RESET-LOW-POWER-WAKE,
  esp32.RESET-BROWNOUT: RESET-BROWNOUT,
  esp32.RESET-SDIO: RESET-HARDWARE,
  esp32.RESET-USB: RESET-HARDWARE,
  esp32.RESET-JTAG: RESET-DEBUG,
  esp32.RESET-EFUSE: RESET-HARDWARE,
  esp32.RESET-POWER-GLITCH: RESET-BROWNOUT,
  esp32.RESET-CPU-LOCKUP: RESET-CPU-LOCKUP,
}

ec618-reasons_ ::= {
  ec618.RESET-POWER-ON: RESET-POWER-ON,
  ec618.RESET-NORMAL: RESET-SOFTWARE,
  ec618.RESET-SOFTWARE: RESET-SOFTWARE,
  ec618.RESET-HARDFAULT: RESET-HARDWARE,
  ec618.RESET-ASSERT: RESET-HARDWARE,
  ec618.RESET-WATCHDOG-SOFTWARE: RESET-WATCHDOG,
  ec618.RESET-WATCHDOG-HARDWARE: RESET-WATCHDOG,
  ec618.RESET-LOCKUP: RESET-CPU-LOCKUP,
  ec618.RESET-AON-WATCHDOG: RESET-WATCHDOG,
  ec618.RESET-BATTERY-LOW: RESET-BROWNOUT,
  ec618.RESET-TEMPERATURE-HIGH: RESET-TEMPERATURE,
  ec618.RESET-FOTA: RESET-SOFTWARE,
  ec618.RESET-CP-RESET: RESET-HARDWARE,
}
