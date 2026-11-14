# RP2350 firmware envelopes

Build an envelope with `make rp2350-envelope RP2350_VERSION=1`. The output
`build/rp2350-envelope/firmware.envelope` initially contains the system
container. Install an application boot container that checks its startup
health and calls `system.firmware.validate` before deploying a trial update.
An unmodified system-only envelope does not confirm itself.

With the matching Toit SDK, update running firmware through its USB console:

```sh
toit tool firmware -e firmware.envelope flash \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00
```

For initial installation or recovery, hold the board's BOOT button while
resetting it (or connecting USB), then release BOOT and run:

```sh
toit tool firmware -e firmware.envelope flash --bootloader --serial BOARD_SERIAL
```

`--serial` selects the ROM device; omit it only when exactly one compatible
board is connected. ROM boot mode has no application serial port. The command
generates the recovery UF2 from the envelope, so installed containers, assets
and configuration are included. Loading uses USB directly; no mounted drive
or manual extraction is needed. On Linux, the Debian package installs the USB
access rule automatically; SDK archives need a one-time setup. See
[flashing tools](rp2350-flasher.md) for that setup and the alternative of copying
a recovery UF2 onto the mounted ROM drive.

Recovery writes the partition table and slot A, preserving slot B and the
registry. It starts confirmed rather than as a trial. The ROM's normal version
selection still applies when slot B contains confirmed firmware; recovery does
not promise a downgrade. Use an update from running firmware for downgrades
with trial validation and rollback.

For workflows distributing a prepared raw image, extract with
`toit tool firmware -e firmware.envelope extract --format=binary --output=firmware.bin`
and distribute the native `ota-upload` executable with it. That uploader needs
no SDK, Python, Jaguar or mounted drive at runtime. It only updates an already
provisioned device; it cannot replace ROM flashing on a blank board.
