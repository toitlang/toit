# EC618 OTA: Dual-Slot VM with Jump Table

## Problem

The EC618 has a single AP image slot (2.5 MB) and a 512 KB FOTA staging
region. There is no room for a full second copy of the firmware, which
creates two problems:

1. **No VM updates over the air.** The current OTA scheme only updates
   the "extension" (Toit containers, config) by skipping the unchanged
   VM prefix. If the VM binary changes (SDK update, C++ bug fix), the
   entire image must be reflashed via UART.

2. **Power-loss bricking.** The commit step copies data from FOTA into
   the active image region. If power is lost mid-copy, the active image
   is corrupted and there is no fallback partition. The device is
   bricked.

## Key Insight

The final binary is composed of two independent parts:

| Component | Flash size | Changes |
|-----------|-----------|---------|
| PLAT SDK (modem, RTOS, drivers, libc) | ~1180 KB | Rarely |
| Toit VM + mbedtls | ~250 KB | On SDK updates |
| Toit extension (containers, config) | Variable | On every OTA |

The Toit VM is small enough to fit twice in the remaining AP space. By
giving the VM two slots (A and B), we get safe atomic updates: write the
new VM to the inactive slot, then switch a pointer to activate it.

Cross-references between PLAT and VM are minimal and nearly
unidirectional, making the split practical.

## Current Binary Layout

From the linker map (`build/toit/toit_debug.map`) of the current
monolithic build:

```
Section          Start       Size
.text            0x848010    0x176FF4  (1500 KB, code + rodata)
  PLAT SDK                   ~1180 KB
  Toit VM                     ~133 KB
  mbedtls                     ~115 KB
  Toolchain (libgcc, libc)     ~27 KB
  Third-party (littlefs)       ~21 KB
  LuatOS interface             ~0.7 KB
  Toit glue code               ~0.2 KB
  Other                        ~25 KB
```

Total AP binary (`ap.bin`): 1.7 MB. The AP region has 2.5 MB of flash
(0x024000--0x2A4000), leaving ~800 KB unused.

### Flash Map (current)

```
0x004000-0x024000  Bootloader (128 KB)
0x024000-0x2A4000  AP image (2.5 MB)
0x304000-0x384000  FOTA staging (512 KB)
0x384000-0x3CC000  FS region (288 KB)
0x3CC000-0x3DC000  Flash registry (64 KB)
0x3DC000-0x400000  NVRAM, backup, plat info
```

## Proposed Architecture

### Flash Layout

```
0x024000  +---------------------------+
          | PLAT SDK (~1.2 MB)        |  Rarely updated (UART only).
          | (modem, RTOS, drivers,    |
          |  libc, littlefs, glue)    |
          |                           |
~0x150000 +---------------------------+
          | Jump table (1 KB)         |  Fixed address. 207 entries.
~0x150400 +---------------------------+
          | VM slot A (~384 KB)       |  Active or inactive.
          | (libtoit_vm.a + mbedtls)  |
~0x1B0400 +---------------------------+
          | VM slot B (~384 KB)       |  Active or inactive.
          | (libtoit_vm.a + mbedtls)  |
~0x210400 +---------------------------+
          | Toit extension            |  Containers, config, images.
          | (variable size)           |
0x2A4000  +---------------------------+
```

Each VM slot is 384 KB, which gives ~50% headroom over the current
250 KB. The extension lives after both slots and is updated via the
existing FOTA-based OTA (prefix skip + copy-back), or it could be
incorporated into the VM slot if desired.

### Slot Switching

The `toit_main.c` glue code (xmake-built, not in a prebuilt PLAT lib)
currently calls `toit_start` directly:

```c
// toit_main.c (current)
extern void toit_start();

static void toit_task(void* arg) {
    toit_start();  // Single BL instruction.
}
```

Changed to:

