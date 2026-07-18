# EC618 Partition Table — Design Brainstorm

> Status: **brainstorm / not yet implemented.** This is a thinking document
> for a future agent (or human) picking up "partition support" on the EC618.
> It captures the facts, the reclaim analysis, design options with their
> trade-offs, the risks, and a concrete incremental plan. Nothing here is
> committed — challenge it.
>
> **Layout note (updated 2026-07-16, post frozen-base):** the flash-map
> specifics below are kept for the *reasoning*; the live geometry is
> toolchains/ec618/partitions.yaml (the descriptor IS the map now —
> base-v2: base-id 0x990000, anchor record 0x991000, slot A 0x993000,
> slot B 0xA53000, free 0xB13000, littlefs 0xB84000 (kept, §0.2),
> registry 0xBCC000, vendor NVRAM band from 0xBDC000).
>
> The jump table is replaced by the **frozen-base architecture**: slots are
> linked separately against the published `base.elf` (two-stage link), carry
> SRL3 relocation tables (relocate-on-write to either slot), and the device
> rejects slot OTAs whose base-id (version + fingerprint at 0x990000) does
> not match — see [ec618-base-image.md](ec618-base-image.md). Linker
> template: `ec618_0h00_flash.c` (preprocessed C, not `.ld`).
>
> **Consequences for this document:** (a) the SRL3 relocation machinery makes
> *floating slots* (§6.3) far more natural — a slot image can already be
> retargeted to any address in the veneer-free range at write time; (b) any
> change to the linker template, dispatcher (`toit_main.c`), guard
> (`sys_ro_override.c`) or `slot_marker.c` is a **BASE change** — a base
> version bump + full reflash of both rigs — so Phase-1 adoption in those
> files must be batched with the next base bump (together with, e.g., the
> known-issues #13 TX-descriptor work). Slot-side consumers
> (`primitive_ec618.cc`, `flash_registry_ec618.cc`, `lib/ec618/slot.toit`)
> are OTA-able and can adopt the descriptor first.
>
> **Live proof of the §6.6 hazard (found 2026-07-16):** `toit_main.c` still
> defines `TOIT_VM_SLOT_SIZE 0x60000` (384 KB) while the linker template
> moved the slots to 768 KB (`0xC0000`) — the dispatcher's entry-point
> validation window is silently half a slot. Benign only because entry
> points sit near the slot start. Fix with the base bump; do not fix alone.

## 0. DECIDED design (2026-07-16, Florian) — supersedes the options below

The brainstorm sections are kept for reasoning; the decided shape is:

1. **Firmware and partition table are independent artifacts.** One published
   envelope works with any compatible table — users choose layouts (more
   program vs more data) at provision time. This is real on the EC618
   because the envelope carries the canonical VM image + SRL3 relocation
   table: the writer retargets it to whatever slot addresses the table
   declares (the same machinery every OTA uses). Compatibility at write
   time = base-id match (exists) + image-fits-declared-slot (trivial).
2. **The table lives in the ANCHOR RECORD** (the A/B two-sector record
   at the anchor) — { seq, crc, boot state, table[] }. Boot state and
   layout are one atomic, power-fail-safe unit, flipped together:
   rollback restores layout AND image. (ESP-IDF-like table, but A/B and
   co-committed — their single fixed table region cannot do either.)
3. **Anchor directly after the base image.** Base ends below 0x990000
   (frozen ABI), base-id page at 0x990000, anchor record at
   0x991000..0x993000 (base-v2; the old post-slot-B location existed for
   base-image flexibility that the frozen-base contract retired). The
   fixed spot is what makes the record findable without a table.
   Everything ABOVE the anchor is table-described (slots, registry, user
   data, free) up to the vendor NVRAM band at 0xBDC000; everything
   below/around is fixed vendor/base territory, included in the table as
   locked entries for tooling visibility.
4. **Provisioning, NO defaults (Florian):** the base embeds NO table —
   gen-anchor.toit bakes the descriptor into the anchor record and
   splices it into the flashable AP images (`make ec618`), so every
   fresh flash carries a valid record. A device whose anchor is missing
   or corrupt CANNOT boot: the dispatcher halts loudly instead of
   guessing (the ping-ponged record makes power loss unable to cause
   this). Custom layout = a different descriptor given to gen-anchor at
   provision time; the canonical image is relocated to whatever slot
   addresses the record declares.
5. **Entry format: SIMPLE** (Florian: do not duplicate the complicated
   ESP32 table). A YAML source file (name, offset, size, type — nothing
   more; a handful of types: locked / base / base-id / anchor / slot /
   data / free) and a correspondingly minimal packed record (0.1).
   `offset` is optional in the YAML: an entry without one starts where
   the previous entry ends, so the chain after the base (base-id, the
   anchor record, slots, free) is never pinned numerically — a future
   base-vN size change is a one-line `size:` edit that reflows
   everything after it (Florian: don't hard-code the anchor "too much").
   Explicit offsets mark external constraints (boot ROM, SDK, live
   on-flash data) and double as assertions that the chain still lands on
   them. Host tools read the descriptor via tools/ec618/partitions.toit;
   nothing on the device compiles the layout in (see 0.1) — the linker
   template's frozen literals are the one exception, and gen-base-id
   refuses to stamp a base whose symbols disagree with the descriptor.
6. **OTA resize: later.** The record flip already gives the atomic
   swap; until a power-fail-safe data-migration journal exists, the
   writer REFUSES table changes that move or shrink a non-empty data
   partition. The registry is movable-in-principle behind that guard.
   **Acceptance test — PASSED 2026-07-19 on quirky-plenty:** slots moved
   +0x1000 via tests/hw/ec618/partitions-shifted.yaml + provision.toit;
   the device booted the moved slot A from the record, the agent came up
   on the record-provisioned console (UART1), and a full OTA cycle
   staged, trial-booted and VALIDATED the moved slot B — the complete
   table-driven dual-slot machinery on a non-default layout.
   (Hard-won test-harness lesson: `make`'s envelope carries ONLY the
   bare system container — mini-jag/sleeper are injected by the tester's
   flows. An image provisioned straight from toit.binpkg has NO agent:
   silence is not death. Build acceptance images via the tester's
   add-ec618-containers recipe.)
7. **Phasing:** the descriptor + host tooling landed first against the
   CURRENT layout (byte-identity validated). The anchor record, the
   table-driven dispatcher, the VM's runtime geometry lookups, the
   anchor move and the toit_main.c 384KB-drift fix land together in the
   base-v2 bump — a HARD cutover: slots built from HEAD link against
   base-v2's anchor ABI and no longer run on base-v1 rigs (the base-id
   gate enforces exactly this). LFS reclaim is deferred out of the bump
   entirely (0.2).

### 0.1 The anchor record — binary format (DECIDED 2026-07-16)

Terminology: "the anchor" is the fixed location directly after the base
image; "the anchor record" is the two-sector, ping-ponged record living
there (toolchains/ec618/project/{inc/anchor.h,src/anchor.c}). One record
= header + table entries + trailer, all sizes multiples of 16 (the flash
write segment), so any entry count writes cleanly and the CRC lands in
the final segment (written last → a torn write is detected):

    header (16 bytes):
      0   u16  magic 'T','A' (0x4154)
      2   u8   version = 2
      3   u8   state                       (SLOT_STATE_*)
      4   u32  seq                         — higher valid record wins
      8   u8   active   'A'/'B'
      9   u8   pending  'A'/'B' or 0
      10  u8   table_count N               (0 = no table)
      11  u8   console                     (0/1/2 = console+control UART;
                                            0xff = no redirect)
      12  u8[4] reserved (0)
    entries (N x 32 bytes), flash order:
      0   char name[16]                    — NUL-padded
      16  u32  offset                      — RAW flash address
      20  u32  size
      24  u8   type   (1=locked 2=base 3=base-id 4=anchor 5=slot 6=data 7=free)
      25  u8[7] reserved (0)
    trailer (16 bytes):
      0   u32  crc32 over header+entries (poly 0xEDB88320)
      4   u8[12] pad (0xff)

The two-sector ping-pong, higher-seq-wins and write-the-other-sector
rules carry over from the v1 slot marker. There is NO fallback anywhere:
`anchor_table` returns 0 for a missing/corrupt record or one without a
table, and the dispatcher then halts with a periodic console message —
provisioning (gen-anchor.toit, run by `make ec618`) is what puts the
record on flash. `anchor_write` keeps the 3-argument boot-state-flip
signature and PRESERVES the stored table; `anchor_write_table` sets
state+table atomically (the layout-change path). Consumers:

- The DISPATCHER boots from the active table's `slot` entries (first =
  'A', second = 'B'). The `__vm_a_start`/`__vm_b_start` linker symbols
  remain as the link-time reservation only.
