# EC618 / Air780E port — roadmap & status

Living status doc for the Toit port to the EC618 (Air780E cellular module),
branch `floitsch/ec618`. Written as a handoff so the work can continue on a
different machine against the same two rigs. Pairs with:

- [ec618-todo.md](ec618-todo.md) — the open work list.
- [ec618-rig-guide.md](ec618-rig-guide.md) — how to drive the two rigs.
- [ec618-known-issues.md](ec618-known-issues.md) — 14 numbered firmware/VM
  issues, each with a reproduction (the authoritative bug log).
- [ec618-hw-tests.md](ec618-hw-tests.md) — the HW test suite + wiring table
  (note: its "console is a build-time config" line is **stale** — see below).
- [partition-table-design.md](partition-table-design.md) — the anchor-record /
  slot / OTA layout model.
- [ota-contract.md](ota-contract.md) — the frozen base/VM ABI.

## Where we are in one paragraph

The VM boots, runs, and does dual-slot OTA on the EC618. All the core
peripherals are HW-proven (UART ×3 with DMA both directions, GPIO incl. AON
pads, PWM incl. AON timers, I2C0/I2C1, async SPI, ADC, deep sleep + pad wake,
watchdog). The firmware is a **frozen universal base** (base-v2, fingerprint
`22cfaacd1b0c62ee44ea4d22744f4e0f`) plus **per-slot VM images** delivered by
OTA; the active partition table and the console-UART selection live in an
**anchor record** on flash, so one base image serves every rig. Both rigs
currently run base-v2 + `22cfaacd`. The remaining work is not bring-up — it is
cellular exercise, a base-image release dispatch, and a handful of polish arcs
(see the todo).

## Build & flash quickstart

```
make ec618                 # -> build/ec618/{firmware.envelope, toit.binpkg, toit-slot-a.elf, slot-reloc.bin}
make ec618-base            # -> build/ec618-base/{base.elf, base.bin, base-manifest.json}  (rarely; base is frozen)
```

- `make ec618` is **run-to-run deterministic** (fingerprints reproduce exactly)
  — keep it that way (rdiff OTA depends on layout stability).
- The **envelope is BARE** (system container only, 333 extension pointers). The
  tester injects the mini-jag agent + sleeper at run time
  (`add-ec618-containers`, → 856 pointers). A raw flash of the bare envelope is
  **agentless — silence is not death.** This tripped multiple multi-day
  hunts; the host doctor now warns about it.
- Toolchain: **gcc-16 is canonical** (two-stage link; the old gcc-14.2 pin is
  retired, archived at `~/.cache/ec618-gcc-14.2`).
- `ectool` for full flashes: `export ECTOOL_PATH=/home/flo/.pyenv/versions/3.8.18/bin/ectool`.

Run a device test / OTA (see the rig guide for port identification):

```
build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
    --chip ec618 --toit-exe build/host/sdk/bin/toit \
    --port-board1 <ec618-console-port> tests/hw/ec618/<name>-ec618.toit

build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit firmware-update \
    --toit-exe build/host/sdk/bin/toit --port <ec618-console-port> \
    --envelope build/ec618/firmware.envelope        # dual-slot OTA, auto-validates
```

## Porting phases (against docs/porting-guide.md)

| Phase | Sections | Status |
|-------|----------|--------|
| 1 — Minimal boot | 1–9 | **DONE** (boot, OS layer, flash registry, RTC mem, embedded data) |
| 2 — Interpreter + peripherals | 10–15 | **DONE** (UART, GPIO, I2C, primitive modules, event system) |
| 3 — Networking | 16–18 | **DONE in code** (cellular, lwIP, TLS) — HW exercise still light (see todo) |
| 4 — Production | 19–24 | OTA **DONE**; Toit libs / firmware tooling / CI **partially** — `lib/ec618`, `tools/ec618`, `tools/firmware.toit` all exist and work; CI workflow not started |

## Major arcs completed (most recent first)

- **I2C real speeds + nominal 400 kHz** (2026-07-18). The "engine ignores the TPR
  divisor" belief was a measurement artifact: ESP32 RMT disproved the 305-tick
  software-batch model. The bounded linear period is `2*SCLx+20`
  functional-clock ticks. The calibrated driver covers ~49–206 kHz on 26 MHz
  and uses the gate-enabled 51.2 MHz source for intermediate fast requests.
  LuatOS's production `soc_i2c` blob supplied the key full-TPR/divisor clue but
  its nominal-400 setup measures ~344 kHz. Toit's nominal **400 kHz** path uses
  the same full timing word on 26 MHz with SCLx=30 and measures ~363 kHz
  (1.25 us high + 1.50 us low); SCLx=28 can make a NACK free-run.
  Requests above 400 kHz clamp to the same setting. `i2c-torture-ec618` passes
  175 value-checked, shape-changing BMP280 transfers with zero bad reads at
  both 100 and 400 kHz.