```c
// toit_main.c (proposed)
extern void toit_start_a();
extern void toit_start_b();

static uint8_t active_slot;  // Read from flash registry at boot.

static void toit_task(void* arg) {
    void (*entry)() = (active_slot == 0) ? toit_start_a : toit_start_b;
    entry();
}
```

This is a RAM-based function pointer. No flash patching required to
switch slots. The slot marker is a single byte in the flash registry,
written after the new VM slot is fully verified.

### Jump Table (PLT)

The VM calls into PLAT through a jump table at a fixed flash address.
This decouples the VM from PLAT's internal layout, allowing either side
to be updated independently.

```c
// At fixed address, e.g. 0x150000.
struct plat_jump_table {
    void* (*malloc)(size_t);
    void  (*free)(void*);
    void* (*memcpy)(void*, const void*, size_t);
    void* (*memset)(void*, int, size_t);
    int   (*swLogPrintf)(const char*, ...);
    // ... 207 entries total.
};
```

The VM is compiled with wrapper stubs that call through the table:

```c
// Auto-generated stub in the VM link.
void* malloc(size_t size) {
    return plat_jump_table->malloc(size);
}
```

The extra indirection (one load + branch per PLAT call) adds a single
cycle on Cortex-M3. Negligible.

## Cross-Reference Analysis

### PLAT --> VM (1 reference)

There is exactly **1 call site** in PLAT code that targets a VM symbol:

```
0x97d080:  bl 0x99a0e4 <toit_start>    (from toit_task in toit_main.c)
```

This is in our glue code (`toit_main.c`), not in a prebuilt PLAT
library. The function-pointer approach above eliminates this as a
hard-coded reference entirely.

Other PLAT-side symbols that interact with VM code
(`sysROSpaceCheck`, `BSP_CustomInit`, `SetPrintUart`, `_write`) are all
defined in our glue code (`sys_ro_override.c`, `bsp_custom.c`), which
lives on the PLAT side and does not need updating when the VM changes.

### VM --> PLAT (1656 references, 207 unique symbols)

The complete list of BL instructions from VM code (address >= 0x970000)
to PLAT code (address < 0x970000):

```
Calls  Function                    Category
-----  --------                    --------
  201  swLogPrintf                 Logging
  169  memcpy                      libc
  157  memset                      libc
   75  excepEcAssert               Assert/fault
   75  ec_assert_regs              Assert/fault
   70  UStackRestoreIRQMask        IRQ management
   57  UStackSaveAndSetIRQMask     IRQ management
   48  free                        Allocator
   45  malloc                      Allocator
   33  vPortFree                   Allocator (FreeRTOS)
   32  GPR_clockEnable             Clock control
   26  GPR_clockDisable            Clock control
   24  __wrap__free_r              Allocator (newlib)
   23  slpManDrvVoteSleep          Sleep manager
   21  XIC_SetVector               Interrupt controller
   21  XIC_EnableIRQ               Interrupt controller
   19  uniLogGetPherType           Logging
   18  XIC_DisableIRQ              Interrupt controller
   18  XIC_ClearPendingIRQ         Interrupt controller
   18  __assert_func               Assert (newlib)
   16  pvPortMallocEC              Allocator (FreeRTOS)
   15  osEventFlagsGet             RTOS events
   15  osEventFlagsClear           RTOS events
   12  usbDevGetLogIfIdx           USB (debug)
   12  osEventFlagsDelete          RTOS events
   11  __wrap__malloc_r            Allocator (newlib)
   11  usbd_early_init_flag        USB
   11  osEventFlagsSet             RTOS events
   10  calloc                      Allocator
    9  osEventFlagsNew             RTOS events
    8  GPR_swReset                 Clock control
    8  delay_us                    Timing
    8  BSP_GetPlatConfigItemValue  Platform config
    6  TIMER_interruptConfig       Timer
    6  SctDrvGetChanlState         USB/serial
    5  xQueueGenericSend           RTOS queues
    5  xQueueGenericReceive        RTOS queues
    5  vQueueDelete                RTOS queues
    5  vPortSetHeapTag             Allocator
    5  swLogDump                   Logging
    5  slpManRegisterPredefined*   Sleep manager (x2)
    5  SctUsbEpDiscard*            USB
    5  pbuf_free                   lwIP
    5  osKernelGetTickCount        RTOS
    5  BSP_QSPI_Erase_Safe        Flash
    5  appSetCFUN                  Modem
    5  apmuGetSleepedFlag          Power management
    5  apmuGetAPLLBootFlag         Power management
    4  xTaskGetCurrentTaskHandle   RTOS
    4  udp_remove                  lwIP
    4  tcp_arg                     lwIP
    4  realloc                     Allocator
    4  PAD_setPinConfig            GPIO pad
    4  osEventFlagsWait            RTOS events
    4  CLOCK_getClockFreq          Clock
    3  xQueueGetMutexHolder        RTOS
    3  __wrap__realloc_r           Allocator
    3  vPortGetHeapTag             Allocator
    3  tcp_recv                    lwIP
    3  tcp_output                  lwIP
    3  TIMER_stop                  Timer
    3  udp_recv                    lwIP
    3  slpManUnregister*           Sleep manager (x2)
    3  SctUsb*                     USB (x4)
    3  osTimerDelete               RTOS timer
    3  OsaFreeDlPduBlockList       PS/modem
    3  dev_eth_rndis_isconnect     USB networking
    3  CLOCK_clockEnable           Clock
    3  BSP_QSPI_Write_Safe        Flash
  2-1  (remaining ~110 functions)  Various
```

