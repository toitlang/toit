// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

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
  check-reset_
  __reset__

/**
Enters deep sleep and wakes into a fresh boot.

If $duration is given, enables a wake timer. Otherwise sleeps until a
  configured wake source fires or the device is reset. Configure GPIO wake
  sources with $configure-wakeup-pin. A configured pin can end a timed sleep
  early. Other wake sources are available through the platform libraries.
Container termination has the same cleanup semantics as $reset.

ESP32 and nRF5340 wake on the configured pin level; EC618 wakes on an edge.
  Valid wake pins, pulls, and duration limits depend on the platform.
  ESP32 rounds durations below 50 ms up to 50 ms; EC618 rounds durations
  below one second up to one second. nRF5340 accepts 1 ms through 24 hours.
  Use $reset when no sleep is intended.

# ESP32
Supports durations up to 24 hours. Longer sleeps can be chained by the
  application. Timer wake reports $RESET-LOW-POWER-WAKE and
  esp32.WAKEUP-TIMER.

# EC618
Durations longer than one hardware-timer interval are split across hibernate
  cycles. Intermediate timer wakes re-enter hibernate without starting the
  Toit VM, and configured wakeup pads remain armed. A non-timer wake cancels
  the remaining duration and starts the device normally.

# nRF5340
Timed sleep uses System ON and untimed sleep uses System OFF. The duration
  starts after VM teardown. Both timer and pin wake from timed sleep report
  $RESET-SOFTWARE; GPIO wake from untimed sleep normally reports
  $RESET-LOW-POWER-WAKE.
Timed sleep suspends the console, selects a 64 MHz application CPU clock
  and low-power GPIO-event latency, and keeps the Zephyr timebase and RAM
  powered. An armed watchdog is neither stopped nor fed and can reset earlier.
Untimed sleep does not retain RAM. An attached debugger can emulate System
  OFF, so functional wake tests do not establish power consumption.
Nordic's reference configurations use approximately 1.5-2.1 microamps with
  an RTC, compared with approximately 1 microamp in System OFF: roughly twice
  the current. This is not a measured upper bound for this firmware. Board
  configuration, powered RAM, and peripherals can increase the difference.
  See https://docs.nordicsemi.com/r/bundle/ps_nrf5340/page/chapters/current_consumption/doc/current_consumption.html.
*/
deep-sleep duration/Duration?=null -> none:
  // int.MIN cannot be a duration in milliseconds: Duration stores microseconds.
  request := prepare-sleep_ (duration ? duration.in-ms : int.MIN)
  __deep-sleep__ request

prepare-sleep_ duration-ms/int -> int:
  #primitive.power.prepare-sleep

check-reset_ -> none:
  #primitive.power.check-reset

/**
Configures $pin as a deep-sleep wake source.

$pin is an integer GPIO number, using the same numbering as gpio.Pin.
  $wake-high selects a high level on ESP32 and nRF5340, or a rising edge on
  EC618. When false, selects a low level or falling edge instead.
$pull-up and $pull-down select an optional internal pull while asleep.
  They cannot both be enabled. Unsupported pins or combinations are rejected
  before sleep; configuration errors leave the previous settings intact.
The configuration applies to the whole device and takes effect at the next
  $deep-sleep, after all VM resources have been released. Configuring a wake
  pin does not change its current GPIO configuration or ownership.
Multiple pins can be configured; any configured pin can wake the device.
  Repeated calls replace the configuration for that pin. Settings remain
  until $disable-wakeup-pin is called or the device reboots.
An already-active level can cause immediate wake on ESP32 and nRF5340.
  EC618 requires an edge after sleep entry.

# Platform restrictions
ESP32 uses EXT1-capable RTC GPIOs. Targets without EXT1 are currently
  unsupported. Original ESP32 supports multiple high-level pins or one
  low-level pin. ESP32-S2/S3 require all wake pins to use the same level;
  chips with per-pin EXT1 polarity support allow mixed levels.
  Original ESP32 GPIO34-39 require external pulls.
EC618 accepts physical PAD40-42. Its pulls belong to the approximately 2 V
  wake-input domain, independently of ordinary GPIO pulls and the AON supply.
  Dedicated non-GPIO wake inputs and both-edge wake remain available through
  ec618.configure-wakeup-input.
nRF5340 accepts available, non-reserved GPIOs.
*/
configure-wakeup-pin pin/int
    --wake-high/bool=true --pull-up/bool=false --pull-down/bool=false -> none:
  flags := 8 | (wake-high ? 1 : 0) | (pull-up ? 2 : 0) | (pull-down ? 4 : 0)
  configure-wakeup-pin_ pin flags

/**
Disables $pin as a deep-sleep wake source.

Does not change the pin's current GPIO configuration. The supported pins are
  the same as for $configure-wakeup-pin.
*/
disable-wakeup-pin pin/int -> none:
  configure-wakeup-pin_ pin 0

configure-wakeup-pin_ pin/int flags/int -> none:
  #primitive.power.configure-wakeup-pin

/**
Returns whether $deep-sleep accepts a duration on this platform.

This describes timer wake support, not a particular hardware power state or
  current consumption. On nRF5340, timed sleep uses System ON.
*/
supports-timed-deep-sleep -> bool:
  #primitive.power.supports-timed-sleep

/**
Returns the reset reason as a combination of RESET-* flags.

Zero means unknown. Multiple flags may be set; test individual bits rather
  than comparing the entire value.
Platform-specific details remain available through the platform libraries.
*/
reset-reason -> int:
  #primitive.power.reset-reason
