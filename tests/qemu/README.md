# Running ESP32 stdio tests with QEMU

These notes describe the workflow verified in August 2026 with the
[`toitlang/qemu` v9.2.2-toitlang.1 release](https://github.com/toitlang/qemu/releases/tag/v9.2.2-toitlang.1).

## Install QEMU

For an x86-64 Linux host:

```sh
QEMU_VERSION=v9.2.2-toitlang.1
curl -L --fail \
  "https://github.com/toitlang/qemu/releases/download/$QEMU_VERSION/qemu-toit-$QEMU_VERSION-linux-x86_64.tar.gz" \
  -o "/tmp/qemu-toit-$QEMU_VERSION-linux-x86_64.tar.gz"
sha256sum "/tmp/qemu-toit-$QEMU_VERSION-linux-x86_64.tar.gz"
tar -xf "/tmp/qemu-toit-$QEMU_VERSION-linux-x86_64.tar.gz" -C /tmp
QEMU=/tmp/qemu-toit-$QEMU_VERSION-linux-x86_64/bin/qemu-system-xtensa
```

The expected SHA-256 for this archive is
`7f064715d32629e34edc3c54c85d5c132c32e40e4d7d5564822258150f3c8fe0`.
Release archives for other hosts are available on the same release page.

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

The USB Serial/JTAG backend can be compile-tested by building the S3 with
`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y` as the primary console and
`CONFIG_ESP_CONSOLE_SECONDARY_NONE=y`. Use a temporary `SDKCONFIG` and a
separate build directory so the checked-in configuration stays unchanged.

The following is the non-interactive configuration used for this test:

```sh
mkdir -p /tmp/toit-s3-usj
cp toolchains/esp32s3/sdkconfig /tmp/toit-s3-usj/sdkconfig
sed -i \
  -e 's/^CONFIG_ESP_CONSOLE_UART_DEFAULT=y$/# CONFIG_ESP_CONSOLE_UART_DEFAULT is not set/' \
  -e 's/^# CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG is not set$/CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y/' \
  -e 's/^# CONFIG_ESP_CONSOLE_SECONDARY_NONE is not set$/CONFIG_ESP_CONSOLE_SECONDARY_NONE=y/' \
  -e 's/^CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG=y$/# CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG is not set/' \
  -e 's/^CONFIG_ESP_CONSOLE_UART=y$/# CONFIG_ESP_CONSOLE_UART is not set/' \
  -e 's/^CONFIG_CONSOLE_UART_DEFAULT=y$/# CONFIG_CONSOLE_UART_DEFAULT is not set/' \
  -e 's/^CONFIG_CONSOLE_UART=y$/# CONFIG_CONSOLE_UART is not set/' \
  /tmp/toit-s3-usj/sdkconfig

source third_party/esp-idf/export.sh
IDF_TARGET=esp32s3 IDF_CCACHE_ENABLE=1 CCACHE_DIR=/tmp/toit-ccache \
  python third_party/esp-idf/tools/idf.py \
    -C toolchains/esp32s3 \
    -B build/esp32s3-usj \
    -D SDKCONFIG=/tmp/toit-s3-usj/sdkconfig \
    build
```

After configuration, verify that
`build/esp32s3-usj/config/sdkconfig.h` defines
`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG` and does not define
`CONFIG_ESP_CONSOLE_UART`.

It cannot currently be tested end-to-end with this QEMU release. The emulated
USB Serial/JTAG device in
[`hw/misc/esp32c3_jtag.c`](https://github.com/toitlang/qemu/blob/v9.2.2-toitlang.1/hw/misc/esp32c3_jtag.c)
returns zero for every register read, ignores every write, has no interrupt,
and exposes no character-device connection. The S3 machine maps that stub,
so an application using USB Serial/JTAG receives no input and its output is
not visible. This is a QEMU limitation, not a usable USB test setup.

ESP32-S2 USB CDC is intentionally outside this test and the current stdio
implementation.
