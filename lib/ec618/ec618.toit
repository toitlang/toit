// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import gpio show Pin
import gpio.adc
import i2c
import spi
import uart

/**
EC618 chip-specific helpers.

# Addressing model

On the EC618, $Pin numbers are physical pad indices from 1 through 48, not
  logical GPIO numbers. Pads are unambiguous: each one is a single physical
  pin on the chip. A few pads share a GPIO controller bit, so addressing by
  GPIO number alone is ambiguous in those cases.

Most user code should use the helpers on $Ec618:

- $Ec618.gpio returns the primary pad of a logical GPIO.
- $Ec618.gpio with `--alt` returns the alternate pad where one exists.
- $Ec618.pad addresses a physical pad directly.
- $Ec618.uart0, $Ec618.uart1, and $Ec618.uart2 return configured $uart.Port
  instances.
- $Ec618.adc0 and $Ec618.adc1 return the two analog ADC inputs.
*/

/**
Enters deep sleep for the specified $duration and does not return.
  Exiting deep sleep causes the device to start over from main.

Durations longer than one hardware-timer interval are split across hibernate
  cycles. Intermediate timer wakes re-enter hibernate without starting the
  Toit VM, and configured wakeup pads remain armed. A non-timer wake cancels
  the remaining duration and starts the device normally.
*/
deep-sleep duration/Duration -> none:
  __deep-sleep__ duration.in-ms

/**
Returns the UART id (0/1/2) that the firmware redirects `print` output
  to, or -1 if the print redirect was disabled at build time
  (CONFIG_TOIT_EC618_PRINT_UART=0).

Use this to adapt to the console selected in the running firmware. Opening the
  selected print UART through $Ec618 fails with `ALREADY_IN_USE`, unless the
  firmware permits the port to adopt the console.
*/
console-uart-id -> int:
  #primitive.ec618.console-uart-id

/**
Returns the live levels of the AON wakeup inputs as a bitmask.

Bits 3, 4, and 5 are PAD40, PAD41, and PAD42 respectively (EC618 GPIO20,
  GPIO21, and GPIO22). Bits 0 through 2 are the dedicated package wake inputs,
  which do not have ordinary $Pin identities.
*/
wakeup-pin-values -> int:
  #primitive.ec618.wakeup-pin-values

/**
Configures an AON wakeup pad as a deep-sleep wake source.

The $pin must identify one of the three ordinary GPIO wake pads:

- PAD40 / `Ec618.gpio 20` / wakeup input 3.
- PAD41 / `Ec618.gpio 21` / wakeup input 4.
- PAD42 / `Ec618.gpio 22` / wakeup input 5.

Other pins are rejected. The dedicated package wake inputs 0 through 2 do not
  have ordinary $Pin identities and are not supported by this API.

The configuration only takes effect at the next $deep-sleep: an edge of
  the enabled polarity ($pos-edge / $neg-edge, at least one required)
  then ends the hibernate early. The wake is a reboot; $wakeup-cause
  reports $WAKEUP-PAD on the boot it causes. $pull-up / $pull-down
  select the pad's internal pull while asleep.
*/
configure-wakeup-pad pin/Pin
    --pos-edge/bool=false
    --neg-edge/bool=false
    --pull-up/bool=false
    --pull-down/bool=false -> none:
  wakeup-pad-configure_ pin.num true pos-edge neg-edge pull-up pull-down

/**
Disables $pin as a deep-sleep wake source.

The supported pins are the same as for $configure-wakeup-pad.
*/
disable-wakeup-pad pin/Pin -> none:
  wakeup-pad-configure_ pin.num false false false false false

/**
Returns the flashed base's identity ("base-v<N>+<fingerprint>"), or
  "base-unknown" for a base without an id record.

The device never activates a slot linked against a different base.
*/
base-id -> string:
  #primitive.ec618.base-id

