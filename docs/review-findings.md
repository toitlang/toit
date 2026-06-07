# EC618 Port: Status and Remaining Work

## Overview

The EC618 port implements all 24 sections of `docs/porting-guide.md`. The core
platform boots, runs Toit programs, connects to cellular, does TLS, persists
data across deep sleep, and supports GPIO/UART/I2C peripherals. This document
tracks what's left.

---

## 1. Unimplemented Features

### OTA — DONE (dual-slot VM OTA via `system.firmware`)

> **Updated 2026-06-07.** This section originally described a FOTA-staging,
> single-image OTA with a placeholder commit step. That approach was **dropped**.
> The EC618 now does **dual-slot VM OTA on the standard `system.firmware` API**,
> implemented and hardware-validated (A↔B soaks pass both directions). The old
> `ota_begin`/`ota_write`/`ota_end` + FOTA copy-back are deleted, and the 512 KB
> FOTA region was reclaimed into the second VM slot.

The firmware is **two 768 KB VM slots** (A/B). OTA is a single
position-independent image relocated to whichever slot it is written to:

- **Write**: the standard `FirmwareWriter`
  (`system/extensions/ec618/firmware.toit`) streams the canonical, table-first
  image to the **inactive** slot via relocate-on-write (`slot.reloc-begin` +
  `slot.write-inactive`); `commit` verifies the canonical SHA-256 and stages a
  trial.
- **Read**: `firmware.map` presents the active slot's **canonical** (un-relocated)
  image via `SlotFirmware` — slot-independent, so the integrity SHA matches on
  either slot.
- **Trial / rollback**: esp-idf-style — a freshly written slot boots once on
  trial; the running image must `firmware.validate`, else the next reset rolls
  back. Backed by the power-fail-safe `.slot_marker` (ping-ponged seq+CRC).

There is no copy-into-active step to brick on power loss. See
[ota-relocation-convergence.md](ota-relocation-convergence.md) for the full
design + status. **Remaining:** Artemis delta-apply (the canonical read path it
needs is done) and deleting the dead legacy Python OTA tooling.

### GPIO Pull-up/Pull-down and Open-drain

- **File**: `src/resources/gpio_ec618.cc:181-182`
- Both return `FAIL(UNIMPLEMENTED)`.
- Would need PAD configuration via `PAD_setPinConfig`, but there's no known
  GPIO-to-PAD pin mapping table. The PLAT SDK `RTE_Device.h` has some PAD
  definitions for I2C but not a general GPIO→PAD map.

### Process-level Random Seeding

- **File**: `src/process.cc` (inside `_ensure_random_seeded()`)
- Currently uses a **constant seed** on EC618 instead of the hardware RNG.
- The hardware RNG is available (`rngGenRandom()` in `src/os_ec618.cc`) and
  used for `mbedtls_hardware_poll`. It should be wired into the entropy mixer.

---

## 2. Missing Hardware Tests

All tests are in `tests/hw/ec618/`. To run a test:

```bash
# Compile the test
build/host/sdk/bin/toit compile --snapshot -o /tmp/test.snapshot tests/hw/ec618/<test>.toit

# Create envelope with the test
cp build/ec618/firmware.envelope /tmp/test-envelope
build/host/sdk/bin/toit tool firmware -e /tmp/test-envelope container install \
    --trigger=boot test /tmp/test.snapshot

# Flash (device must be in boot mode)
build/host/sdk/bin/toit tool firmware -e /tmp/test-envelope flash --port=/dev/ttyACM0
```

### GPIO Test (needs external hardware)

No test exists for `src/resources/gpio_ec618.cc`.

**What to test**:
- Output: set a pin high/low, verify with a second pin as input (wire them
  together, or use an LED).
- Input: read pin state.
- Interrupts: `pin.wait-for 1` / `pin.wait-for 0` with level changes.

**Pin notes**:
- 32 pins total, 2 ports of 16 (port = pin / 16).
- Pins 20-27 are AON (always-on domain) — require powering on a separate
  power domain. The driver handles this with refcounting.
- Pull-up/pull-down and open-drain are UNIMPLEMENTED.

**Hardware needed**: Two GPIO pins wired together (one output, one input), or
a button + LED. Check the Air780E module datasheet for which pins are exposed
on the dev board.

### UART Test

No test exists for `src/resources/uart_ec618.cc`.

**What to test**:
- Read bytes sent to the debug console UART.

**Notes**:
- The driver is **receive-only** — it reads from the platform's debug UART
  (`UsartPrintHandle`).
- Uses a circular buffer: 4 segments × 1024 bytes = 4KB.
- The ISR callback `toit_uart_event()` is registered in PLAT's `bsp_custom.c`.
- Primitives: `init`, `create`, `close`, `read` (returns available bytes or
  null).

### I2C Test (needs I2C device)

No test exists for `src/resources/i2c_ec618.cc`.

**What to test**:
- Bus scan (probe addresses).
- Read/write to a known device (e.g., BME280, SSD1306).

**Pin mappings** (hardcoded in driver):
- I2C0: SDA=12, SCL=13 (or SDA=16, SCL=17)
- I2C1: SDA=8, SCL=9 (or SDA=4, SCL=5)

