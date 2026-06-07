# EC618 OTA: converging on `system.firmware` (design + status)

Status: **shipped.** The relocation engine, storage format, and the full
`system.firmware` convergence are implemented and hardware-validated on
quirky-plenty (slot A and the relocated slot B both reach `running on EC618 @
204MHz`; A↔B OTA soaks pass in both directions). All five increments below are
done — see the increment list:

- **#1** dual-image builder, **#2** bundled containers into the slot,
- **#3** `firmware.map` un-relocate-on-read, **#4** `FirmwareWriter`
  relocate-on-write (+ FOTA path deleted), and
- **#5** host transport: the live path is the standard Jaguar / `system.firmware`
  flow (write **and** read are canonical-domain). The legacy Python
  `splice_dual_slot.py` / `ota_uart_stream.py` and the `uart-ota.toit` receiver
  remain checked in only as **dead code, pending deletion**.

So the EC618 uses the standard `system.firmware` API end to end — `FirmwareWriter`
(relocate-on-write) going in and `firmware.map` (un-relocate-on-read) coming out —
exactly like the ESP32, with the dual-slot relocation hidden in the EC618 C++.
The prose below is the design rationale, written forward-looking but now
implemented. The one item still open is end-to-end **Artemis delta-apply**, which
*uses* the canonical read path (#3) but is not yet wired.

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
domain — the image is linked once at a **neutral base** (`__vm_link_base`,
0x01000000) that is NEITHER slot, so EVERY slot (including slot A) is relocated
to its flash address; slot A is not a privileged "delta 0" canonical — table-
first:

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
__vm_a_start = 0x991000  (slot A flash addr; the image is linked at the
                          neutral __vm_link_base and relocated to here) ─┐
  [ VM body (relocated) ]  code + rodata + .init_array + .vm_entry
  [ extension           ]  bundled container images + image table + config
  [ free                ]
  [ SRL1 reloc table    ]  (variable)
  [ table_size : u32    ]  the slot's last word (self-locating)
__vm_a_start + SLOT_SIZE ──────────────────────────────────────────────┘
                                            (slot B identical, +SLOT_SIZE)
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

> **TODO / future (delta-OTA):** option A bakes containers at slot-A addresses
> and merges their pointer sites into the SRL1 (delta-shift). The cost: when the
> VM body grows and shifts a container, that container's canonical bytes change,
> so delta-OTA re-transmits it **even if it's unchanged**. Keeping bundled
> containers in their **native position-independent bitmask form** instead —
> exactly like programs-partition containers (`ImageOutputStream` /
> `RelocationBits`), baked to the in-slot address by the device's image
> relocator, with the bitmap stored in the relocation trailer — makes an
> unchanged container's canonical bytes position-independent, so delta-OTA skips
> it. We start with A because it's one uniform mechanism and matches the ESP32
> firmware-image shape; the bitmask approach is a worthwhile later optimization
> for stable bundled apps over cellular delta-OTA. (The VM body can't use bits —
> it has Thumb branches that aren't single-word pointers — so this only applies
> to the container pointers.)

## Relocation completeness: THREE regions (2026-06-04)

The image is linked once at slot A's base, so slot A is the "canonical" image
and `delta == 0` when writing slot A. The trap (Florian): a slot pointer that is
**missed** by relocation stays at its slot-A value, which on slot A is *valid* —
so A→B always works, reads on B "work", and only **B→A** (the one direction that
erases slot A) explodes. Three regions hold slot pointers; the original design
only relocated the first, so B→A hard-faulted until all three were covered:

1. **VM body** (`.vm_a`) — the SRL1 table (`--emit-relocs`), applied
   relocate-on-write. Verified by `gen-slot-reloc --verify-slot-b` (byte-identity
   against an independent slot-B link).
2. **In-slot extension** — pointer-offsets merged into the SRL1 table by
   `tools/firmware.toit`. `--verify-slot-b` does **not** cover it, so a new
   `[ext-verify]` self-check (`verify-ec618-extension-relocation_`) builds the
   extension at slot B too and asserts `relocate(A) == B` byte-for-byte. (This is
   exactly Florian's debug method: build an independent slot-B image and diff
   `relocate(A)` against it — any difference is a missed/misaligned pointer.)
3. **Shared writable `.data`** (`.load_dram_shared`) — the interpreter's
   computed-goto `dispatch_table` and the per-module `*_primitives_` pointers.
   PLAT loads this RAM **once** from a fixed flash image (the link slot's
   data-init), and the per-slot SRL1 relocation never touches it, so these ~141
   words are slot-A forever. On a slot-B boot the interpreter therefore ran
   slot-A code, and a B→A OTA self-erased the code it was executing. Fix:
   `tools/ec618/gen-data-reloc.toit` extracts the linker's
   `.rel.load_dram_* → .vm_a` records into `src/toit_data_reloc.c`;
   `relocate_data_slot_pointers()` (toit_ec618.cc `start()`) adds
   `active_slot_base − link_base` to each word at boot, before any static
   initializer or the interpreter runs (no-op on the link slot). `make ec618`
   guards staleness with `gen-data-reloc.toit --check`.

A separate, related hazard (Option M): the in-slot `__wrap_<sym>` jump-table
stubs are reached by **PLAT/RAM-resident code** too (because `-Wl,--wrap` is
global), resolved to the absolute slot-A copy — so a context switch mid-B→A-erase
calls an erased stub → undefined-instruction fault. Fixed by wrapping **only the
VM archive** (`objcopy --redefine-syms`) and dropping `--wrap` from the final
link, so PLAT calls the real functions and never branches into a slot. The VM
still calls its in-slot stubs, so the SRL1 table is unchanged.

> **The clean future direction (Florian):** relocate **every** slot from a
> neutral base — no slot is "canonical". Then a missed/misaligned relocation
> fails loudly on slot A too, and "no word in slot B may point into slot A"
> becomes a hard, checkable invariant instead of a latent B→A-only fault.

## Completeness, the fourth concern: the FIXED side (2026-06-07)

The three regions above are all places that **do** get relocated. The dual
invariant — the one nothing checked — is the **fixed** side: PLAT `.text`, the
jump table, `.init`/`.fini`, every allocated section the device loads once at its
link address and **never** relocates. A pointer into the slot from any of those
is fixed at link time, so after OTA it resolves to the wrong slot — or, with the
neutral base, an unmapped `0x01xxxxxx` VMA — the same invisible class of fault,
on the side no relocation can rescue. A whole-ELF relocation scan (every
allocated section, which words resolve into the slot's link range) found two:

- **VM static constructors leaked out of the slot.** The PLAT `.text` rule used
  `*(.init*)`, and the glob `.init*` matches `.init_array` too — so PLAT `.text`
  **stole** the VM archives' `.init_array` before the `.vm_a` `KEEP` could claim
  it. Net: `__vm_init_array` was empty, `run_static_initializers()` ran nothing
  (the 6 `_GLOBAL__sub_I_*` constructors — `ec618_primitives_`,
  `flash_primitives_`, `GcMetadata`, `EntropyMixer`, `MbedTlsResourceGroup`,
  `ProgramUsage` — never ran, masked only because those globals tolerated it),
  and the leaked init_array pointers sat in fixed PLAT memory aiming into the
  slot. Fix: `EXCLUDE_FILE` the VM archives from `*(.init*)` (mirroring the
  `.text`/`.rodata` rules), so the init_array lands in the slot, runs via
  `run_static_initializers()`, and is relocated by the SRL1 table — whose ABS32
  count rose by exactly those 6 (1907 → 1913).
- **`operator new(nothrow)` reached from fixed code.** PLAT-resident
  `__cxa_thread_atexit` (libstdc++) calls the slot's `operator new`. That path is
  dead (the VM registers no `thread_local` with a non-trivial destructor, so
  `__cxa_thread_atexit` is never invoked), so it is allow-listed rather than
  relocated — PLAT cannot be relocated. If it ever goes live it must be
  eliminated (e.g. a VM-side `__cxa_thread_atexit` stub), not allow-widened.

`tools/ec618/check-slot-refs.toit` makes this a hard build-time invariant
(`make ec618`): it reads the retained relocations and **fails** if any allocated,
non-relocated section references the slot, except the allow-set. It is the exact
dual of `check-slot-pic.toit` (which guards slot→outside escapes). HW: slot A
boots with the constructors now running + 4/4 A↔B OTA soak.

### The jump table is the VM↔PLAT ABI — keep it generous (2026-06-07)

The flip side of "no fixed word may point into the slot" is how the slot reaches
the fixed side: every VM→PLAT call goes through `g_plat_jt[]`, a `const` table at
a FIXED flash address (`.jt_data`). It is baked at PLAT-build time and — because
the whole point of dual-slot OTA is that PLAT is NOT reflashed — effectively
FROZEN: a future firmware OTA'd into a slot can only reach PLAT functions that
already have a table entry. So `tools/ec618/gen-plat-jt.toit` includes, in
addition to the symbols the current VM calls (derived from the VM archives' call
relocations), a curated "always-include" API surface of likely-useful PLAT
functions — `BSP_`/`GPIO_`/peripheral drivers/`slpMan`/power/clock/flash/RTC/
`luat_`/`__aeabi_` plus libc/libm — restricted to functions PLAT already DEFINES.
Exposing an already-linked function is cheap (a 4 B table slot + a 16 B in-slot
stub, no PLAT growth); the modem/USB/IP stack internals (`Cerrc*`/`Asn*`/`usb*`/
`tcp`…) are deliberately excluded. Bound: `.jt_data` is 4 KB ≈ 1024 entries; the
table is 456 (181 relocation-derived + the curated set). Indices come from sorting
the final set, so changing the set reshuffles them — a future firmware must be
built against the SAME `plat_jt.h` that matches the flashed `g_plat_jt[]`. HW:
boots + 4/4 A↔B OTA soak.

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

1. **Dual-image builder** (Toit, replaces `splice_dual_slot.py`) — **DONE.**
   From slot-A `ap.bin` + the SRL1 table, relocate slot A → slot B and write the
   active-slot marker. **Hardware:** the relocate-built dual image boots both
   slots — proven a *bootable* slot B, not just byte-identity.
2. **Containers into the slot, option A** — **DONE + HW-validated.**
   `tools/firmware.toit` places the extension inside the slot (after the VM body)
   and **extends the SRL1 table** with the in-slot post-link pointers (image
   table, `DromData.extension`, each container's relocation-bitmap sites); the
   merged table rides at the slot tail; build-time fit check; `build-dual-image`
   relocates the whole slot. No `embedded_data` change. **Hardware:** slot A and
   relocated slot B both reach `running on EC618` and run the in-slot system
   container stably. NOTE: this makes `firmware.map`'s EC618 range stale and the
   old FOTA path non-functional until #3/#4 (neither is boot-load-bearing).
3. **`firmware.map` → active slot + un-relocate-on-read** — **DONE + HW-validated.**
   The read path returns the canonical slot (VM + extension), un-relocated, via
   `SlotFirmware` (`src/slot_reloc_ec618.{h,cc}`) wired through
   `ec618_active_firmware_open/at/copy` into `firmware.map` (primitive_core.cc,
   EC618 branch). `unrelocate_window` is straddle-safe (Thumb-branch sites are
   2-aligned and can cross a 4-byte boundary, so each is re-encoded from the full
   4 bytes). **Hardware:** a bundled container SHA-256s `firmware.map` at boot and
   prints the SAME canonical hash on slot A and slot B — `firmware.map` is
   slot-independent on real silicon (integrity SHA + Artemis delta-OTA match
   regardless of the live slot).
4. **`FirmwareWriter` → slot; drop FOTA** — **DONE + HW-validated.** The standard
   FirmwareWriter streams the canonical image to the inactive slot via
   relocate-on-write (`slot.reloc-begin` + `slot.write-inactive`), `commit`
   verifies the canonical SHA + `slot.stage` (no reset), and the provider maps
   `validate`/`rollback`/`is-validation-pending` to the slot marker. New
   `slot_stage` primitive; `slot_reloc_begin` made OTA-write-safe (body & trailer
   in disjoint sectors + tail erase); `PRIVILEGED` restored; FOTA
   `ota_begin/write/end` + `perform_ota_commit` deleted. **Hardware (self-OTA
   container):** boot A → relocate-on-write ~390 KB into slot B → stage →
   `firmware.upgrade` → trial-boot B → running → `validate` → steady state ✓;
   and a refused trial → automatic rollback to slot A ✓. Bonus: the ~390 KB write
   ran modem-on with no reset, and an OTA interrupted by the post-flash POR
   safely retried. Optional later: fold the write-path statics into the slot
   abstraction.
5. **Host transport + docs** — **DONE (cleanup pending).** The live OTA transport
   is the standard `system.firmware` path driven by Jaguar (`jag firmware update`
   over HTTP/WiFi or UART), and any future `system.firmware` transport (cellular)
   reuses the same canonical artifact. The legacy Python `splice_dual_slot.py` /
   `ota_uart_stream.py` and the `uart-ota.toit` receiver + the out-of-slot
   extension path are superseded; they remain checked in only as dead code, to be
   deleted (checked-in scripts must be Toit, and the build must not depend on
   Python).

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
