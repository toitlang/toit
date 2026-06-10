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

/**
EC618 (Air780E) chip-specific helpers.

# Addressing model

On the EC618, $Pin numbers are physical PAD indices (1..47), not logical
GPIO numbers. PADs are unambiguous: each one is a single physical pin on
the chip. A few PADs share a GPIO controller bit (e.g. PAD22 and PAD26
both connect to GPIO11), so addressing by GPIO number alone is ambiguous
in those cases — addressing by PAD never is.

Most user code shouldn't construct $Pin directly on the EC618. Use the
helpers on $Ec618:

- $Ec618.gpio for "the primary pad of GPIO N" (matches Air780 silkscreen
  labels for most boards).
- $Ec618.gpio --alt for the alternate pad of a GPIO that has one.
- $Ec618.pad to address a physical pad directly when you know the number.
- $Ec618.uart0, $Ec618.uart1, $Ec618.uart2 for fully-configured
  $uart.Port instances.
- $Ec618.adc0, $Ec618.adc1 for the two analog ADC inputs (AIO3/AIO4).
*/

import gpio show Pin
import gpio.adc
import uart

/**
Enters deep sleep for the specified $duration and does not return.
Exiting deep sleep causes the device to start over from main.
*/
deep-sleep duration/Duration -> none:
  __deep-sleep__ duration.in-ms

/**
Returns the UART id (0/1/2) that the firmware redirects `print` output
  to, or -1 if the print redirect was disabled at build time
  (CONFIG_TOIT_EC618_PRINT_UART=0).

Use this to write tests that adapt to whichever firmware variant is
  loaded — opening the print UART via $Ec618.uart0/1/2 fails with
  "ALREADY_IN_USE" when the redirect is on.
*/
print-uart-id -> int:
  #primitive.ec618.print-uart-id

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
  if 0 <= reason and reason < RESET-REASON-NAMES_.size:
    return RESET-REASON-NAMES_[reason]
  return "reset-$reason"

