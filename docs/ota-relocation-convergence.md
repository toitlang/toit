# EC618 OTA: converging on `system.firmware` (design for review)

Status: **proposal**. The relocation engine + storage format are built and proven
(see commits up to `cce8ce5c`); this document is the plan for the remaining
*read + convergence* phase. Nothing here is implemented yet.

## Goal

Make the EC618 use the **standard `system.firmware` API** (`FirmwareWriter`,
`validate`, `rollback`, `is-validation-pending`, `firmware.map`) exactly like the
ESP32, with the dual-slot relocation hidden inside the EC618 C++. The Toit
firmware code stays architecture-agnostic (no `system.architecture` branch).

Mental model: **EC618 = a preexisting platform (bootloader + PLAT + CP behind
the fixed jump table) + our firmware**. "Our firmware" is the active VM slot —
a single position-independent image. That is the OTA unit: SHA'd, validated,
rolled back, and delta-OTA'd as one thing, just like the ESP32 app partition.

## Decisions already taken (by the user)

1. The reloc table is **embedded in the firmware image**, stored at the **tail
   of the slot** with its size as the slot's **last word** (self-locating,
   variable-size). Done: `slot_reloc_parse_trailer` / `slot_reloc_build_trailer`
   + the write path stores it (`slot_reloc_begin`).
2. Relocation is **transparent C++**: write relocates canonical→slot,
   read un-relocates slot→canonical. Done: `src/slot_reloc_ec618.{h,cc}`,
   `slot_inactive_write`.
3. **`firmware` = the active VM slot only** (not the whole AP image).
4. **Bundled containers move into the slot** (ESP32 model): the slot is one
   contiguous, self-contained, atomically-OTA'd unit.

## Canonical image vs. physical slot

There are two views of the firmware, and the distinction matters for the SHA.

**Canonical image** — what the server builds and ships, what the user can hash
themselves, what the SHA covers and what delta-OTA diffs. In the link-base
domain (slot A), table-first:

```
[ table_size : u32 ][ SRL1 reloc table ][ VM body ][ extension ]
\___________________ all of it is SHA'd; the table is part of the firmware ____/
```

The reloc table is **conceptually at the front** and **inside the SHA'd area**:
it ships in the binary the user holds, so they can compute the SHA, and the
device can verify the whole image (table included) against corruption. Table-
first also lets the device stream it: read `table_size` + table up front, then
relocate the body as it arrives.

**Physical slot** — after relocate-on-write, the same bytes localized to a slot,
with the table moved to the tail so the VM body keeps the slot origin (no
linker/boot change) and the table is self-locating from the last word:

```
__vm_a_start (= link base, 0x991000) ─┐
  [ VM body (relocated) ]  code + rodata + .init_array + .vm_entry
  [ extension           ]  bundled container images + image table + config
  [ free                ]
  [ SRL1 reloc table    ]  (variable)
  [ table_size : u32    ]  the slot's last word (self-locating)
__vm_a_start + SLOT_SIZE (0x9f1000) ──┘     (slot B identical, +0x60000)
```

The device reconstructs the canonical image (and its SHA) from the physical
slot: read `table_size`+table from the tail, un-relocate body+extension to the
link-base domain, and hash in canonical order
`SHA(table_size ‖ table ‖ canonical(body+extension))`. During an OTA it is even
simpler — the incoming stream *is* the canonical image, so the device hashes it
directly (no un-relocation) while relocating the body onto the slot.

`SLOT_SIZE` stays 0x60000 (384 KB). Body ~255 KB + extension (system snapshot
~a few KB + bundled containers) + table (~2 KB) must fit; a build-time check
enforces `body + extension + table + 4 <= SLOT_SIZE`. If bundled containers
ever overflow, we grow `SLOT_SIZE` (both slots) and shift `.slot_marker`.

## What is relocated, and what is not

**Decision: option A — one relocatable image, one SRL1 table.** Treat the whole
slot (VM body + bundled extension + container images) as a single relocatable
unit, with one SRL1 table covering every absolute pointer that lands in the
slot. This is the natural (and only correct) fit because of how EC618 runs
bundled containers:

