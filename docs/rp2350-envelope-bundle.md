# Toit RP2350 firmware bundle

This host-specific bundle contains:

- `firmware.envelope`: the editable Toit firmware envelope.
- `recovery.uf2`: the immediately confirmed slot-A recovery image, including
  the RP2350 partition table. It preserves slot B and the registry partition.
- `ota-upload` (`ota-upload.exe` on Windows): the native serial uploader.

The envelope created by the repository target contains only the system
container. Production OTA images deliberately require an application boot
container that checks its own health and calls `system.firmware.validate`.
Install that application and any assets or configuration into
`firmware.envelope`, then extract the resulting envelope in `binary` format.
Uploading the unmodified, system-only envelope as a trial would roll back
because nothing confirms it.

Distribute the extracted binary with this native uploader. An end user uploads
it to a provisioned device through its stable USB serial path:

```sh
./ota-upload --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00 \
  APPLICATION-FIRMWARE.bin
```

The uploader contains its SHA-256 implementation. It needs no Pico SDK,
compiler, Python, Jaguar, or mounted UF2 volume at runtime. The Linux build
uses only glibc, libm, and its architecture-specific dynamic loader; build a
release on the oldest supported glibc baseline. The CI workflow builds on
Ubuntu 22.04 and checks its glibc 2.35 baseline. Linux is covered by
the PTY protocol and runtime-dependency tests. The Windows implementation has
been cross-compiled with only Windows system DLL imports, but Windows and
macOS have not been tested with physical RP2350 hardware; the macOS build
remains unverified.

`recovery.uf2` is for initial provisioning and recovery in BOOTSEL mode. Use
the separately distributed picotool bundle for direct USB loading; the
recovery image installs its own partition table, so the command must use
absolute addressing:

```sh
picotool load -v --ignore-partitions recovery.uf2 --ser BOARD_SERIAL
picotool reboot --ser BOARD_SERIAL
```

The recovery image starts confirmed and therefore has no initial rollback
window. It does not overwrite slot B or the registry, but normal ROM version
selection still applies when slot B contains another confirmed image. Recovery
does not promise a version downgrade; use OTA from running firmware for tested
downgrade and rollback behavior.

The USB device must be accessible to the current user. Linux installations
normally need the udev rule supplied with the separate picotool bundle.

## Local validation

The native version 59 build completed the full envelope suite: malformed-image
and boundary tests, parser fuzz cases, picotool hash verification, TBYB digest
handling, container installation, and binary/UF2 extraction. Its retained
section occupies 0x1010 bytes in SRAM bank 0 at 0x20006730. The generated Linux
archive was extracted and its uploader started successfully. The unchanged
uploader also passed the PTY protocol tests.

The local archive at
`build/rp2350-envelope/toit-rp2350-linux-x86_64.tar.gz` was built with the host's
glibc 2.42. It is a validation artifact, not evidence of the CI glibc 2.35
baseline; that workflow has not been run as part of this local bring-up.
