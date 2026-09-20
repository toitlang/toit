# RP2350 OTA uploader

Build the standalone uploader from the repository root:

```sh
tools/rp2350/ota-upload/build.sh
```

The script prints the resulting executable path, normally
`build/rp2350-ota-upload/ota-upload`. Upload a raw firmware image through the
application's USB serial port:

```sh
build/rp2350-ota-upload/ota-upload \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00 \
  firmware.bin
```

Use `--no-reboot` to stop after the device has committed the image. Otherwise,
the uploader requests an application reboot, requires the serial device to
disconnect, reopens the same stable port path for up to 60 seconds, and checks
that the new partition has left trial mode. Returning on the original partition
is reported as a rollback failure. The serial port stays at 115200 baud and
asserts DTR so Pico SDK USB stdio accepts the connection; the protocol does not
use RTS. The tool never requests the ROM's 1200-baud BOOTSEL reset.

The executable contains its SHA-256 implementation and needs no SDK, compiler,
Python, Jaguar, or mounted volume at runtime. GNU/Linux release builds link the
GNU C++ runtimes statically. Build release artifacts on the oldest supported
glibc baseline.

Run the PTY protocol tests with:

```sh
ctest --test-dir build/rp2350-ota-upload --output-on-failure
```

Python is used only by these tests.