/**
Helpers for EC618 pin addressing and peripheral construction.

All pin indices used by Toit on the EC618 are physical PAD numbers, but
silkscreens and datasheets normally refer to logical GPIO numbers; see the
top-of-file comment for the addressing model.
*/
class Ec618:
  // GPIO -> primary PAD lookup. Values must match `kGpioPrimaryPad` in
  // src/resources/pad_table_ec618.cc. -1 means we don't have a mapping
  // documented yet.
  static GPIO-PRIMARY-PAD_/List ::= [
    -1,  16,  13,  14,  15,  -1,  -1,  -1,
    23,  24,  25,  26,  27,  28,  29,  30,
    31,  32,  33,  34,  40,  41,  42,  43,
    44,  45,  46,  47,  37,  35,  36,  -1,
  ]

  // GPIO -> alternate PAD lookup. -1 means the GPIO has no alt pad.
  static GPIO-ALT-PAD_/List ::= [
    -1,  -1,  17,  18,  19,  20,  -1,  -1,
    -1,  -1,  -1,  22,  -1,  -1,  -1,  -1,
    21,  -1,  38,  39,  -1,  -1,  -1,  -1,
    -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,
  ]

  // UART pad layout. Values must match `kUartPads` in pad_table_ec618.cc.
  // Indexed first by uart-id (0..2), then by mapping (0..1). Each entry
  // is [tx-pad, rx-pad, rts-pad, cts-pad]; -1 means the corresponding
  // role isn't available on that mapping.
  static UART-PADS_/List ::= [
    // UART0.
    [
      [30, 29, 27, 28],   // Mapping 0 — primary.
      [32, 31, -1, -1],   // Mapping 1 — alt; no flow control.
    ],
    // UART1.
    [
      [34, 33, 31, 32],   // Mapping 0 — only mapping for TX/RX/RTS.
      // Mapping 1 — the alt CTS pad. TX/RX have a single routing on UART1,
      // so this mapping keeps them; only CTS differs. (With TX/RX as -1
      // this mapping was unusable: open-uart_ rejects an enabled role
      // without a pad.)
      [34, 33, -1, 22],
    ],
    // UART2.
    [
      [26, 25, -1, -1],   // Mapping 0 — primary.
      [28, 27, -1, -1],   // Mapping 1 — alt 1, GPIO12/13.
    ],
  ]

  /**
  Returns a $Pin addressing the physical PAD with the given $num.

  Use this when the chip's PAD index is what you have. For most boards
    silkscreens don't label PADs directly; in that case prefer $gpio.
  */
  static pad num/int -> Pin:
    return Pin num

  /**
  Returns a $Pin for the EC618 logical GPIO with the given $num.

  Defaults to the primary pad of that GPIO. Pass $alt to address the
    alternate pad where one exists (currently GPIO2..GPIO5, GPIO11 and
    GPIO16).
  */
  static gpio num/int --alt/bool=false -> Pin:
    if num < 0 or num >= 32: throw "INVALID_ARGUMENT"
    pad-num/int := alt ? GPIO-ALT-PAD_[num] : GPIO-PRIMARY-PAD_[num]
    if pad-num < 0: throw "INVALID_ARGUMENT"
    return Pin pad-num

  /**
  Opens UART0 (EC618 controller 0).

  Default $mapping (0): TX=GPIO15, RX=GPIO14 (the chip's debug /
    firmware-download UART on most modules; data on these pads also
    travels through the bootloader at chip reset). With $rts-enabled or
    $cts-enabled, RTS=GPIO12 and CTS=GPIO13.

  Alternate $mapping (1): TX=GPIO17, RX=GPIO16. No hardware flow
    control on this mapping.

  Set $tx-disabled or $rx-disabled to leave the corresponding pad free
    for general-purpose IO; address it via $gpio with the appropriate
    GPIO number.

  Note: UART0 is normally the print/console UART of the Toit firmware;
    constructing this with the default config will fail with
    "ALREADY_IN_USE" unless the firmware was built with
    CONFIG_TOIT_EC618_PRINT_UART=0 or the redirect was pointed at a
    different controller via CONFIG_TOIT_EC618_PRINT_UART_ID.

  With $mode equal to $uart.Port.MODE-RS485-HALF-DUPLEX, pass the RS485
    direction (DE) pin as $rs485-de; any GPIO-capable pad works. See
    $uart2 for details.
  */
  static uart0
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
      -> uart.Port:
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

  /**
  Opens UART1 (EC618 controller 1, the only one that can wake the chip
    from deep sleep at low baud rates).

  Single mapping: TX=GPIO19, RX=GPIO18. With $rts-enabled or $cts-enabled,
    RTS=GPIO16 and CTS=GPIO17. UART1 also has a fixed alternate CTS pad
    on GPIO11; if your module exposes only that one, pass $mapping equal
    to 1 along with $cts-enabled.

  Note on UART1 as the print UART: if the firmware was built with
    CONFIG_TOIT_EC618_PRINT_UART_ID=1 (so Toit's `print` is routed
    here), every cold-boot starts with a single garbled line on UART1
    before the first real output. The chip leaves some TX state on
    UART1 that we cannot fully drain from software. This is cosmetic
    and only happens on cold boot — a warm reset is clean. See
    toolchains/ec618/ec618_config.h for the details and how to choose a
    different print UART.
  */
  static uart1
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
      -> uart.Port:
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
  static uart2
      --mapping/int=0
      --tx-disabled/bool=false
      --rx-disabled/bool=false
      --baud-rate/int
      --data-bits/int=8
      --stop-bits/uart.StopBits=uart.Port.STOP-BITS-1
      --parity/int=uart.Port.PARITY-DISABLED
      --mode/int=uart.Port.MODE-UART
      --rs485-de/Pin?=null
      -> uart.Port:
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

  static open-uart_
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
      -> uart.Port:
    if uart-id < 0 or uart-id > 2: throw "INVALID_ARGUMENT"
    if mapping < 0 or mapping >= UART-PADS_[uart-id].size: throw "INVALID_ARGUMENT"

    rs485 := mode == uart.Port.MODE-RS485-HALF-DUPLEX
    if rs485 and (rts-enabled or cts-enabled): throw "INVALID_ARGUMENT"
    if rs485 != (rs485-de != null): throw "INVALID_ARGUMENT"

    layout/List := UART-PADS_[uart-id][mapping]
    tx-pad := layout[0]
    rx-pad := layout[1]
    rts-pad := layout[2]
    cts-pad := layout[3]

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
        --baud-rate=baud-rate
        --data-bits=data-bits
        --stop-bits=stop-bits
        --parity=parity
        --mode=mode

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