- The VM reads everything at runtime over the frozen ABI: slot bases and
  size via `anchor_table` (slot-size primitive included), the flash
  registry by locating the `registry` data entry, and the base-id page
  via the exported `__toit_base_id_start` symbol. Nothing layout-shaped
  is compiled into the slot image.
- Host tools read partitions.yaml directly (tools/ec618/partitions.toit);
  the fault-injecting host test (tools/anchor_test, wired into
  `make ec618`) proves the record rules AND validates gen-anchor's bytes
  through the real device reader.

### 0.2 LFS reclaim — DEFERRED out of base-v2 (2026-07-16)

Disassembly of the linked base shows `mainTask` calls `LFS_init` at
every boot and the SDK's OSA config layer (`OsaFopen`,
`OsaGet/SetFlashValue`) stores its values in that littlefs — live PLAT
middleware state, likely modem-adjacent, and the port FORMATS the region
on mount failure. Reclaiming 0x384000..0x3CC000 is therefore not a
"delete the mount" edit; a careful shrink (measure OSA's real usage
first) can be its own change later. base-v2 keeps `littlefs: locked`.

Follow-up measurement (2026-07-18): the linked base configures LittleFS as
72 × 4 KB blocks (288 KB). Direct call-site inspection finds the live OSA
users `plat_config` and `timer_values`. A read-only XIP scan on
`quirky-plenty` found 16 non-erased blocks, spread across indices
`0,1,3,4,12-15,17-23,62`. The high block is the expected consequence of
LittleFS wear-leveling and means that lowering `FLASH_FS_REGION_END` is not an
in-place shrink: the filesystem must be migrated or deliberately reformatted.
The 64 KB Toit registry next to it is separate from LittleFS.

