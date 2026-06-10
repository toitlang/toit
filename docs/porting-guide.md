# Porting the Toit Language to the EC618

** IMPORTANT: this document sometimes wants to "replace" existing functionality. That's wrong. We want to *add* new support.

This document guides a developer through reimplementing Toit language support
for the EC618 cellular IoT module (Cortex-M3, FreeRTOS). The EC618 is a
Cat.1bis LTE modem SoC designed by Eigencomm. It is the same silicon found
in modules like the Air780E (by Luat/AirM2M). It is organized into
independent work packages that can be tackled in roughly the order listed,
since each layer builds on the previous one.

The upstream repository is https://github.com/toitlang/toit. All file paths
are relative to that repository root unless stated otherwise.

Throughout this guide, the ESP32 port serves as the primary reference
implementation. Many changes follow the pattern "do what ESP32 does, but for
FreeRTOS/EC618 instead of ESP-IDF."

Throughout this guide we use `ec618` as the identifier in file names, defines,
and code (e.g., `TOIT_EC618`, `src/os_ec618.cc`). Adjust as needed for your
project.

---

## Getting Started: Recommended Approach

### How to Structure the Work

The porting work divides into four phases. Each phase builds on the previous
one and has a clear milestone you can test before moving on.

**Phase 1 — Minimal Boot (sections 1-9)**
Goal: The Toit VM boots on the EC618, runs a trivial "hello world" program,
and can enter deep sleep.

This is the foundational work and the largest phase. Start with the build
system and platform detection, then implement the OS layer (threads, mutexes,
memory), then flash/storage/RTC, then the boot sequence. Tackle these
sections strictly in order — each depends on the previous.

*Milestone*: Flash the device, see `[toit] INFO: running on EC618 @ XXMHz`
on the serial console, and verify the system enters deep sleep.

**Phase 2 — Peripherals (sections 10-15)**
Goal: GPIO, I2C, and UART work. You can blink an LED, read a sensor, and
receive serial input.

The event system (section 12) must come first, as GPIO and UART depend on it.
I2C is independent of the event system and can be done in parallel. The
interpreter optimization (section 10) is also independent and improves
performance noticeably.

*Milestone*: Run the `examples/ec618-io` example: read a BME280 sensor
over I2C and display values on an SSD1306 OLED.

**Phase 3 — Networking (sections 16-18)**
Goal: The device connects to a cellular network, makes HTTP/HTTPS requests,
and can resolve DNS.

Cellular (section 16) must come first. lwIP changes (section 17) are needed
for TCP/UDP. TLS (section 18) enables HTTPS. These should be done in order.

*Milestone*: Connect to cellular, make an HTTPS request to a public API,
receive a response.

**Phase 4 — OTA and Polish (sections 19-23)**
Goal: Over-the-air firmware updates work, bucket storage persists across
reboots, CI is green.

OTA (section 19) is the most complex feature in this phase. The remaining
sections are polish and infrastructure.

*Milestone*: Push a firmware update over the network. The device downloads,
verifies, commits, reboots, and runs the new firmware.

### When in Doubt, Ask

If the instructions are unclear or you are stuck, ask. Don't ask on the
first build error — try to fix it yourself first.

### Key Patterns to Understand First

Before starting implementation, read and understand these patterns in the
upstream ESP32 port:

1. **Platform ifdef pattern**: The codebase uses `TOIT_ESP32` for
   ESP32-specific code and `TOIT_FREERTOS` for code shared between all
   FreeRTOS platforms. A recurring task is deciding whether existing
   `TOIT_ESP32` guards should stay ESP32-specific or be generalized to
   `TOIT_FREERTOS`. Rule of thumb: if it uses ESP-IDF APIs
   (`esp_*`, `heap_caps_*`), keep it `TOIT_ESP32`. If it uses standard
   FreeRTOS APIs, generalize to `TOIT_FREERTOS`.

2. **Resource/ResourceGroup pattern**: Hardware peripherals are modeled as
   `ResourceGroup` (the controller, e.g., I2C bus) and `Resource` (individual
   entities, e.g., a connection). Study `src/resource.h` and any ESP32
   resource implementation.

3. **EventSource pattern**: Asynchronous events (interrupts, network events)
   are delivered through `EventSource` subclasses that run on their own
   threads and dispatch to `Resource` objects. Study
   `src/event_sources/timer.h` for the simplest example.

4. **Primitive pattern**: C++ functions exposed to Toit code via
   `#primitive.module.name`. Each module is declared in `src/primitive.h`,
   implemented in a `src/resources/` or `src/primitive_*.cc` file, and has a
   type propagation file in `src/compiler/propagation/`.

5. **System extension pattern**: Toit-level system services
   (`system/extensions/`) provide high-level APIs (cellular, firmware) that
   are compiled into the system snapshot and run as privileged code.

### Common Pitfalls

- **The PLAT SDK expects specific linker section names**. Make sure the
  `.toit.rtc.noinit` section is in the linker script and marked as NOLOAD.
- **Newlib's printf is limited**. 64-bit format specifiers (`%lld`, `PRId64`)
  may not work or may silently produce wrong output. Always test formatting.
- **FreeRTOS stack sizes are in words, not bytes** on some ports. Verify
  `xTaskCreate` stack size units for the Cortex-M3 port.
- **Flash writes must be aligned** to `FLASH_SEGMENT_SIZE` (16 bytes). The
  last write of any sequence needs zero-padding.
- **The lwIP on EC618 has a modified API** compared to standard lwIP.
  `tcp_write` has extra parameters, and `udp_recv` callbacks return `int`
  instead of `void`. Check the PLAT's lwIP headers when in doubt.
- **Deep-sleep timer minimum is ~1 second**. Setting it lower may cause the
  timer to expire before the system enters sleep, preventing wake-up.

---

## Table of Contents

