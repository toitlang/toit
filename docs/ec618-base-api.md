# EC618 frozen peripheral API

The base must retain implemented peripheral APIs even when their pads are not
exposed, a fixture is unavailable, or there is no public Toit API yet. Peripheral
drivers can then be added or corrected in an OTA slot without first updating the
base. Retention is a native linking capability; it does not certify hardware
behavior or make a peripheral publicly supported.

The previous hand-maintained keep-list was broad but incomplete. Link-time
garbage collection removed unreferenced functions outside the list. In
particular, implementing I2S later required fractional clock and MCLK/BCLK exports
that the deployed base did not contain. Successful tests of existing peripherals
and networking could not detect this omission.

## Contract and release checks

`toolchains/ec618/base-api.json` records 399 required symbols across 49 SDK
headers, including chip drivers, peripheral HAL, CMSIS driver tables, low-power
services and USB application helpers. Existing non-peripheral exports stay in
`plat_keep.c`. The generated `peripheral_keep.inc` adds required symbols that are
not already explicitly retained there.

`make ec618-base` runs fault-injection tests and checks the contract before
building, then checks the linked ELF before stamping its identity. The gate fails
on missing exports, stale retention entries, changed reviewed headers, and new
headers in the audited chip/HAL/core-driver directories. An SDK update requires a
review of changed declarations and exclusions; after that review, regenerate:

```sh
build/host/sdk/bin/toit run --project-root tools tools/ec618/check-base-api.toit -- --write
```

The gate is implemented in Toit. Its fault tests also run in the ordinary host
suite as `tests/ec618-base-api-test.toit`, including deterministic generation
and exclusion of duplicate retention pointers.

Base releases also carry `ec618-base-vN-api.json`, the reviewed contract used
by the build gate. Keep it with the ELF, binary and identity manifest when
archiving a release. The export check accepts defined global symbols, including
defined weak symbols; undefined weak symbols, local symbols and malformed
symbol records cannot satisfy the contract.

`make ec618` checks the complete export contract against the selected
`EC618_BASE_DIR/base.elf` before linking slots. This also covers downloaded
and previously built bases, including APIs that the current slot does not
use yet. It does not rebuild or upgrade a selected base to satisfy the gate.

EC618 CI runs for pull requests affecting the runtime, libraries, system,
EC618 tooling, native tests or build configuration, and for pushes to master.
After the fresh-base build, its Linux job downloads the published
`toitlang/toit` release named by `toolchains/ec618/base-version` and runs the
full slot build against those artifacts. Missing releases or assets fail
the check; the local base is never substituted. The source-build matrix
continues to run on Linux, macOS and Windows.

When introducing a base version, first review and publish its artifact set
with the EC618 base release workflow. That workflow proves a full slot build
before publication and refuses to overwrite an existing version. The
published-base CI check must then pass before merging the version change.
Until v5 is published, this additional compatibility check intentionally
fails; local candidate results do not count as published-base qualification.

Do not regenerate the contract from the current ELF: that would accept precisely
the omissions this gate is intended to catch. Changes to prebuilt SDK libraries
still require implementation review and hardware qualification; header hashes
and symbol presence do not establish semantic compatibility.

## Coverage and exclusions

Retained APIs cover ADC/reference output, alarms, charger detection, clocks and
reset, flash/cache, DMA including descriptor chains, GPIO/pad control, interrupts,
keypad scanning, one-wire, timers/PWM, UART/low-power UART, watchdog, hardware
AES/SHA, I2C, SPI, I2S, camera-SPI, power/wakeup and USB application helpers.

The manifest records symbol-level reasons for declarations without linkable SDK
implementations. This includes the alarm convenience layer disabled by
`__USER_CODE__`, disabled audio volume helpers, and unimplemented generic
UART/I2C/PCM/LCD wrappers. Their implemented lower-level hardware dependencies
remain retained. The SDK enables I2S table 0 and camera-SPI table 1; the disabled
alternate tables are not fabricated. Common clocks, DMA, pads and interrupts
remain available to slot-owned drivers for other instances. The SDK's alternate
CMSIS SPI driver is disabled; its configured `soc_spi.h` implementation is kept.

Factory modem calibration/debug commands, crash-dump helpers and drivers for
external codecs/displays are outside this application-peripheral inventory.
This is not a promise to retain every private symbol in the modem SDK. Any future
space-driven exclusion must record its measured flash/RAM cost and the capability
it prevents. Lack of wiring or live tests is not a valid exclusion reason.

## Historical base v5 candidate measurement

These measurements and live results come from the combined EC618 bring-up
candidate, which also contains other platform changes. They establish the
candidate's export coverage and observed size, not the fingerprint or full
build qualification of an isolated base-API patch. Rebuild and validate the
final reviewed source before publishing its base and matching envelopes.

Against the preceding `3a0bedaa1309695df5b9ac0a985a1d9c` candidate:

| Allocation | Before | After | Increase |
| --- | ---: | ---: | ---: |
| ELF text | 1,439,712 | 1,462,784 | 23,072 bytes |
| Initialized data | 19,220 | 19,848 | 628 bytes |
| BSS | 575,358 | 576,894 | 1,536 bytes |

Flash payload growth is 23,700 bytes (text plus initialized data). Static data
RAM grows by 2,164 bytes; code copied into RAM adds another 2,256 bytes, for about
4.3 KiB of additional RAM allocation, plus alignment. The frozen XIP text ends
at `0x98bf80`, leaving 16,512 bytes before the base-id page at `0x990000`.
The linker enforces that boundary. None of the implemented APIs in this audit
was excluded for size.

Base v5 candidate fingerprint: `f0ae7c907be49d8af02ea2dbcfa6aecf`.
The earlier candidate fails the new export gate; v5 passes. Both slot links,
relocation byte identity, device relocator host checks, provisioning, partition,
anchor, and firmware export checks pass. The flashed base now passes its live
boot/identity check on slot A, UART0, with no pending OTA trial. A subsequent
same-base OTA installed the container-upload recovery fix and validated slot B;
all 11 platform CTest entries pass afterward. Subsequent tests pass all 90
permanent I2S receive cases, 24 transmit cases and eight two-second duplex
cases at 16/48 kHz. See `ec618-todo.md` for their exact scope and the unresolved
96-kHz duplex and intermittent UART transport findings. Retained but untested
APIs remain unqualified.

Slot OTA requires an exact base identity because native call addresses depend on
that base. Expanding the contract prevents many future base updates; it does not
make different bases binary compatible. Base OTA would additionally need its
own recoverable update design and is not implemented by this change.

Build logs and artifact hashes are under
`dev/ec618-rig/base-interface-audit-2026-10-11/`.

## Current integrated qualification

The subsequently rebuilt integration base has identity
`base-v5+0a267ba79e218a57efff8eae73f2f665`. It is deployed on the breakout rig
and passes the full export gate. Later stack-unit, packed-ring and block-copy
fixes were installed through slot OTA without changing this base. The final
two-minute I2S qualification leaves validated slot A and the original S3
application restored; see `ec618-todo.md` for evidence and scope.

These are local candidate results. The `ec618-base-v5` release remains absent
at the 2026-10-14 audit, so neither published-artifact compatibility CI nor
public availability is established. The earlier candidate's measurements
above must not be presented as measurements of this rebuilt base.
