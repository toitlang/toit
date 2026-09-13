# EC618 open work

## Runtime and peripherals

- **Gap-free UART TX across staging buffers at high baud rates.** Multi-chunk
  transfers work, but at 3 MBd the 4 KiB boundaries can introduce line-idle gaps.
  Waveform generation must fit in one staging buffer (`--large-buffers` requests
  4 KiB). Removing the gaps needs hardware-chained TX DMA descriptors in the
  base driver. See `uart2-gapfree-{ec618,esp32}.toit` for the supported contract.
- **Cellular disconnect reasons.** `disconnect_reason` in
  `src/resources/cellular_ec618.cc` still returns a placeholder.
- **ADC completion events.** Replace the one-millisecond polling in
  `lib/gpio/adc.toit` with a resource event when the platform supports it.
- **Orderly firmware shutdown.** Stop other containers and services before
  resetting for an upgrade; the shared lifecycle orchestration is still missing.
  The TODO is retained in both embedded firmware providers.
- **Portable watchdog package.** Add EC618 support to `toit-watchdog`; the
  implementation currently lives in `lib/ec618/watchdog.toit` and
  `src/watchdog_ec618.cc`.
- **Delta OTA integration.** Finish/qualify the Artemis delta-apply path using
  the existing canonical firmware read and write APIs.

## Release and tooling

- **First base/envelope release.** The `ec618-base-vN` workflow and
  `EC618_BASE_DIR` consumer path exist. Publish after review and toolchain
  qualification. Each supported base needs a self-contained envelope; initially
  support only the base in use, adding others for a concrete need.
- **Toolchain qualification.** CI pins GNU Arm 10.3-2021.10. Vendor archives
  contain both GCC 10.2.1 and 10.3.1 objects; qualify ABI/runtime compatibility
  when changing either compiler. Recent rig runs used GCC 14.2 slots against
  the pinned base compiler, which does not by itself qualify all combinations.
- **Partition schema publication.** Verify deployment of the checked-in schema
  at `tools/schemas/ec618/partition-table/v1.json` to its public schema URL.
- **Partition/tool audit.** Finish reviewing descriptor/anchor validation and
  CLI error handling. Keep data-partition migration and base OTA outside the
  initial update API. Before reducing vendor reservations, establish boot-time
  FOTA/LittleFS writes and the required RF-calibration footprint.
- **LuatOS glue.** Remove the unnecessary `luat_*` interface layer from the
  Toit base project (see the TODO in `toit_main.c`).

## Test coverage and rig automation

- Wire the EC618 suites into CTest with explicit fixture ownership and a
  recovery procedure for the manually booted dev board.
- Narrow remaining catch-all handlers in rig tests so unexpected exceptions
  cannot masquerade as expected timeouts (for example GPIO edge helpers).
- Finish contention/cancellation coverage outside the new bus suites and
  replace remaining bring-up probes with bounded, asserted tests.
- Generalize the tester's `--debug-boot` capture into reusable UART diagnostics.
- Investigate independent classic ESP32 Wi-Fi TCP hangs and ESP-NOW packet
  loss. Both reproduce on unchanged master; short-sleep timing has also failed
  there historically. The S3 ultrasound check requires an obstacle in range.
