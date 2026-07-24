// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import ec618 show Ec618
import ec618
import i2c

/**
Experiments with the EC618 AGPIOWU output path.

Pokes the AON IO control registers directly without a firmware change.
  Register addresses were recovered from `ioCtrl.o` in the SDK's
  `libdriver_private.a`; all offsets below use AON base 0x4D020000:

  0x54  AONIO voltage      (slpManAONIOVoltSet: 3.3V group v -> ((v-16)<<2)|1)
  0x70  AONIO LDO power    (slpManAONIOPowerOn: writes 1, then polls)
  0xAC  bit 23             (slpManAONIOLatchEn — outputs frozen if latched?)
  0x148 WU pad pull bits   (bits 0..5 pull-up?, 8..13 pull-down?)
  0x14C WU wake-enable     (bits 0..2 = WAKEUP_PAD_3..5 = pads 40..42)
  0x150 WU aonio-release   (set = pad released from wake duty to AONIO)
  0x170 the vendor magic   (example_gpio writes 1 before its output demo)

RULED OUT (both rounds, 2026-07-02, HW): the magic write (sticks, no
  effect), NVIC PadWakeup3..5 disable (they idle disabled: ISER0=0xf400),
  AONIO volt-set to 3.30 V (S3), latch-disable (S4; bit 23 idles clear).
  S5 (magic as a per-pad bank, 0x170=0x7) WEDGES the container — bits 1+
  are apparently reserved; kept here for the record, do not re-run S5
  casually.

Probe: board pin 9's net is the BMP280's VCC — chip-id readable = the
  output reached the wire. Standalone; don't run bmp280-esp32.toit
  concurrently.

Run via the mini-jag tester:

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> \
      tests/hw/ec618/aon-wu-output-experiments-ec618.toit
```
*/

POWER-PAD ::= 42  // GPIO22, board pin 9 — the wakeup-capable AON trio.
SDA-PAD ::= 23
SCL-PAD ::= 24
ADDRESS ::= 0x76

AON ::= 0x4D02_0000
REG-VOLT ::= AON + 0x54
REG-POWER ::= AON + 0x70
REG-LATCH ::= AON + 0xAC     // Bit 23.
REG-WU-PULL ::= AON + 0x148
REG-WU-EN ::= AON + 0x14C
REG-WU-REL ::= AON + 0x150
REG-MAGIC ::= AON + 0x170

VOLT-3-30 ::= 0x15           // ((IOVOLT_3_30V - 16) << 2) | 1.

dump label/string -> none:
  print "aon-wu-exp[$label]: volt=0x$(%02x (ec618.peek32 REG-VOLT)) pwr=$(ec618.peek32 REG-POWER) latch23=$((ec618.peek32 REG-LATCH) >> 23 & 1) pull=0x$(%04x (ec618.peek32 REG-WU-PULL)) wuen=0x$(%02x (ec618.peek32 REG-WU-EN)) wurel=0x$(%02x (ec618.peek32 REG-WU-REL)) magic=0x$(%x (ec618.peek32 REG-MAGIC))"

// Drives PAD42 high through a fresh open/config cycle; reports the wire.
try-output bus/i2c.Bus label/string -> bool:
  power := gpio.Pin POWER-PAD --output --value=1
  sleep --ms=500  // Rail charge + sensor startup.
  alive := bus.test ADDRESS
  wu := ec618.wakeup-pin-values
  power.set 0
  sleep --ms=300  // Rail discharge, so the next stage starts equal.
  power.close
  print "aon-wu-exp: $label -> rail $(alive ? "HIGH (output WORKS)" : "dead") (wu-pins-while-high=0b$(%b wu))"
  return alive

main:
  bus := i2c.Bus --sda=(Ec618.pad SDA-PAD) --scl=(Ec618.pad SCL-PAD)

  dump "boot"
  s0 := try-output bus "S0 baseline"
  dump "after-open"

  ec618.poke32 REG-VOLT VOLT-3-30
  s3 := try-output bus "S3 volt-3.30"

  latch := ec618.peek32 REG-LATCH
  ec618.poke32 REG-LATCH (latch & ~(1 << 23))
  s4 := try-output bus "S4 latch-off"

  ec618.poke32 REG-MAGIC 0x7
  s5 := try-output bus "S5 magic-0x7"

  dump "final"
  bus.close
  print "aon-wu-exp: RESULT baseline=$s0 volt=$s3 latch-off=$s4 magic7=$s5"
  print "aon-wu-exp: PASS (experiment complete)"
