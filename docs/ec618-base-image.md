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
The device ENFORCES this: every base carries a `{ base-vN, fingerprint }`
record (stamped by `gen-base-id.toit`, version from
`toolchains/ec618/base-version`), every OTA payload carries the id it was
linked against (SRL3), and a mismatch is refused before any flash write:

    [toit] ERROR: base mismatch — image built for base-v2, device runs
    base-v1; full-flash the matching base

`ec618.base-id` returns the flashed identity. Bump the version file
whenever a base change ships; the fingerprint catches everything else
that contributes to the base. The console UART is selected by the anchor
record, so one universal base serves every rig.

## When you must rebuild the base (and full-flash every device)

Any change to a base-side input:

- `toolchains/ec618/project/` (dispatcher, `bsp_custom.c`, `plat_keep.c`,
  `slot_marker.c`, cmpctmalloc, `xmake.lua`)
- `toolchains/ec618/ec618_config.h`
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
  slot toolchain, land in-slot.
- Slot compiler upgrades remain possible, but are pre-release qualification
  work rather than part of the initial toolchain contract.

## Toolchains

- Base: the xmake-pinned arm-none-eabi GCC 10.3 (`EC618_GCC_PATH`) — the
  base's bytes do not depend on the PATH compiler at all.
- Slot: the same xmake-pinned arm-none-eabi GCC 10.3 selected by
  `EC618_GCC_PATH`. The build passes that explicit toolchain root through
  xmake, CMake, the slot link, and ELF utilities. A newer GCC or Clang needs
  separate ABI, runtime, linker, relocation, and hardware qualification.

## Fingerprints and per-rig state

The compatibility unit is `base.bin`, and the device checks it itself
(the base-id gate). Keeping the deployed base's artifacts per rig
(convention: `~/.cache/ec618-fp/`) remains useful for building matching
slots and for diagnosing a reject.

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

## Releases

The "EC618 base release" workflow (`workflow_dispatch`) publishes the
artifact set as an immutable GitHub release `ec618-base-vN` (named from
`toolchains/ec618/base-version`; bump it for every shipped base change):
the universal base's `{elf, bin, json-manifest}`, proven by a full slot
build with all guards before publishing. This release is a producer input,
not an artifact that an end user or flasher has to find.

To build a slot against a release, put its files in a directory as
`base.elf`/`base.bin` and:

    make ec618 EC618_BASE_DIR=<dir>

Every distributed EC618 envelope is self-contained. It carries the complete
AP image, including the exact base, the matching CP image, and the slot
relocation metadata. Envelope creation checks that the carried base identity
matches the slot before producing the artifact. A static flash therefore
never downloads or selects a base and cannot create a base/slot mismatch.

`toitlang/envelopes` owns the public supported-base list and releases one
EC618 envelope for each base on that list. The list initially contains only
the current base; another base is added when there is a concrete user need.
Old bases are not accumulated inside one envelope.

An OTA extracted from an envelope contains only its canonical slot image.
Jaguar should compare its carried base identity with the target before
transfer. Independently, the on-device OTA path rejects the slot before
activation if it does not match the installed base. Updating the base by OTA
is unsupported.

The CI job (`ci-ec618.yml`) builds base + slot + guards on every push.