**Breakdown by category:**

| Category | Unique symbols | Call sites |
|----------|---------------|------------|
| Allocator (malloc/free/realloc/vPort*) | ~15 | ~250 |
| Logging (swLogPrintf, swLogDump, uniLog*) | ~5 | ~230 |
| libc (memcpy, memset, assert) | ~4 | ~350 |
| Assert/fault handling | ~3 | ~170 |
| IRQ management | ~5 | ~170 |
| RTOS (tasks, queues, events, timers) | ~25 | ~120 |
| Clock/power/sleep management | ~15 | ~80 |
| lwIP (TCP, UDP, pbuf) | ~25 | ~60 |
| Flash (BSP_QSPI_*) | ~3 | ~10 |
| GPIO/PAD/I2C | ~5 | ~10 |
| USB/serial | ~20 | ~60 |
| Modem/PS | ~10 | ~15 |
| Timer (hardware) | ~6 | ~15 |
| Other | ~60 | ~120 |

### Patching Approach: Stubs vs Direct Relocation

**Option A: Direct relocation (no stubs)**

Ship a relocation table with the VM image: for each of the 1656 BL
instructions, store (offset, target_address). At OTA write time or
first boot, patch each BL instruction in flash.

- Relocation table size: 1656 x 8 bytes = ~13 KB.
- Requires one flash write per BL instruction (could batch by page).
- The VM binary is position-dependent; the table must be regenerated
  if PLAT changes.

**Option B: Jump table / PLT stubs (recommended)**

The VM links against a stub table (207 entries). Each stub is a
single indirect branch through a fixed-address jump table. The jump
table is populated by PLAT at build time.

- Jump table size: 207 x 4 bytes = 828 bytes (rounded to 1 KB).
- Stub overhead in VM: 207 x ~8 bytes = ~1.6 KB.
- Runtime overhead: 1 extra cycle per PLAT call (load + branch).
- **Decouples VM from PLAT layout.** A new PLAT build just
  regenerates the jump table; all existing VM images keep working as
  long as the API is unchanged.
- If PLAT adds new functions, the jump table grows (append-only).
  Old VM images ignore the new entries. New VM images that need them
  require the updated PLAT.

Option B is strictly better: smaller metadata, future-proof, and
it is exactly what a PLT in a shared library does.

