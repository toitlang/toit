# RP2350 Linux flasher

For routine updates of a provisioned Toit device, use the
[USB OTA uploader](rp2350-ota.md). The ROM flasher below remains the initial
provisioning and recovery path.

The Linux flasher bundle contains `picotool` 2.3.1 and the USB library it
needs. A person flashing a board does not need the Pico SDK, a compiler,
Python, Jaguar, or a mounted UF2 drive. The executable uses the host's glibc,
libm, and architecture-specific dynamic loader, and it needs permission to
open the RP2350 USB device.

This bundle is currently built and checked only on Linux. It is neither a
fully static executable nor a cross-platform package. Build a release on the
oldest glibc-based Linux distribution that the release is intended to support;
a binary built on a newer distribution may require a newer glibc.

## Use the bundle

Extract the archive and check the executable:

```sh
tar -xzf rp2350-flasher-linux-x86_64.tar.gz
cd linux-x86_64
./picotool version
./picotool info -a firmware.uf2
```

The second command reads a firmware file and does not access USB. Put the
target in its USB boot mode before using a device command. If more than one
compatible target is attached, first read the board serial and always select
it explicitly:

```sh
./picotool info -a
./picotool info -a --ser BOARD_SERIAL
./picotool load -v -x firmware.uf2 --ser BOARD_SERIAL
```

`load` writes the target. Keep its power and USB connection stable until the
command completes. It talks directly to the USB bootloader; mounting or
copying to a UF2 volume is unnecessary.

Normal user access to the USB device requires a one-time platform setup. A
system administrator can install the rule included in the bundle, reload the
rules, and reconnect the board:

```sh
sudo install -m 0644 60-picotool.rules /etc/udev/rules.d/60-picotool.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

The rule is for Linux systems using udev. Distribution policy may require a
different group or device-access mechanism.

## Build a bundle

Prepare the pinned picotool and Pico SDK sources with the repository's RP2350
setup, then run:

```sh
bash tools/rp2350/build-flasher.sh
```

The host needs Git, curl, a C/C++ toolchain, CMake, Ninja, make, tar,
`sha256sum`, Python 3, and `readelf`. These are build dependencies only. The
result is:

```text
build/rp2350-flasher/rp2350-flasher-linux-ARCH.tar.gz
```

The build pins picotool 2.3.1 and libusb 1.0.30. It builds libusb statically
without libudev, links the GCC and C++ runtimes statically, and checks that the
only remaining shared libraries are libc, libm, and the loader for the build
architecture. The picotool OTP metadata and its helper payloads are embedded;
the installed program does not read SDK or picotool data files at runtime.

## Licenses and relinking

`licenses/` contains the license notices shipped by picotool, libusb, the Pico
SDK, Mbed TLS, and picotool's vendored libraries. `sources/` contains the exact
source archives, revisions, checksums, documentation, and a copy of the build
script used for the binary. This is included because libusb is linked
statically under LGPL-2.1.

To rebuild the executable or relink it with a modified libusb, install the
build dependencies above and run the recipe directly from the source bundle:

```sh
cd linux-ARCH/sources
bash build-flasher.sh
```

It verifies `SHA256SUMS`, unpacks the corresponding picotool, Pico SDK,
Mbed TLS, and libusb sources, and writes the rebuilt executable under
`sources/rebuilt/linux-ARCH/`. Set `RP2350_BUILD_ROOT` and
`RP2350_FLASHER_OUTPUT` to put the temporary build and result elsewhere.
