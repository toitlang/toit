# RP2350 SDK flashing tools

The SDK bundles `picotool`, `ota-upload` and a replaceable libusb shared library
in `lib/toit/bin`. `toit tool firmware flash` invokes these tools automatically:
`--port` updates running Toit firmware; `--bootloader` installs or recovers a
board placed in ROM BOOT mode. Neither path requires Python or a mounted drive.

On Linux, an administrator can install the supplied `60-picotool.rules` under
`/etc/udev/rules.d/`, reload udev rules, and reconnect the board to allow USB
access. Windows must have a WinUSB driver for the board's picoboot interface.

## Building

From a Toit source checkout with the top-level Pico SDK and ESP-IDF mbedTLS
submodules initialized:

```sh
cmake -S tools/rp2350/host-tools -B build/rp2350-host-tools \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/build/rp2350-tools"
cmake --build build/rp2350-host-tools --parallel
cmake --install build/rp2350-host-tools
```

The build downloads checksum-pinned picotool and libusb sources. Picotool uses
precompiled embedded helper payloads and the SDK headers, so no Arm compiler
is needed. Upstream generation steps require Python during the build only.
Use CMake's normal compiler/toolchain options to cross-compile. Linux releases
must be built against the oldest supported glibc baseline.

The additional whereami notice is copied from
[its upstream MIT license](https://github.com/gpakosz/whereami/blob/master/LICENSE.MIT);
picotool vendors its implementation without that separate license file.

## Replacing libusb

`libusb-source.tar.gz` contains the exact libusb 1.0.30 sources and CMake recipe
from libusb-cmake revision `c8477c10ac2ac6b1718d4d498e102b9f18b776f5`.
The library is LGPL-2.1 licensed; notices are in `licenses/`. To build a modified
replacement, extract the archive into an empty directory and run:

```sh
cmake -S . -B build -DLIBUSB_BUILD_SHARED_LIBS=ON -DLIBUSB_ENABLE_UDEV=OFF
cmake --build build --config Release
```

Replace the SDK's `lib/toit/bin/libusb-1.0.so.0` (Linux),
`libusb-1.0.0.dylib` (macOS), or `libusb-1.0.dll` (Windows) with the built shared
library for the same architecture. No picotool relink is necessary. On macOS,
set the replacement's install name to `@rpath/libusb-1.0.0.dylib` if necessary.