## OTA Update Flow

### VM-only Update (common case)

1. Server computes new VM binary, linked against the stub table.
2. Device downloads the new VM image (~250 KB) over cellular.
3. Image is written to the **inactive** VM slot.
4. SHA-256 verification of the written slot.
5. Slot marker in flash registry is updated to point to the new slot.
6. Device reboots. `toit_main.c` reads the marker, calls the new
   `toit_start`.

If power is lost during step 3: the old slot is untouched. Device
boots normally on next power-up.

If power is lost during step 5: the marker write is a single flash
word. NOR flash single-word writes are effectively atomic. But even if
corrupted, a CRC on the marker can detect this and fall back to the
previous slot.

### Extension-only Update (current OTA, unchanged)

Toit containers and config are updated via the existing FOTA mechanism
(write extension to FOTA region, verify, copy into active image after
the VM slots). This path is unchanged.

### Full PLAT Update (rare, requires UART)

If the PLAT SDK changes, the entire image must be reflashed via UART.
This also regenerates the jump table. Existing VM slots become invalid
(the stub addresses are the same, but the jump table entries may have
moved). After a PLAT reflash, a fresh VM must also be flashed.

## Implementation Steps

### Phase 1: Linker Script Split

Modify the xmake linker script to place PLAT and VM code in separate
memory regions:

```
MEMORY {
    PLAT_FLASH (rx)  : ORIGIN = 0x024000, LENGTH = 1280K
    JT_FLASH   (r)   : ORIGIN = 0x150000, LENGTH = 1K
    VM_A_FLASH (rx)  : ORIGIN = 0x150400, LENGTH = 384K
    VM_B_FLASH (rx)  : ORIGIN = 0x1B0400, LENGTH = 384K
    EXT_FLASH  (r)   : ORIGIN = 0x210400, LENGTH = 600K
    /* ... RAM regions unchanged ... */
}
```

Objects from `libtoit_vm.a` and mbedtls go into `VM_A_FLASH` (or
`VM_B_FLASH`). Everything else goes into `PLAT_FLASH`.

### Phase 2: Jump Table Generation

1. Build PLAT with all exported symbols kept (via `KEEP()` in linker
   script or `--whole-archive`).
2. After linking PLAT, extract the 207 symbol addresses into a
   structured jump table at the fixed `JT_FLASH` address.
3. Generate C stub wrappers (`plat_stubs.c`) that call through the
   jump table. These are compiled into the VM.

This can be automated: a script reads the PLAT ELF, extracts the
export list, and generates both the jump table data and the stub
source file.

### Phase 3: Dual VM Link

Link `libtoit_vm.a` + mbedtls + stubs twice:
- Once targeting `VM_A_FLASH` base address.
- Once targeting `VM_B_FLASH` base address.

Or compile with `-fPIC` (position-independent code) and link once.
PIC on Cortex-M3 uses a GOT (Global Offset Table) for globals, adding
~2% code size overhead. Fixed-address dual linking avoids this but
requires two link passes.

### Phase 4: Slot Manager

Add slot management to the firmware:
- A `active_slot` byte in the flash registry.
- Modified `toit_main.c` to read the marker and branch to the correct
  entry point.
- OTA commit logic: verify the new slot, update the marker, reboot.

### Phase 5: Tooling

- Modify the build system to produce separate PLAT and VM artifacts.
- Modify the OTA server/CLI to send VM-only images (~250 KB) instead
  of full firmware images.
- Add a `plat_version` field to the firmware config so the server
  knows which jump table the device has and can send compatible VM
  images.

## Risks

### Dead-Code Elimination

GCC's `--gc-sections` strips PLAT functions not referenced by the
current VM. A future VM that needs a stripped function would fail to
link.

**Mitigation:** Maintain an export list of PLAT functions. Use
`KEEP()` in the linker script for all exported symbols. The export list
is the 207 functions identified above, plus any future additions. New
functions require a PLAT reflash.

