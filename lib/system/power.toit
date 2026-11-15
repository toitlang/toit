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

/** Resets the device after releasing VM resources. */
reset -> none:
  if not embedded_: throw "UNIMPLEMENTED"
  __reset__

/**
Enters deep sleep and wakes into a fresh boot.

ESP32 and EC618 require $duration; their platform libraries document minimum
  durations and provide additional wake-source configuration.
On nRF5340, omit $duration to enter System OFF. A timer cannot wake that state,
  so supplying a duration throws `UNIMPLEMENTED`. Use $sleep-and-restart when
  the higher consumption of System ON is acceptable.

The optional integer $wake-pin and its $wake-high level are supported on
  nRF5340. The pin is configured after releasing VM resources. $pull-up and
  $pull-down select its bias and cannot both be enabled. Without a pin,
  waking requires another hardware source such as reset.
*/
deep-sleep duration/Duration?=null
    --wake-pin/int?=null --wake-high/bool=true
    --pull-up/bool=false --pull-down/bool=false -> none:
  if system.platform == system.PLATFORM-ZEPHYR:
    if duration: throw "UNIMPLEMENTED"
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
Stops the VM, waits in System ON, and restarts after $duration.

Currently supported on nRF5340 for 1 ms through 24 hours. This keeps the
  timebase and system RAM powered. An armed watchdog remains active and can
  reset the device earlier. This operation does not promise deep-sleep power.
*/
sleep-and-restart duration/Duration -> none:
  if system.platform != system.PLATFORM-ZEPHYR: throw "UNIMPLEMENTED"
  zephyr.sleep-and-restart duration

/** Returns whether timed deep sleep is supported by this platform. */
supports-timed-deep-sleep -> bool:
  return (system.architecture.starts-with "esp32") or
      system.architecture == system.ARCHITECTURE-EC618

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