/** Reset after power was (re)applied (cold boot). */
RESET-POWER-ON ::= 0
/** Normal reset after waking from deep sleep (sleep2) or hibernate. */
RESET-NORMAL ::= 1
/** Software reset (an explicit system reset request). */
RESET-SOFTWARE ::= 2
/** Reset after a hard fault (see the fault dump on the console). */
RESET-HARDFAULT ::= 3
/** Reset after a failed runtime assertion in the platform. */
RESET-ASSERT ::= 4
/**
Reset attributed to a watchdog via a software-recorded reason.

Note: the application watchdog in the `ec618.watchdog` library does NOT produce
  this. Its reset is an autonomous hardware reset that the chip reports as
  $RESET-POWER-ON.
*/
RESET-WATCHDOG-SOFTWARE ::= 5
/**
Reset attributed to a hardware watchdog.

Note: the application watchdog in the `ec618.watchdog` library does NOT produce
  this. Its reset is an autonomous hardware reset that the chip reports as
  $RESET-POWER-ON.
*/
RESET-WATCHDOG-HARDWARE ::= 6
/** Reset after the CPU locked up. */
RESET-LOCKUP ::= 7
/** Reset by the always-on (sleep-manager) watchdog. */
RESET-AON-WATCHDOG ::= 8
/** Reset because the battery voltage was too low. */
RESET-BATTERY-LOW ::= 9
/** Reset because the temperature was too high. */
RESET-TEMPERATURE-HIGH ::= 10
/** Reset to apply a firmware-over-the-air update. */
RESET-FOTA ::= 11
/** Reset triggered by the cellular processor (CP). */
RESET-CP-RESET ::= 12
/** The reset reason could not be determined. */
RESET-UNKNOWN ::= 13

// Human-readable names indexed by the RESET-* value. Keep in sync with the
// constants above (the SDK's LastResetState_e order).
RESET-REASON-NAMES_/List ::= [
  "power-on",
  "normal",
  "software",
  "hardfault",
  "assert",
  "watchdog-software",
  "watchdog-hardware",
  "lockup",
  "aon-watchdog",
  "battery-low",
  "temperature-high",
  "fota",
  "cp-reset",
  "unknown",
]

/**
Returns the reason for the most recent reset of the application processor.

The result is one of the RESET-* constants ($RESET-POWER-ON,
  $RESET-WATCHDOG-HARDWARE, ...). Use $reset-reason-name to turn it into a
  human-readable string.
*/
reset-reason -> int:
  #primitive.ec618.reset-reason

/**
Returns a human-readable name for the given reset $reason.

The $reason should be one of the RESET-* constants, typically the result of
  $reset-reason. Unrecognized values are formatted as "reset-<n>".
*/
reset-reason-name reason/int -> string:
  if 0 <= reason < RESET-REASON-NAMES_.size:
    return RESET-REASON-NAMES_[reason]
  return "reset-$reason"

/** Cold boot: power was (re)applied, or a reset that isn't a sleep wake. */
WAKEUP-POWER-ON ::= 0
/** Woke from deep sleep by the RTC deep-sleep timer (see $deep-sleep). */
WAKEUP-RTC ::= 1
/** Woke from deep sleep by an AON wakeup pad. */
WAKEUP-PAD ::= 2
/** Woke from sleep by activity on the low-power UART (UART1). */
WAKEUP-LPUART ::= 3
/** Woke from sleep by USB activity. */
WAKEUP-LPUSB ::= 4
/** Woke by the PWRKEY pin. */
WAKEUP-PWRKEY ::= 5
/** Woke by the charger (VBUS) detection. */
WAKEUP-CHARGER ::= 6

// Human-readable names indexed by the WAKEUP-* value. Keep in sync with
// the constants above (the SDK's slpManWakeSrc_e order).
WAKEUP-CAUSE-NAMES_/List ::= [
  "power-on",
  "rtc",
  "pad",
  "lpuart",
  "lpusb",
  "pwrkey",
  "charger",
]

/**
Returns what woke the chip at the most recent boot.

The result is one of the WAKEUP-* constants ($WAKEUP-POWER-ON,
  $WAKEUP-RTC, ...). Use $wakeup-cause-name to turn it into a
  human-readable string.

The EC618 reports $reset-reason as $RESET-POWER-ON even after a wake
  from deep sleep, so this is the call that tells a deep-sleep wake
  (by timer or wakeup pad) apart from a cold boot.
*/
wakeup-cause -> int:
  #primitive.ec618.wakeup-cause