### Linker Script Complexity

The xmake build system uses its own linker script. Modifying it to
support separate PLAT/VM regions requires understanding the existing
memory layout, which includes special sections for RAM code
(`.load_ap_piram_asmb`, `.load_ap_firam_asmb`), shared memory, sleep
backup regions, etc.

### XIP and RAM Code Placement

Some code must run from RAM (e.g., flash write routines, sleep
callbacks). The current linker script places these in special sections.
The VM/PLAT split must preserve this: if a VM function needs to be in
RAM, it must go in a RAM section within the VM's region, not PLAT's.

### BSS/Data Initialization

Both PLAT and VM have `.bss` (zero-init) and `.data` (initialized)
sections. The startup code must initialize both. With dual VM slots,
only the active slot's BSS/data should be initialized. This requires
the startup code to know which slot is active.

### mbedtls Placement

mbedtls is logically part of the VM (only the VM calls it), but one
PLAT lib (`libdriver_private.a`) has a reference to
`mbedtls_sha256_init`. In the current build this is dead-code
eliminated (no actual call site in the final binary). If mbedtls goes
in the VM slot, this dangling reference in PLAT must be confirmed dead
or stubbed out.

## Alternative Considered: Binary Diff Patching

Instead of dual slots, send a bsdiff-style patch and apply it to the
active image in-place. The patch would be small (~50--100 KB for a
typical VM change).

**Rejected because:**
- bsdiff needs random access to the old image during patch application;
  you cannot stream it page-by-page.
- In-place patching of the active image has the same power-loss bricking
  risk as the current copy-back approach.
- Dual slots provide atomic switching with no window of vulnerability.

## References

- Flash layout: `third_party/luatos-soc-ec618/PLAT/device/target/board/ec618_0h00/common/inc/mem_map.h`
- Current OTA primitives: `src/primitive_ec618.cc`
- Current OTA commit: `src/toit_ec618.cc:155-237`
- Flash write guard: `third_party/luatos-soc-ec618/project/toit/src/sys_ro_override.c`
- Firmware service: `system/extensions/ec618/firmware.toit`
- Linker map: `third_party/luatos-soc-ec618/build/toit/toit_debug.map`
- Porting guide OTA section: `docs/porting-guide.md` section 19

## Implementation Status (2026-05-25)

### Phase 2 prototype landed: every VM→PLAT call goes through a jump table

The "jump table / PLT stubs" half of Option B is implemented end-to-end
for the current binary and validated on hardware.

**What ships:**
- `tools/gen_plat_jt.py` — generator that takes a list of PLAT symbols
  the VM reaches, and emits matching jump-table data, per-symbol stubs,
  and `--wrap=` ldflags. It also rewrites the marker block in
  `third_party/luatos-soc-ec618/xmake.lua`.
- `tools/plat_jt_ldflags.lua` — generated symbol list, version-controlled
  so the build is reproducible without re-running the analysis.
- `third_party/luatos-soc-ec618/project/toit/inc/plat_jt.h` — generated
  slot enum + `extern const g_plat_jt[]`.
- `third_party/luatos-soc-ec618/project/toit/src/plat_jt.c` — generated
  jump-table contents + per-symbol naked-Thumb-2 stubs.

**How it works:**
- `--wrap=<sym>` on every PLAT symbol the VM reaches. The linker rewrites
  the VM's `bl <sym>` into `bl __wrap_<sym>`. The original symbol stays
  reachable to PLAT itself as `__real_<sym>`.
- Each `__wrap_<sym>` is a 16-byte naked Thumb-2 stub: `movw/movt` to
  load `&g_plat_jt[slot]`, `ldr` the function pointer, `bx` tail-call.
  Type-agnostic: r0–r3 + stack are already laid out by the caller, so
  the tail-call preserves the original signature exactly.
