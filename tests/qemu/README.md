# Running ESP32 stdio tests with QEMU

These notes describe the workflow verified in August 2026 with the
[`toitlang/qemu` v9.2.2-toitlang.2 release](https://github.com/toitlang/qemu/releases/tag/v9.2.2-toitlang.2).

## Install QEMU

For an x86-64 Linux host:

```sh
QEMU_VERSION=v9.2.2-toitlang.2
QEMU_ARCHIVE=qemu-toit-$QEMU_VERSION-linux-x86_64.tar.gz
QEMU_SHA256=103a3a52ab0639afffc0a82c10cb92294d0f5c8a00ee631ce98cb190e7d5a17d
curl -L --fail \
  "https://github.com/toitlang/qemu/releases/download/$QEMU_VERSION/$QEMU_ARCHIVE" \
  -o "/tmp/$QEMU_ARCHIVE"
printf '%s  %s\n' "$QEMU_SHA256" "/tmp/$QEMU_ARCHIVE" | sha256sum --check
tar -xf "/tmp/$QEMU_ARCHIVE" -C /tmp
QEMU=/tmp/qemu-toit-$QEMU_VERSION-linux-x86_64/bin/qemu-system-xtensa
```

Release archives for other hosts are available on the same release page.

## Run the automated tests

After building the regular ESP32 firmware, build a separate S3 envelope whose
primary console is USB Serial/JTAG and run all standard-stream fixtures:

```sh
tests/qemu/build-s3-usb-envelope.sh
QEMU_SYSTEM_XTENSA=$QEMU tests/qemu/run-tests.sh
```

The runner tests stdin, stdout, and stderr through both an ESP32 UART and the
ESP32-S3 USB Serial/JTAG device. It also verifies that `io.stdin` and
`uart.Port.console` can share the console UART. Each input is sent only after
the corresponding readiness marker appears, and every wait has a timeout.

## Build and create a flash image

Build the SDK and ESP32 firmware from the repository root. In a restricted
agent environment, point ccache at a writable directory:

```sh
CCACHE_DIR=/tmp/toit-ccache make -j4 esp32
```

Compile the test program, add it as a boot-triggered container, and ask the
firmware tool to assemble a complete flash image:

```sh
TOIT=build/host/sdk/bin/toit
$TOIT compile --snapshot --project-root tests/qemu \
  -o build/esp32/qemu-stdio.snapshot tests/qemu/stdio.toit
$TOIT tool firmware --envelope=build/esp32/firmware.envelope \
  container install -o build/esp32/qemu-stdio.envelope \
  stdio build/esp32/qemu-stdio.snapshot
$TOIT tool firmware --envelope=build/esp32/qemu-stdio.envelope \
  extract --format=image -o build/esp32/qemu-stdio.bin
```

Using `firmware extract --format=image` is easier and less error-prone than
calling `esptool merge-bin` manually: it uses the offsets and binaries stored
in the envelope.

## Run the ESP32 UART test

```sh
$QEMU \
  -M esp32 \
  -display none \
  -monitor none \
  -serial stdio \
  -drive file=build/esp32/qemu-stdio.bin,format=raw,if=mtd \
  -no-reboot
```

Wait for `STDIO-READY` before entering input. Opening the interrupt-driven
console UART deliberately flushes bytes received before it was opened. For
example, entering `hello-qemu` followed by return should produce both
`STDOUT:hello-qemu` and `STDERR:hello-qemu`.

The separate `stdio-uart-console.toit` fixture checks that `io.stdin` and
`uart.Port.console` can share the driver. It first reads through `io.stdin`,
then through the UART port; send one line after each readiness marker.

Using `-display none -monitor none -serial stdio` gives the UART exclusive use
of the terminal. `-nographic` also works, but multiplexes the QEMU monitor and
serial port and therefore makes scripted input less convenient.

## ESP32-S3

The UART configuration can be tested in the same way:

```sh
CCACHE_DIR=/tmp/toit-ccache make -j4 esp32s3
```

Repeat the envelope commands with `build/esp32s3`, then run QEMU with
`-M esp32s3`. The tested QEMU release prints a PSRAM-detection error during
boot; this did not prevent the Toit runtime or UART stdio test from running.

Build the S3 USB Serial/JTAG envelope with the provided helper. It uses a
generated `SDKCONFIG` and a separate build directory, leaving the checked-in
configuration unchanged:

```sh
CCACHE_DIR=/tmp/toit-ccache tests/qemu/build-s3-usb-envelope.sh
```

Connect QEMU's emulated device to a character backend using the structured
`-global` form. The device type contains dots, so the shorthand form cannot
address it:

```sh
$QEMU \
  -M esp32s3 \
  -accel tcg,thread=single \
  -display none \
  -monitor none \
  -serial null \
  -chardev stdio,id=usb \
  -global driver=misc.esp32c3.usb_serial_jtag,property=chardev,value=usb \
  -drive file=build/esp32s3-usj/qemu-stdio.bin,format=raw,if=mtd \
  -no-reboot
```

The automated runner creates the flash image and supplies these options.

ESP32-S2 USB CDC is intentionally outside this test and the current stdio
implementation.