1. [Prerequisites and PLAT SDK](#1-prerequisites-and-plat-sdk)
2. [Build System](#2-build-system)
3. [Platform Detection and Compile Definitions](#3-platform-detection-and-compile-definitions)
4. [OS Abstraction Layer](#4-os-abstraction-layer)
5. [Memory Management](#5-memory-management)
6. [Flash Registry and Storage](#6-flash-registry-and-storage)
7. [RTC Memory (Persistent State Across Reboots)](#7-rtc-memory)
8. [Embedded Data and Firmware Mapping](#8-embedded-data-and-firmware-mapping)
9. [Boot Sequence and Sleep Management](#9-boot-sequence-and-sleep-management)
10. [Interpreter Performance](#10-interpreter-performance)
11. [Primitive Modules Registration](#11-primitive-modules-registration)
12. [Event System](#12-event-system)
13. [UART Support](#13-uart-support)
14. [GPIO and Pin Support](#14-gpio-and-pin-support)
15. [I2C Support](#15-i2c-support)
16. [Cellular Networking](#16-cellular-networking)
17. [TCP/IP Networking (lwIP)](#17-tcpip-networking-lwip)
18. [TLS and Cryptography](#18-tls-and-cryptography)
19. [OTA Firmware Updates](#19-ota-firmware-updates)
20. [Toit Libraries and System Extensions](#20-toit-libraries-and-system-extensions)
21. [Newlib / libc Compatibility](#21-newlib-libc-compatibility)
22. [Heap Reporting](#22-heap-reporting)
23. [Firmware Tooling](#23-firmware-tooling-toolsfirmwaretoit)
24. [CI Workflow](#24-ci-workflow)

---

## 1. Prerequisites and PLAT SDK

The EC618 has a vendor-provided SDK (referred to as "PLAT") that provides:

- Board support package for `ec618_0h00` (board definitions, linker scripts,
  startup assembly)
- Chip drivers: GPIO, I2C, UART, SPI, PAD mux configuration
- FreeRTOS port for Cortex-M3
- lwIP networking stack (patched for cellular)
- mbedTLS (used as a submodule rather than the ESP-IDF bundled version)
- littleFS
- CMSIS drivers (ARM standard driver interfaces for I2C, UART, etc.)
- Protocol stack libraries (cellular modem control, `ps_lib_api`,
  `ps_event_callback`)
- Flash and sleep management APIs (`flash_rt.h`, `slpman.h`)

The PLAT directory is roughly 2,800 files and is placed at the repository root
as `PLAT/`. It is built via its own Makefile, invoked from the top-level
Makefile.

### Obtaining the PLAT SDK

The best publicly available source for the EC618 PLAT files is the **LuatOS
CSDK**. The EC618 is the same chip used in the Luat Air780E module, and the
LuatOS project maintains an open CSDK with the full PLAT directory.

**Primary source**: Look for `luatos-soc-2022` or `luatos-soc-ec618` under
the [openLuat](https://github.com/openLuat) GitHub organization. A publicly
accessible fork exists at https://github.com/casterbn/luatos-soc-ec618.

The CSDK repository contains a `PLAT/` directory with the same structure
needed here: `device/`, `driver/`, `middleware/`, `os/freertos/`, `prebuild/`
(protocol stack blobs), and `tools/`. The chip and board directories are
already named `ec618` / `ec618_0h00`.

**Important**: The LuatOS CSDK may have a **newer version** of the PLAT files
than what was originally used. This is generally a good thing (bug fixes,
updated drivers), but be aware that:
- API signatures in driver headers may have changed slightly.
- The lwIP patches may differ, which could affect the TCP/UDP changes
  described in section 17 (especially the extra `tcp_write` parameters and
  the `udp_recv` callback return type).
- The FreeRTOS cmpctmalloc API (`vPortIterateAllocations`,
  `vPortGetHeapStats`) may have different function signatures.
- Pre-built library names may differ (e.g., `libcore_airm2m.a` vs
  `libdriver_private.a`).

When encountering API mismatches later in this guide, consult the PLAT
headers in the version you obtained. The LuatOS CSDK also has example
projects under `project/` that demonstrate how peripherals are used, which
can help clarify driver APIs.

The LuatOS CSDK uses **xmake** as its build system, but you do not need to
adopt xmake — the Toit port uses CMake/Make and only links against the PLAT
libraries. What matters is the headers and the pre-built `.a` files.

**Action**: Clone or download the LuatOS CSDK. Copy (or symlink) the `PLAT/`
directory into your repository root. Ensure the `arm-none-eabi-gcc` toolchain
is installed (targets Cortex-M3).

**Verification**: `arm-none-eabi-gcc --version` should work, and
`PLAT/driver/chip/ec618/` should exist.

### Patches Required to the PLAT SDK

The stock PLAT SDK does not work out of the box for the Toit port. The
following functional changes are needed. Apply them incrementally as you
work through the later sections — each is noted in context where it becomes
relevant, but they are collected here for reference.

**1. Toit project skeleton** (needed for section 2)

Create `PLAT/project/ec618_0h00/ap/apps/toit/` with:
- `GCC/Makefile`: Project-level Makefile. Copy the `hello` example as a
  starting point, then configure the build options (see below).
- `inc/app.h`, `inc/bsp_custom.h`: Minimal headers.
- `src/app.c`: The `main_entry()` function. This is called by the PLAT
  startup code. It should call `BSP_CommonInit()`, `osKernelInitialize()`,
  create a task that calls `toit_start()` (declared as `extern`), and call
  `osKernelStart()`. Also enable MemManage, BusFault, and UsageFault
  exceptions early (`SCB->SHCSR |= ...`).
- `src/bsp_custom.c`: Board-specific initialization. Key contents:
  - `BSP_CustomInit()`: Disable the sleep manager watchdog
    (`slpManAonWdtStop()` — without this, the device reboots after ~27s).
    Set the print UART to UART1.
  - UART1 receive callback: Forward UART events to `toit_uart_event()`.
  - Panic/fault handlers: Install custom HardFault, MemManage, BusFault,
    and UsageFault handlers that dump registers and a stack trace to the
    serial console before halting. This is invaluable for debugging.
- `inc/RTE_Device.h`: Pin mux configuration for I2C (needed for section 15).

**Project Makefile build options** (in `GCC/Makefile`):
```
LITE_FEATURE_MODE_ENABLE     = y     # Saves ~16KB flash
LOW_SPEED_SERVICE_ONLY_ENABLE = y    # Saves ~170KB RAM (trades CPU speed)
THIRDPARTY_DHCPD_ENABLE      = n    # Saves ~12KB (not needed for client)
THIRDPARTY_MQTT_ENABLE        = n
THIRDPARTY_HTTPC_ENABLE       = n
THIRDPARTY_IPERF_ENABLE       = n
THIRDPARTY_PING_ENABLE        = n
THIRDPARTY_CJSON_ENABLE       = n
```

**2. cmpctmalloc integration** (needed for section 5)

This is the most involved PLAT change. The stock SDK uses heap_6 (tlsf).
Toit needs cmpctmalloc for heap tagging and memory reporting.

- Add `PLAT/os/freertos/portable/mem/cmpctmalloc/` directory with
  `cmpctmalloc.c` and `cmpctmalloc.h`. These are taken from the Toit
  ESP-IDF port (the same cmpctmalloc used on ESP32) and adapted:
  remove ESP-IDF-specific includes, use FreeRTOS `vTaskSuspendAll` /
  `xTaskResumeAll` for locking.
- Create `PLAT/os/freertos/src/heap_7.c`: A new heap implementation
  (alongside the existing heap_6.c) that delegates to cmpctmalloc. It
  provides all the standard FreeRTOS heap functions (`pvPortMalloc`,
  `vPortFree`, `pvPortRealloc`, `pvPortMemalign`) plus the Toit-specific
  ones (`vPortGetHeapStats`, `vPortIterateAllocations`). Also wraps
  Newlib's `_malloc_r` / `_free_r` / `_realloc_r` via `--wrap` linker
  flags.
- In `PLAT/os/freertos/inc/FreeRTOS.h`: Change
  `configSUPPORT_DYNAMIC_ALLOC_HEAP` from 6 to 7 (selects heap_7).
- In `PLAT/os/freertos/inc/portable.h`: Add declarations for
  `heap_stats_t`, `tagged_memory_callback_t`, `vPortGetHeapStats()`,
  `vPortIterateAllocations()`, and the `MALLOC_ITERATE_*` flag constants.
- In `PLAT/os/freertos/Makefile.inc`: Add the cmpctmalloc directory to
  include paths and source directories.
- In `PLAT/os/freertos/CMSIS/ap/inc/FreeRTOSConfig.h`:
  - Set `configNUM_THREAD_LOCAL_STORAGE_POINTERS` to 2 (slot 0: Toit
    thread pointer, slot 1: cmpctmalloc heap tag).

**3. FreeRTOS configuration** (needed for sections 4, 9)

In `PLAT/os/freertos/CMSIS/ap/inc/FreeRTOSConfig.h`:
- Tickless idle: The stock SDK sets `configUSE_TICKLESS_IDLE` to 2. This
  was initially disabled (set to 0) because it was broken, then re-enabled
  once deep sleep was implemented. Keep it at 2 for deep sleep to work.

In `PLAT/os/freertos/src/tasks.c`:
- Re-enable `_reclaim_reent()` for Newlib. The stock SDK had this
  commented out. Without it, task-local Newlib state leaks memory.

In `PLAT/os/freertos/portable/gcc/port.c`:
- Enable floating-point support for printf/scanf (link with `-u
  _printf_float -u _scanf_float`).
- Reduce stack alignment waste (optimize the initial stack frame setup
  to not waste extra words for alignment).

**4. Linker script changes** (needed for sections 7, 8, 9)

In the linker script (`PLAT/device/target/board/ec618_0h00/ap/gcc/ec618_0h00_flash.ld`):
- Add a `.toit.rtc.noinit` section in the ASMB (always-on SRAM) area,
  marked as `NOLOAD`. This preserves RTC memory across deep sleep.
- Capture `.init_array` (C++ static initializers) in the `.data` section
  with `__init_array_start` / `__init_array_end` symbols. Without this,
  C++ global constructors don't run, and static initialization silently
  fails.
- Both sections must go in RAM (`MSMB_AREA` or `ASMB_AREA`), not flash.

**5. OTA flash write permission** (needed for section 19)

In `PLAT/device/target/board/ec618_0h00/ap/src/system_ec618.c`:
- Add two global variables `toit_ap_image_modify_start` and
  `toit_ap_image_modify_end`.
- In the `sysROAddrCheck()` function (which prevents accidental writes
  to the AP flash image), add a check: if the address falls within the
  modify range, return 0 (allow). This lets the OTA code write to the
  active image region during firmware commit.

**6. Performance: move crypto tables to RAM** (needed for section 18)

In `PLAT/middleware/thirdparty/mbedtls/library/aes.c` and `sha256.c`:
- Add `__attribute__((section(".data")))` to the large lookup tables
  (`FSb`, `FT0`, `RSb`, `RT0` in AES; `K` in SHA-256). Like the
  interpreter dispatch table, these are `const` but frequently accessed,
  and the flash has no data cache. Moving them to RAM gives a ~3.5x
  speedup for AES-GCM and ~2x for SHA-256.

**7. lwIP patches** (needed for section 17)

In `PLAT/middleware/thirdparty/lwip/src/core/ipv4/ip4.c` and `ipv6/nd6.c`:
- Wrap DHCPD-related code in `#if LWIP_ENABLE_PPP_RNDIS_LAN` guards so
  it compiles when DHCPD is disabled.
- Fix an `#ifdef` to `#if` for the `LWIP_ENABLE_PPP_RNDIS_LAN` check.

**8. C++ compatibility fix** (needed for section 16)

In `PLAT/middleware/developed/qcapi/psapi/inc/ps_lib_api.h`:
- Remove the struct name from `typedef struct BearerPktStats { ... }
  BearerPktStats;` (change to `typedef struct { ... } BearerPktStats;`).
  The original form doesn't compile with a C++ compiler because
  `BearerPktStats` is used both as a struct tag and a typedef.

---

## 2. Build System

### 2.1 CMake Toolchain File

Create `toolchains/ec618.cmake`:

- Set `CMAKE_SYSTEM_NAME` to `Generic`, `CMAKE_SYSTEM_PROCESSOR` to `arm`.
- Set `TOIT_SYSTEM_NAME` to `"ec618"` — this string is matched throughout
  CMakeLists.txt and source code.
- Use `arm-none-eabi-gcc` / `arm-none-eabi-g++` as compilers.
- Key compiler flags: `-mcpu=cortex-m3 -mthumb -nostartfiles -mapcs-frame
  -specs=nano.specs -ffunction-sections -fdata-sections
  -fno-isolate-erroneous-paths-dereference -freorder-blocks-algorithm=stc
  -gdwarf-2`.
- Add include directories pointing into the PLAT SDK hierarchy (board headers,
  chip headers, FreeRTOS headers, lwIP headers, CMSIS headers, middleware
  headers, prebuild headers). There are roughly 15 include paths.
- Add compile definitions:
  - `__EC618`, `CHIP_EC618`, `CORE_IS_AP` — platform identification
  - `__FREERTOS__` — enables FreeRTOS code paths
  - `SDK_REL_BUILD`, `configUSE_NEWLIB_REENTRANT=1`, `ARM_MATH_CM3`
  - `CONFIG_TOIT_ENABLE_IP` — enables lwIP/TCP/UDP networking
  - `CONFIG_TOIT_CRYPTO` — enables TLS/crypto support
  - `CONFIG_TOIT_FONT`, `CONFIG_TOIT_BITMAP`, `CONFIG_TOIT_BIT_DISPLAY`,
    `CONFIG_TOIT_BYTE_DISPLAY` — enables display/font primitives
  - A debug log header override pointing to a dummy header in PLAT
  - `LWIP_CONFIG_FILE` pointing to the EC618-specific lwIP config

**Important details**:
- The ASM flags are different from C/C++ flags and include `--apcs=interwork`
  and `__MICROLIB`.
- Set `FIND_LIBRARY_USE_LIB64_PATHS OFF` to avoid library search issues on
  the host.

### 2.2 CMakeLists.txt Changes

In the top-level `CMakeLists.txt`:

- Change the mbedTLS include path from the ESP-IDF bundled one
  (`${IDF_PATH}/components/mbedtls/mbedtls/include`) to
  `third_party/mbedtls/include`.
- Add an `elseif` for `TOIT_SYSTEM_NAME` matching `ec618` that sets
  `MBEDTLS_C_FLAGS` with a config file pointing to
  `third_party/mbedtls_config_toit.h`.
- Exclude `tools/`, `examples/`, and `external/` subdirectories when building
  for EC618 (same as ESP32 exclusion).
- Move the mbedTLS `add_subdirectory` call outside of the `!esp32` block so
  that it is also built for EC618. Point it at `third_party/mbedtls`.

### 2.3 Makefile Changes

Add a `ec618` Make target that:

1. Builds the host SDK first (`make sdk`).
2. Cross-compiles the Toit VM: `make TARGET=ec618 TOOLCHAIN=ec618 ec618-vm`
   (which runs `ninja toit_vm` in the cross build directory).
3. Builds mbedTLS: `make TARGET=ec618 TOOLCHAIN=ec618 mbedtls`.
4. Copies the resulting static libraries (`libtoit_vm.a`, `libmbedtls.a`,
   `libmbedx509.a`, `libmbedcrypto.a`) into the PLAT output directory.
5. Invokes the PLAT Makefile to link everything into a final binary.
6. Compiles the system snapshot using the host `toit.compile` tool.
7. Creates a firmware envelope using the host `toit.run` tool and
   `tools/firmware.toit`.

Set the default `all` target to `ec618` instead of `sdk`.

Define configuration variables with sensible defaults:
- `EC618_PLAT_DIR ?= PLAT`
- `EC618_TARGET ?= ec618_0h00`
- `EC618_BOARD_NAME ?= ec618_0h00`
- `EC618_CORE ?= ap`
- `EC618_PROJECT ?= toit`
- `EC618_SYSTEM_ENTRY = system/extensions/ec618/boot.toit`

**Note**: Add `.NOTPARALLEL` to each phony target. The EC618 build has
sequential dependencies between targets that don't work well with Make's
parallel execution.

### 2.4 Third-Party Dependencies: mbedTLS

The upstream Toit host build uses the mbedTLS copy bundled inside
`third_party/esp-idf/components/mbedtls/mbedtls/`. This cannot be used for
the EC618 cross-build because:

- **ESP-specific config**: The ESP-IDF build uses `esp_config.h` as the
  mbedTLS config file, which pulls in ESP-IDF headers (`esp_config.h`
  includes `sdkconfig.h`, `esp32/*` headers, etc.). These don't exist when
  cross-compiling for the EC618.
- **Threading model**: The EC618 needs `MBEDTLS_THREADING_ALT` with
  FreeRTOS/CMSIS-OS2 mutex wrappers, not the ESP-IDF threading
  implementation.
- **Hardware entropy**: The EC618 provides entropy via its own hardware RNG
  (`rngGenRandom`), configured through `MBEDTLS_ENTROPY_HARDWARE_ALT`. The
  ESP-IDF version uses `esp_fill_random`.
- **Memory tuning**: The EC618 has tighter RAM constraints and needs smaller
  SSL buffers (e.g., 7800 bytes in, 3800 bytes out, vs. the typical 16KB).

Instead, add a standalone mbedTLS as a git submodule:

```
git submodule add https://github.com/Mbed-TLS/mbedtls.git third_party/mbedtls
cd third_party/mbedtls
git checkout v2.28.3   # or whichever 2.28.x is current
git submodule update --init  # mbedtls has its own submodules (e.g., everest)
```

Use the 2.x branch (not 3.x) — the Toit codebase uses the mbedTLS 2.x API
throughout (e.g., `MBEDTLS_ALLOW_PRIVATE_ACCESS` patterns, direct struct
access). The PLAT SDK also ships mbedTLS 2.28.x internally.

Then create `third_party/mbedtls_config_toit.h` — a custom mbedTLS
configuration header for the EC618. Key settings:
- `MBEDTLS_THREADING_C` + `MBEDTLS_THREADING_ALT` (FreeRTOS mutexes)
- `MBEDTLS_ENTROPY_HARDWARE_ALT` (hardware RNG)
- `MBEDTLS_SSL_MAX_CONTENT_LEN = 7800`
- `MBEDTLS_SSL_MAX_OUT_CONTENT_LEN = 3800`
- `MBEDTLS_AES_FEWER_TABLES` (saves ~6KB of RAM)
- Enable: AES, SHA family, ECDSA, ECDH, RSA, ChaCha20-Poly1305, GCM,
  X.509, SSL/TLS client
- The config must `#include "FreeRTOS.h"` and `#include "cmsis_os2.h"` for
  the threading types

Update `.gitmodules` to add the mbedtls submodule entry. The `esp-idf`
submodule entry can be removed if it's not needed for this port.

**Verification**: `make ec618` should complete successfully, producing
`PLAT/gccout/ec618_0h00/ap/toit/ap_toit.bin` and a firmware envelope.

---

## 3. Platform Detection and Compile Definitions

### File: `src/top.h`

This is the central platform detection header. Add a new `#elif` block after
the ESP32 detection:

```
#elif defined(__EC618)
  → define TOIT_EC618
  → include "FreeRTOS.h"
  → if configSUPPORT_DYNAMIC_ALLOC_HEAP == 7, define TOIT_CMPCTMALLOC 1
```

The FreeRTOS heap mode 7 check enables cmpctmalloc, which is a compact malloc
implementation used for heap tagging and reporting.

Also:
- Add `TOIT_EC618` to the mutual-exclusion check (the line that ensures only
  one OS is defined).
- Add `__EC618` to the 32-bit architecture detection (alongside `ESP32` and
  `__WIN32`).

**Key insight**: `TOIT_EC618` implies FreeRTOS but NOT ESP32. Many existing
`#ifdef TOIT_FREERTOS` blocks were actually ESP32-specific and need to be
changed to `#ifdef TOIT_ESP32`. Conversely, some `TOIT_ESP32` checks should be
generalized to `TOIT_FREERTOS` so they cover EC618 too. This is a recurring
theme throughout the codebase.

---

## 4. OS Abstraction Layer

### 4.1 New File: `src/os_ec618.cc`

This is the main OS abstraction for EC618. It implements all the `OS::`
methods that the Toit VM requires. Use `src/os_esp32.cc` as a reference, but
replace ESP-IDF APIs with FreeRTOS/EC618 equivalents.

**Key implementations**:

- **Mutexes**: Wrap FreeRTOS `xSemaphoreCreateMutex` /
  `xSemaphoreTake`/`xSemaphoreGive`. Implement lock-level checking (debug
  assertion that locks are always acquired in increasing level order to prevent
  deadlocks).

- **Condition variables**: Implement using FreeRTOS task notifications
  (`xTaskNotifyWait` / `xTaskNotify`). Maintain a tail-queue of waiters. Use
  two signal bits: `SIGNAL_ONE` and `SIGNAL_ALL`. When a `signal_all` bit is
  received by a waiter, it must re-signal to propagate the wake-up to other
  waiters. This is the trickiest part of the implementation.

- **Threads**: Wrap FreeRTOS `xTaskCreate`. Use thread-local storage pointer
  slot 0 to store the `Thread*`. Thread join is implemented via a binary
  semaphore (`terminated`) that is given when the thread's entry function
  returns. Default stack size: 2KB.

- **Time**:
  - `get_system_time()`: Use `RtcMemory::wakeup_time() +
    osKernelGetTickCount()` converted to milliseconds. This accounts for time
    spent in deep sleep.
  - `monotonic_gettime()`: Use `osKernelGetTickCount()` converted to
    microseconds via `portTICK_PERIOD_MS`. Note: the granularity is low
    (millisecond-level ticks). A TODO exists for finding a more precise source.
  - `get_real_time()`: Read the RTC via `OsaSystemTimeReadRamUtc()`, which
    returns UTC seconds and milliseconds.
  - `set_real_time()`: Use `OsaTimerSync()` with `APP_TIME_SRC` and
    `SET_LOCAL_TIME`. Requires packing the time into three uint32 values
    (year/month/day, hour/min/sec, milliseconds).

- **Memory allocation**: `allocate_pages()` uses `aligned_alloc` with
  `TOIT_PAGE_SIZE` alignment. `grab_virtual_memory()` just uses `malloc`
  (there's no virtual memory on this MCU).

- **Heap memory range**: Uses `vPortGetHeapStats()` when cmpctmalloc is
  enabled, otherwise uses linker-defined symbols (`end_ap_data` and
  `start_up_buffer`) to determine the heap extent.

- **Entropy / RNG**: Implement `mbedtls_hardware_poll()` (as an `extern "C"`
  function) using the EC618's hardware RNG via `rngGenRandom()`. This
  provides 24 bytes of randomness per call. Note: process-level random seeding
  is temporarily using a constant seed — this should be fixed to use the
  hardware RNG.

- **Platform identification**: `get_platform()` returns `"FreeRTOS"`,
  `get_architecture()` returns `"ec618"`.

- **Unsupported operations**: `read_entire_file()` returns -1, `getenv()` /
  `setenv()` / `unsetenv()` are `UNIMPLEMENTED()` by design.

- Print startup info: `printf("[toit] INFO: running on EC618 @ %ldMHz\n",
  SystemCoreClock / 1000000)`.

### 4.2 New File: `src/os_freertos.cc` / `src/os_freertos.h`

Extract the heap summary reporting code from `src/os_esp32.cc` into shared
files that both ESP32 and EC618 can use.

The `HeapSummaryCollector` class and `HeapSummaryPage` class are moved here.
The key difference from the ESP32 version:
- ESP32 uses `heap_caps_get_info()` and `heap_caps_iterate_tagged_memory_areas()`.
- EC618 uses `vPortGetHeapStats()` and `vPortIterateAllocations()`.

Conditionally compile with `#if defined(TOIT_FREERTOS) && defined(TOIT_CMPCTMALLOC)`.

The `register_allocation` callback's return type changes from `bool` to `int`
for the EC618 cmpctmalloc API. Similarly, in `src/heap_report.h`, the
`HeapFragmentationDumper::log_allocation` static method returns `int` instead
of `bool`, and `compute_allocation_type` takes a `word` instead of `uword`.

### 4.3 Changes to `src/os_esp32.cc`

- Move the `HeapSummaryCollector` / `HeapSummaryPage` classes out to
  `os_freertos.cc`.
- Include `os_freertos.h`.
- The ESP32 `heap_summary_report` calls the shared `HeapSummaryCollector` but
  uses `heap_caps_iterate_tagged_memory_areas` for iteration.
- Change `register_allocation` return type from `bool` to `int`.
- Add the marker string to the "not enough memory" printf.
- In non-cmpctmalloc fallback, print the marker via `puts()` instead of
  hardcoded "Out of memory".

### 4.4 Changes to `src/os.cc`

Add `#ifdef TOIT_EC618` blocks for:
- `monotonic_gettime()`: Use FreeRTOS tick count instead of `clock_gettime`.
- `get_real_time()`: Use the EC618 UTC timer instead of `clock_gettime`.

Include EC618-specific headers (`"FreeRTOS.h"`, `"cmsis_os2.h"`, and
`"osasys.h"` via `extern "C"`).

### 4.5 Changes to `src/os_posix.cc` and `src/os_win.cc`

In `heap_summary_report()`, change the hardcoded `"Out of memory"` message to
use the `marker` parameter. This is a quality-of-life improvement that applies
to all non-ESP32 platforms.

**Verification**: The VM should boot, print the startup message with the clock
frequency, and be able to create threads and mutexes without deadlocking.

---

## 5. Memory Management

### 5.1 `src/third_party/dartino/gc_metadata.cc`

Remove the `#elif defined(TOIT_FREERTOS) → FATAL("UNIMPLEMENTED")` block. The
EC618 does not need the ESP32-specific heap adjustments (which account for
the first 108k of DRAM). The generic code path works fine.

### 5.2 `src/process.cc`

In `_ensure_random_seeded()`, add a temporary `#ifdef TOIT_EC618` that
fills the seed with a constant value (bypassing the entropy mixer). This is a
known limitation — entropy support should be connected to the hardware RNG
later.

### 5.3 `src/scheduler.cc`

In `process_stats()`, change `#ifdef TOIT_FREERTOS` to `#ifdef TOIT_ESP32`
for the `heap_caps_get_info` call. Add a TODO for implementing proper heap
stats on EC618. The fallback provides `Smi::MAX_SMI_VALUE` for free bytes
and largest free block.

### 5.4 Heap Dump (`src/primitive_core.cc`)

Generalize heap dump support:
- Change `#if defined(TOIT_LINUX) || defined(TOIT_ESP32)` to
  `#if defined(TOIT_LINUX) || defined(TOIT_FREERTOS)`.
- Inside, add `#ifdef TOIT_ESP32` / `#else` branches: ESP32 uses
  `heap_caps_iterate_tagged_memory_areas`, EC618 uses
  `vPortIterateAllocations`.
- Remove the `#ifdef TOIT_CMPCTMALLOC` guard around
  `serial_print_heap_report` so it compiles on all platforms (the function
  is a no-op without cmpctmalloc anyway).

**Verification**: `import system; system.print-heap-report "test"` from Toit
should print a heap summary without crashing.

---

## 6. Flash Registry and Storage

### 6.1 New File: `src/flash_registry_ec618.cc`

Implement the `FlashRegistry` class for EC618. Key details:

- Use a dedicated 384KB flash region between the AP image and the FOTA area,
  starting at a fixed offset (e.g., `0x002a4000`).
- The region is accessible via XIP (execute-in-place) at
  `AP_FLASH_XIP_ADDR + REGION`.
- Use `BSP_QSPI_Erase_Safe()`, `BSP_QSPI_Write_Safe()`, and
  `BSP_QSPI_Read_Safe()` from the PLAT SDK for flash operations.
- Erase granularity is `FLASH_PAGE_SIZE`.
- The `flush()` method is a no-op (no data cache on this platform).
- Smart erase: only erase pages that aren't already erased (check for all-0xFF
  bytes before erasing).

### 6.2 Changes to `src/primitive_flash_registry.cc`

This file needs several modifications:

- **Remove the outer `#if !defined(FREERTOS) || defined(TOIT_ESP32)` guard**.
  The flash registry is now available on all FreeRTOS platforms.
- Add `#include "flash_rt.h"` under `#elif defined(TOIT_EC618)`.
- **`partition_find` primitive**: Return `FAIL(FILE_NOT_FOUND)` on EC618 —
  there is no ESP-style partition table.
- **`region_read/write/erase` primitives**: Add `#elif defined(TOIT_EC618)`
  branches that use `BSP_QSPI_Read_Safe`, `BSP_QSPI_Write_Safe`, and
  `BSP_QSPI_Erase_Safe`.
- **`region_is_erased` primitive**: Change the outer guard from `TOIT_ESP32`
  to `TOIT_FREERTOS`, then add inner ESP32/EC618 branches for the read call.
- **Add two new primitives**:
  - `get_all_pages`: Returns a proxy byte array pointing to the full flash
    allocation (not just the header page). Used by the bucket storage
    implementation to read multi-page allocations.
  - `write_non_header_pages`: Writes content to a flash allocation starting
    after the header page. Used for multi-page bucket storage writes.

Register these new primitives in `src/primitive.h` in the
`MODULE_FLASH_REGISTRY` macro.

### 6.3 Bucket Storage: `system/storage/bucket.toit`

The EC618 does not have an ESP-style NVS (non-volatile storage) key-value
store. Implement a flash-based bucket storage instead:

- Introduce a `BucketResource` interface and a `BucketResourceBase` abstract
  class (renamed from the original `BucketResource`).
- Comment out or replace the original `FlashBucketResource` that used NVS
  primitives.
- Implement a new `FlashBucketResource` that uses a `FlashBucket` class.
- `FlashBucket` stores key-value data in the flash registry as UBJSON-encoded
  assets:
  - Each bucket gets a UUID (uuid5 of its name in the `"flash:bucket"`
    namespace).
  - On write, the entire bucket is encoded, a new flash allocation is
    reserved, the header page is written via the standard allocate path, and
    extra pages are written via the new `write_non_header_pages` primitive.
  - On read, the allocation is found by UUID, all pages are read via
    `get_all_pages`, and entries are decoded from UBJSON.
  - Entries are cached in RAM and copied from flash to avoid dangling pointers
    when the allocation is freed.
  - Instances are shared per bucket name (singleton map) with reference
    counting.

**Verification**: Toit code that uses `import system.storage` and reads/writes
bucket entries should persist data across reboots.

---

## 7. RTC Memory

### New Files: `src/rtc_memory_ec618.cc` and `src/rtc_memory_ec618.h`

Implement RTC memory (state that persists across deep-sleep reboots). The
ESP32 version uses dedicated RTC RAM; the EC618 uses a noinit section.

**Key design**:

- Place `RtcData` struct and user data in a linker section `.toit.rtc.noinit`
  (using `__attribute__((__section__(".toit.rtc.noinit")))`). This section must
  not be zeroed on warm boot by the startup code.
- Track `boot_count` and `wakeup_time` (accumulated FreeRTOS ticks across
  sleep cycles).
- Validate with a CRC32 checksum that incorporates the embedded VM UUID. This
  ensures the RTC data is invalidated when firmware changes.
- On cold boot (`SLP_ACTIVE_STATE`) or hibernation wake (`SLP_HIB_STATE`),
  clear all RTC memory.
- On warm boot (deep sleep wake), validate the checksum and increment
  `boot_count`.
- `adjust_wakeup_time_before_sleep(ms)`: Add the current tick count plus the
  sleep duration to `wakeup_time` so the system time is approximately correct
  after waking.
- Provide 2048 bytes of user data accessible via `user_data_address()`.

**Changes to `src/primitive_core.cc`**: Change `#ifdef TOIT_FREERTOS` to
`#ifdef TOIT_ESP32` for the ESP32 RTC memory include, and add
`#ifdef TOIT_EC618` to include `rtc_memory_ec618.h`. The `rtc_user_bytes`
primitive should work for both platforms since the API is the same.

Also generalize `#ifdef TOIT_FREERTOS` → `#ifdef TOIT_ESP32` for the
`spi_flash_mmap.h` include — EC618 does not have this header.

**Verification**: `RtcMemory.boot_count` should increment across deep-sleep
cycles but reset on power cycle.

---

## 8. Embedded Data and Firmware Mapping

### Changes to `src/embedded_data.cc`

The EC618 firmware layout differs from ESP32:

- The `EmbeddedDataExtension::cast()` validation: on EC618, valid extensions
  have `HEADER_INDEX_FREE == 0` (the free field is not used). Add a check for
  this.
- The `config()` method: on EC618, skip the "free area" size check. The
  config data immediately follows the used area. Read the size, then return a
  list pointing to the data after the size field.
- Enable the `DromData` struct (used for locating embedded data in flash) for
  EC618 alongside ESP32: `#if defined(TOIT_ESP32) || defined(TOIT_EC618)`.

### Changes to `src/primitive_core.cc` — `firmware_map` / `firmware_unmap`

Add `#ifdef TOIT_EC618` handling:

- `firmware_map`: If passed non-null bytes, return them directly. Otherwise,
  create a proxy byte array that spans from a fixed flash address (`0x00824000`)
  to the end of the config data in the embedded extension. This gives the
  firmware update process access to the currently running firmware image in
  flash.
- `firmware_unmap`: Clear the proxy's external address.

### Changes to `src/primitive_programs_registry.cc`

Generalize `bundled_images` and `config` primitives from `TOIT_ESP32` to
`TOIT_FREERTOS`:
- Remove the `#elif defined(TOIT_FREERTOS) → FAIL(UNIMPLEMENTED)` fallback.
- This allows the EC618 to access bundled images and configuration, which is
  needed for the boot process and firmware updates.

**Verification**: The boot process should be able to find and load the system
snapshot from embedded data.

---

## 9. Boot Sequence and Sleep Management

### New File: `src/toit_ec618.cc`

This is the main entry point for the Toit runtime on EC618. It provides the
`toit_start()` C function that is called from the PLAT startup code.

**Boot sequence**:

1. Call C++ static initializers (`__init_array_start` to `__init_array_end`).
2. **Sleep management**: Vote against entering sleep state 1 during execution
   (`slpManPlatVoteDisableSleep`). Set the maximum sleep state to 2 (deep
   sleep with RAM preservation): `slpManSetPmuSleepMode(true, SLP_SLP2_STATE,
   false)`.
3. **Cold vs warm boot**: Check `slpManGetLastSlpState()`. On cold boot
   (`SLP_ACTIVE_STATE`), call `appSetCFUN(0)` to initialize the modem in
   minimal mode. On warm boot, cancel any running deep-sleep timer.
4. **Start protocol stack**: Call `cmsStartPs()` before initializing Toit
   (lwIP needs to be initialized first for the event source).
5. **Initialize subsystems**: `RtcMemory::set_up()`, `FlashRegistry::set_up()`,
   `OS::set_up()`, `ObjectMemory::set_up()`.
6. **Load and run the program**: Get the boot program from `EmbeddedData`,
   create a VM, load platform event sources, and run the scheduler.
7. **OTA commit**: If an OTA update was staged during execution (signaled by a
   global `ota_updated` flag), verify and commit it (see [OTA](#19-ota-firmware-updates)).
8. **Enter sleep**: Based on the scheduler exit state:
   - `EXIT_DEEP_SLEEP`: Start a deep-sleep timer (min 1s, max 2h), adjust
     the wakeup time tracker.
   - `EXIT_ERROR`: Sleep for 1s (safety restart).
   - `EXIT_DONE`: Enter deep sleep without a wakeup timer.
9. **Vote for sleep**: Re-enable sleep voting and enter a `while(true)` loop
   with `osDelay` until FreeRTOS puts the system to sleep.

**Key detail**: The deep-sleep timer has a minimum of ~1s (if set too low, it
may expire before the system actually enters sleep, causing it to never wake
up) and a maximum of ~2h.

### New File: `system/extensions/ec618/boot.toit`

The Toit-level boot script that is compiled into the system snapshot. It:

1. Scans the flash registry.
2. Initializes the system with service providers:
   - `FirmwareServiceProvider`
   - `StorageServiceProvider` (backed by the flash registry)
   - `CellularServiceProvider`
3. Registers a `SystemImage` container.
4. Calls the standard `boot` function.

**Verification**: After flashing, the device should boot, print startup
messages, and (if no user program) enter deep sleep.

---

## 10. Interpreter Performance

### Changes to `src/interpreter_run.cc`

The EC618's flash has no data cache. The interpreter's dispatch table (an
array of `void*` label addresses) would normally be in flash, causing every
bytecode dispatch to be a slow flash read.

**Fix**: Place the dispatch table in RAM using a section attribute:

```c
#ifdef TOIT_EC618
#define DISPATCH_SECTION __attribute__((section(".data")))
#else
#define DISPATCH_SECTION
#endif
```

Apply `DISPATCH_SECTION` to the `dispatch_table` static variable. This
significantly improves interpreter performance on the EC618.

**Verification**: Toit programs should run noticeably faster than if the
dispatch table were in flash. Benchmark with a tight loop.

---

## 11. Primitive Modules Registration

### Changes to `src/primitive.h`

Register three new primitive modules:

1. **`MODULE_EC618`**: OTA primitives — `ota_begin(2)`, `ota_write(1)`,
   `ota_end(1)`.
2. **`MODULE_CELLULAR`**: Cellular modem control — `init(0)`, `close(1)`,
   `connect(1)`, `disconnect(2)`, `disconnect_reason(1)`, `get_ip(2)`,
   `get_cell_info(0)`.
3. **`MODULE_UART_EC618`**: UART receive — `init(0)`, `create(1)`,
   `close(2)`, `read(1)`.

Also:
- Add unpacking macros for `UartEc618ResourceGroup`, `CellularResourceGroup`,
  `CellularEvents`, `UartEc618Resource`.
- Change `gpio.config_interrupt` from 2 args to 3 args (adds a `value`
  parameter for level-triggered interrupts).
- Add `get_all_pages(1)` and `write_non_header_pages(2)` to
  `MODULE_FLASH_REGISTRY`.

### Changes to `src/tags.h`

Register new resource tags: `CellularEvents`, `UartEc618Resource`,
`UartEc618ResourceGroup`, `CellularResourceGroup`.

### Compiler Propagation Files

Create three new files in `src/compiler/propagation/`:
- `type_primitive_ec618.cc`
- `type_primitive_cellular.cc`
- `type_primitive_uart_ec618.cc`

These are boilerplate: each declares `MODULE_TYPES(name, MODULE_NAME)` and
lists each primitive with `TYPE_PRIMITIVE_ANY(name)`. Follow the pattern of
existing files like `type_primitive_esp32.cc`.

---

## 12. Event System

### New Files: `src/event_sources/uart_ec618.cc` and `.h`

The EC618 event system is simpler than ESP32's. Instead of using ESP-IDF's
event loop, it uses a FreeRTOS queue to deliver events from ISR context to the
Toit event processing thread.

**Architecture**:

- `Ec618EventSource` extends both `EventSource` and `Thread`.
- It owns a FreeRTOS queue (`xQueueCreate(32, sizeof(Event))`).
- ISR handlers (UART, GPIO) push events into this queue via
  `xQueueSendFromISR`.
- The event thread loops on `xQueueReceive`, then dispatches events to
  matching resources.
- The `Event` struct has a `Type` enum (STOP, UART, GPIO_NUM_0..GPIO_NUM_31)
  and a `data` field.

**`EventResource`** is a `Resource` subclass that stores an `Event::Type` for
matching.

This event source is shared by UART, GPIO, and potentially other peripherals.
It's a singleton accessed via `Ec618EventSource::instance()`.

### New Files: `src/event_sources/cellular_ec618.cc` and `.h`

Separate event source for cellular URC (unsolicited result codes):

- `CellularEventSource` extends `EventSource`.
- A static `on_urc` callback is registered with `registerPSEventCallback`.
- When the protocol stack delivers an event, `on_urc` wraps it in a
  `CellularEvent` struct and dispatches it to all registered resources.
- Note: `Thread::ensure_system_thread()` must be called on every URC callback
  because the callback may come from any thread.

### New File: `src/vm_ec618.cc`

Register platform event sources:
- `TimerEventSource` (from existing code)
- `CellularEventSource` (new)
- `Ec618EventSource` (new)
- `LwipEventSource` (existing, conditional on `CONFIG_TOIT_ENABLE_IP`)
- `TlsEventSource` (existing, conditional on `CONFIG_TOIT_ENABLE_IP`)

---

## 13. UART Support

### New File: `src/resources/uart_ec618.cc`

Implements a receive-only UART using the CMSIS USART driver. This is used for
debug console input.

**Design**:
- Uses a circular buffer with 4 segments of 1024 bytes each.
- DMA transfers fill segments; on completion or timeout, the ISR notifies the
  event source.
- Read/write segment pointers track consumption. Overflow is handled by
  advancing the read pointer and signaling an error.
- The UART driver is accessed via `UsartPrintHandle` (a global set up by PLAT).
- A C callback `toit_uart_event()` is registered with the USART driver and
  forwards events to the event source.

**Primitives**: `init`, `create`, `close`, `read` (returns available bytes as
a byte array, or null if none available).

**Verification**: Reading from the UART in Toit should return bytes typed on
the debug console.

---

## 14. GPIO and Pin Support

### New File: `src/resources/gpio_ec618.cc`

Implements GPIO control. The EC618 has 32 GPIO pins organized in 2 ports of
16 pins each (port = pin >> 4, pin_in_port = pin & 0xf).

**Key design decisions**:

- **AON (Always-On) pins** (20-27): These require powering on a separate power
  domain before use. Track AON users with a reference count; power on the
  domain by writing `0x1` to register `0x4D020170` on first use, power off on
  last release.
- **Interrupts**: Use level-triggered interrupts (not edge-triggered). When an
  interrupt fires, disable further interrupts on that pin immediately (to avoid
  an infinite loop), then push a GPIO event to the event queue. Use a
  monotonically increasing counter instead of a timestamp for edge detection
  ordering (since getting a precise timestamp in an ISR is difficult).
- **ISR handler**: Registered via `XIC_SetVector(PXIC1_GPIO_IRQn, handler)`.
  Iterates over both ports, reads interrupt flags, dispatches events per pin,
  and clears flags.
- **Limitations**: Pull-up/pull-down and open-drain are not yet implemented
  (would require PAD configuration via `PAD_setPinConfig`, but there's no
  known GPIO-to-PAD mapping). These primitives return `FAIL(UNIMPLEMENTED)`.

### Changes to `lib/gpio/pin.toit`

The `gpio_config_interrupt_` primitive gains a third parameter: `value/int`.
This tells the driver whether to trigger on high level or low level. Update all
call sites in `wait_for` and the `finally` cleanup.

### Changes to `src/primitive.h`

Change `config_interrupt` from 2 to 3 arguments in the GPIO module.

**Verification**: Toggle an LED on pin 27, read a button on pin 1. Use
`pin.wait-for 0` / `pin.wait-for 1` to wait for level changes.

---

## 15. I2C Support

### New File: `src/resources/i2c_ec618.cc`

Implements I2C using the CMSIS `ARM_DRIVER_I2C` interface.

**Key details**:

- Two I2C ports: I2C0 (pins 12/13 or 16/17) and I2C1 (pins 4/5 or 8/9).
  Currently only 12/13 and 8/9 are enabled.
- Pin-to-port mapping is hardcoded based on the PLAT's `RTE_Device.h`
  configuration.
- Supported frequencies: 100kHz (standard), 400kHz (fast), 1MHz (fast+),
  3.4MHz (high-speed).
- Initialization sequence: `driver->Initialize(null)`,
  `driver->PowerControl(ARM_POWER_FULL)`,
  `driver->Control(ARM_I2C_BUS_SPEED, ...)`,
  `driver->Control(ARM_I2C_BUS_CLEAR, 0)`.
- Write operations: The I2C register address and data payload must be sent as
  a single contiguous buffer. The implementation mallocs a temporary buffer,
  copies the register address prefix and data, then calls `MasterTransmit`.
- Read operations with register address: First `MasterTransmit` with
  `pending=true` (repeated start), then `MasterReceive`.
- Resource cleanup: `PowerControl(ARM_POWER_OFF)` then `Uninitialize()`.

**Note**: The existing `MODULE_I2C` primitives in `src/primitive.h` are reused
— no new primitive module is needed. The EC618 implementation is compiled
instead of the ESP32 one based on the `TOIT_EC618` define.

**Verification**: Read a BME280 temperature sensor or scan for I2C devices.
The example `examples/ec618-io` demonstrates I2C with BME280 and SSD1306.

---

## 16. Cellular Networking

### New File: `src/resources/cellular_ec618.cc`

Implements cellular modem control through the EC618 protocol stack.

**Architecture**:

- `CellularResourceGroup`: Manages the cellular connection. Only one instance
  allowed (via resource pool). Registers for protocol stack events via
  `registerPSEventCallback(PS_GROUP_ALL_MASK, callback)`.
- `CellularEvents`: A resource that tracks connection state (STOPPED, STARTED,
  CONNECTED).
- Event handling (`on_event`): Processes protocol stack URCs:
  - `PS_URC_ID_PS_NETINFO` with `NM_NETIF_ACTIVATED`: Extract IPv4 address,
    set CELLULAR_ATTACHED state.
  - `PS_URC_ID_PS_NETINFO` with `NM_NO_NETIF_OR_DEACTIVATED`: Set
    CELLULAR_DETACHED state.
  - `PS_URC_ID_PS_CEREG_CHANGED`: Log registration changes.
  - `PS_URC_ID_MM_NITZ_REPORT`: Log timezone/DST information.
  - Other events are logged for debugging.
- `connect()` calls `appSetCFUN(1)` to enable the modem.
- Cleanup calls `appSetCFUN(0)` to disable the modem.

**Cell tower information** (`get_cell_info` primitive):
- Uses `appGetECBCInfoSync_v2()` to query the serving cell information.
- Returns a 16-element array with: MCC, MNC (hex-encoded), EARFCN, cell ID,
  TAC, physical cell ID, SNR presence flag, SNR, RSRP, RSRQ, SRXLEV, TDD
  flag, band, RSSI compensation, UL bandwidth, DL bandwidth.
- Returns null if no serving cell is present, or an error code integer on
  failure.

### New File: `system/extensions/ec618/cellular.toit`

The Toit-level cellular service provider:

- Extends a `NetworkServiceProviderBase` (see
  [shared network base](#shared-network-base) below).
- Connection flow: Initialize the cellular module, wait for
  `CELLULAR_ATTACHED` event (with 30s timeout), extract IP address, configure
  DNS fallback servers (the cellular network doesn't always supply DNS
  servers).
- Disconnection: Dispose event state, call `cellular-close_`, notify all
  network resources.
- Provides `address` (returns the assigned IP) and `resolve` (DNS lookup)
  handlers.

### New File: `lib/net/cellular.toit` (additions)

Add the `TowerInfo` class with all LTE cell tower fields:
- mobile-country-code, mobile-network-code, channel (EARFCN), cell-id,
  tracking-area-code, physical-cell-id, snr, rsrp, rsrq, signal-receive-level,
  is-tdd, band, rssi-compensation, uplink-bandwidth, downlink-bandwidth.
- A `get-tower-info` function that calls the `get_cell_info` primitive and
  decodes the hex-encoded MCC/MNC values into decimal.
- Helper function `hex-digits-to-decimal-digits` for the MCC/MNC conversion
  (each hex digit is treated as a decimal digit).

**Verification**: Connect to the cellular network, obtain an IP address, and
make an HTTP request. Use `cellular.get-tower-info` to retrieve cell info.

---

## 17. TCP/IP Networking (lwIP)

### Changes to `src/event_sources/lwip_esp32.cc` and `.h`

Generalize the lwIP event source from ESP32 to all FreeRTOS platforms:

- Change the outer compilation guard from `TOIT_ESP32 || TOIT_USE_LWIP` to
  `TOIT_FREERTOS || TOIT_USE_LWIP`.
- In `LwipEventSource` constructor: ESP32 calls `esp_netif_init()`. EC618
  does nothing (lwIP is initialized by the protocol stack via `cmsStartPs()`).
  Add `#elif defined(TOIT_FREERTOS)` with a comment.

### Changes to `src/resources/tcp_esp32.cc`

- Change the compilation guard from `TOIT_ESP32 && CONFIG_TOIT_ENABLE_IP` to
  `TOIT_FREERTOS && CONFIG_TOIT_ENABLE_IP`.
- **Nagle's algorithm**: Disable Nagle on all TCP connections on EC618
  (`tcp_nagle_disable(tpcb)`). Nagle timers don't work correctly on this
  platform. Add this in `on_accept`, `on_connected`, and the `set_option`
  handler. Use a `force_nodelay` bool to make the NO_DELAY option always
  enabled.
- **`tcp_write` API**: The EC618's lwIP has additional parameters:
  `DATA_RAI_NO_INFO` (release assistance indication), `FALSE` (exception
  data), and `0` (sequence number). Wrap the call in `#ifdef TOIT_EC618`.
- Add `#include "pscommtype.h"` for the EC618 to get the lwIP extension
  types.

### Changes to `src/resources/udp_esp32.cc`

- Change the compilation guard to `TOIT_FREERTOS || TOIT_USE_LWIP`.
- The `on_recv` callback's return type changes from `void` to `int` (return 0
  for success). This matches the EC618's lwIP API.

### Changes to `src/resources/uart_esp32_hal.c`

- Change the guard from `__FREERTOS__` to `TOIT_ESP32`. This file is
  ESP32-specific and should not compile for EC618.

**Verification**: After cellular connection, open a TCP socket to a known
server, send data, receive a response.

---

## 18. TLS and Cryptography

### Changes to `src/resources/tls.cc`

- Change `#ifdef DEBUG_TLS` to `#ifdef MBEDTLS_DEBUG_C` (the EC618 mbedTLS
  config uses this standard define instead of a custom one).
- In `get_internals`: Change `#elif defined(TOIT_FREERTOS)` to
  `#elif defined(TOIT_ESP32)` for the ESP-IDF AES context access.

### Header Include Order Fixes

Several headers that use mbedTLS types need `#include "top.h"` added before
the mbedTLS includes, because `top.h` sets up the platform defines that
the mbedTLS config file depends on:

- `src/entropy_mixer.h`: Add `#include "top.h"` before `<mbedtls/error.h>`.
- `src/sha.h`: Add `#include "top.h"` before `<mbedtls/sha256.h>`.
- `src/resources/x509.h`: Add `#include "../top.h"` before `<mbedtls/x509_crt.h>`.
- `src/resources/x509.cc`: Move `#include "x509.h"` before the conditional
  compilation guard.
- `src/bignum.cc`: Has a duplicate `#include "top.h"` — ensure it appears
  before `#define MBEDTLS_ALLOW_PRIVATE_ACCESS`.
- `src/primitive_font.cc`: Add `#include "top.h"` at the top.

### Changes to `lib/tls/session.toit`

Move `group := tls-group.use` before the `try` block. On EC618, the TLS
group needs to be acquired before entering the try block to avoid a race
condition where the group is not properly cleaned up on timeout.

**Verification**: Make an HTTPS request (e.g., to a cloud endpoint) after
establishing a cellular connection.

---

## 19. OTA Firmware Updates

> **SUPERSEDED (2026-06-07).** This section documents the *original* FOTA-staging
> OTA (single AP image, `ota_begin`/`ota_write`/`ota_end` → FOTA region →
> copy-into-active on commit). That approach has been **replaced** by dual-slot
> VM OTA on the standard `system.firmware` API: two 768 KB VM slots, one
> position-independent image relocated per slot (relocate-on-write via
> `FirmwareWriter`, un-relocate-on-read via `firmware.map`), esp-idf-style
> trial+rollback on the `.slot_marker`. The `ota_begin/write/end` primitives and
> the FOTA region described below are gone. See
> [ota-relocation-convergence.md](ota-relocation-convergence.md) for the current
> design. The text below is kept for historical context.

### New File: `src/primitive_ec618.cc`

Implements the OTA (Over-The-Air) update primitives:

- **`ota_begin(from, to)`**: Validate the range. Calculate the actual write
  region in flash (the "FOTA region" at `FLASH_FOTA_REGION_START`). The prefix
  (VM + system code) is skipped — only the new extension data is written.
  Only one OTA session can be active at a time.
- **`ota_write(bytes)`**: Write firmware bytes to the FOTA flash region. Skip
  bytes that fall within the prefix (they're identical to what's already
  flashed). Erase flash pages as needed. Handle the final write which may not
  be aligned to `FLASH_SEGMENT_SIZE` (16 bytes) by padding with zeros.
- **`ota_end(size)`**: If size is non-zero, set the global `ota_updated` flag
  so the shutdown code knows to commit the update. Reset OTA state.

### OTA Commit (in `src/toit_ec618.cc`)

After the VM shuts down, if `ota_updated` is true:

1. Compute the unmodified prefix size (from `AP_FLASH_LOAD_ADDR` to the start
   of the embedded data extension).
2. Verify the new firmware image in the FOTA region by computing a SHA-256
   hash (using the `Sha` class) over the prefix + new extension data.
3. Check that the SHA matches the checksum stored at the end of the image.
4. Erase the target flash region and copy the FOTA data into the active image
   location. Use a RAM buffer as intermediary (can't copy flash-to-flash
   directly).
5. Allow flash modifications via a guard object (`AllowFirmwareModifications`)
   that sets linker-defined variables `toit_ap_image_modify_start` /
   `toit_ap_image_modify_end` to permit writes to the active image region.
6. Print the verification SHA for the update initiator (e.g., Artemis CLI) to
   recognize.

### New File: `system/extensions/ec618/firmware.toit`

Toit-level firmware service:

- `FirmwareServiceProvider`: Extends `FirmwareServiceProviderBase`. Provides
  firmware configuration (decoded from embedded UBJSON config). Validation and
  rollback are not implemented (no dual-partition scheme). `upgrade()` triggers
  a deep sleep of 10ms (effectively a reboot).
- `FirmwareWriter_`: Implements buffered writes with page alignment. Buffers
  4096 bytes, flushing in 16-byte-aligned chunks. Handles the final flush
  with non-aligned sizes. On commit, writes remaining bytes and calls
  `ota_end_`.

**Verification**: Use the Artemis CLI or equivalent to push a firmware update
over the network. The device should download, verify, commit, and reboot with
the new firmware.

---

## 20. Toit Libraries and System Extensions

### New File: `lib/ec618/ec618.toit`

A minimal library that exposes the `deep-sleep` function:

```
deep-sleep duration/Duration -> none:
  __deep-sleep__ duration.in-ms
```

This calls the `__deep_sleep__` built-in which is handled by the scheduler.

### Shared Network Base

The cellular service provider uses a `NetworkServiceProviderBase` class that
provides common network service functionality. This is shared infrastructure
for cellular (and potentially WiFi/Ethernet on other platforms). The pattern
follows the existing ESP32 WiFi service provider but is adapted for cellular.

**Verification**: Import `ec618` and call `ec618.deep-sleep (Duration --s=60)`
— the device should enter deep sleep and wake up after 60 seconds.

---

## 21. Newlib / libc Compatibility

The EC618 uses Newlib (nano spec), which has some limitations:

### Integer Formatting in `src/primitive_core.cc`

Newlib's `snprintf` doesn't support 64-bit format specifiers (`PRId64`,
`PRIo64`, `PRIx64`) well. The integer-to-string conversion is refactored:

- Rename `printf_style_integer_to_string` to `int_to_string_using_printf` and
  change it to use plain `int` (`%d`, `%o`, `%x`) instead of 64-bit formats.
- Add a separate `int64_to_string` function that manually converts 64-bit
  values using digit-by-digit extraction.
- The fast path (`int_to_string_using_printf`) is used when the value fits in
  a 32-bit int.
- The `smi_to_string_base_10` primitive: Use `%d` instead of `%zd` on EC618
  (`%zd` is incorrectly handled by Newlib, outputting "zd" literally).
- The `printf_style_int64_to_string` primitive: For values > INT_MAX, use the
  manual `int64_to_string` with unsigned printing.

### File Operations in `src/primitive_file_non_win.cc`

Exclude the entire file from EC618 compilation by changing the guard to
`#if !defined(TOIT_EC618) && (defined(TOIT_POSIX) || defined(TOIT_FREERTOS))`.
The EC618 has no filesystem.

**Verification**: `"$12345678901234"` should print correctly. Negative numbers
and various bases (2, 8, 10, 16) should all format properly.

---

## 22. Heap Reporting

### Changes to `src/heap_report.cc`

The heap fragmentation dumper and allocation iterator need platform-specific
branches:

- Include `"portable.h"` (cmpctmalloc header) when `TOIT_CMPCTMALLOC` is
  defined but not on ESP32.
- Split the `#endif` for TOIT_ESP32 and add `#ifdef TOIT_FREERTOS` for the
  serial fragmentation dumper (shared between ESP32 and EC618).
- In `dump_heap_fragmentation`: ESP32 uses
  `heap_caps_iterate_tagged_memory_areas`, EC618 uses
  `vPortIterateAllocations`.
- Change `compute_allocation_type` parameter from `uword` to `word`.

### Changes to `src/heap_report.h`

- `log_allocation` callback returns `int` instead of `bool`.
- `compute_allocation_type` takes `word` instead of `uword`.

**Verification**: `import system; system.print-heap-report "marker"` should
produce a formatted heap report on the serial console.

---

## 23. Firmware Tooling (`tools/firmware.toit`)

The upstream `tools/firmware.toit` is an ESP32-centric tool that creates
firmware envelopes, flashes devices via esptool, and extracts images. It needs
significant adaptation for EC618.

### Key changes:

- **Envelope format version**: Change from 6 to 1000 (a completely different
  format to avoid confusion with ESP32 envelopes).
- **Remove ESP32-specific entries**: Drop `partitions.bin`, `partitions.csv`,
  `otadata.bin`, and `flashing.json` from the envelope format. EC618 doesn't
  use ESP-IDF partition tables.
- **Simplify `create-envelope`**: Don't parse the firmware binary as an
  `Esp32Binary` or strip DROM extensions. Just include the raw firmware binary
  directly.
- **Replace esptool with ectool**: The EC618 uses `ectool` (a custom flashing
  tool) instead of esptool. Replace all `find-esptool_` references with
  `find-ectool_`. The tool lookup checks `ECTOOL_PATH` env var, then looks for
  it next to the firmware binary, then in PATH.
- **Binary extract format**: Instead of raw binary, convert to `.binpkg`
  format using a `convert-to-binpkg` function. This is the EC618's expected
  flash image format.
- **Remove QEMU support**: No QEMU emulation for EC618.
- **Flash command**: Simplify options — remove `baud`, change `chip` enum to
  `["ec618"]`, add `port-type` enum `["usb", "uart"]`. The flash command
  calls ectool with the binpkg file.
- **Firmware parts extraction**: Replace `Esp32Binary.parts` with a generic
  `extract-parts` function that works with the EC618 binary format.

### `tools/stacktrace.toit`

Adapt the stack trace tool to work with EC618 binaries. The main change is
using the EC618 binary format instead of the ESP32 binary format for
extracting embedded data offsets.

### Third-party: `ectool`

The `ectool` flashing tool is bundled as pre-built binaries for Linux, macOS,
and Windows in `third_party/ectool/`. It is also built from source via a
GitHub Actions workflow (`build-ectool.yml`).

---

## 24. CI Workflow

### `.github/workflows/ci.yml`

Replace the upstream CI (which tests on Linux/Mac/Windows with ESP32) with a
EC618-specific workflow:

- Use a self-hosted runner (`self-linux`).
- Build the SDK, then build the EC618 firmware.
- Run the test action.

### New: `.github/workflows/test-action.yml`

A workflow for testing the EC618 firmware build.

### New: `.github/workflows/build-ectool.yml`

Builds the `ectool` (envelope creation tool) for Linux, macOS, and Windows.

### New: `actions/build/action.yml`, `actions/envelope/action.yml`, `actions/ectool/action.yml`

Reusable GitHub Actions for the EC618 build pipeline.

---

## Summary of Files to Create

| File | Purpose |
|------|---------|
| `toolchains/ec618.cmake` | CMake toolchain |
| `src/os_ec618.cc` | OS abstraction (mutexes, threads, time, memory) |
| `src/os_freertos.cc` + `.h` | Shared heap summary code |
| `src/vm_ec618.cc` | Platform event source registration |
| `src/toit_ec618.cc` | Boot sequence, sleep, OTA commit |
| `src/primitive_ec618.cc` | OTA primitives |
| `src/flash_registry_ec618.cc` | Flash storage |
| `src/rtc_memory_ec618.cc` + `.h` | Persistent state across reboots |
| `src/resources/cellular_ec618.cc` | Cellular modem control |
| `src/resources/gpio_ec618.cc` | GPIO pin control |
| `src/resources/i2c_ec618.cc` | I2C bus driver |
| `src/resources/uart_ec618.cc` | UART receive |
| `src/event_sources/cellular_ec618.cc` + `.h` | Cellular event source |
| `src/event_sources/uart_ec618.cc` + `.h` | UART/GPIO event source |
| `src/compiler/propagation/type_primitive_ec618.cc` | Compiler type propagation |
| `src/compiler/propagation/type_primitive_cellular.cc` | Compiler type propagation |
| `src/compiler/propagation/type_primitive_uart_ec618.cc` | Compiler type propagation |
| `lib/ec618/ec618.toit` | Deep sleep library |
| `lib/net/cellular.toit` (additions) | TowerInfo class |
| `system/extensions/ec618/boot.toit` | System boot script |
| `system/extensions/ec618/cellular.toit` | Cellular service provider |
| `system/extensions/ec618/firmware.toit` | Firmware update service |
| `third_party/mbedtls_config_toit.h` | mbedTLS configuration |

## Summary of Files to Modify

| File | Nature of Change |
|------|------------------|
| `src/top.h` | Add EC618 platform detection |
| `src/primitive.h` | Register new modules and primitives |
| `src/tags.h` | Register new resource tags |
| `src/primitive_core.cc` | Newlib compat, heap dump, firmware map, RTC |
| `src/os.cc` | EC618 time implementations |
| `src/process.cc` | Temporary entropy bypass |
| `src/scheduler.cc` | Heap stats platform split |
| `src/interpreter_run.cc` | Dispatch table in RAM |
| `src/embedded_data.cc` | EC618 firmware layout |
| `src/primitive_flash_registry.cc` | Flash operations, new primitives |
| `src/primitive_programs_registry.cc` | Generalize to TOIT_FREERTOS |
| `src/primitive_file_non_win.cc` | Exclude from EC618 |
| `src/primitive_font.cc` | Add top.h include |
| `src/heap_report.cc` + `.h` | Platform-specific iteration |
| `src/os_esp32.cc` | Extract shared code, API changes |
| `src/os_posix.cc`, `src/os_win.cc` | Use marker in error messages |
| `src/bignum.cc`, `src/sha.h`, `src/sha1.h` | Add top.h includes |
| `src/entropy_mixer.h` | Add top.h include |
| `src/resources/tls.cc` | Debug defines, platform split |
| `src/resources/x509.cc` + `.h` | Include order fixes |
| `src/resources/tcp_esp32.cc` | Generalize to FreeRTOS, Nagle fix |
| `src/resources/udp_esp32.cc` | Generalize to FreeRTOS, callback type |
| `src/resources/uart_esp32_hal.c` | Restrict to ESP32 only |
| `src/event_sources/lwip_esp32.cc` + `.h` | Generalize to FreeRTOS |
| `src/third_party/dartino/gc_metadata.cc` | Remove UNIMPLEMENTED |
| `lib/gpio/pin.toit` | Add value param to config-interrupt |
| `lib/tls/session.toit` | Move group acquisition before try |
| `system/storage/bucket.toit` | Flash-based bucket storage |
| `CMakeLists.txt` | mbedTLS path, EC618 exclusions |
| `Makefile` | EC618 build target |
| `tools/firmware.toit` | Replace esptool with ectool, EC618 binary format |
| `tools/stacktrace.toit` | EC618 binary format support |
| `tests/storage-test.toit` | Tests for multi-page flash bucket storage |
| `src/compiler/propagation/type_primitive_flash.cc` | Register new flash primitives |
| `.gitmodules` | mbedtls submodule |
| `.gitignore` | Build artifacts |
