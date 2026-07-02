# EC618: the frozen-base contract — removing the jump table

Status: phases 1–3 DONE + HW-validated (2026-07-02): SRL2 (`43ea9e8a`),
jump-table removal (`8d7dfb01`), pooled dram reserve (`c254f5fd`).
Phase 4 is designed in [frozen-base-phase4.md](frozen-base-phase4.md)
(base-vN publishing, two-stage link, device-side reject).

## Goal

Build the BASE (PLAT + dispatcher + everything outside the VM slots) once,
publish it as a release artifact, and let every future firmware be a
slot-only OTA built independently of the base — at a later date, with a
different compiler, by CI. "Is this slot compatible with that base?" must
be a mechanical check, not an archaeology session.

## Why now: the couplings we measured

The 2026-06-27 system-compiler upgrade (arm-none-eabi-gcc 14.2 -> 16.1)
forced the question. Rebuilding the *unchanged* tree with GCC 16 and
diffing against the flashed (GCC 14.2) base showed:

- `load_dram` (shared RAM layout): **byte-identical**.
- `check-slot-refs`, `gen-data-reloc --check`: **pass**.
- The plat jump table: **incompatible** — GCC 16's `std::random_device`
  ctor emits an out-of-line call to `std::string::_S_copy`, a libstdc++
  symbol the table does not carry.

So the jump table was the *only* thing that turned a compiler upgrade into
a base change — and it is also the component whose flexibility promise
(new VM against an old base) never held in practice: table indices are
assigned sorted-by-name, so any symbol addition shifts them and breaks
every older base anyway (see the deep-sleep arc: one added `slpMan` symbol
shifted ~100 indices = full reflash).

The deeper observation: a device's base never changes except by reflash.
Compatibility is always "new slot vs. THE base build on the device". The
jump table's indirection buys nothing for that question — linking the slot
against the *published base's symbol addresses* answers it directly.

## The base <-> slot contract

Everything a slot build must agree on with the flashed base:

| # | Coupling | Today | Target |
|---|----------|-------|--------|
| 1 | VM->PLAT calls | JT stubs + sorted indices (`.jt_data`, 4 KB, curated) | **direct calls**, relocated by the slot table; symbol addresses from the published base |
| 2 | PLAT symbol availability | JT FORCE-INCLUDE pulls un-referenced API into the base link | keep-list in the base link (bounded by flash, not a 4 KB table) |
| 3 | Shared RAM layout | VM `.data`/`.bss` placed by the same link as the base — any VM static shifts base-visible RAM | **fixed-size reserved region** for VM `.data`/`.bss` (+ headroom, build ASSERT) |
| 4 | Slot geometry, `.vm_entry`, marker protocol, per-slot `.data` header | checked-in linker constants | unchanged; versioned with the base artifact |
| 5 | Compatibility check | host-side fingerprint discipline (`/tmp/fp_ref.elf`) | fingerprint embedded in base + OTA payload; **device rejects** a mismatch |

Residual events that still require a new base release: a slot needing a
PLAT symbol the base didn't link (keep-list miss), or exceeding the RAM
reserve. Generosity in both makes these rare; nothing makes them
impossible.

## Phases

### Phase 1 — relocation-table straddle fix (prerequisite, this change)

With the JT gone, every VM->PLAT call site (~1140 in the current image)
becomes a Thumb-branch relocation in the dual-slot table. Thumb sites are
2-aligned, so one can land at `sector_end - 2` and straddle the 4 KB
chunks the device writes — the case the chunked applier rejects today
(`slot_reloc_apply`: "Straddles") and the latent bug that blocked a June
layout. At ~1140 sites the expected number of straddling sites per layout
is ~0.6: it stops being a freak layout accident and becomes routine.

Fix: bump the table format to **SRL2**. Thumb sites that straddle a 4 KB
sector boundary (`offset % 0x1000 == 0xffe`, classified at build time) move
to a third stream whose entries carry the site's **4 canonical bytes**
inline:

```
[ 'S' 'R' 'L' '2' ]
[ link_base ][ slot_size ][ body_size ]        (u32 LE)
[ abs32_count ][ thmbl_count ][ data_size ]    (u32 LE)
[ straddle_count ]                             (u32 LE, header now 32 B)
[ abs32 offsets:    delta-varints ]
[ thmbl offsets:    delta-varints ]            (non-straddling sites only)
[ straddle entries: delta-varint offset + 4 canonical site bytes, each ]
```

With the canonical bytes in the table, the applier computes the full
relocated site without needing bytes from a neighbouring chunk and writes
whichever half falls inside the current window — stateless, both
directions, any window split. Cost: 5–6 bytes per straddling site (a
handful per image).

SRL1 is not accepted (no fleet exists; the flashed device is updated by
the phase-2 full flash, which carries the new parser).

### Phase 2 — remove the jump table

- Drop the `--redefine-syms` objcopy pass, `plat_jt.c`, the `--wrap`
  ldflags block, `gen-plat-jt.toit`, and the `.jt_data` region.
- VM->PLAT calls link directly; `gen-slot-reloc` (which diffs the slot-A
  and slot-B links) picks the ~1140 branch sites up automatically; the
  byte-identity oracle stays the correctness guard.
- Retire `check-slot-pic` (its invariant — no branch leaves the slot — is
  deliberately gone). `check-slot-refs` (no fixed word points INTO the
  slot) remains.
- Keep-list: PLAT API that future slots may need but the current image
  does not reference (the old FORCE-INCLUDE/ALWAYS-INCLUDE surface) is
  pulled into the base link via `-Wl,--undefined=<sym>` flags generated
  from a checked-in list.
- The manually-wrapped RTC-backed libc time shims (`__wrap_time` etc.)
  are unrelated to the JT and stay.

One full reflash of the rig lands phases 1+2 together.

### Phase 3 — RAM reserve

Linker-script regions of fixed size for the VM's `.data` and `.bss`
contributions, with headroom, ASSERT-checked. Base symbols placed after
the reserve stop moving when the VM's RAM use changes. This is what makes
compiler upgrades and normal VM development slot-only *by construction*
(the GCC-16 measurement showed we currently get this only by luck of the
sources).

### Phase 4 — two-stage link + published base

- Stage 1 (rare): link + publish the base (`base.bin`, `base.elf`, the
  linker-script geometry version, the reserve budget, the fingerprint).
- Stage 2 (every firmware): link the VM archives against
  `--just-symbols=base.elf` inside the frozen geometry; any compiler; the
  slot carries its own compiler's runtime bits in-slot.
- Embed the base fingerprint in every OTA payload; the device REJECTS a
  mismatched slot write instead of faulting later.

## What this deletes

`tools/ec618/gen-plat-jt.toit`, `plat_jt_redefine.txt`,
`plat_jt_ldflags.lua`, `toolchains/ec618/project/src/plat_jt.c`,
`tools/ec618/check-slot-pic.toit`, the objcopy rewrite step, the 4 KB
`.jt_data` region, ~480 16-byte in-slot stubs — and the whole class of
"new libstdc++/libgcc escape breaks the build" failures that every
toolchain bump would otherwise reproduce.