Throughout, "partition" is used loosely for the hardcoded flash regions the
EC618 image carves out today. It is not (yet) a real partition table; that is
what this document is about building.

## 1. Background

We just shipped dual-slot OTA with esp-idf-style trial boot + automatic
rollback (see [`ota-dual-slot-plan.md`](ota-dual-slot-plan.md)). The Toit
VM lives in two slots (`.vm_a` / `.vm_b`, 384 KB each) and the known-good /
trial state is tracked in a power-fail-safe `.slot_marker` region (two 4 KB
sectors, sequence-numbered + CRC). Each OTA-state record uses one 4 KB flash
page so a valid record can always be read back after a torn write.

Two ideas motivated this document:

1. Use the *remaining* flash for a partition table — but first we need real
   partition support, because the EC618 image has **no partition table**: the
   flash layout is a set of hardcoded `#define`s.
2. Put the partition table inside the active slot's flash so the **table
   itself** can be updated OTA — e.g. to resize the base image if it grows.
   Even ESP-IDF can't safely OTA-update its partition table; we might.

## 2. The current layout (hardcoded constants)

The authoritative map is the vendor header
[`mem_map.h`](../third_party/luatos-soc-ec618/PLAT/device/target/board/ec618_0h00/common/inc/mem_map.h)
(it even draws the layout as ASCII art in its header comment). All addresses
come in two flavors: **raw** (`0x000000`-based, used for erase/write) and
**XIP** (`+0x800000`, the AP's memory-mapped/execute-in-place view).
`AP_FLASH_XIP_ADDR = 0x00800000` is the offset between them.

The build runs with `__USER_CODE__` defined, which sets
`AP_FLASH_LOAD_SIZE = 0x2E0000` (2.875 MB) — this absorbs the 384 KB `resv1`
gap into the AP image. (Confirmed by the `_Static_assert` in
[`sys_ro_override.c`](../toolchains/ec618/project/src/sys_ro_override.c).)

### AP flash (4 MB) as Toit sees it

| Raw addr | XIP addr | Size | Region | Defines (`mem_map.h`) | Used by Toit? |
|---|---|---|---|---|---|
| 0x000000 | — | 8 KB | header1 | `BLS_SEC_HAED_ADDR` | fixed (flasher) |
| 0x002000 | — | 8 KB | header2 | `SYS_SEC_HAED_ADDR` | fixed (flasher) |
| 0x004000 | 0x804000 | 128 KB | bootloader | `BOOTLOADER_FLASH_LOAD_ADDR`/`_SIZE` | fixed |
| 0x024000 | 0x824000 | 2.875 MB | **AP image** (see carve below) | `AP_FLASH_LOAD_ADDR`/`_SIZE` | **yes** |
| 0x304000 | 0xb04000 | 512 KB | **FOTA** | `FLASH_FOTA_REGION_START`/`_LEN`/`_END` | **no** (LuatOS only) |
| 0x384000 | 0xb84000 | 288 KB | **LittleFS** | `FLASH_FS_REGION_START`/`_END`/`_SIZE` | SDK storage, mounted at boot |
| 0x3cc000 | 0xbcc000 | 64 KB | **FDB = flash registry** | `FLASH_FDB_REGION_START`/`_END` (SoftSIM disabled, size 0) | **yes** (storage) |
| 0x3dc000 | 0xbdc000 | 16 KB | NVRAM factory | `NVRAM_FACTORY_PHYSICAL_BASE`/`_SIZE` | modem (RF cal) |
| 0x3e0000 | 0xbe0000 | 16 KB | NVRAM runtime | `NVRAM_PHYSICAL_BASE`/`_SIZE` | modem |
| 0x3e4000 | 0xbe4000 | 96 KB | hib backup | `FLASH_MEM_BACKUP_*` | SDK deep-sleep/PSM + Toit RTC memory |
| 0x3fc000 | 0xbfc000 | 4 KB | plat config | `FLASH_MEM_PLAT_INFO_ADDR`/`_SIZE` | SDK boot |
| 0x3fd000 | 0xbfd000 | 4 KB | reset info | `FLASH_MEM_RESET_INFO_ADDR`/`_SIZE` | SDK |
| 0x3fe000 | 0xbfe000 | 4 KB | excep key info | `FLASH_EXCEP_KEY_INFO_ADDR`/`_LEN` | SDK crash dump |
| 0x400000 | 0xc00000 | — | end of 4 MB | | |

### How Toit re-carves the AP image (linker script)

Toit does **not** use the SDK's app layout as-is. The linker script
[`ec618_0h00_flash.ld`](../third_party/luatos-soc-ec618/PLAT/core/ld/ec618_0h00_flash.ld)
defines `FLASH_AREA : ORIGIN = 0x00824000, LENGTH = 2944K` (= 0x2E0000,
ending exactly at the FOTA region) and carves it:

| XIP addr | Raw addr | Size | Section | Linker symbols | OTA'd? |
|---|---|---|---|---|---|
| 0x824000 | 0x024000 | ~1.4 MB | **PLAT base** (modem, RTOS, drivers, libc, dispatcher) | (image start) | **no** |
| 0x990000 | 0x190000 | 4 KB | jump table | `__jt_data_start`/`_end` | no |
| 0x991000 | 0x191000 | 384 KB | **VM slot A** | `__vm_a_start`/`_end` | **yes** |
| 0x9f1000 | 0x1f1000 | 384 KB | **VM slot B** | `__vm_b_start`/`_end` | **yes** |
| 0xa51000 | 0x251000 | 8 KB | **slot marker** (OTA state) | `__slot_marker_start`/`_end` | written on OTA |
| 0xa53000 | 0x253000 | — | end of used flash | `totalFlashLimit` | |

The PLAT base and VM are decoupled by a **jump table** at 0x990000: the VM
(in the slots) calls PLAT functions through it. This is what lets the small
VM be A/B'd while the large PLAT base stays fixed. From the dual-slot doc:
PLAT SDK ≈ 1180 KB (rarely changes), VM + mbedtls ≈ 250 KB (changes on SDK
updates), extension = variable (every OTA). A 250 KB VM in a 384 KB slot has
headroom; the ~1.4 MB base does not fit twice in 4 MB — hence A/B of the VM
only.

## 3. Reclaimable space

Everything Toit doesn't use sits in one band between the end of used flash
and the flash registry:

```
0x253000  totalFlashLimit (end of slot marker)   ┐
          [708 KB already free inside AP image]   │
0x304000  FOTA region (512 KB, unused by Toit)    │  ~1.5 MB contiguous,
0x384000  LittleFS    (288 KB, unused by Toit)    │  reclaimable
0x3cc000  flash registry / FDB (64 KB) — KEEP     ┘  (bounded above by registry)
0x3dc000  NVRAM / hib / plat — KEEP (modem + SDK)
```

- **FOTA (512 KB)** — referenced only by LuatOS Lua-script OTA
  (`luat_fota_ec618.c`, `LUA_SCRIPT_ADDR`) and the xmake build. Toit writes
  the VM slots directly and does its own trial/rollback, so FOTA is never on
  Toit's boot or OTA path. **Reclaimable.**
- **LittleFS (288 KB)** — live SDK storage, mounted by `mainTask` on every boot.
  Toit does not mount it directly, but PLAT stores `plat_config` and
  `timer_values` there. It is a **shrink candidate, not directly reclaimable**;
  see §0.2 and §4.1.
- **SoftSIM** — already disabled (size 0) in `__USER_CODE__`; the slot is the
  FDB registry. Nothing to reclaim.

**Reclaim total: ~800 KB (FOTA + LFS), contiguous with the 708 KB already
free → ~1.5 MB (0x253000–0x3cc000).**

**Must keep:** bootloader + headers (boot ROM jumps to fixed addr); the AP
image load address 0x824000 (SDK bootloader entry); NVRAM factory + runtime
(modem RF calibration — losing it bricks the modem); hib backup (deep-sleep);
plat/reset/excep info (SDK reads early at boot); the CP image + CP NVRAM
(separate 1 MB chip, see `mem_map.h` CP section).

## 4. Where Toit's data lives (don't lose it)

Toit's persistent storage = the **FDB region**, NOT LittleFS:

- [`flash_registry_ec618.cc`](../src/flash_registry_ec618.cc) locates the
  `registry` data entry in the active anchor table. The default descriptor
  places it at `0x003CC000` with size 64 KB. It is accessed via XIP for reads
  (`AP_FLASH_XIP_ADDR + offset`) and `BSP_QSPI_*_Safe` for erase/write.
- [`storage.toit`](../system/extensions/ec618/storage.toit) builds buckets on
  top of the registry.

Any partition scheme must preserve this 64 KB of live data across both
re-layout and OTA. It is the one data partition that already exists.

### 4.1 Registry capacity and expansion choices (2026-07-18)

64 KB is too small as a general container-and-storage partition. For a concrete
bound, the O2 HTTPS hardware test produces a 92,928-byte binary image; after
the 32-bit image relocation compaction it reserves 90,112 bytes (88 KB) in the
registry. It therefore cannot fit even when the current registry is empty.

There are two practical expansion paths:

1. **Shrink LittleFS and grow the registry downward.** Keeping 128 KB (32
   blocks) for LittleFS would move its end to `0x3a4000` and grow the contiguous
   registry to `0x3a4000..0x3dc000` = 224 KB. The current 16 dirty blocks make
   128 KB a reasonable size to test, not yet a proven production minimum.
   This needs a new base because `FLASH_FS_REGION_END` and LittleFS's block
   count are compiled into PLAT. It also needs an LFS migration/reformat plan.
   The existing registry remains at the upper end of the enlarged range, so a
   downward-only expansion may preserve its raw allocations without copying;
   that behavior still needs a power-loss-safe acceptance test.
2. **Move the registry into the existing free band.** The active table already
   has 452 KB at `0x313000..0x384000`, so this can enlarge the registry without
   touching LittleFS or changing the frozen base's filesystem constants. It is
   a data-partition move, however, and `provision.toit` correctly refuses it
   until a migration journal exists. A read-only scan on `quirky-plenty` found
   stale data in 81 of the band's 113 sectors (likely an old FOTA payload), so
   provisioning must erase the target rather than assume that `free` means
   physically erased.

Before the first public base dispatch, the first path is the simpler layout
if 224 KB is sufficient and LFS state migration is implemented. Otherwise,
keep base-v2's layout and implement general data-partition migration before
using the larger free band.

## 5. FAT / filesystem support in the SDK

- **FatFS: present, and SD-over-SPI works.** `thirdparty/fatfs/` ships ChaN
  FatFS (`ff.c`/`ff.h`/`ffconf.h`) with a **pluggable diskio** layer
  (`diskio_impl.c` registration) and a complete **SD/TF-over-SPI** backend
  ([`diskio_spitf.c`](../third_party/luatos-soc-ec618/thirdparty/fatfs/diskio_spitf.c)
  — full SD command set, built on the generic `luat_spi` + `luat_gpio`). A VFS
  adapter (`thirdparty/vfs/luat_fs_fatfs.c`) mounts it at a path.
  [`project/example_fatfs`](../third_party/luatos-soc-ec618/project/example_fatfs/src/example_main.c)
  is a working demo: `luat_fatfs_mount(DISK_SPI, spi=1, cs=GPIO27, 25.6 MHz,
  power=GPIO28, ...)` mounting a card at `/tf`. This mirrors how Toit does
  FAT-on-SD on ESP32 (SD over SPI).
- **SDIO is not an option.** `luat_sdio.h` exists but has **no
  implementation**, and there is no SDMMC/SDIO peripheral driver in
  `PLAT/driver`. SPI is the only SD path on EC618.
- **LittleFS: present, SDK-side.** `thirdparty/littlefs/` is what the SDK's
  on-chip FS region uses. Better suited than FAT for internal NOR
  (wear-leveling, power-fail robust).
- **For an SD card, FAT-over-SPI is the right choice** (PCs and other readers
  can read the card). It is a **separate concern from the internal partition
  table**: an SD card is removable external media mounted via VFS, not part of
  the flash layout (`mem_map.h`'s `SD_CARD_XIP_ADDR` is just a notional VFS
  address, not real XIP). None of fatfs/vfs/diskio is compiled into the Toit
  firmware today — using it means adding those sources to the Toit build and
  writing a Toit binding that mirrors the ESP32 FAT/SD code.
- For Toit's own *internal* storage we already have the flash registry, so no
  on-chip FS is needed there. LittleFS only becomes interesting if we expose a
  generic internal user-files data partition.

## 6. Design: an OTA-updatable partition table

### 6.1 The anchor problem

Something must run *before* the table is read, so it lives at a fixed address
and cannot itself be described by the table. On EC618 the immovable anchors
are dictated by hardware / the SDK bootloader / the modem:

- flash headers (0x0, 0x2000) and bootloader (0x4000) — boot ROM jumps there;
- the **AP image entry at 0x824000** — the SDK bootloader loads/jumps here, so
  whatever sits at 0x824000 is effectively a bootloader for the Toit side;
- NVRAM factory/runtime, plat/reset info, CP image/NVRAM — fixed addresses
  baked into the SDK and modem stack.

### 6.2 Tiered model (mirrors esp-idf bootloader / otadata / app, extended)

- **Tier 0 — frozen reader at 0x824000.** Reads the table, runs the
  trial/rollback state machine, jumps into the chosen partition. This is
  today's dispatcher
  ([`toit_main.c`](../toolchains/ec618/project/src/toit_main.c)),
  but to make the base resizable it must be **split out** of the monolithic
  PLAT runtime into a tiny, rarely-changed loader. Because it can't be
  OTA-fixed safely, it must stay minimal and well-tested.
- **Tier 1 — the partition table, stored A/B.** This is a *generalization of
  the slot marker*: the existing
  [`slot_marker.c`](../toolchains/ec618/project/src/slot_marker.c)
  already implements the exact power-fail-safe primitive we need — two
  sectors, sequence number, CRC, write-the-other-sector, read-the-higher-seq.
  Reuse that machinery for the table. An atomic sector flip activates a new
  layout together with the new image; rollback restores the old layout
  together with the old image. **That co-commit of table + image is the
  property ESP-IDF lacks** (its table is a single fixed region, no A/B, no
  atomic co-update with the app → torn table = brick).
- **Tier 2 — the partitions** described by the table: base/runtime, VM slot A,
  VM slot B, flash registry, free/staging. Code reads the table instead of the
  hardcoded constants in §7.

### 6.3 Are the A/B slots "special"? Decoupling them from PLAT

A natural question: the VM slots are bundled into the PLAT image today — are
they fundamentally part of PLAT, or can they be moved "out" so the active-slot
marker records where they actually live (and thus they can be resized)?

**They are barely coupled already, and moving them out is the low-risk,
high-value step** — much cheaper than the Tier-0 split that *PLAT* updates
would need (§6.2 / §6.5).

The VM is **already a separate link unit**: it is position-dependent code that
reaches PLAT through exactly one channel — the **207-entry jump table**
(`g_plat_jt`), the deliberate ABI boundary (see
[`ota-dual-slot-plan.md`](ota-dual-slot-plan.md) "jump table"). In the base
build, `libtoit_vm.a` + mbedtls are linked into slot B's address and slot A is
left **empty** (`__vm_a_start == __vm_a_end`); an OTA writes a VM image linked
for the inactive slot. So the slots are logically outside PLAT — what pins them
*inside* it is purely mechanical:

1. **Fixed addresses in PLAT's linker script** — `.vm_a 0x991000`,
   `.vm_b 0x9f1000`, `totalFlashLimit`
   ([`ec618_0h00_flash.ld`](../third_party/luatos-soc-ec618/PLAT/core/ld/ec618_0h00_flash.ld)).
2. **The dispatcher reading those linker symbols** (`__vm_a_start` /
   `__vm_b_start`) to locate and jump to a slot
   ([`toit_main.c`](../toolchains/ec618/project/src/toit_main.c)).
3. **The guard + primitives hardcoding the bounds**
   ([`sys_ro_override.c`](../toolchains/ec618/project/src/sys_ro_override.c),
   [`primitive_ec618.cc`](../src/primitive_ec618.cc)).

**To move them out:** make #2 and #3 read each slot's base + size from the
marker/table instead of from linker symbols. The slots then *float* and the
marker is authoritative — exactly "the active-slot flash page knows where the
data lives." PLAT, slot A, and slot B become three independent partitions
rather than sub-regions of one linked image; the build emits separate images.
The dual-slot plan already sketches this — distinct `PLAT_FLASH` / `VM_A_FLASH`
/ `VM_B_FLASH` memory regions ([`ota-dual-slot-plan.md`](ota-dual-slot-plan.md)
"Modify the xmake linker script").

**What still has to stay anchored** (everything else floats):

- **AP entry 0x824000** — the SDK bootloader jumps here; the dispatcher lives
  here and reads the table.
- **The jump-table address (0x990000)** — the VM is XIP-linked *against* it, so
  treat it as a frozen ABI constant. PLAT grows *below* it; slots float
  *elsewhere*. If PLAT ever needs to cross it, that is a breaking change
  requiring a coordinated reflash anyway.
- **The marker/table anchor** — fixed (top), so the dispatcher always finds it.

**The one unavoidable constraint is XIP:** "move or resize a slot" always means
"ship a VM image *linked* for the new address." The table records the geometry;
the image must be built to match — they are one bundle (§6.5). Freeing the slots
to float is what makes a VM that outgrows 384 KB possible without touching PLAT:
the new (larger) slot is placed in the reclaimed ~1.5 MB and the table points at
it.

**Where to store the per-slot geometry:** the existing 16-byte marker record has
a `reserved[2]` field and an otherwise-empty 4 KB sector, so slot A/B base+size
fit alongside the active/pending/state fields. Keep in mind the *active-slot*
state changes on every OTA transition while *geometry* changes only on resize —
they can share the A/B sectors as one record or as two record types, but the
geometry must live at the fixed top anchor (the anchors listed above), not
wedged after the slots where it would move when they do.

### 6.4 Where the table lives

The slot marker is at 0xa51000 today — but that is *inside* the region that
moves if the base grows. For an OTA-resizable layout the table must sit at a
**fixed top anchor** that survives resize: just below the flash registry
(0x3cc000) / the modem NVRAM band, which never move. Everything else is
expressed relative to that anchor and the fixed bottom anchor (0x824000).

Note: the table's *address* being fixed is not a limitation (ESP-IDF's table
is fixed at 0x8000 too). The feature is that the table's *contents* are
updated atomically via the A/B sectors.

