# EC618 open work

## Breakout integration status (2026-10-14)

The original EC618 port and networking were released in alpha.199. This
checklist covers the subsequent breakout enhancement and remaining platform
work; it does not reopen the original network qualification.

The integration branch contains the new pad routes, native I2S and 1-Wire,
ADC completion events, cellular disconnect reasons, shared watchdog support,
and Python-free standalone and FPC bus CTest runners. Implemented features
below must not be confused with unpublished package/release dependencies.

| Area | Evidence and limits |
| --- | --- |
| UART, I2C, SPI | The integrated stack-unit correction passes all four FPC bus cases: both UART routes, dual I2C and SPI. Evidence: `stack-units-offline-2026-10-14/bus-status.txt` and its test logs. The subsequent native changes affect only I2S. |
| Platform lifecycle | All nine standalone cases pass on the current validated bulk-copy firmware in `final-standalone-2026-10-14/ctest.log` and `LastTest.log`: basics, ADC lifecycle/events, cellular lifecycle, watchdog stop, integer widths, I2S stop, buffer capacity and live-clock stop/cancellation. Each case passes exact-base and validated-slot health before and after execution. This supersedes the earlier diagnostic-image-only suite evidence. The final stack correction also has separate basics, GC and 20-KiB TLS echo qualification. |
| I2S memory and transfer | Packed 24-bit rings and bounded block copies are implemented. Default-buffer supported-width captures pass; explicit 100-ms allocations can fail from fragmentation. The API reports allocation failure rather than silently reducing the request. |
| Sustained I2S | `i2s-bulk-copy-repeat-2026-10-14` passes eight separate ten-second EC618/independent captures, with four native S3 failures. `i2s-long-capture-2026-10-14` passes one uninterrupted 120-second 96-kHz/24-bit EC618 capture (69,120,000 bytes, zero over/underruns), both native S3 receivers and independent SPI. SPI observes approximately two seconds, not the entire EC618 capture. Historical intermittent failures are not erased by these passes. |
| Base API stability | The 399-symbol/49-header contract gates both base production and selection of an existing base. Current live identity is `base-v5+0a267ba79e218a57efff8eae73f2f665`; the full export check passes. Retained symbols are not hardware qualification for unwired peripherals. |
| External packages | Native 1-Wire has recorded DS18B20 CRC and cancellation/container-cleanup qualification; the sensor is now disconnected for I2S. Package PR [toit-1-wire #38](https://github.com/toitware/toit-1-wire/pull/38) remains open. Shared-watchdog SDK [#3241](https://github.com/toitlang/toit/pull/3241) and package [#18](https://github.com/toitware/toit-watchdog/pull/18) remain open. |

Evidence directories above are under `dev/ec618-rig/` in the bring-up
workspace. They are local qualification artifacts, not published CI results.
The two-minute test restores and verifies the original S3 app and passes
final EC618/peer health. Slot A is validated on the previously qualified base.
The deterministic object-order change produces candidate fingerprint
`54dcd4c53ba8df5f38479c62e1106e2e`; two local builds are byte-identical and
pass the export contract, but CI identity and live qualification are pending.
Keep the rig on its qualified base until the final candidate is ready.

Remaining closure work includes review/publication of the integration and
package dependencies, publishing v5 and proving the published-base CI path,
and resolving or explicitly documenting the remaining qualification limits.
The 2026-10-14 release lookup still returns `release not found` for v5.
Do not declare complete bring-up or publication from local commits alone.

## Runtime and peripherals

- **Gap-free UART TX across staging buffers at high baud rates.** Multi-chunk
  transfers work, but at 3 MBd the 4 KiB boundaries can introduce line-idle gaps.
  Waveform generation must fit in one staging buffer (`--large-buffers` requests
  4 KiB). Removing the gaps needs hardware-chained TX DMA descriptors in the
  base driver. See `uart2-gapfree-{ec618,esp32}.toit` for the supported contract.
- **Orderly firmware shutdown.** Stop other containers and services before
  resetting for an upgrade; the shared lifecycle orchestration is still missing.
  The TODO is retained in both embedded firmware providers.
- **Portable watchdog publication.** Coordinate the implemented shared API
  and package qualification with SDK #3241 and watchdog #18 before publishing
  the package's required SDK version. The qualification runner uses Toit.
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

- Standalone and FPC bus suites are registered through `standalone.cmake`
  and `bus.cmake`, using Toit runners with exact-base checks, exclusive rig
  ownership and recovery. Paired I2S matrices require the matching resident
  S3 fixture; enabling a suite is not proof that its fixture is installed.
- GPIO edge helpers already distinguish deadlines from driver errors. The
  output-low startup-glitch check remains unqualified with the opposing
  external pull-up installed. Preserve that limitation until the wiring
  permits the check; do not interpret the other GPIO passes as covering it.
- Finish contention/cancellation coverage outside the new bus suites and
  replace remaining bring-up probes with bounded, asserted tests.
- Generalize the tester's `--debug-boot` capture into reusable UART diagnostics.
- Investigate independent classic ESP32 Wi-Fi TCP hangs and ESP-NOW packet
  loss. Both reproduce on unchanged master; short-sleep timing has also failed
  there historically. The S3 ultrasound check requires an obstacle in range.