- `g_plat_jt[]` is `const` so it lives in `.rodata` (flash) at a fixed
  link-time address. That matters because PLAT startup calls `memcpy`
  *before* `.data` is copied to RAM — a RAM-resident jump table would
  crash on the very first instruction.
- A volatile load in the wrapper would defeat constant-folding for the
  pointer-followed-then-called pattern in C; the asm stubs sidestep that
  concern entirely.

**What was validated on the EC618:**
- 169 unique PLAT symbols routed through `g_plat_jt[]` — 3769 `bl`
  call-sites across both PLAT and VM (PLAT's own libc calls get wrapped
  too, which is harmless and saves a duplicate code path).
- Text grew by ~3 KB total (169 × 16-byte stub + 676-byte table).
- Toit boots cleanly, `BSP_CustomInit` runs, the system reaches the
  `[toit] INFO: running on EC618 @ 204MHz` print. Watchdog still trips
  after the boot prints because no Toit container is installed in the
  envelope used for testing — same as before the prototype.

**Drift from this doc's original analysis:**
The original "207 unique / 1656 BL instructions" came from an earlier
snapshot. Re-running the analysis on the current `toit.elf` gives 169
unique / 915 calls. Reproduce with:
```
arm-none-eabi-objdump -d -j .text third_party/luatos-soc-ec618/build/toit/toit.elf | \
    awk '/\tbl\t/ { ... }'  # see tools/gen_plat_jt.py development notes
```
The categorisation also shifted: `swLogPrintf` is no longer called from
VM in the current build, allocator + libc string ops + iprintf dominate.

**What is *not* yet done (Phase 1, 3, 4, 5):**
- Linker script split: PLAT and VM still occupy a single contiguous
  `.text`. `g_plat_jt` lives at whatever address the linker picks; the
  production design wants it at a fixed address so VM slot images can
  be linked independently of PLAT layout.
- Dual VM slots: still a single VM image. No A/B switching.
- Slot manager: `toit_main.c` still has the unconditional `toit_start()`
  call. No active-slot byte in the flash registry.
- OTA tooling: ectool-based flash still ships the whole image. No
  VM-only OTA path.
- Symbol-list regeneration: today the list is captured by a one-off
  analysis. A `make` target (or CI step) should run the objdump+awk
  pipeline so the symbol list never gets stale relative to the VM.

**Next concrete step:** decide whether to keep the wrap approach for
production (it's global — wraps PLAT's own calls too) or switch to a
post-link `objcopy --redefine-syms` pass that touches only VM objects.
The wrap approach is simpler and the runtime cost is negligible; the
objcopy approach gives a cleaner factoring once we split the linker
script.

### Phases 1, 3, 4 landed (2026-05-27, commit `dd78fe4e` + submodule `52797be`)

Flash layout actually shipped (XIP addresses):
- `0x848000-0x990000` PLAT `.text` (~1.27 MB used, ~50 KB headroom)
- `0x990000-0x991000` `.jt_data` (4 KB; holds `g_plat_jt[]`)
- `0x991000-0x9F1000` `.vm_a` (384 KB, slot A)
- `0x9F1000-0xA51000` `.vm_b` (384 KB, slot B)
- `0xA51000-0xA52000` `.slot_marker` (4 KB; one byte: `'A'` or `'B'`)
- `0xA52000-0xAA4000` extension (~328 KB)

Linker script (`PLAT/core/ld/ec618_0h00_flash.c`):
- `.text` excludes `libtoit_vm.a / libmbedtls*.a` so PLAT and VM
  occupy disjoint flash ranges.
- `.vm_a` / `.vm_b` are sibling sections placed at fixed XIP
  addresses (`addr :` prefix, not `>FLASH_AREA` with a counter —
  the latter just stacks slots back-to-back at the end of PLAT).
