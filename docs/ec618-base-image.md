# The EC618 base image: building, compatibility, day-to-day rules

The EC618 firmware is TWO artifacts with different lifetimes:

- **The base** — PLAT SDK, boot/dispatcher, the exported API surface
  (`plat_keep.c`), RAM/flash geometry. Flashed over the boot ROM, changed
  rarely. Built by `make ec618-base` into `build/ec618-base/`
  (`base.elf`, `base.bin`, `base.binpkg`).
- **The slot** — the Toit VM, linked *separately* against `base.elf` and
  delivered by slot OTA. Built by `make ec618` (which also assembles the
  full flashable image and the envelope).

Design background: [frozen-base-design.md](frozen-base-design.md) (why),
[frozen-base-phase4.md](frozen-base-phase4.md) (the base-vN publishing
model this is heading toward).

## The one rule

**A slot runs only on the exact base build it was linked against.**
Everything below is bookkeeping around that rule. Until the device-side
`.base_id` reject lands (phase-4 step 3), nothing stops you from OTA'ing a
mismatched slot — it faults in creative ways instead of erroring. Keep the
discipline manual and boring.

## When you must rebuild the base (and full-flash every device)

Any change to a base-side input:

- `toolchains/ec618/project/` (dispatcher, `bsp_custom.c`, `plat_keep.c`,
  `slot_marker.c`, cmpctmalloc, `xmake.lua`)
- `toolchains/ec618/ec618_config.h` — **including `PRINT_UART_ID`: the
  UART0 and UART1 console variants are DIFFERENT bases**
- the SDK submodule (`third_party/luatos-soc-ec618`), including the linker
  script template (geometry, reserves, exported anchors)
- the PLAT toolchain (the pinned xmake GCC 10.3)
- a slot failing to link with `undefined reference to <PLAT symbol>` —
  that is the keep-list telling you the base does not export something the
  slot now needs. Add it to `plat_keep.c` → that is a base change.

`make ec618` does **not** rebuild the base automatically — it only checks
that `build/ec618-base/base.elf` exists. After base-side edits, run
`make ec618-base` yourself, then `make ec618`, then plan the reflash.

## What does NOT need a new base

- All VM/slot C++ and all Toit code, including **new VM statics**: the
  base reserves a pooled 24 KB for the VM's `.data`+`.bss`
  (`TOIT_VM_DATA_RESERVE` + `TOIT_VM_ZI_RESERVE` in the linker template);
  growth inside the pool moves nothing the base can see. Exceeding it
  fails the build with a clear ASSERT — growing the reserve is a base
  change.
- New primitives, new drivers, mbedtls changes — slot-side, OTA-able.
- The slot's own C++ runtime helpers (libgcc/libstdc++): pulled from the
  slot toolchain, land in-slot. (Mixed slot *compilers* against one base
  are the phase-4 goal; until the gcc-16 acceptance test passes, keep
  slots on the pinned toolchain below.)

## Toolchains

- Base: the xmake-pinned arm-none-eabi GCC 10.3 (`EC618_GCC_PATH`).
- Slot (and the VM archives): the PATH compiler. Until the repo pins it,
  use the local pin — the system compiler is a rolling Arch package and
  HAS drifted (14.2→16.1 broke builds once already):

      PATH=~/.cache/ec618-gcc-14.2/usr/bin:$PATH make ec618

## Fingerprints and per-rig state

The compatibility unit is `base.bin` — byte-identical base = slot-OTA
compatible. Keep the deployed base's artifacts per rig (convention:
`~/.cache/ec618-fp/`, e.g. `base-uart0-twostage.bin`,
`fp-modest-affair-uart0-twostage.elf`) and diff before trusting a slot
OTA. The device-side check will eventually make this automatic; the host
discipline stays as the early warning.

## Flashing and updating

Full flash (new base — needs the boot ROM):

1. Put the EC618 in boot/download mode FIRST (manual boards: your hand;
   quirky-plenty: `jag run -d quirky-plenty dev/ec618-rig/boot-high.toit`).
2. Within ~15 s:

       ECTOOL_PATH=... build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit setup \
           --chip ec618 --toit-exe build/host/sdk/bin/toit \
           --port <console-tty> --envelope build/ec618/firmware.envelope

3. The chip auto-reboots after the burn (no PWRKEY — that is only for
   power-on after a power-cycle). The setup confirms the agent is healthy.

Slot OTA (same base):

    build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit firmware-update \
        --toit-exe build/host/sdk/bin/toit --port <console-tty> \
        --fast-baud <921600|115200> --envelope build/ec618/firmware.envelope

(UART1-console rigs need `--fast-baud 115200`; the hop fails there.)

## Where this is going (phase 4, remaining)

The base becomes a published, versioned release artifact — **base-vN** —
with its fingerprint embedded in a `.base_id` record and in every OTA
payload, so the device REJECTS mismatched slots instead of faulting, and
CI links slots against the released base. When that lands, this README's
manual discipline shrinks to "match the base-vN number".