### 6.5 Resizing the base, concretely

"Resize the base" has two readings; the table serves both:

- **Grow the VM slot** (VM > 384 KB): ship a new table with larger slot
  offsets/sizes + a VM image linked for the new addresses, into the reclaimed
  ~1.5 MB. Loader reads the new table, jumps to the new slot.
- **Grow the PLAT base** (~1.4 MB runtime): only possible once Tier 0 is split
  out (§6.2). Then the runtime is a partition; ship a new table + new runtime
  to the staging area; the frozen loader applies it.

In all cases, **XIP code cannot be relocated at runtime** — "resize" always
means "ship a differently-linked image whose link addresses match the new
table." The table and the image are **one bundle**; the build must produce
the image for the geometry the table declares. Enforce that they agree.

### 6.6 Cheap first win (independent of OTA-resizing)

The same flash addresses are hardcoded **independently** in at least six
places (see §7), and the build already *parses* `mem_map.h`
([`xmake.lua:595`](../third_party/luatos-soc-ec618/xmake.lua)). Even before
anything is OTA-updatable, deriving them all from a **single partition
descriptor** — read at runtime by the C/C++/Toit code and generated into the
linker script at build time — removes a class of "edit one, forget the other,
silently corrupt flash" bugs. This is the recommended first phase.