- A build-time `-DTOIT_VM_SLOT_B` flips which slot the VM lands in;
  the unselected slot keeps its base/end symbols but emits no
  bytes, leaving a sector-aligned hole the splice step fills.
- VM-side `.init_array` is captured into the slot
  (`__vm_init_array_start/end`); PLAT-side static initialisers stay
  in `.load_dram_shared` so PLAT's own startup is unchanged.

Slot dispatcher (`project/toit/src/toit_main.c`):
- Reads `.slot_marker` (defaults to `'A'` on a fresh build).
- Each slot's first word is a `.vm_entry` function pointer
  (defined in `src/toit_ec618.cc`); the linker emits each slot's
  own `toit_start` address there. The dispatcher tail-calls
  through it — no fixed-offset entry symbol needed inside the
  slot.

Build pipeline:
1. `make ec618` — slot A link pass; envelope create patches slot
   A's `DromData` with the extension XIP address + uuid.
2. `toit … extract --format binary -o ap_a_patched.bin`
3. `TOIT_VM_SLOT_B=1 xmake build` from
   `third_party/luatos-soc-ec618` — slot B link pass, raw output.
4. `tools/splice_dual_slot.py --slot-a ap_a_patched.bin
   --slot-b out/toit/ap.bin --output ap_dual.bin --active-slot A`
   — overwrites the slot-B file region with the second link pass
   and copies slot A's patched `DromData` into slot B's so both
   slots resolve the embedded program at the same XIP address.

Validated on `quirky-plenty` (`/dev/ttyUSB1`):
- Active byte `'A'` → `[toit] INFO: booting VM slot A` →
  slot A's `toit_start` runs → `running on EC618 @ 204MHz`.
- Active byte `'B'` → same flow for slot B
  (`toit_start` at `0xa12bc8` vs slot A's `0x9b2bc8`).

Drift from the original layout in this doc:
- JT origin bumped from `0x150000` → `0x990000` to sit just past
  PLAT in the AP image's XIP range. The "0x15…" addresses in the
  original layout sketch were illustrative.
- VM slots placed at `0x991000` / `0x9F1000`, not `0x150400` /
  `0x1B0400` — same reason.

### Phase 3 footnote: the two link passes are byte-identical outside the slot

Comparing the slot-A region from the slot-A build against the
slot-B region from the slot-B build (apples-to-apples, same 384 KB):

| Encoding | Count | Slot-dependent? |
|---|---|---|
| `BL` within slot (VM→VM) | 4,723 | No (both ends move) |
| `BL` to PLAT `__wrap_*` stubs | 915 | **Yes** |
| `movw` standalone (small constants) | 113 | No (16-bit immediates only) |
| `movt` | 0 | — |
| `movw/movt` address-loading pairs | 0 | — |

Total diff: ~2,866 bytes out of 393,216 (0.73 %). Of those:
- ~1,885 are pure 32-bit absolute pointers
  (`slot_A_value + 0x60000 == slot_B_value`).
- ~970 are the BL encoding deltas from those 915 wrappers.
- A handful are PLAT-side static-const tables in
  `.load_dram_shared` that hold pointers to VM symbols; these
  aren't load-bearing for slot dispatch (they're vtable-like
  references the active VM never reads from the wrong slot), so
  the splice keeps PLAT from the slot-A build for the prototype.

The current splice approach ships *both* link passes inside the
same flashed image, which is fine for initial flashing but
doesn't address how a future OTA delivers a new VM without
knowing the device's active slot.

## Phase 5 design: relocatable OTA payload

The OTA path can't reasonably ship two pre-linked images per
release (storage doubles, transport doubles, server has to know
which slot the device is on). The chosen design is a
**single relocatable image** the device patches as it writes.

### Step 1 — kill the BL-to-PLAT relocations

Move `plat_jt.o` (the `__wrap_*` stubs) from `libtoit.a`/`.text`
into each slot section. One-line addition in
`PLAT/core/ld/ec618_0h00_flash.c`:

