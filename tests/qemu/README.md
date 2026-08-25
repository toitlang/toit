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
`-M esp32s3`. QEMU's default S3 PSRAM model is quad SPI. The normal SDK
configuration tries quad PSRAM and tolerates detection failure, so the runtime
can fall back to internal RAM.

For a checked, PSRAM-backed inspector fixture, build a separate octal image:

```sh
CCACHE_DIR=/tmp/toit-ccache tests/qemu/build-s3-psram-inspector.sh
```

The helper enables runtime checkpoints, selects octal PSRAM, and disables the
"PSRAM not found" fallback. Run it with QEMU's matching model:

```sh
$QEMU \
  -M esp32s3 -m 4M \
  -global driver=ssi_psram,property=is_octal,value=true \
  -display none -monitor none -serial stdio \
  -drive file=build/esp32s3-qemu-psram/device-inspector.bin,format=raw,if=mtd \
  -no-reboot
```

A successful boot logs `using SPIRAM for heap metadata and heap` before
`DEVICE-INSPECTOR-READY`.

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

## Device-inspector reference capture

`device-inspector-fixture.toit` keeps recognizable objects live for a memory
capture. `capture-device-inspector.sh` stops QEMU through QMP after the
readiness marker, validates HMP `memsave` output for manifest-selected CPU
virtual regions, captures every core's raw registers and exact target
description through GDB remote when supported, and otherwise parses and retains
the official QEMU release's named HMP register output. It imports the evidence
into a versioned `.toitdump` artifact. See
`tools/device-inspector/README.md` for the manifest, exact command, API, and
current limitations. QMP, GDB RSP, and acquisition are implemented in Toit;
the reusable protocol client lives in `tools/gdb`.

Passing a sixth argument selects an instrumented runtime checkpoint instead of
waiting for the readiness marker. Build that firmware with
`TOIT_VM_STATE_CHECKPOINTS=1 make esp32`, generate `checkpoint-layout.json`
with `tools/device-inspector/extract-checkpoint-layout.toit`, and keep it next
to the manifest. Every checkpoint capture must use a fresh QEMU process; the
script supplies `-S`, arms the requested checkpoint through GDB, and verifies
QEMU's debugger-stopped state before reading memory.

A seventh argument selects one process-group/container ID. The stopped-target
planner keeps only the selected program heap, globals, object-heap chunks, and
the shared metadata spine required by the decoder. The resulting artifact
records omitted groups and unresolved external/native memory explicitly.

Set `QEMU_PSRAM_SIZE=4M` and use
`device-inspector-esp32-4m-psram-manifest.json` to include classic ESP32
QEMU's modeled PSRAM aperture in a full capture. The normal ESP32 firmware has
SPIRAM disabled, so this validates raw acquisition only; testing Toit-owned
objects in PSRAM requires a SPIRAM-enabled firmware build. For the semantic S3
case, use `device-inspector-esp32s3-4m-octal-psram-manifest.json` and set both
`QEMU_PSRAM_SIZE=4M` and `QEMU_PSRAM_MODE=octal`. Its PSRAM address is tied to
the exact inspector firmware layout produced by the helper.
