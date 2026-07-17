// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Multiple concurrent GPIO outputs (EC618-only, register-verified).

Opening or closing one pin must not disturb another pin's configuration.
This was in doubt: a register probe during bring-up showed the boot OUTEN
mask (0x3fbc) collapsing to just the newly-opened pin, which would be
fatal for any program driving two outputs — so this test asserts the
contract through the GPIO controller registers (wiring-independent; the
pins' nets don't matter):

- opening pin B leaves pin A's output enable set;
- driving one pin changes only its own DATAOUT bit;
- closing pin B leaves A and C configured and drivable.

Pins (gpio.Pin numbers are PAD numbers on EC618):
  PAD26 = GPIO11 (controller GPIO0, bit 11)
  PAD22 = GPIO7  (controller GPIO0, bit 7)
  PAD47 = GPIO27 (controller GPIO1, bit 11 there; AON domain)

Registers: GPIO0 at 0x4D070000, GPIO1 at +0x1000; DATAOUT +0x4,
OUTENSET +0x10 (reads as the enable mask). Each instance is 16 bits.
*/

import expect show *
import gpio
import ec618

GPIO-BASE ::= 0x4D07_0000

// The three pins under test: [pad, controller-bit].
PINS ::= [[26, 11], [22, 7], [47, 27]]

outen bit/int -> int:
  reg := ec618.peek32 GPIO-BASE + (bit >= 16 ? 0x1000 : 0) + 0x10
  return (reg >> (bit % 16)) & 1

dataout bit/int -> int:
  reg := ec618.peek32 GPIO-BASE + (bit >= 16 ? 0x1000 : 0) + 0x4
  return (reg >> (bit % 16)) & 1

check-outens opened/List label/string:
  opened.do: | entry/List |
    bit := entry[1]
    if (outen bit) != 1:
      print "gpio-multi: FAIL $label: controller bit $bit lost its output enable"
      exit 1

main:
  print "gpio-multi: opening $(PINS.size) outputs one by one"
  pins := []
  opened := []
  PINS.do: | entry/List |
    pad := entry[0]
    pins.add (gpio.Pin pad --output)
    opened.add entry
    // THE regression check: every previously opened pin keeps its
    // output enable when another pin is configured.
    check-outens opened "after opening pad $pad"

  print "gpio-multi: walking drive patterns"
  patterns := [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 1], [0, 0, 0]]
  patterns.do: | pattern/List |
    pattern.size.repeat: pins[it].set pattern[it]
    sleep --ms=10
    pattern.size.repeat: | i/int |
      bit := PINS[i][1]
      if (dataout bit) != pattern[i]:
        print "gpio-multi: FAIL pattern $pattern: controller bit $bit reads $(dataout bit)"
        exit 1
    check-outens opened "under pattern $pattern"

  print "gpio-multi: closing the middle pin must not disturb the others"
  pins[1].close
  remaining := [PINS[0], PINS[2]]
  check-outens remaining "after closing pad $(PINS[1][0])"

  // The survivors must still drive.
  pins[0].set 1
  pins[2].set 1
  sleep --ms=10
  if (dataout PINS[0][1]) != 1 or (dataout PINS[2][1]) != 1:
    print "gpio-multi: FAIL survivors no longer drive after a close"
    exit 1

  pins[0].close
  pins[2].close
  print "gpio-multi: PASS concurrent outputs stay independent"