> **Finding:** `EmbeddedDataExtension::image(n).program` is used **directly
> from flash** ([embedded_data.cc:65](../src/embedded_data.cc#L65)) — bundled
> container images run **XIP at their build-time-relocated absolute addresses**
> (`tools/firmware.toit` does `container.relocate --relocation-base=<absolute>`).
> There is no load-time relocation. So once a container moves into the slot, its
> internal absolute pointers are slot-specific and MUST be relocated when the
> slot moves — exactly like the VM body's ABS32 pointers.

So the earlier "make addressing slot-relative" idea (option B) does not work for
the image *contents*: an XIP-run image can't be "computed slot-relative", its
pointers have to be relocated regardless. Option A handles everything uniformly:

- **VM body pointers** (1903 ABS32 + 2 `__wrap_time` branches): the SRL1 table
  from `toit.elf` (`--emit-relocs`). Already handled.
- **In-slot extension/container pointers** — the image-table entries,
  `DromData.extension`, and each container image's own relocation sites (from
  `container.relocation-information`). These are written post-link by
  `tools/firmware.toit`, which therefore **extends the SRL1 table** with their
  offsets (only those whose value lands in the slot — same in-slot test as the
  VM body). The device's existing relocate-on-write / un-relocate-on-read then
  fixes them with no special cases.

**Big simplification: no VM changes for container addressing.** `embedded_data`
keeps reading absolute pointers — they are simply *correct for the active slot*
because they were relocated to it on write. The work is entirely in the envelope
tool (place the extension in-slot; merge the post-link relocations into the
SRL1 table) plus the dual-image builder. `firmware.map`'s read-path change is
separate (and still needed).

## Read path: `firmware.map` → active slot, canonical (table-first)

`firmware.map` ([primitive_core.cc:2655](../src/primitive_core.cc#L2655),
EC618 branch) currently returns the whole AP image. Change it to present the
**active slot's canonical firmware** — the same table-first image the server
SHA'd and ships: `[ table_size ][ table ][ VM body ][ extension ]`.

The slot stores those pieces in a different physical order (table at the tail,
body relocated to the front), so the read path assembles the canonical view:

- `firmware_mapping_at` / `firmware_mapping_copy`
  ([primitive_core.cc:2705](../src/primitive_core.cc#L2705),
  [:2725](../src/primitive_core.cc#L2725)) map a canonical offset to its
  physical source: the leading `[table_size][table]` come from the slot tail
  (read directly — the table is slot-independent metadata), the rest from the
  slot body+extension, **un-relocated** via `slot_reloc_apply(..., TO_CANONICAL)`
  (subtract `delta` from ABS32 words, re-encode branches). When the active slot
  is A (`delta == 0`) the body is already canonical; only the table is
  reordered to the front.
- The proxy carries `delta = active_slot_base - link_base`, the parsed tail
  table (`slot_reloc_parse_trailer`), and the body+extension extent.

Net: every reader (the integrity SHA, `firmware.map` copy, Artemis delta-OTA)
sees the **same canonical, table-included bytes regardless of which slot is
live** — so the SHA is slot-independent *and* covers the reloc table, and
delta-OTA diffs match the server's canonical image. During an OTA the device
need not assemble anything: the incoming stream already *is* this canonical
image, so it is hashed directly while the body is relocated onto the slot.

The fixed platform below the slot (bootloader + PLAT) is **hidden** from
`firmware.map` — it is the preexisting platform, not the firmware. For the cases
that genuinely need it (introspecting the PLAT version, hashing the platform to
attest it), an **optional, EC618-only** primitive in `lib/ec618` can expose a
read-only view of the fixed region, gated by a config flag
(`CONFIG_TOIT_EC618_*`) so a developer can compile it out. It stays out of the
shared `system.firmware` surface.

## Write path: `FirmwareWriter` → the inactive slot

Replace the FOTA staging path with a slot writer. The standard `FirmwareWriter`
(`lib/system/firmware.toit`) buffers to 4 KB and flushes; the EC618 provider
(`system/extensions/ec618/firmware.toit`) currently forwards to
`ota_begin/write/end` → FOTA region. Re-point it at the slot:

- `open`: pick the inactive slot, erase it (sector loop), arm relocation. The
  reloc table arrives **first** in the stream (the image is framed
  `[N][table][body+extension]`), so the writer reads `N`+table up front, calls
  `slot_reloc_begin` (which arms relocation **and** lays the tail trailer), then
  streams the body+extension through `slot_inactive_write` (relocated
  transparently).
- `commit(checksum)`: verify the canonical SHA over the slot (un-relocated),
  then `slot_stage_and_reset` (trial boot — already implemented).
- `validate` / `rollback` / `is-validation-pending`: map to the existing slot
  marker primitives (`slot_mark_valid`, `slot_mark_invalid_and_reset`,
  `slot_trial`). The esp-idf-style trial+rollback is already on hardware.
- **Delete** `ota_begin` / `ota_write` / `ota_end` and the
  `perform_ota_commit` FOTA copy-back in `toit_ec618.cc`. Restore `PRIVILEGED`
  on the slot primitives (the writer runs in the system process).

Because the firmware image is framed table-first, the writer stays a plain
**sequential** writer; the VM splits table vs body internally. This is the only
place that "knows" the EC618 image is table-first — the rest of `FirmwareWriter`
is the shared, unmodified Toit code.

## Initial full-flash image (replace `splice_dual_slot.py`)

New Toit builder (`tools/ec618/build-dual-image.toit`, replacing the Python
splice): from the slot-A `ap.bin`, the bundled extension, and `slot-reloc.bin`,
produce the flashable AP image with **both** slots populated:

- slot A = `[body+extension]` (canonical) + tail trailer.
- slot B = same, relocated `+0x60000` (reuses the *exact* relocation +
  trailer logic, validated against the slot-B link by the existing
  byte-identity check), + tail trailer.

One source image, no second link pass in the shipped flow (the slot-B link
survives only as the build-time byte-identity oracle).

## Transport / host driver

The OTA artifact is the canonical firmware framed table-first: `[N][SRL1
table][body+extension]`. The host driver (replacing `tools/ota_uart_stream.py`,
in Toit) streams it; the device's `FirmwareWriter` path does the rest. Same
artifact works for UART now and any `system.firmware`-based transport (HTTP,
cellular) later — nothing transport-specific in the relocation.

## Delta-OTA (Artemis) compatibility

Artemis diffs the **canonical** image and the device patcher reads the old image
via `firmware.map` at 32-bit-aligned offsets. Since `firmware.map` now
un-relocates to canonical, the patcher sees exactly what the server diffed; the
new canonical bytes it produces are streamed table-first and relocated on write.
Relocation is a pure boundary transform; the diff never sees slot addresses.

## Build-order change

`gen-slot-reloc` must run **before** the envelope so the table can be embedded;
the slot-B relink + byte-identity proof + C relocator test stay as the
correctness gate. The bundled extension must be built and its size known before
the slot layout check.

## Proposed increments (each reviewable, hardware-testable where noted)

1. **Dual-image builder** (Toit, replaces `splice_dual_slot.py`): from slot-A
   `ap.bin` + the SRL1 table, relocate slot A → slot B and write both slots'
   tail trailers + the active-slot marker. Current layout (extension still after
   the AP image). **Hardware:** flash the relocate-built dual image, boot A, and
   boot B via the marker — proves relocation yields a *bootable* slot B, not
   just byte-identity.
2. **Containers into the slot, option A**: `tools/firmware.toit` places the
   extension inside each slot (after the VM body) and **extends the SRL1 table**
   with the in-slot post-link pointers (image table, `DromData.extension`, each
   container's relocation sites); build-time fit check; the builder relocates the
   whole slot. No `embedded_data` change. **Hardware:** flash dual image, boot A,
   run bundled containers; boot B, run them too.
3. **`firmware.map` → active slot + un-relocate-on-read**: read path returns the
   canonical slot (VM + extension), un-relocated. Verifiable: `firmware.map` SHA
   on slot A == server SHA; on slot B == same SHA.
4. **`FirmwareWriter` → slot; drop FOTA**: re-point the provider, delete
   `ota_begin/write/end` + copy-back, restore `PRIVILEGED`. **Hardware:** OTA a
   canonical image → relocate-on-write → trial-boot B → validate; rollback path.
5. **Host transport in Toit** + docs; retire `splice_dual_slot.py` /
   `ota_uart_stream.py`.

## Future: drop the runtime jump table (Flavor B — TODO)

Replace the runtime PLAT jump table with **flash-time symbol resolution**: the
VM calls PLAT directly (no `g_plat_jt` indirection, no in-slot stubs); the
device keeps `g_plat_jt` as a flash-time symbol table (index → PLAT address),
and the OTA reloc table carries `(offset, index)` per VM→PLAT call. On flash the
device resolves each against `g_plat_jt` and bakes the `BL`. Keeps the stable
index ABI (one OTA image works across devices with different-but-compatible PLAT
builds) but with no runtime indirection, and frees the ~3 KB/slot of stubs.
Cost: a bigger reloc table, and the canonical image must keep PLAT branches in a
PLAT-address-independent placeholder form (so un-relocate-on-read / delta-OTA
re-placeholder them). Orthogonal to this convergence — a focused follow-up.

## Open decisions for you

- **Container addressing** — RESOLVED to **option A** (one SRL1 table covers the
  whole slot; the envelope tool merges in the post-link pointers). Forced by the
  finding that bundled containers run XIP from build-time-relocated absolute
  addresses (option B is infeasible for XIP-run images). For **bundled**
  (in-slot) containers only; externally installed containers live in the
  separate FlashRegistry / FDB region (`0x3CC000`) at fixed addresses and are
  unaffected by slot relocation.
- **Where the firmware SHA value lives** — the SHA now **covers the reloc table**
  (table-first canonical image). Open: store the 32-byte digest in the slot (a
  trailer field, for on-demand integrity checks) vs. only verify it at OTA
  commit against the server-provided checksum (trial-boot already gives boot
  integrity). Also: keep the `config` blob inside the canonical image (after the
  extension) — yes, it stays part of the firmware.
- **Slot size** — keep 0x60000 and rely on the build-time fit check, or grow it
  now to leave headroom for bundled containers?