```ld
.vm_a TOIT_VM_A_ORIGIN :
{
    __vm_a_start = .;
    KEEP(*(.vm_entry))
    *libtoit.a:plat_jt.o(.text*)        /* new */
    /* … existing __vm_init_array_* + libtoit_vm.a / libmbedtls.a … */
}
```
Mirror in `.vm_b`. Each slot now carries its own copy of the 169
stubs (~2 KB per slot, ~4 KB total). The wrappers' `movw/movt`
operands still reference the single `g_plat_jt[]` at the fixed
`.jt_data` address, so the duplicated stub bytes are
byte-identical between the two slots; only the wrappers' *base
addresses* differ. The 915 VM→PLAT BLs now land on slot-local
stubs and their encoded offsets become slot-independent. After
this change the only slot-dependent bytes left in the slot are
the ~1,885 absolute 32-bit pointers.

### Step 2 — magic-prefix pointer rewriting

Link the VM at a deliberately-chosen "magic" base address chosen
so that **no other 32-bit word in the image has the same upper
13 bits**. The slot is 384 KB = 0x60000 bytes, so each
slot-local pointer occupies the lower 19 bits and we have 13
bits "above" to use as a marker. There are 2¹³ = 8,192
candidate prefixes and the VM is ~64 K 32-bit words — easy to
find a safe one because populated upper-13-bit values cluster
heavily around real address regions (XIP, RAM) and small
constants.

Build-time tool:
1. Tentatively link the VM at slot A's address.
2. Histogram the upper 13 bits of every 32-bit word in the
   slot region.
3. Pick the smallest unused 13-bit prefix `P`.
4. Re-link at `B = P << 19`.
5. Ship: image bytes + `B` (4 bytes of metadata).

Device-side patcher (called from the OTA write path):
```c
for each 32-bit word w at offset o in the OTA stream:
    if ((w >> 19) == P) {
        w = dest_slot_base | (w & 0x7FFFF);
    }
    write w to dest_slot + o
```
Bandwidth overhead: 4 bytes per release. Patcher overhead: one
extra load + compare + conditional rewrite per 4 bytes of
image. The shipped OTA image is *not* directly runnable — its
pointers live in the fake address range — but it doesn't need
to be; the device only ever sees the patched version.

### Step 3 — UART transport (current rig)

`quirky-plenty` exposes the EC618's UART1 on `/dev/ttyUSB1`,
which is also the print UART. Either:
- relax the `ALREADY_IN_USE` check in
  `src/resources/uart_ec618.cc:355` for this UART, or
- set `CONFIG_TOIT_EC618_PRINT_UART=0` while the OTA container
  is the only running app.

Toit-side: a small container reads `<header><image bytes>` off
UART1 (header carries `B` and the image size + SHA-256),
streams chunks through the magic-prefix rewriter, writes to the
inactive slot via new `slot_write` / `slot_erase` primitives
(both backed by `BSP_QSPI_*_Safe` inside the existing
`AllowFirmwareModifications` guard — see
[[feedback_ec618_bsp_qspi_hang_on_reject]]), verifies SHA, then
rewrites `.slot_marker` and reboots.

### Step 4 — host transport

Host script reads the relocatable image + `B` from the build
output and streams them down `/dev/ttyUSB1` with a tiny framing
protocol (length-prefixed; SHA-256 trailer for the device to
verify against). Same machine that runs `jag run` for the
ESP32-C6 power/boot strap can run this.

### What we are *not* building

- `-mword-relocations` on the VM build. Verified that GCC isn't
  using `movw/movt` for any 32-bit address loads in the current
  VM (0 `movt` instructions in the slot disassembly), so we
  don't need to force literal-pool loads.
- Full PIC. With the BL stubs moved into the slot and the
  pointer relocation handled by the magic-prefix scan, the
  remaining cost is roughly one prefix check per 4 bytes of OTA
  payload — already acceptable.
