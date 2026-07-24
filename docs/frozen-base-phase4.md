# EC618 frozen base, phase 4: two-stage linking + the published base

Status: implemented. Phases 1–3 are HW-validated: SRL2 straddle handling
(`43ea9e8a`), jump-table removal (`8d7dfb01`), and the pooled VM DRAM reserve
+ pinned heap start (`c254f5fd`). This phase made the base a versioned
artifact — **base-vN** — that slots link against independently, with the
device refusing a mismatched slot instead of faulting.

## Why two links

Before this phase, base and slot were one link. Phases 1–3 removed most
couplings, but the mixed-compiler experiment exposed the one a single link
cannot fix: **C++ comdat spill**. Which libstdc++ helpers the VM emits as
in-slot comdats versus imports from the base differs per compiler (GCC 16 emits
`_S_copy_chars` itself; GCC 14 imports it), so the base's libstdc++ content
— and everything placed after it — depends on the slot's compiler. Separate
links break that dependency structurally: the base exports **no C++ runtime
symbols at all**, and every slot carries its own compiler's runtime in-slot.

## Stage 1 — the base link (rare; produces base-vN)

Inputs: the PLAT SDK (pinned GCC 10.3, as today), the base project sources
(`toit_main.c`, `bsp_custom.c`, `plat_keep.c`, `slot_marker.c`,
`sys_ro_override.c`, cmpctmalloc), and **no VM archives**.

Changes from today:
- `plat_keep.c` drops its mangled C++ entries (the `_ZN*` string/
  `random_device` family) — slots bring their own. The C-symbol surface
  (PLAT drivers, libc, libm, `__aeabi_*` from the base's libgcc) stays.
- The base no longer carries a VM `.data` init image at all: `.vm_dram_data`
  has no base-side LMA, the `__vm_data_load` fallback dies, and a slot
  without a per-slot `.data` region is a **fatal boot error** (every image
  produced since the per-slot-data fix carries one).
- A `.base_id` record lands at a fixed flash address — the freed jump-table
  page at `0x990000` is the natural home:
  `{ magic, version N, fingerprint }`, where the fingerprint hashes the base
  flash bytes outside the slot regions. Readable by the device (the reject
  check, an `ec618.base-id` primitive) and by tools.

The published artifact set for base-vN:

| File | Purpose |
|---|---|
| `base-vN.elf` | symbol source for slot links (`--just-symbols`) |
| `base-vN.bin` / bootloader + CP | the flashable base image |
| `base-vN.manifest` | geometry: slot origins/sizes, link base, reserve budgets, keep-list hash, fingerprint |

## Stage 2 — the slot link (every firmware)

A slot-only linker script (the `.vm_a`/`.vm_b` capture, `.vm_entry`, the VM
init_array bracket, `.vm_dram_data`/`.vm_dram_zi` at the manifest's RAM
addresses) linked with `--just-symbols=base-vN.elf` at the neutral link
base. Resolution does the right thing automatically: symbols the base
defines resolve there; everything else — including the slot compiler's
libgcc/libstdc++ helpers — is pulled from the slot's own toolchain archives
and lands in-slot.

The correctness machinery carries over unchanged in spirit:
- **Byte-identity oracle**: link the slot twice (slot-A and slot-B
  geometry) from the same objects; `gen-slot-reloc` diffs and proves the
  SRL3 table.
- `check-slot-refs` keeps guarding fixed words pointing into the slot;
  `gen-data-reloc` now extracts the per-slot `.data` init from the slot
  link (its only source — the base carries none).
- The per-slot `.data`, extension merge, envelope framing, and every OTA
  transport (mini-jag, Jaguar, Artemis) are unchanged.

## The device-side reject

The SRL table header grows a `base_id` field (SRL2 → SRL3): the base
version+fingerprint the slot was linked against. `slot_reloc_begin`
compares it with the flashed `.base_id` and refuses a mismatch with a
clean, Toit-visible error ("image built for base-v3, device runs base-v2")
— converting the entire silent-incompatibility fault class into an error
message. The tester and Jaguar surface it; a fleet manager can react to it.

This replaces the host-side fingerprint discipline (`fp_ref` diffing) as
the safety mechanism; the host check remains a convenience warning.

## Developer workflow

`make ec618` keeps working as one command: it builds the base locally
(cached; rebuilt when base inputs change) and links the slot against it —
dev friction unchanged. `make ec618-base` produces the publishable
artifact set. CI publishes base-vN on demand (this is where the porting
guide's section 24 lands); PR builds link slots against the *released*
base-vN and can therefore run on any toolchain the runner has.

## Migration steps (each its own commit; one full flash at the end)

1. Split the linker script into base + slot halves; add the two-stage
   Makefile targets; local two-stage build with the oracle green.
2. Slots carry their own C++ runtime; `plat_keep` drops the C++ entries.
   **Acceptance test: re-run the mixed-compiler experiment** — a GCC-16
   slot on the GCC-14 base must now pass base-bytes identity and validate
   on hardware. This is the go/no-go for the whole design.
3. `.base_id` + SRL3 + the device reject + `ec618.base-id` primitive +
   tester/Jaguar error surfacing.
4. The base-vN CI/publishing job + docs; retire the fp_ref discipline notes.

## Open questions / risks

- `--just-symbols` and weak symbols: base.elf's definitions win for
  anything it exports; the slot must not accidentally prefer a base C++
  symbol — guaranteed by the base simply not exporting any (step 2).
- Shared newlib state (`struct _reent`, malloc arena) stays base-owned and
  base-exported, as today.
- Veneer risk is unchanged (link base stays `0x00D00000`); the oracle
  catches any asymmetry.
- The bootloader and CP image version with the base artifact; a base-vN
  bump is always a full flash, by definition.