- **Quirky RX deafness** (2026-07-17, `0c3840ff`+`ea760fda`) — **dormant, not
  fixed.** The shared-console-on-UART1 software path is exonerated (a
  runtime console-flip made modest an exact replica and it stayed responsive),
  and quirky itself would not reproduce (3× cold boot + idle probes all clean).
  Prime remaining suspect: the console-dongle path (a wedge cured by USB
  replug). Known-issues **#14** has an ordered next-occurrence protocol
  (crucially: **USB-replug LAST**, it destroys the evidence).
- **Console in the anchor record** (`76b1d0a2`) — one universal base for every
  rig; the console UART is a byte in the anchor record, chosen at runtime by
  `bsp_custom` from `anchor_console()`. Set it with `ec618.set-console-uart` +
  reboot. **This supersedes the `CONFIG_TOIT_EC618_PRINT_UART_ID` build knob**
  (deleted) and the stale "one config line + rebuild" note in the hw-tests doc.
- **Partition table / anchor record** (arc closed) — firmware is independent of
  the partition table; the ACTIVE table lives in the anchor record (two
  ping-ponged 4 KB sectors right after the base-id page). Slot-move acceptance
  passed on hardware (an 18-entry shifted table boots + OTAs). `tools/ec618/`
  holds the codec, generator, provisioner, base-id anti-drift gate.
- **The rig doctor** (`9c1f8ec7`) — `tools/ec618/doctor.toit` (host: descriptor,
  base artifacts, flashable image, envelope agent check, data-reloc, serial
  ports) + `tests/hw/ec618/doctor-ec618.toit` (device self-report). Run the host
  doctor first when anything looks wrong.
- Earlier arcs (all HW-verified): frozen base + two-stage link + base-id gate;
  dual-slot OTA with per-slot VM `.data`; deep sleep + GPIO/pad wake; the CMSIS
  UART DMA engine; the CMSIS I2C IRQ engine; full pin-coverage matrix; gap-free
  UART TX (≤921600). See the memory index and each `docs/ec618-*.md`.

## Architecture cheat-sheet (what lives where)

- **Base image** (frozen, `make ec618-base`): AP + PLAT + the frozen ABI. Its
  linker template (`third_party/luatos-soc-ec618/PLAT/core/ld/ec618_0h00_flash.c`)
  carries the v2 origins and the `__toit_base_id_start` export. Exported ABI
  symbols are held by the keep-list `toolchains/ec618/project/src/plat_keep.c`.
- **VM slots** (per-slot, OTA target): the Toit VM + its `.data`, relocate-on-
  write. Two slots (A/B); the anchor record says which is active.
- **Anchor record**: `toolchains/ec618/project/{inc/anchor.h,src/anchor.c}`
  (format v2 = 16 B header incl. console byte @11 + N×32 B entries + CRC32
  trailer). The dispatcher `toolchains/ec618/project/src/toit_main.c` reads it to
  find the boot slot and **halts loudly** if it is garbage (no default fallback).
- **Console selection**: `toolchains/ec618/project/src/bsp_custom.c` reads
  `anchor_console()` at boot.
- **I2C driver**: `src/resources/i2c_ec618.cc` (on the fork-completed CMSIS
  `bsp_i2c.c` IRQ engine).
- **Toit-side lib**: `lib/ec618/ec618.toit` (`Ec618.uart0/1/2`, `.i2c0/i2c1`,
  `.spi0`, `print-uart-id`, `set-console-uart`, `peek32`/`poke32`, watchdog,
  deep sleep, wake config, base-id, slot info).
- **EC618-only tooling**: `tools/ec618/` (partitions codec, gen-anchor,
  provision, gen-base-id, splice-slot, doctor, gen-data-reloc). **Checked-in
  scripts must be Toit** (no Python/shell in the build path).

## Standing conventions

- Copyright header: `// Copyright (C) 2026 Toit contributors.` (not "Toitware
  ApS. All rights reserved.").
- **Commit after each section/arc**, not in batches.
- EC618 is **additive** — add alongside ESP32, never replace it. Guard
  EC618 code with `#ifdef TOIT_EC618`; generalize shared guards to
  `TOIT_FREERTOS` where correct.
- **Bring-up doctrine**: don't paper over a firmware/VM bug in test code — fix
  it and log it in known-issues. Tests must not mask issue #1 with try/finally.
- The device IO rail is a **software-configurable LDO (1.65–3.4 V)**, measured
  3.3 V on the dev board — both drive directions are safe.
