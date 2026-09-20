# RP2350 firmware updates

The RP2350 port implements whole-image firmware updates through Toit's standard
`system.firmware` service. The first transport is a line-and-binary protocol on
the application's USB CDC console. A standalone native uploader drives that
protocol, so updating an already provisioned device needs no Pico SDK, compiler,
Python, Jaguar, or mounted BOOTSEL volume.

The implementation uses the RP2350 ROM's linked A/B partitions and
try-before-you-buy (TBYB) boot flow. Both physical slots map to the same XIP
address, so the VM and its embedded Toit program use the same linked addresses
from either slot. A new image is written to the inactive slot, checked, and
selected by a flash-update reboot. The trial image must validate itself or a
subsequent normal reset returns to the confirmed image.

An update replaces the complete firmware image: the native VM, system program,
and bundled containers. Images can come from the bring-up build selected with
`TOIT_RP2350_PROGRAM` or from a firmware envelope. Separately installed
containers and storage live in the persistent registry and survive firmware
updates. There is no network stack or network update transport on this port
yet; the current uploader uses USB.

The RP2350 TLS port also leaves `tls.get_internals` unimplemented because the
Pico SDK's private mbedTLS headers are not C++ compatible. That primitive is
used to export TLS session state and hand an established mbedTLS connection to
Toit's symmetric-session implementation. A future network transport must add
and validate an adapter for that path; the current USB OTA results make no
claim about TLS connections or session resumption.

## Build and upload workflow

Build a VM image with a 16-bit ROM image version; the Make target defaults to
1. OTA supports upgrades, downgrades, and equal-version replacements. The
version affects normal ROM selection after validation and recovery, as
described below.

```sh
make rp2350 \
  RP2350_VERSION=2 \
  RP2350_PROGRAM="$PWD/tests/hw/rp2350/vm-smoke.toit"

make rp2350-ota-upload
```

The default outputs used below are:

```text
build/rp2350-vm/toit-rp2350.bin
build/rp2350-ota-upload/ota-upload
```

`TOIT_RP2350_OTA` and `TOIT_RP2350_AUTO_VALIDATE` are enabled by default. Pass
additional CMake settings through `RP2350_CMAKE_FLAGS`; for example, a rollback
experiment can disable automatic validation with
`-DTOIT_RP2350_AUTO_VALIDATE=OFF`.

The USB serial OTA protocol cannot provision an empty board. ROM BOOTSEL must
first install the experimental partition table and one compatible firmware
image. Firmware envelopes can package both into one recovery UF2 as described
under Firmware envelopes below.
Generate the partition-table UF2 with:

```sh
.cache/rp2350/install/bin/picotool partition create \
  toolchains/rp2350/partitions-experimental.json \
  build/rp2350-vm/partitions-experimental.uf2
```

