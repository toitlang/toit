# Hardware and test rig

## Devices

Identify boards by their full `/dev/serial/by-id/` path and adapters by MAC.
HCI indices swap when dongles are replugged.

| Board | Chip | Base MAC | Serial ID (suffix) |
| --- | --- | --- | --- |
| ESP32 Board1 | ESP32 rev 1.0 | 98:cd:ac:63:76:2c | `CP2102N_..._06fbaa46a6e3ea1198b5157c994a5d01` |
| ESP32 Board2 | ESP32 | 98:cd:ac:60:e0:ac | `CP2102N_..._cebffb0133faea11a7175a185fbcde76` |
| ESP32 (retained-bond) | ESP32 | 08:3a:f2:23:4d:a8 | `CP2102N_..._7eb10aca7cfbea11919ff4375fbcde76` |
| ESP32-S3 Board1 | ESP32-S3, 2 MB PSRAM | f4:12:fa:c1:50:fc | `usb-1a86_USB_Single_Serial_544C020917` |
| ESP32-S3 Board2 | ESP32-S3 | 84:f7:03:a0:0b:38 | `CP2102N_..._0ec6e009cbd3eb11a86e340c44d319e3` |

Dongles: Edimax `7392:c611` at `08:BE:AC:2A:DA:C2` and Realtek `0bda:a729` at
`8A:88:4B:A3:56:A9`. Both are Realtek RTL8761-class controllers. Other serial
devices on the host are not part of the rig.

## Permissions on the development host

- `build/host/sdk/lib/toit/bin/toit.run` carries `cap_net_admin=ep`, needed for the HCI user channel and management socket. Rebuilding drops it; reapply with `sudo -n /usr/bin/setcap cap_net_admin+ep <path>` (granted without a password, see `tools/ble-hci.sudoers`).
- `sudo -n /usr/bin/btmgmt --index 0 power off|on` is granted without a password; the adapter must be powered down by BlueZ before Toit binds its user channel. Note the grant is by index, not MAC.
- Other sudo needs interactive authentication.

## Linux: run a direct-host example

```sh
sudo -n /usr/bin/btmgmt --index 0 power off
build/host/sdk/bin/toit run examples/ble/... 0      # adapter index 0
sudo -n /usr/bin/btmgmt --index 0 power on
```

`tests/ble-hardware/adapter-policy.toit` with `tools/ble-hci-supervisor.cc`
does the same with a per-MAC lock, identity check and restoration on any exit;
build the supervisor with `-DTOIT_BUILD_BLE_TEST_TOOLS=ON`.

## ESP32: build and flash

Controller-only firmware is a committed build variant:

```sh
make BLE_HOST=1 esp32      # build/esp32-ble-host/firmware.envelope
make BLE_HOST=1 esp32s3    # build/esp32s3-ble-host/firmware.envelope
```

It layers `toolchains/<chip>/sdkconfig.ble-host` (no Bluedroid, no NimBLE,
controller only, BLE-only mode on the original ESP32) over the ordinary
defaults. The development rig also keeps `build/ble-esp32-current-build.sh`
and `build/ble-esp32s3-current-build.sh` (plain cmake against the current host
SDK, outputs under `build/esp32-ble-current` and `build/esp32s3-ble-current`)
for quick rebuilds.

Assemble and flash an application:

```sh
toit=build/host/sdk/bin/toit
$toit compile -s -o /tmp/provider.snapshot examples/ble/experimental/advertising-provider.toit
$toit compile -s -o /tmp/app.snapshot examples/ble/experimental/advertising-counter.toit
cp build/esp32-ble-current/firmware.envelope /tmp/app.envelope
$toit tool firmware -e /tmp/app.envelope container install provider /tmp/provider.snapshot
$toit tool firmware -e /tmp/app.envelope container install app /tmp/app.snapshot
$toit tool firmware -e /tmp/app.envelope flash --port /dev/serial/by-id/<board>
stty -F /dev/serial/by-id/<board> 115200 raw; cat /dev/serial/by-id/<board>
```

Flashing the envelope rewrites all partitions including NVS; retained bonds on
that board are lost. Use `toit tool firmware ... extract` and an app-only
esptool write when bonds must survive.

## Software peers

- **BlueZ** on the second dongle: the independent Linux peer for pairing, bonding and GATT tests. `bluetoothctl`, `btmgmt` and `btmon` are the tools; `btmon` on the Toit-owned adapter needs `CAP_NET_RAW`.
- **Bumble** (Python): `tests/ble-interop/run.py` runs 61 process-pipe cases without hardware; `radio-*.py` scripts drive an adapter against a board. Install into a virtualenv from `tests/ble-interop/requirements.txt` (Bumble 0.0.234). The GitHub workflow `ble-interop.yml` runs the software part on manual dispatch.
- **NimBLE**: any board flashed with the default firmware and `tests/ble-hardware/fixtures/reference-peer.toit` or `nimble-bond-peer.toit` is an independent third peer.

Additional peers are available on request: a Linux laptop with its own
Bluetooth, an Android phone, a Raspberry Pi 4 (`ssh pi4`), and other ESP32
variants.

## Tracing

Wrap a transport in `ble.experimental.hexdump.Hexdump` on a board to print
every HCI packet as `HCI RX|TX <us> <hex>` on the serial log; convert a saved
log with `toit run tools/ble-hci-log.toit LOG OUT.btsnoop` and open it in
Wireshark. On Linux, `ble.experimental.btsnoop.Btsnoop` writes the file
directly, and `btmon` captures the other side when it is a BlueZ adapter.
Traces contain keys; keep them out of the repository. The revocation campaign
fixtures take `--trace` to enable this on all three boards
(`tests/ble-hardware/fixtures/vhci-bond-revocation-*.toit`).

## Checking the `ble` package on the host

`tests/ble-hardware/compat.sh` (outputs under `build/ble-compat-001/`) installs
`tests/ble-hardware/bench/provider.toit` and the unchanged
`examples/ble/heart_rate.toit` on the original ESP32's controller-only image,
then runs `tests/ble-hardware/compat-central.toit` on the Edimax dongle in two processes (bluetoothd re-powers the adapter after every session, so the runner powers it off between them): a
Linux provider in the same process and the `ble` package's central API on
top of it (scan by name, connect, discover, subscribe, three notifications,
one write). Pass: the central prints `COMPAT COMPLETE` and the board prints
`Heart rate app received data`.

`tests/ble-hardware/multi-central-check.sh` runs the same flow with the
traced provider (`bench/provider-traced.toit`, two peripheral sessions) and
holds the connection for ten seconds; the board's HCI log then shows LE Set
Advertising Enable again right after the connection, before the disconnect,
which is the controller advertising for a second central while the first
is connected. The two-central data path itself is covered by
`tests/ble-compat-multi-peripheral-test.toit`.

## Nightly run

`tests/ble-hardware/nightly.sh` runs pair and resume against BlueZ, the
three-board revocation campaign, both benchmark variants and the two `ble`
package checks in sequence, one line of pass/fail per step plus the markers
each step printed. It expects the campaign directories under `build/`
(`ble-resume-features-003`, `ble-mic-003`, `ble-bench-001`) and the boards
flashed as those campaigns leave them; wire it to cron on the rig host.
