# RP2350 firmware updates

The port implements whole-image updates through `system.firmware`. The USB
CDC console supplies the update transport. An update replaces the native VM,
system program and bundled containers; separately installed containers and
storage remain in the flash registry.

## Flash layout

The 16 MiB WeAct layout is defined by
[`partitions-experimental.json`](../toolchains/rp2350/partitions-experimental.json).

| Physical flash range (exclusive end) | Purpose |
| --- | --- |
| `0x000000–0x002000` | ROM partition-table slots |
| `0x002000–0x402000` | Firmware A, 4 MiB |
| `0x402000–0x802000` | Firmware B, 4 MiB |
| `0x802000–0xffd000` | Toit flash registry |
| `0xffd000–0x1000000` | Reserved tail, including the ROM E10 workaround |

The ROM maps either firmware slot to the same XIP address. The registry is
used only when the ROM reports the expected linked firmware pair and the
registry follows both slots. Changing this layout is a provisioning operation,
not a routine firmware update.

## Staging and integrity

Only one firmware writer may be open. It accepts a complete raw image starting
at offset zero, between one 4096-byte sector and the inactive slot's capacity.
An unconfirmed trial cannot open a writer and overwrite its fallback.

Opening the writer erases the inactive slot's first sector. The new first
sector stays in SRAM while subsequent sectors are erased and written. Commit
checks the length, optional transport SHA-256, and the candidate image before
publishing its first sector. It verifies the image again from flash afterward.
This leaves an interrupted download without a bootable header. It does not
make individual flash operations atomic; physical power-cut coverage remains
necessary for publication and ROM confirmation.

The native parser accepts the SDK's two-block PICOBIN format: matching
versions, Arm Secure executable definitions with try-before-you-buy (TBYB)
flags, valid XIP/SRAM load ranges, and SHA-256 metadata. It rejects malformed
links, extra image definitions, signatures, partition tables, unknown metadata,
and trailing data. The digest masks the mutable TBYB bit as the ROM does.
These checks provide integrity, not publisher authentication. Secure boot and
OTP provisioning are outside the port's current scope.

Staged state is held in RAM. Resetting before activation leaves the confirmed
image selected and requires another upload. `firmware.upgrade` rechecks the
candidate, asks the ROM to select the inactive slot, verifies that selection,
and requests a flash-update reboot. ROM selection is deferred until this point
because it can change downgrade state.

## Trial validation and rollback

The candidate boots as a trial and must call `system.firmware.validate` after
application health checks. Production system firmware never confirms on the
application's behalf. A normal reset, critical container failure, or ROM
watchdog expiry before confirmation returns to the confirmed image.

Validation calls `rom_explicit_buy`. If confirmation fails after the ROM has
disabled its watchdog, the port requests a normal reboot. Upgrades, equal
versions and downgrades use the same trial path. Once validation succeeds,
ROM downgrade handling may erase the previous image's header to make the new
version win future selection. The previous image is protected through the
trial, not after successful validation.

Native exit, abort, panic, processor faults and system-process OOM request
normal ROM reboot. Fault handlers use a dedicated SRAM stack and a ROM call
path that remains available without XIP. Fatal reporting arms reset before
printing so a blocked console cannot prevent recovery. An application can
also enable the hardware watchdog; the port does not automatically enable or
feed it after trial validation.

The `make rp2350` hardware-test wrapper confirms after VM/service startup and
a garbage collection, then runs the test in a separate noncritical container.
This differs deliberately from production envelopes. Disable it with
`-DTOIT_RP2350_AUTO_VALIDATE=OFF` for rollback tests.

## Recovery images

`toit tool firmware extract --format=image` generates a recovery UF2 from the
current envelope. It includes the partition table and populated slot-A prefix,
including the envelope's containers and configuration. It has no blocks for
slot B or the registry. Extraction clears the terminal TBYB bit, as ROM
confirmation does, and verifies the resulting hash. Recovery therefore starts
confirmed, without an initial trial watchdog or rollback window.

Recovery loading uses absolute UF2 addresses (`picotool load -v
--ignore-partitions`), then a normal reboot. On a provisioned board, preserved
slot B remains a candidate under normal ROM version selection. Recovery does
not promise a downgrade; use an update from running firmware for that. The
partition-table address at the start of the recovery UF2 is not a firmware-slot
address, so picotool's `load -x` is not a substitute for selecting a trial slot.

## USB protocol

The [native uploader](../tools/rp2350/ota-upload/README.md) drives this protocol
on the application's console, ignoring unrelated log output:

1. `TOIT-OTA INFO` returns protocol version, running partition, trial flag and
   inactive-slot capacity.
2. `TOIT-OTA WRITE <size> <sha256>` receives `TOIT-OTA READY 4096`.
3. Each binary chunk, up to 4096 bytes, receives
   `TOIT-OTA ACK <cumulative-offset>`.
4. Successful validation and staging produce `TOIT-OTA COMMITTED`.
5. `TOIT-OTA REBOOT` activates the staged image. The uploader waits for USB
   disconnect/reconnect and verifies that the other partition is confirmed.

Errors use `TOIT-OTA ERROR ...`. The uploader reports rollback when the board
returns on the original partition. `--no-reboot` stops after staging, which
allows paired hardware tests to prepare their peer before activation.

## Tests

[Host tests](../tools/rp2350/tests/README.md) cover image parsing, malformed
metadata, hashes, envelope extraction, UF2 ranges and retained-memory layout.
[Hardware tests](../tests/hw/rp2350/README.md) exercise updates, rollback,
container persistence, native failures and recovery. Build fault injection only
with `TOIT_RP2350_TEST_FAULT`; normal firmware has no injection command or task.