**Speed modes**: 100kHz (standard), 400kHz (fast), 1MHz (fast+), 3.4MHz (high).

**Notes**:
- Uses CMSIS `ARM_DRIVER_I2C` interface.
- Write: register address + data sent as one contiguous buffer via
  `MasterTransmit`.
- Read with register: `MasterTransmit` with `pending=true` (repeated start),
  then `MasterReceive`.
- The porting guide mentions an `examples/ec618-io` example with BME280 +
  SSD1306.

### Cellular Tower Info Test

No test for `get-tower-info` in `lib/net/cellular.toit`.

**What to test**:
- Call `cellular.get-tower-info` while connected.
- Verify MCC/MNC, cell ID, RSRP, RSRQ are plausible.

**Notes**:
- Uses `appGetECBCInfoSync_v2()` primitive.
- Returns a `TowerInfo` object with 15+ fields.
- MCC/MNC are hex-encoded in the primitive and decoded to decimal in Toit.
- Returns null if no serving cell.

---

## 3. Infrastructure TODOs

### CI Workflow

- `.github/workflows/ci-ec618.yml` exists (untracked) and builds the firmware.
- Missing (per porting guide section 24):
  - `test-action.yml` — run hardware tests
  - `build-ectool.yml` — build the flashing tool for Linux/macOS/Windows
  - Reusable actions: `actions/build/`, `actions/envelope/`, `actions/ectool/`

### Cellular Disconnect Reason

- `src/resources/cellular_ec618.cc:174` — `disconnect_reason` primitive returns
  0 instead of the actual reason.

### Monotonic Time Precision

- `src/os_ec618.cc` — `monotonic_gettime()` uses FreeRTOS tick count
  (millisecond granularity). A more precise timer source would improve
  performance measurement.

### Watchdog: upstream into the toit-watchdog package

- The EC618 now has a hardware watchdog (`lib/ec618/watchdog.toit`,
  primitives in `src/primitive_ec618.cc`) and a `reset-reason` query
  (`lib/ec618/ec618.toit`), so a watchdog reset is detectable on the next
  boot (`RESET-WATCHDOG-HARDWARE`).
- TODO: update [toit-watchdog](https://github.com/toitware/toit-watchdog) so
  its portable watchdog API also works on the EC618, instead of relying on
  this chip-specific library.

---

## 4. Flash Layout Reference

For anyone modifying flash usage:

```
0x004000-0x024000  Bootloader
0x024000-0x2A4000  AP image (2.5MB)
0x304000-0x384000  FOTA staging region (512KB)
0x384000-0x3CC000  FS region (288KB, mostly unused by Toit)
  0x384000           └─ RTC memory flash backup (1 sector, 4KB)
0x3CC000-0x3DC000  Flash registry / SOFTSIM (64KB, used by Toit)
0x3DC000-0x3E0000  NVRAM factory (16KB, DO NOT USE)
0x3E0000-0x3E4000  NVRAM (16KB, DO NOT USE)
0x3E4000-0x3FC000  FLASH_MEM_BACKUP (96KB)
0x3FC000-0x3FE000  PLAT_INFO + RESET_INFO
```

---

## 5. Key Files for an Agent Getting Started

| Purpose | Files |
|---------|-------|
| Boot sequence | `src/toit_ec618.cc` |
| OS layer | `src/os_ec618.cc` |
| RTC memory | `src/rtc_memory_ec618.cc`, `src/rtc_memory_ec618.h` |
| Flash registry | `src/flash_registry_ec618.cc` |
| GPIO driver | `src/resources/gpio_ec618.cc` |
| UART driver | `src/resources/uart_ec618.cc` |
| I2C driver | `src/resources/i2c_ec618.cc` |
| Cellular driver | `src/resources/cellular_ec618.cc` |
| Cellular service | `system/extensions/ec618/cellular.toit` |
| OTA primitives | `src/primitive_ec618.cc` |
| Firmware service | `system/extensions/ec618/firmware.toit` |
| Storage buckets | `system/storage/bucket.toit` |
| Event sources | `src/event_sources/uart_ec618.cc`, `src/event_sources/cellular_ec618.cc` |
| Porting guide | `docs/porting-guide.md` |
| Build system | `Makefile`, `toolchains/ec618.cmake` |
| Platform headers | `third_party/luatos-soc-ec618/PLAT/prebuild/PLAT/inc/` |
| Existing tests | `tests/hw/ec618/` |

### Build Commands

```bash
make ec618                    # Full build (SDK + cross-compile + envelope)
make ec618 -j1                # If parallel build fails

# Cross-compile only (after initial build)
cd build/ec618 && ninja toit_vm
```

### PLAT SDK Notes

- The SDK is at `third_party/luatos-soc-ec618/` (git submodule).
- Prebuilt libraries are in `PLAT/prebuild/PLAT/lib/gcc/lite/`.
- Some header-declared functions (e.g., `slpManGetUsrNVMem`) are **not
  implemented** in any prebuilt library — always verify with
  `arm-none-eabi-nm` before using a new SDK function.
- The `xmake` build in the submodule links everything into the final ELF.
