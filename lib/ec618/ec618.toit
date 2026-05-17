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
*/

import gpio show Pin
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
    -1,  -1,  13,  14,  15,  16,  -1,  -1,
    -1,  -1,  25,  26,  27,  28,  29,  30,
    31,  32,  33,  34,  -1,  -1,  -1,  -1,
    -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,
  ]

  // GPIO -> alternate PAD lookup. -1 means the GPIO has no alt pad.
  static GPIO-ALT-PAD_/List ::= [
    -1,  -1,  -1,  -1,  19,  20,  -1,  -1,
    -1,  -1,  -1,  22,  -1,  -1,  23,  24,
    21,  -1,  -1,  -1,  -1,  -1,  -1,  -1,
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
      [-1, -1, -1, 22],   // Mapping 1 — alt CTS pad only.
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
    alternate pad where one exists (currently only GPIO4, GPIO5, GPIO11,
    GPIO14, GPIO15, GPIO16).
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

  /**
  Opens UART1 (EC618 controller 1, the only one that can wake the chip
    from deep sleep at low baud rates).

  Single mapping: TX=GPIO19, RX=GPIO18. With $rts-enabled or $cts-enabled,
    RTS=GPIO16 and CTS=GPIO17. UART1 also has a fixed alternate CTS pad
    on GPIO11; if your module exposes only that one, pass $mapping equal
    to 1 along with $cts-enabled.
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

  /**
  Opens UART2 (EC618 controller 2). UART2 has no hardware flow control.

  Mapping selector $mapping picks between pin layouts:
  - 0 (default): TX=GPIO11, RX=GPIO10.
  - 1:           TX=GPIO13, RX=GPIO12 (the layout Air780EG/EUG modules
                 use, because GPIO10/11 are taken by their GNSS subsystem).
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
      -> uart.Port:
    if uart-id < 0 or uart-id > 2: throw "INVALID_ARGUMENT"
    if mapping < 0 or mapping >= UART-PADS_[uart-id].size: throw "INVALID_ARGUMENT"

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
    rts/Pin? := rts-enabled ? (Pin rts-pad) : null
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