## 7. The constants/code to replace (reference index)

A partition system has to dislodge these. The vendor `mem_map.h` stays
untouched (it's the SDK's own map for regions we don't manage); these are the
**Toit-side** sites that hardcode the layout:

| File | What it hardcodes |
|---|---|
| [`flash_registry_ec618.cc:30-31`](../src/flash_registry_ec618.cc) | `FLASH_REGISTRY_PHYSICAL_OFFSET = 0x3CC000`, size 64 KB |
| [`sys_ro_override.c`](../toolchains/ec618/project/src/sys_ro_override.c) | `BOOTLOADER_END 0x22000`, `AP_IMAGE_START 0x24000`, `AP_IMAGE_END 0x304000`; the `toit_ap_image_modify_{start,end}` writable window; `_Static_assert` on `AP_FLASH_LOAD_SIZE == 0x2E0000` |
| [`slot_marker.c`](../toolchains/ec618/project/src/slot_marker.c) | `__slot_marker_start`, `MARKER_SECTOR_SIZE 0x1000`, `MARKER_RECORD_SIZE 16`, 2-sector A/B scheme |
| [`toit_main.c`](../toolchains/ec618/project/src/toit_main.c) | `__vm_a_start`/`__vm_b_start`, `TOIT_VM_SLOT_SIZE 0x60000`, slot dispatch |
| [`primitive_ec618.cc`](../src/primitive_ec618.cc) (slot primitives ~L380-440) | `SLOT_SIZE`, `inactive_slot_base()`, `AP_FLASH_XIP_ADDR`, writable-window juggling |
| [`ec618_0h00_flash.ld`](../third_party/luatos-soc-ec618/PLAT/core/ld/ec618_0h00_flash.ld) | `FLASH_AREA` origin/length; `.jt_data`/`.vm_a`/`.vm_b`/`.slot_marker` fixed addresses; `totalFlashLimit`; size ASSERTs |
| [`slot.toit`](../lib/ec618/slot.toit) | `SLOT-SIZE 0x60000`, `SECTOR-SIZE 0x1000` |
| [`mem_map.h`](../third_party/luatos-soc-ec618/PLAT/device/target/board/ec618_0h00/common/inc/mem_map.h) | the vendor source of truth (leave as-is; the build parses it) |

The **writable-window guard** is the safety-critical piece:
[`sys_ro_override.c`](../toolchains/ec618/project/src/sys_ro_override.c)
overrides the SDK's `sysROSpaceCheck`; a partition system must keep this guard
in sync with the live table so a write can never land outside the intended
partition. Per project memory, `BSP_QSPI_*_Safe` **hangs** (does not return)
when `sysROSpaceCheck` rejects — so an off-by-one in the window is not a clean
error, it's a hang.

## 8. What speaks against it

1. **Tier 0 is un-updatable.** Bugs in the frozen loader can't be OTA-fixed
   (or require a risky self-overwrite). It must be tiny and frozen, and
   splitting it out of the monolithic PLAT base is real work.
2. **Full base A/B does not fit in 4 MB.** Two copies of the ~1.4 MB runtime
   exceed the part. Base updates must use single-bank + staging (loader copies
   into place with a survivable fallback) — less safe than A/B, and it implies
   a long **modem-off** window to copy ~1.4 MB. Sustained AP-flash + UART with
   the modem on resets the chip after a few seconds (the CP real-time deadline
   documented in `slot.toit` and project memory); the copy must run with
   `appSetCFUN(0)`, sector by sector, and survive power loss mid-copy.
3. **The SDK still references reclaimed regions.** `lfs_port_task`, fota, and
   the merge tool all reference FOTA/LFS addresses even if Toit stops using
   them. Reclaiming requires auditing that nothing in the linked PLAT writes
   there, and adjusting the writable window. Get it wrong and you either
   corrupt a modem region or hang on the guard.
4. **Data migration is the classic hard problem.** Moving/resizing the
   registry (or any data partition) needs copy-then-commit plus its own
   resumable journal across many sectors. The table's A/B flip gives you an
   atomic *pointer* swap, but the *data copy itself* needs power-fail-safe
   journaling. ESP-IDF avoids this on purpose.
5. **Complexity vs payoff.** On 4 MB, the wins are: reclaim ~1.5 MB, make VM
   slot geometry adjustable, and (with the Tier-0 split) enable
   loader-applied base updates. Whether base-update is worth the foot-guns
   depends on how often PLAT really changes after ship.
6. **Two OTA paths today.** The standard Toit firmware service
   ([`firmware.toit`](../system/extensions/ec618/firmware.toit)) reports
   `is-rollback-possible = false` / `is-validation-pending = false`; the real
   dual-slot logic lives in `ec618.slot` + `uart-ota`. A partition system
   should unify these or clearly define how they relate.

## 9. Suggested incremental path

1. **Single source of truth (no behavior change).** Define a partition
   descriptor; derive the constants in §7 from it (runtime struct + generated
   linker symbols). Reuses the existing `mem_map.h`-parsing precedent in
   `xmake.lua`. Pure refactor; removes the "edit one of six, corrupt flash"
   hazard.
2. **Reclaim FOTA and right-size LittleFS.** FOTA is unused by Toit. LittleFS
   is live PLAT storage and must be migrated or reformatted before shrinking;
   §4.1 records the measured starting point. Extend the writable window and
   expose only the proven-safe remainder as free/available space.
3. **Decouple the VM slots from PLAT, table at a fixed top anchor (§6.3).**
   Generalize `slot_marker.c`'s seq+CRC two-sector scheme to carry slot
   geometry; make the dispatcher, guard, and primitives read each slot's
   base+size from the marker instead of the linker symbols `__vm_a_start` /
   `__vm_b_start`. The slots now *float* (PLAT, slot A, slot B become
   independent partitions) and the VM becomes **resizable on its own** —
   without the Tier-0 split. The only fixed cross-reference left is the
   jump-table address (frozen ABI). This is the high-value, moderate-cost step.
4. **(Optional, gated on real need) Tier-0 split + base update via staging.**
   Carve a tiny frozen loader at 0x824000, move the PLAT runtime into a
   table-described partition, and add a staging+apply flow with a survivable
   fallback. This is the expensive part (and the only one that lets *PLAT*
   itself be OTA'd); justify it before building.

Keep Tier 0 / the table reader minimal and frozen at every step; everything
else stays negotiable.

## 10. Open questions / verification TODOs

- [x] Link-map check: `LFS_init`, the LittleFS implementation, `OsaFopen`, and
      the PLAT configuration/time callers are linked into base-v2; `mainTask`
      calls `LFS_init` before loading PLAT configuration.
- [ ] Does anything in the SDK boot path write FOTA/LFS without Toit asking
      (e.g. an auto-apply step, an fs auto-format on first boot)?
- [x] The 96 KB hib-backup region is required. The SDK represents it as four
      wear-levelled 24 KB blocks and restores a 16 KB `apFlashMem` shadow from
      it. Toit RTC memory uses the shadow's application-reserved sector 3 and
      requests writeback with `AP_FLASHREQ_RSVD`; 16 consecutive hardware
      hibernation cycles preserved its checksum and user bytes (2026-07-18).
- [ ] Exact RF-calibration footprint in NVRAM factory/runtime — confirm the
      32 KB band is the true immovable minimum (don't shrink blindly).
- [ ] Where exactly does the SDK bootloader hand control to 0x824000, and what
      does it assume about the bytes there? (Determines how small Tier 0 can
      be.)
- [ ] Decide the table format: extend the 16-byte slot record, or a separate
      record type co-located in the same A/B sectors? Field layout
      (offset/size/type/flags/label), max partitions, alignment.
- [ ] How does this unify with the `firmware.toit` service so there is one OTA
      story, not two?
- [ ] Confirm the jump table is the VM's *only* cross-reference into PLAT (no
      stray direct `bl <plat_sym>` / data references that bypass `g_plat_jt`).
      Any such leak would break when PLAT internals move and undermines the
      slot-decoupling in §6.3. Check the VM link map / the `--wrap` set
      described in `ota-dual-slot-plan.md`.
- [ ] If/when we want FAT-on-SD: add `fatfs` + `vfs` + `diskio_spitf` to the
      Toit build and write a Toit VFS/driver binding mirroring ESP32's FAT/SD
      (separate from the internal partition table; SPI bus + CS + power GPIO).

## 11. Reference: key files

- Vendor map: [`mem_map.h`](../third_party/luatos-soc-ec618/PLAT/device/target/board/ec618_0h00/common/inc/mem_map.h)
- Linker carve: [`ec618_0h00_flash.ld`](../third_party/luatos-soc-ec618/PLAT/core/ld/ec618_0h00_flash.ld)
- Dispatcher / trial-boot: [`toit_main.c`](../toolchains/ec618/project/src/toit_main.c)
- OTA-state record (reuse for the table): [`slot_marker.c`](../toolchains/ec618/project/src/slot_marker.c) + [`slot_marker.h`](../toolchains/ec618/project/inc/slot_marker.h)
- Writable-window guard: [`sys_ro_override.c`](../toolchains/ec618/project/src/sys_ro_override.c)
- Slot primitives: [`primitive_ec618.cc`](../src/primitive_ec618.cc)
- Flash registry (Toit storage): [`flash_registry_ec618.cc`](../src/flash_registry_ec618.cc)
- Toit-side slot API: [`slot.toit`](../lib/ec618/slot.toit)
- Prior OTA design: [`ota-dual-slot-plan.md`](ota-dual-slot-plan.md)
