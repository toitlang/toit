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
Resets the device and does not return.

Stops every container and releases its native resources before requesting
  a hardware reset. This does not unwind Toit stacks or run application shutdown
  code. Flush buffered application data and coordinate cleanup beforehand.
On nRF5340, resource cleanup disconnects pins owned by VM peripherals. External
  devices attached to those pins are not reset by this cleanup.
After reboot, $reset-reason includes $RESET-SOFTWARE on the nRF5340.
*/
reset -> none:
  __reset__

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
