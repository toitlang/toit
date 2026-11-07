# Toit RP2040 envelope bundle

This bundle targets the board named in its directory and a 2 MiB flash chip.
`pico_w_2023` is the ESP8285-equipped clone, not the official Pico W. Keep its
onboard modem on GP0/GP1; its recovery input is GP17. The plain Pico and official
Pico W recovery loaders use GP1. Do not interchange their loaders.

The native `rp2040-ota-upload` executable needs no Python, Jaguar, or compiler.
It uses the board's USB serial interface. Selecting 1200 baud requests recovery
without sending text to application stdin; the loader ignores the baud rate.
Use 115200 for ordinary terminal sessions. Select a persistent
serial path, such as `/dev/serial/by-id/...` on Linux; do not select a numbered
port by guessing.

## Initial installation

Installing the recovery loader replaces the first 64 KiB of flash. Back up any
existing firmware you need first. Hold the RP2040 BOOTSEL button while connecting
USB, then copy `recovery.uf2` to the board's ROM mass-storage drive. On the W-2023,
this is the RP2040 BOOTSEL button, not the wireless modem's BOOT button.

When USB serial appears, install the bundled system firmware:

```sh
./rp2040-ota-upload --port /dev/serial/by-id/OBSERVED_PICO_LINK firmware.bin
```

The default firmware provides system services and accepts updates. It has no
bundled user application. Subsequent application updates do not require BOOTSEL
and never overwrite the recovery loader or persistent flash registry.

## Applications and updates

With a matching Toit SDK, compile an application and install it in the envelope:

```sh
toit compile -s -o app.snapshot app.toit
toit tool firmware -e firmware.envelope container install \
  --output application.envelope app app.snapshot
toit tool firmware -e application.envelope flash \
  --port /dev/serial/by-id/OBSERVED_PICO_LINK
```

Alternatively extract a binary and use this bundle's standalone uploader:

```sh
toit tool firmware -e application.envelope extract --format=binary -o app.bin
./rp2040-ota-upload --port /dev/serial/by-id/OBSERVED_PICO_LINK app.bin
```

The uploader requests recovery, binds to the observed board identity, and
checks block acknowledgements and the installed version/size/CRC after reboot.
An optional `--id` rejects a different board before writing. By default the
numeric update version increases by one; `--version` can override it. A completed
upload verifies installation, not application-specific startup checks.

If an upload is interrupted, rerun it on the same device path. A committed
update resumes installation after reset. There is no automatic rollback or
image authentication; CRC detects accidental corruption. Applications can also
stage updates through `system.firmware.FirmwareWriter`.

The uploader does not enter ROM boot mode or replace the recovery loader.
The SDK `firmware flash --bootloader` option is not supported for RP2040.
