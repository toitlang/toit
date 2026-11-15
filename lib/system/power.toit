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

If $duration is given, enables a wake timer. Otherwise sleeps until a
  configured wake source fires or the device is reset. Wake sources are
  configured through the platform library: esp32.enable-external-wakeup,
  ec618.configure-wakeup-input or ec618.configure-wakeup-pad, and
  zephyr.configure-wakeup-pin. A configured pin can end a timed sleep early.
Container termination has the same cleanup semantics as $reset.

ESP32 and nRF5340 wake on the configured pin level; EC618 wakes on an edge.
  Valid wake pins, pulls, and duration limits depend on the platform.
  ESP32 rounds durations below 50 ms up to 50 ms; EC618 rounds durations
  below one second up to one second. nRF5340 accepts 1 ms through 24 hours.
On nRF5340, timed sleep uses System ON and untimed sleep uses System OFF.
  See zephyr.deep-sleep for power-consumption and watchdog considerations.
*/
deep-sleep duration/Duration?=null -> none:
  if system.platform == system.PLATFORM-ZEPHYR:
    zephyr.deep-sleep duration
  if (system.architecture.starts-with "esp32"):
    esp32.deep-sleep duration
  if system.architecture == system.ARCHITECTURE-EC618:
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
