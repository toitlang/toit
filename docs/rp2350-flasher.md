# RP2350 flashing tools

The normal Toit SDK bundles picotool, the native OTA uploader, and a replaceable
libusb shared library. Use `toit tool firmware -e firmware.envelope flash --port
SERIAL_PORT` for updates, or `flash --bootloader` for a board in ROM BOOT mode.
The latter generates a recovery UF2 from the current envelope automatically.
Neither operation needs Python or a mounted UF2 drive at runtime.

## Standalone tools

To distribute the native tools separately, build a portable bundle from a
source checkout with the top-level Pico SDK and ESP-IDF mbedTLS submodules
initialized:

```sh
bash tools/rp2350/build-flasher.sh
```

The output is `build/rp2350-flasher/PLATFORM-ARCH.tar.gz`. It contains the same
`lib/toit/bin` tools and `lib/toit/rp2350` notices, USB rules and libusb source
as the SDK. CMake, C/C++ compilers, and upstream Python generators are build
dependencies only. Cross-compilation options can be passed to the script as
CMake arguments. Build Linux releases on the oldest supported glibc baseline.

Put the board in ROM boot mode by holding BOOT while resetting or connecting
USB, then release BOOT. From an extracted bundle, flash a prepared Toit
recovery image using:

```sh
lib/toit/bin/picotool info -a
lib/toit/bin/picotool load -v --ignore-partitions recovery.uf2 --ser BOARD_SERIAL
lib/toit/bin/picotool reboot --ser BOARD_SERIAL
```

Use `--ser` to select the intended board when more than one is connected.
`--ignore-partitions` is required for Toit's absolute recovery image, which
contains its own partition table. Other UF2 files may use a different loading
procedure. Normal ROM version selection still applies to preserved slot B;
recovery does not promise a downgrade.

ROM flashing with picotool uses the PICOBOOT USB interface, separate from the
ROM's mass-storage interface. Permission to mount the removable drive does not
grant direct USB access to picotool.

On Linux, the Toit Debian package installs the USB access rule automatically.
For SDK archives or standalone bundles, an administrator installs the supplied
rule once, reloads udev, and reconnects the board:

```sh
sudo install -m 0644 lib/toit/rp2350/60-picotool.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

Alternatively, extract a recovery UF2 with
`toit tool firmware -e firmware.envelope extract --format=image --output=recovery.uf2`
and copy it onto the mounted ROM drive. This uses the mass-storage interface
and does not require the picotool access rule. Updates through the running
application's serial port also do not require this rule.

On Windows, RP2350 ROM flashing does not need the manual WinUSB driver
installation required for RP2040; see the upstream
[picotool driver notes](https://github.com/raspberrypi/picotool#zadig).
The native uploader uses the application's serial port.

## Dependency notices and replacement

`lib/toit/rp2350/licenses/` contains dependency notices.
`lib/toit/rp2350/libusb-source.tar.gz` contains the exact libusb sources and
portable CMake recipe. Its accompanying README explains how to rebuild and
replace the adjacent shared library without relinking picotool. The complete
build recipe is [tools/rp2350/host-tools](../tools/rp2350/host-tools).