For initial provisioning, enter BOOT mode and load that table with picotool
`load -v`, selecting the recorded device serial with `--ser`. Re-enter BOOT
mode so the ROM reloads the new table, then load the VM UF2 with `load -v -x`.
Installing this layout changes how existing flash contents are interpreted;
it is a provisioning operation, not part of routine updates. This host used
the [UF2 fallback](rp2350-rig-guide.md#uf2-mass-storage-fallback-on-this-host)
because raw USB access for picotool is not configured.

After that one-time bootstrap, use the stable application serial path and the
raw `.bin` image:

```sh
build/rp2350-ota-upload/ota-upload \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00 \
  build/rp2350-vm/toit-rp2350.bin
```

The uploader opens USB serial at a nominal 115200 baud and asserts DTR, which
the Pico SDK uses to decide whether USB stdio is connected. It does not switch
to 1200 baud or request ROM BOOTSEL. `--no-reboot` stops after the image is
committed, which is useful for staging and protocol tests. Staging is tracked
in RAM: a normal reset keeps the old confirmed image and requires a fresh
upload before `firmware.upgrade` can activate a candidate.

Without `--no-reboot`, the uploader requests the flash-update reboot, requires
the USB serial device to disconnect, and reopens the same stable path for up to
60 seconds. It sends `INFO` until the running partition differs from the old
one and is no longer a trial. Returning on the original partition is reported
as rollback. Startup may print `TOIT-OTA VALIDATED`, but the uploader does not
depend on observing that transient line.

The native uploader is built by the standalone CMake project in
[`tools/rp2350/ota-upload`](../tools/rp2350/ota-upload). Its SHA-256
implementation is embedded. GNU/Linux release builds link the GNU C++ runtimes
statically and otherwise depend on the platform C library and loader. Build
distributed binaries on the oldest supported system-library baseline. The CI
bundle is built on Ubuntu 22.04 and rejects uploader binaries that require a
glibc version newer than 2.35.

## USB console protocol

The console ignores unrelated log lines. Protocol errors are returned as
`TOIT-OTA ERROR ...`.

1. The uploader sends `TOIT-OTA INFO` and receives
   `TOIT-OTA INFO 1 <partition> <trial> <inactive-slot-size>`.
2. It computes the raw image's SHA-256 and sends
   `TOIT-OTA WRITE <size> <64-hex-digit-sha256>`.
3. The device replies `TOIT-OTA READY 4096`.
4. The uploader sends chunks of at most 4096 bytes. After every chunk, the
   device replies `TOIT-OTA ACK <cumulative-offset>`.
5. After native validation and staging, the device replies
   `TOIT-OTA COMMITTED`.
6. The uploader normally sends `TOIT-OTA REBOOT`, receives
   `TOIT-OTA REBOOTING`, and performs the disconnect/reconnect checks described
   above.

The console also has bring-up commands `TOIT-OTA VALIDATE` and
`TOIT-OTA ROLLBACK`. Normal deployments rely on startup health checks and the
standard firmware API instead of driving those commands manually.

## Firmware service

[`system/extensions/rp2350/firmware.toit`](../system/extensions/rp2350/firmware.toit)
installs the standard `system/firmware/rp2350` provider. It reports the URI
`flash:rp2350` and exposes validation, rollback, upgrade, and incremental
`FirmwareWriter` operations through `system.firmware`.

The writer currently accepts one complete raw image beginning at offset zero.
The declared length must be at least one 4096-byte sector and no larger than
the inactive slot. Only one writer may be open. Writes are refused while the
running firmware is a trial, so an unconfirmed image cannot replace its known
fallback.

The console supplies a SHA-256 over the complete incoming byte stream to
`FirmwareWriter.commit`. This detects transport corruption. The image's own
PICOBIN SHA-256 is checked separately before its boot header is published.
These hashes provide integrity, not publisher authentication; secure boot and
OTP provisioning are outside the current scope.

## Power-loss-aware staging order

Opening a writer erases the inactive slot's first sector immediately, making
any old candidate in that slot unbootable. The service retains the new first
4096 bytes in SRAM and writes the rest of the image sector by sector, erasing
each destination sector immediately before programming it. A partial final
sector is padded with `0xff`.

Commit checks the declared length and optional stream checksum, then validates
the complete candidate while overlaying the still-unpublished first sector
from SRAM. Only after those checks pass does the native `stage` primitive write
the first sector. It then verifies the image again from flash and records the
staged size for `firmware.upgrade`.

This first-sector-last order means an interrupted download or failed candidate
check leaves the inactive slot without a bootable header. It does not make a
single flash operation power-loss atomic. Physical power-cut testing during
body writes, first-sector publication, ROM selection, and confirmation remains
required.

Flash reads use the physical uncached, untranslated XIP alias. Erase and program
operations go through the ROM flash API, which excludes interrupts while XIP is
unavailable. Core 1 is currently unused; enabling it requires a flash lockout
protocol.

## Candidate checks

The native parser deliberately accepts a narrow SDK-produced format rather
than trying to implement every PICOBIN variation. It requires:

- a raw image from 4096 bytes through the 4 MiB slot size, with a four-byte
  aligned length;
- exactly one root block in the ROM's first 4096-byte scan window;
- linked initial and terminal blocks whose links form the expected two-block
  loop and whose versions match;
- RP2350 Arm Secure executable image definitions with TBYB set in both blocks;
- a bounded load map containing only valid XIP or RP2350 SRAM ranges, with only
  zero-filled alignment gaps;
- the expected SHA-256 `HASH_DEF` and `HASH_VALUE`, with no signatures,
  partition tables, alternate entry points, extra image definitions, or
  unknown metadata; and
- a terminal block ending exactly at the declared image length.

The native verifier hashes the declared load-map ranges and hash-definition
block, masking the mutable TBYB bit as the ROM does, and compares the result to
the image digest. `firmware.upgrade` rechecks the staged image, asks
`rom_pick_ab_partition` to select the inactive slot, and requires the selected
partition to be the expected peer before issuing a flash-update reboot.

`rom_pick_ab_partition` can update ROM boot-RAM version/downgrade state, so it
is invoked only from a confirmed image immediately before reboot. The service
does not call it while receiving or validating an incomplete candidate.

## Trial validation and rollback

The bring-up boot wrapper installs the system service manager and firmware
provider, constructs the USB console, and completes a garbage collection before
automatic validation. Its test application runs in a separate noncritical
container, so application assertions and exceptions do not stop USB updates.
`TOIT_RP2350_OTA=OFF` retains the original single-process teardown tests.

Production envelopes follow ESP32/EC618: their boot applications call
`system.firmware.validate` after checking startup health. The system container
does not confirm on their behalf. Install a boot container that validates, or
an OTA trial will roll back. A critical container failure terminates the system;
the native error path reboots normally, rejecting an unconfirmed trial. A trial
that hangs without validation is still subject to the ROM watchdog.

Validation calls `rom_explicit_buy` with a private 4096-byte work area. If the
ROM refuses the buy after disabling its watchdog, the primitive requests a
normal reboot so the confirmed slot can recover.

Before validation, `firmware.rollback` performs a normal reboot and lets ROM
selection return to the confirmed image. After successful validation, ROM
downgrade handling may erase the previous image's first sector when necessary
to make the new version win later selection. TBYB therefore preserves the
fallback through the trial, but does not promise that it remains bootable after
the new image is bought.

## Native failure recovery

The VM overrides the Pico SDK's default breakpoint loops for native exit,
abort, panic, and processor faults. Toit `FATAL` and system-process OOM also
use this path. A normal ROM reboot rejects an unconfirmed trial; confirmed
firmware restarts in its selected slot. Fatal reporting arms the reset before
printing and stops task scheduling, so a blocked USB or stdio operation cannot
prevent recovery or allow another task to cancel the reset by validating.
Panic text may be truncated when interrupts are disabled.

Processor fault handlers switch to a dedicated 1 KiB stack, clear MSPLIM, and
call ROM from SRAM. The compiler output was checked to ensure that no outlined
flash wrapper remains in that path. Applications can also enable the
[hardware watchdog](rp2350-rig-guide.md#application-watchdog) after validating
their firmware to recover from deadlocks. The port does not arm or feed an
application watchdog automatically.

Physical checks passed for
[unconfirmed hard-fault rollback](../tests/hw/rp2350/results/2026-09-19-native-hardfault-rollback.log),
[rollback with XIP disabled](../tests/hw/rp2350/results/2026-09-19-native-xip-fault-rollback.log),
[confirmed restart with XIP disabled](../tests/hw/rp2350/results/2026-09-19-native-xip-fault-confirmed.log),
[confirmed native abort](../tests/hw/rp2350/results/2026-09-19-native-abort-confirmed.log),
and [panic with interrupts disabled](../tests/hw/rp2350/results/2026-09-19-native-panic-rollback.log).
The [Toit `FATAL` path](../tests/hw/rp2350/results/2026-09-19-native-fatal-rollback.log)
and [native `_exit`](../tests/hw/rp2350/results/2026-09-19-native-exit-rollback.log)
also returned unconfirmed trials to the confirmed image.
Each test observed the trial boot, injected fault, USB disconnect, normal
reboot into the expected confirmed slot, and responsive OTA console afterward.

The [application allocation test](../tests/hw/rp2350/results/2026-09-19-memory-pressure.log)
caught twenty rejected 1 MiB allocations while preserving 64 retained buffers,
GC, timers, and OTA access. A separate
[system-process OOM test](../tests/hw/rp2350/results/2026-09-19-system-oom-rollback.log)
used an envelope with a deliberately failing system snapshot. It logged the
allocation failure and native panic, then restored the confirmed image and
OTA console 3.46 seconds after the test marker. That timing distinguishes the
explicit reboot from expiry of the original ROM trial watchdog. Its initial
fixture lacked service discovery and stalled before allocating; that earlier
run is not counted as OOM coverage.

Finally, the normal version 42 envelope was
[uploaded and validated](../tests/hw/rp2350/results/2026-09-19-native-recovery-final-envelope-upload.log)
with no fault-injection code. A physical RUN reset
[booted it confirmed](../tests/hw/rp2350/results/2026-09-19-native-recovery-final-envelope-reset.log)
and passed assets, configuration, GC, storage RPC, and the existing persistent
flash fixtures again.

Fault injection is available only in explicitly configured test builds; normal
firmware has no injection task or command. For example:

```sh
cmake -S toolchains/rp2350 -B build/rp2350-fault-test -G Ninja \
  -DTOIT_RP2350_BUILD_VM=ON -DTOIT_RP2350_VERSION=37 \
  -DTOIT_RP2350_AUTO_VALIDATE=OFF -DTOIT_RP2350_TEST_FAULT=xip-fault
cmake --build build/rp2350-fault-test --target toit-rp2350 --parallel
python tests/hw/rp2350/native-failure-test.py \
  --uploader build/rp2350-ota-upload/ota-upload \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00 \
  --image build/rp2350-fault-test/toit-rp2350.bin --fault xip-fault \
  --log build/rp2350-fault-test/result.log
```

Set `TOIT_RP2350_AUTO_VALIDATE=ON` and pass `--validated` to test confirmed
restart instead. Injection runs only when the image initially boots as a
trial, so that confirmed image starts normally after its fault-induced reset.

## Experimental 16 MiB layout

| Physical flash range (exclusive end) | Purpose |
| --- | --- |
| `0x000000–0x002000` | ROM partition-table slots |
| `0x002000–0x402000` | Firmware A, 4 MiB |
| `0x402000–0x802000` | Firmware B, 4 MiB |
| `0x802000–0xffd000` | Toit flash registry |
| `0xffd000–0x1000000` | Reserved tail, including the ROM E10 workaround |

The board's JEDEC ID was read as `ef4018`, indicating 16 MiB. The table is
[`toolchains/rp2350/partitions-experimental.json`](../toolchains/rp2350/partitions-experimental.json).
The flash registry uses partition 2 only when the ROM reports the expected
linked firmware pair and the registry follows both firmware slots.

## Validation status

The native ROM watchdog rollback test passed on 2026-09-19. Version 2 booted
from partition 0 as a flash-update trial (`type=4 trial=1`), deliberately
remained unconfirmed until the ROM watchdog reset it, and version 1 then booted
from partition 1 as a normal non-trial image (`type=0 trial=0`). The captured
log is `.cache/rp2350/ota-v2-rollback.log`.

The native uploader's PTY suite covers fragmented serial I/O, unrelated log
lines, a multi-chunk transfer, independent SHA-256 comparison, device errors,
bad cumulative ACKs, and response timeout. Physical end-to-end results for the
implemented Toit service and uploader now cover these transitions:

- [Version 10 to version 11](../tests/hw/rp2350/results/2026-09-19-ota-v10-to-v11.log):
  the confirmed image on partition 0 uploaded, booted, and validated version 11
  on partition 1.
- [Deliberately unconfirmed version 12](../tests/hw/rp2350/results/2026-09-19-ota-trial-rollback.log):
  partition 0 booted as a trial, the ROM watchdog returned to confirmed version
  11 on partition 1, and the uploader correctly reported rollback with exit
  status 1.
- [Version 11 to version 10 downgrade](../tests/hw/rp2350/results/2026-09-19-ota-downgrade-v11-to-v10.log):
  the confirmed image moved from partition 1 to a validated version 10 on
  partition 0.
- [Equal-version update](../tests/hw/rp2350/results/2026-09-19-ota-equal-version-v10.log):
  another version 10 image moved from confirmed partition 0 to validated
  partition 1.
- [Reset after equal-version validation](../tests/hw/rp2350/results/2026-09-19-ota-equal-version-reset.log):
  partition 1 returned as a normal, non-trial boot and the VM smoke program
  passed 1,346 garbage collections.
- [Concurrent event-stress update](../tests/hw/rp2350/results/2026-09-19-ota-stress-upload.log):
  confirmed version 10 on partition 1 uploaded, booted, and validated the
  version 13 stress image on partition 0. A subsequent
  [normal reset](../tests/hw/rp2350/results/2026-09-19-ota-stress-run.log)
  returned on partition 0 with `type=0 trial=0`; the shared-dispatcher GPIO,
  UART, I2C, and timer workers all passed, followed by clean application
  teardown.

- [Rejected uploads](../tests/hw/rp2350/results/2026-09-19-ota-negative.log):
  wrong transport SHA-256, a damaged body with a recomputed transport checksum,
  a cleared terminal TBYB flag with a still-valid image hash, and a download
  stopped after 8192 bytes all produced the expected errors. After every
  rejection the confirmed partition remained active and the console recovered.
- [Reset during upload](../tests/hw/rp2350/results/2026-09-19-ota-interrupted-reset-pass.log):
  after acknowledging 8192 bytes of a higher-version image, RUN was pulsed
  before the transfer completed. The old confirmed partition returned and its
  peripheral stress test passed again. The earlier `ota-interrupted-reset.log`
  records a harness failure handling the asynchronous startup line, fixed for
  this run. A later [version 54 check](../tests/hw/rp2350/results/2026-09-19-ota-reset-during-write.log)
  with the low-power SDK fix interrupted the native uploader after 229,376
  bytes. It again returned to confirmed partition 1, preserving flash buckets
  and raw storage; the normal container passed assets, config, GC, storage RPC,
  and identity checks.
- [Reset after complete staging](../tests/hw/rp2350/results/2026-09-19-ota-staged-reset-pass.log):
  version 14 was fully checked and committed with `--no-reboot`. A normal RUN
  reset kept confirmed version 13 on partition 0 and its stress test passed.
  The passing harness required the old USB connection to disconnect before
  checking the new boot; the earlier `ota-staged-reset.log` missed that step.
- [Final version 14 update](../tests/hw/rp2350/results/2026-09-19-ota-final-v14.log):
  a fresh upload moved from confirmed partition 0 to confirmed partition 1.
  The 504,224-byte image took 17.22 seconds from uploader start through
  validated reboot on this rig. The VM then passed 1,349 garbage collections.
  This was the confirmed image before subsequent peripheral and storage tests.

- [Persistent storage write](../tests/hw/rp2350/results/2026-09-19-storage-write.log)
  and [read after OTA](../tests/hw/rp2350/results/2026-09-19-storage-persistence.log):
  RAM buckets, flash buckets, and raw flash regions passed. Flash data survived
  the move from version 15 to version 16, including writes crossing page and
  sector boundaries.
- [Container installation](../tests/hw/rp2350/results/2026-09-19-container-install.log)
  and [persistence after OTA](../tests/hw/rp2350/results/2026-09-19-container-persistence.log):
  the system installed a separately compiled container in 257-byte chunks,
  started it with arguments, verified GC and storage RPC from that process,
  and received its successful exit. After a firmware update, the container
  auto-started from persistent flash and was successfully uninstalled.
- [Packaged envelope](../tests/hw/rp2350/results/2026-09-19-envelope.log):
  the firmware CLI extracted and uploaded version 22, which validated on
  partition 1. Its bundled application verified assets, firmware configuration,
  40 garbage collections with retained objects, and persistent storage RPC.
- [Confirmed recovery image](../tests/hw/rp2350/results/2026-09-19-envelope-recovery.log):
  a combined absolute UF2 installed version 25 into slot A on a provisioned
  board whose confirmed version 24 remained in slot B. The ROM selected slot A
  as immediately confirmed (`trial=0`); the bundled application, assets,
  configuration, 40 garbage collections, and storage RPC passed. Existing
  flash-bucket and raw-region fixtures in the registry survived recovery. This
  test copied the UF2 through BOOTSEL mass storage because the host lacks raw
  USB permission; the equivalent picotool transport command below has not been
  exercised physically.
- [OTA after recovery](../tests/hw/rp2350/results/2026-09-19-envelope-after-recovery-upload.log):
  the CLI uploaded the same version 25 from recovered, confirmed slot A into
  slot B. It booted as a trial and validated on partition 1. The subsequent
  [application log](../tests/hw/rp2350/results/2026-09-19-envelope-after-recovery.log)
  shows the bundled container, assets, configuration, garbage collections,
  storage RPC, and the pre-recovery flash fixtures all passing.
- [Application failure isolation](../tests/hw/rp2350/results/2026-09-19-container-isolation/container-failure.log):
  a deliberately failing noncritical application printed its assertion while
  the system and OTA console remained responsive. A
  [subsequent OTA upload](../tests/hw/rp2350/results/2026-09-19-container-isolation/after-container-failure-upload.log)
  booted and validated the VM/GC/timer smoke image successfully.
- [Critical startup rollback](../tests/hw/rp2350/results/2026-09-19-critical-rollback-sequence.log):
  an unconfirmed production trial failed its critical boot container. The VM
  reported `reason=4 value=255`, completed teardown, and rebooted normally.
  ROM returned to the previous confirmed envelope; its assets, configuration,
  GC, storage RPC, and persistent flash fixtures passed again. This capture
  distinguishes the explicit error reboot from a watchdog-only rollback.
- [Application-controlled validation](../tests/hw/rp2350/results/2026-09-19-envelope-health-validation-upload.log):
  the production envelope uploaded and validated successfully with validation
  performed by its critical application after all startup checks. The system
  boot program no longer automatically confirms production envelopes.

Run the rejection suite against a confirmed board with Python and pyserial:

```sh
python tests/hw/rp2350/ota-negative-test.py \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00 \
  --image build/rp2350-vm/toit-rp2350.bin
```

It overwrites the inactive candidate slot and checks that the active partition
stays confirmed. Python is only a test dependency; the distributed uploader
does not need it. Interrupted confirmation and physical power loss at each
staging boundary remain untested. RUN reset tests do not remove flash power.

Offline checks passed for the native uploader's PTY protocol suite, sanitizer
parser/fuzz tests, independent image digest verification, and picotool hash
verification. CI builds and runs these checks against the generated VM image.
The matching host Toit build and existing `crypto-test.toit` also passed after
enabling the RP2350 crypto primitives.

## Firmware envelopes

`make rp2350-envelope RP2350_VERSION=N` builds a native VM base and packages it
with the RP2350 system container in `build/rp2350-envelope/firmware.envelope`.
It also creates a host-specific distribution such as
`build/rp2350-envelope/toit-rp2350-linux-x86_64.tar.gz`. The archive contains
the editable envelope, its confirmed `recovery.uf2`, the native OTA uploader,
the repository license, and [bundle instructions](rp2350-envelope-bundle.md).
CI retains this archive as the `toit-rp2350-linux-x86_64` artifact. The native
base is deliberately incomplete: flash an extracted envelope image, not the
base binary or its SDK-generated UF2.

The generated envelope initially contains only the system container. That is
useful as a confirmed bootstrap recovery image, but it is not a deployable OTA
trial: production system firmware intentionally does not validate itself.
Before extracting a raw binary or using `flash`, install a critical boot
container that performs application health checks and calls
`system.firmware.validate`. The archive deliberately omits a pre-extracted raw
binary so it cannot be mistaken for a ready-to-upload application image.

The envelope CLI supports installing containers, assets, configuration, raw
binary extraction, blank-board recovery UF2 extraction, and USB OTA flashing.
Envelope creation requires the partition-table UF2 generated from the checked-in
JSON manifest. The CLI validates its hash and exact A/B/registry layout before
embedding it. During development, run the source tool to use the current
implementation. The following extraction and flash commands assume that a
validating application container has already been installed in the envelope:

```sh
build/host/sdk/bin/toit run --project-root tools tools/firmware.toit -- \
  -e build/rp2350-envelope/firmware.envelope extract --format=binary \
  --output=build/rp2350-envelope/firmware.bin

build/host/sdk/bin/toit run --project-root tools tools/firmware.toit -- \
  -e build/rp2350-envelope/firmware.envelope extract --format=image \
  --output=build/rp2350-envelope/recovery.uf2

RP2350_OTA_UPLOAD_PATH="$PWD/build/rp2350-ota-upload/ota-upload" \
  build/host/sdk/bin/toit run --project-root tools tools/firmware.toit -- \
  -e build/rp2350-envelope/firmware.envelope flash \
  --port=/dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00
```

The `image` output uses absolute UF2 addresses. It contains the partition-table
page and the populated prefix of physical slot A. It has no blocks for slot B
or the registry, so recovery and repeat provisioning preserve registry data.
Unlike the raw `binary` output used by OTA, the recovery image is immediately
confirmed: extraction clears the terminal image definition's TBYB bit exactly
as the ROM's `explicit_buy` operation does. The ROM hash deliberately masks
that bit, and extraction verifies that the existing digest remains valid. A
bootstrap image therefore has no initial trial watchdog or rollback; later USB
OTA updates retain TBYB and use the normal validation and rollback path.
Load it from BOOTSEL with the packaged picotool, then request a normal reboot:

```sh
build/rp2350-flasher/linux-x86_64/picotool load -v \
  --ignore-partitions \
  build/rp2350-envelope/recovery.uf2 --ser BOARD_SERIAL
build/rp2350-flasher/linux-x86_64/picotool reboot --ser BOARD_SERIAL
```

The explicit `--ignore-partitions` is required because this is an absolute
recovery image that installs the partition table itself. A blank board has no
valid slot B, so the normal boot selects the newly written confirmed slot A.
On an already provisioned board, the preserved slot B remains a candidate and
the ROM's normal version and confirmation rules still apply. The confirmed
recovery format has been physically validated by installing a newer slot A
over a board with an older confirmed slot B while preserving registry data.
This recovery path does not promise a downgrade. Use the tested OTA path from
running firmware for downgrades; it explicitly selects the staged slot and
preserves the confirmed fallback until validation.

Do not use `load -x` as a substitute for that version rule. Picotool 2.3.1
derives the flash-update reboot base from the first mapped address in the UF2.
For this combined absolute file that address is the partition-table page at
flash offset zero, rather than the slot-A start at `0x10002000`. The SDK ROM API
only gives preferential A/B selection when the flash-update base matches the
start of a partition or slot. The recovery image is made bootable under the
ordinary selection path instead of relying on that mismatched update base.

Extraction preserves linked native segments, appends relocated containers and
configuration, updates the embedded-data descriptor, and regenerates the ROM
LOAD_MAP and SHA-256 metadata. The reusable
`tools/rp2350/tests/run_envelope_tests.sh` checks the result with the device's
native parser, an independent digest calculation, and picotool. It also checks
assets, boot flags, configuration, deterministic output, malformed images and
partition tables, physical UF2 ranges, and byte equality with picotool's
independent conversion and combination path.

## Primary references

- [Pico SDK ROM APIs](https://www.raspberrypi.com/documentation/pico-sdk/runtime.html)
- [Raspberry Pi's OTA example](https://github.com/raspberrypi/pico-examples/tree/master/pico_w/wifi/ota_update)
- [ROM confirmation implementation](https://github.com/raspberrypi/pico-bootrom-rp2350/blob/c6cdb1711f32c3e34faaebd58618a6d096dbd52e/src/main/arm/varm_launch_image.c)
- [ROM slot/version selection](https://github.com/raspberrypi/pico-bootrom-rp2350/blob/c6cdb1711f32c3e34faaebd58618a6d096dbd52e/src/main/arm/varm_flash_boot.c)