/**
Returns a human-readable name for the given wakeup $cause.

The $cause should be one of the WAKEUP-* constants, typically the result
  of $wakeup-cause. Unrecognized values are formatted as "wakeup-<n>".
*/
wakeup-cause-name cause/int -> string:
  if 0 <= cause < WAKEUP-CAUSE-NAMES_.size:
    return WAKEUP-CAUSE-NAMES_[cause]
  return "wakeup-$cause"

/**
Helpers for EC618 pin addressing and peripheral construction.

All pin indices used by Toit on the EC618 are physical pad numbers.
  Silkscreens and datasheets often use logical GPIO numbers, for which $gpio
  provides a convenience conversion.
*/
class Ec618:
  static NO-PAD_ ::= 0xff

  // GPIO -> primary PAD lookup. This is intentionally the only GPIO -> PAD
  // resolver; native drivers receive PADs and only derive controller bits
  // from them. Values come from the official CSDK's complete `allGpioMap`
  // example table and its GPIO_ToPadEC618 helper. GPIO20..28 (pads 40..48)
  // are AON-domain GPIOs: their shared LDO is powered while at least one is
  // configured for GPIO or PWM. Deep-sleep wake inputs use a separate rail.
  static GPIO-PRIMARY-PAD_/ByteArray ::= #[
    15,  16,  17,  18,  19,  20,  21,  22,
    23,  24,  25,  26,  27,  28,  29,  30,
    31,  32,  33,  34,  40,  41,  42,  43,
    44,  45,  46,  47,  48,  35,  36,  37,
  ]

  // GPIO -> alternate ALT4 PAD lookup. 0xff means the GPIO has no alt pad.
  // Values match the CSDK's `allGpioMap` table and GPIO_ToPadEC618 helper.
  static GPIO-ALT-PAD_/ByteArray ::= #[
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff,   11,   12,   13,   14,
    0xff, 0xff,   38,   39, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
  ]

  // UART pad layout. Values must match `kUartPads` in pad_table_ec618.cc.
  // Flattened as controller, mapping, then [tx, rx, rts, cts]. 0xff means
  // the corresponding role isn't available on that mapping.
  static UART-MAPPINGS-PER-CONTROLLER_ ::= 2
  static UART-PADS-PER-MAPPING_ ::= 4
  static UART-PADS_/ByteArray ::= #[
    30, 29,   27,   28,  // UART0 mapping 0 — primary.
    32, 31, 0xff, 0xff,  // UART0 mapping 1 — alt; no flow control.

    34, 33,   31,   32,  // UART1 mapping 0 — only TX/RX/RTS route.
    34, 33, 0xff,   22,  // UART1 mapping 1 — alternate CTS.

    26, 25, 0xff, 0xff,  // UART2 mapping 0 — primary.
    28, 27, 0xff, 0xff,  // UART2 mapping 1 — alt 1.
  ]

  /**
  Returns a $Pin addressing the physical PAD with the given $num.

  Use this when the chip's PAD index is what you have. For most boards
    silkscreens don't label PADs directly; in that case prefer $gpio.
  The configuration options have the same meaning as on $(Pin.constructor num).
  */
  static pad num/int -> Pin
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --value/int=0:
    return Pin num
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --value=value

  /**
  Returns a $Pin for the EC618 logical GPIO with the given $num.

  Defaults to the primary ALT0 pad of that GPIO. Pass $alt to address its
    alternate ALT4 pad where one exists. The returned $Pin still uses the
    physical PAD number as its unique identity.
  The configuration options have the same meaning as on $(Pin.constructor num).
  */
  static gpio num/int -> Pin
      --alt/bool=false
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --value/int=0:
    if not 0 <= num < 32: throw "INVALID_ARGUMENT"
    pad-num/int := alt ? GPIO-ALT-PAD_[num] : GPIO-PRIMARY-PAD_[num]
    if pad-num == NO-PAD_: throw "INVALID_ARGUMENT"
    return pad pad-num
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --value=value

  /**
  Opens UART0 (EC618 controller 0).

  Default $mapping (0): TX=PAD30, RX=PAD29 (the chip's debug /
    firmware-download UART on most modules; data on these pads also
    travels through the bootloader at chip reset; the pads have no GPIO
    function). With $rts-enabled or
    $cts-enabled, RTS=GPIO12 and CTS=GPIO13.

  Alternate $mapping (1): TX=GPIO17, RX=GPIO16. No hardware flow
    control on this mapping.

  Set $tx-disabled or $rx-disabled to leave the corresponding pad free
    for general-purpose IO; address it via $gpio with the appropriate
    GPIO number.

  Note: UART0 is normally the print/console UART of the Toit firmware.
    Constructing this then fails with "ALREADY_IN_USE", unless the
    firmware was built with CONFIG_TOIT_EC618_ALLOW_PRINT_UART_REUSE
    (then the port adopts the console: reads/writes share the wire with
    `print` output — this is how the HW-test agent serves its control
    protocol), with CONFIG_TOIT_EC618_PRINT_UART=0, or with the redirect
    pointed elsewhere via the anchor record's console byte.

  With $mode equal to $uart.Port.MODE-RS485-HALF-DUPLEX, pass the RS485
    direction (DE) pin as $rs485-de; any GPIO-capable pad works.
  */
  static uart0 -> uart.Port
      --mapping/int=0
      --rts-enabled/bool=false
      --cts-enabled/bool=false
      --tx-disabled/bool=false
      --rx-disabled/bool=false
      --baud-rate/int
      --data-bits/int=8
      --stop-bits/uart.StopBits=uart.Port.STOP-BITS-1
      --parity/int=uart.Port.PARITY-DISABLED
      --mode/int=uart.Port.MODE-UART
      --rs485-de/Pin?=null
      --large-buffers/bool?=null:
    return open-uart_
        --uart-id=0
        --mapping=mapping
        --rts-enabled=rts-enabled
        --cts-enabled=cts-enabled
        --tx-disabled=tx-disabled
        --rx-disabled=rx-disabled
        --baud-rate=baud-rate
        --data-bits=data-bits
        --stop-bits=stop-bits
        --parity=parity
        --mode=mode
        --rs485-de=rs485-de
        --large-buffers=large-buffers

  /**
  Opens UART1 (EC618 controller 1, the only one that can wake the chip
    from deep sleep at low baud rates).

  Single mapping: TX=GPIO19, RX=GPIO18. With $rts-enabled or $cts-enabled,
    RTS=GPIO16 and CTS=GPIO17. UART1 also has a fixed alternate CTS pad
    on GPIO11; if your module exposes only that one, pass $mapping equal
    to 1 along with $cts-enabled.

  Note on UART1: the chip's mask ROM emits a complete "^boot.rom..."
    banner on UART1 at every reset, before application software runs.
    The banner has no trailing newline and cannot be suppressed, so a
    line-oriented receiver should discard it before accepting application
    traffic.
  */
  static uart1 -> uart.Port
      --mapping/int=0
      --rts-enabled/bool=false
      --cts-enabled/bool=false
      --tx-disabled/bool=false
      --rx-disabled/bool=false
      --baud-rate/int
      --data-bits/int=8
      --stop-bits/uart.StopBits=uart.Port.STOP-BITS-1
      --parity/int=uart.Port.PARITY-DISABLED
      --mode/int=uart.Port.MODE-UART
      --rs485-de/Pin?=null
      --large-buffers/bool?=null:
    return open-uart_
        --uart-id=1
        --mapping=mapping
        --rts-enabled=rts-enabled
        --cts-enabled=cts-enabled
        --tx-disabled=tx-disabled
        --rx-disabled=rx-disabled
        --baud-rate=baud-rate
        --data-bits=data-bits
        --stop-bits=stop-bits
        --parity=parity
        --mode=mode
        --rs485-de=rs485-de
        --large-buffers=large-buffers

  /**
  Opens UART2 (EC618 controller 2). UART2 has no hardware flow control.

  Mapping selector $mapping picks between pin layouts:
  - 0 (default): TX=GPIO11, RX=GPIO10.
  - 1:           TX=GPIO13, RX=GPIO12 (the layout Air780EG/EUG modules
                 use, because GPIO10/11 are taken by their GNSS subsystem).

  With $mode equal to $uart.Port.MODE-RS485-HALF-DUPLEX, $rs485-de is the
    RS485 direction (DE) pin: the driver raises it just before a
    transmission starts and drops it once the last bit has left the shift
    register. Unlike the fixed RTS/CTS routings, ANY GPIO-capable pad can
    serve as DE (it is driven as a plain GPIO), so it is passed as a $Pin
    (use $Ec618.gpio or $Ec618.pad). Required in RS485 mode; rejected
    otherwise.
  */
  static uart2 -> uart.Port
      --mapping/int=0
      --tx-disabled/bool=false
      --rx-disabled/bool=false
      --baud-rate/int
      --data-bits/int=8
      --stop-bits/uart.StopBits=uart.Port.STOP-BITS-1
      --parity/int=uart.Port.PARITY-DISABLED
      --mode/int=uart.Port.MODE-UART
      --rs485-de/Pin?=null
      --large-buffers/bool?=null:
    return open-uart_
        --uart-id=2
        --mapping=mapping
        --rts-enabled=false
        --cts-enabled=false
        --tx-disabled=tx-disabled
        --rx-disabled=rx-disabled
        --baud-rate=baud-rate
        --data-bits=data-bits
        --stop-bits=stop-bits
        --parity=parity
        --mode=mode
        --rs485-de=rs485-de
        --large-buffers=large-buffers

  /**
  Opens the I2C0 bus.

  SDA=PAD14, SCL=PAD13 — the module pins labelled I2C0_SDA/I2C0_SCL
    (peripheral-routed at iomux function 2; as GPIOs the same pads are
    GPIO15/GPIO14 at function 4).

  If $pull-up is true, the pads' internal pull-ups are enabled. Most
    sensor breakouts carry their own bus pull-ups.

  $frequency is an upper bound. Values below about 49kHz are rejected.
    The EC618's measured-safe ceiling is about 363kHz; requests of 400kHz
    or more use that ceiling.
  */
  static i2c0 --frequency/int=100_000 --pull-up/bool=false -> i2c.Bus:
    return i2c.Bus
        --sda=(pad 14)
        --scl=(pad 13)
        --frequency=frequency
        --pull-up=pull-up

  /**
  Opens the I2C1 bus.

  SDA=PAD23, SCL=PAD24 (GPIO8/GPIO9) — the module's I2C1/SPI0 pins; one
    peripheral at a time.

  If $pull-up is true, the pads' internal pull-ups are enabled.

  $frequency is an upper bound. Values below about 49kHz are rejected.
    The EC618's measured-safe ceiling is about 363kHz; requests of 400kHz
    or more use that ceiling.
  */
  static i2c1 --frequency/int=100_000 --pull-up/bool=false -> i2c.Bus:
    return i2c.Bus
        --sda=(pad 23)
        --scl=(pad 24)
        --frequency=frequency
        --pull-up=pull-up

  /**
  Opens the SPI0 bus (master).

  MOSI=PAD24, MISO=PAD25, CLK=PAD26 — shared with I2C1 and UART2; one
    peripheral at a time. Chip-select is a plain GPIO passed per device
    (see $spi.Bus.device).
  */
  static spi0 -> spi.Bus:
    return spi.Bus --mosi=(pad 24) --miso=(pad 25) --clock=(pad 26)

  /**
  Opens the SPI1 bus (master).

  MOSI=PAD28, MISO=PAD29, CLK=PAD30 — shared with UART0, so this is
    unusable while UART0 is the console. Accepted but untested.
  */
  static spi1 -> spi.Bus:
    return spi.Bus --mosi=(pad 28) --miso=(pad 29) --clock=(pad 30)

  static open-uart_ -> uart.Port
      --uart-id/int
      --mapping/int
      --rts-enabled/bool
      --cts-enabled/bool
      --tx-disabled/bool
      --rx-disabled/bool
      --baud-rate/int
      --data-bits/int
      --stop-bits/uart.StopBits
      --parity/int
      --mode/int
      --rs485-de/Pin?
      --large-buffers/bool?:
    if not 0 <= uart-id <= 2: throw "INVALID_ARGUMENT"
    if not 0 <= mapping < UART-MAPPINGS-PER-CONTROLLER_:
      throw "INVALID_ARGUMENT"

    rs485 := mode == uart.Port.MODE-RS485-HALF-DUPLEX
    if rs485 and (rts-enabled or cts-enabled): throw "INVALID_ARGUMENT"
    if rs485 != (rs485-de != null): throw "INVALID_ARGUMENT"

    layout-offset := (
        uart-id * UART-MAPPINGS-PER-CONTROLLER_ + mapping
      ) * UART-PADS-PER-MAPPING_
    tx-pad := uart-pad_ layout-offset
    rx-pad := uart-pad_ layout-offset + 1
    rts-pad := uart-pad_ layout-offset + 2
    cts-pad := uart-pad_ layout-offset + 3

    if tx-disabled and rx-disabled: throw "INVALID_ARGUMENT"
    if (not tx-disabled) and tx-pad < 0: throw "INVALID_ARGUMENT"
    if (not rx-disabled) and rx-pad < 0: throw "INVALID_ARGUMENT"
    if rts-enabled and rts-pad < 0: throw "INVALID_ARGUMENT"
    if cts-enabled and cts-pad < 0: throw "INVALID_ARGUMENT"

    tx/Pin? := tx-disabled ? null : (Pin tx-pad)
    rx/Pin? := rx-disabled ? null : (Pin rx-pad)
    // In RS485 mode the generic uart API carries the direction pin in the
    // rts slot (the driver takes it out of flow-control matching).
    rts/Pin? := rs485 ? rs485-de : (rts-enabled ? (Pin rts-pad) : null)
    cts/Pin? := cts-enabled ? (Pin cts-pad) : null

    return uart.Port
        --tx=tx
        --rx=rx
        --rts=rts
        --cts=cts
        --large-buffers=large-buffers
        --baud-rate=baud-rate
        --data-bits=data-bits
        --stop-bits=stop-bits
        --parity=parity
        --mode=mode

  static uart-pad_ offset/int -> int:
    value := UART-PADS_[offset]
    return value == NO-PAD_ ? -1 : value

  /**
  Opens ADC channel 0 — the EC618's AIO3 input (the board's "ADC0").

  The EC618's application ADC inputs are dedicated analog channels (AIO3/AIO4),
    not GPIO pads, so they are addressed by channel rather than by a $Pin (see
    $adc.Adc.channel). $max-voltage selects the smallest internal range that
    covers it (up to 3.8 V) for the best resolution; null uses the widest range.
  */
  static adc0 --max-voltage/float?=null -> adc.Adc:
    return adc.Adc.channel 0 --max-voltage=max-voltage

  /**
  Opens ADC channel 1 — the EC618's AIO4 input (the board's "ADC1").

  See $adc0; only the channel differs.
  */
  static adc1 --max-voltage/float?=null -> adc.Adc:
    return adc.Adc.channel 1 --max-voltage=max-voltage

/**
Sets the provisioned console/control UART in the anchor record.

The $id selects UART 0, 1 or 2; 0xff disables the redirect. Takes effect
  on the NEXT boot: the base reads the byte before its first print, and
  the mini-jag agent follows it via $console-uart-id. Per-device
  provisioning state — it survives OTAs and resets.
*/
set-console-uart id/int -> none:
  #primitive.ec618.console-uart-set

wakeup-pad-configure_ pad enabled pos-edge neg-edge pull-up pull-down -> none:
  #primitive.ec618.wakeup-pad-configure
