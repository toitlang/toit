# EC618 frozen peripheral API

The base must retain implemented peripheral APIs even when their pads are not
exposed, a fixture is unavailable, or there is no public Toit API yet. Peripheral
drivers can then be added or corrected in an OTA slot without first updating the
base. Retention is a native linking capability; it does not certify hardware
behavior or make a peripheral publicly supported.

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

Header SHA256 values normalize CRLF to LF so Git's Windows checkout conversion
does not appear to change the ABI. All other bytes, including non-UTF-8 vendor
comments and lone carriage returns, remain significant. Generated retention
text likewise permits LF or CRLF without changing its required contents.

The gate is implemented in Toit. Its fault tests also run in the ordinary host
suite as `tests/ec618-base-api-test.toit`, including deterministic generation
and exclusion of duplicate retention pointers.

Base releases also carry `ec618-base-vN-api.json`, the reviewed contract used
by the build gate. Keep it with the ELF, binary and identity manifest when
archiving a release. The export check accepts defined global symbols, including
defined weak symbols; undefined weak symbols, local symbols and malformed
symbol records cannot satisfy the contract.

The release workflow pins the release tag to its tested workflow commit,
serializes publication, and refuses an existing tag (even without a release)
or an unsuccessful remote tag lookup. Its `-SHA256SUMS` asset covers the ELF,
binary, identity manifest and API contract. Published-base CI downloads and
checks all four before using the base. These checks establish artifact
integrity; they do not replace the export or firmware build gates.

Dispatching the release workflow requires `qualified_base_sha256`: the
lowercase SHA-256 of the exact `base.bin` that passed hardware qualification.
The workflow rejects malformed input and verifies the freshly built binary
against that digest before building the slot or publishing. Do not substitute
a new build's digest merely to pass this check; a mismatch requires
investigation and, if the base changes intentionally, renewed qualification.

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

## Base compatibility

Slot OTA requires an exact base identity because native call addresses depend
on that base. Retaining peripheral APIs reduces the need for base updates;
it does not make different bases binary compatible. Base OTA requires a
separate recoverable update design.

Base builds sort object paths before archiving and linking to avoid variation
from filesystem enumeration order. Different toolchains and configurations
can still produce different identities. Consumers must use the exact published
base artifacts.
