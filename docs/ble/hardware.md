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

The firmware is controller-only: the vendor Bluetooth controller with the
Toit host (no Bluedroid, no NimBLE), and the BLE provider in the system
container.

```sh
make esp32      # build/esp32/firmware.envelope
make esp32s3    # build/esp32s3/firmware.envelope
```

The C3 and C6 build the same way (`make esp32c3`, `make esp32c6`) but no
board on the rig runs them.

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

The second central process connects while the first is still connected,
which is the board advertising for another central while serving one (the
built-in provider allows two). The two-central data path is also covered
by `tests/ble-compat-multi-peripheral-test.toit`.

## Application API

`tests/ble-hardware/next-check.sh` flashes the controller-only original
ESP32 (or ESP32-S3 Board1 with `NEXT_BOARD=s3`) with the provider and
`examples/ble/v2-peripheral.toit`, then runs
`next-central.toit` on the Edimax dongle through `ble.v2.linux`.
The central finds the board by address, connects, reads the link,
subscribes, has one write refused with an application ATT error, asks for
new parameters and disconnects (`NEXT_CENTRAL COMPLETE`). The board prints
the connect and disconnect events, the link (PHY, MTU, RSSI, transmit
power at the 9 dBm it set, parameters, data length) and the refused write.
Pass `2` to request the 2M PHY explicitly. The example also sets its link to
6 dBm: on the ESP32-S3 the link then reads 6 dBm (a -12 dBm setting showed
as a 22 dB lower RSSI at the dongle); the original ESP32 refuses, because its
controller keeps transmitting a live connection at the default level whatever
per-connection level its vendor API accepts (measured at the dongle, with
every connection slot set).

## GATT client as a peripheral

`tests/ble-hardware/peripheral-client-check.sh` flashes the original ESP32
with the provider and `peripheral-client.toit` and lets `bluetoothctl` on
the Edimax dongle connect to it. While BlueZ discovers the board, the board
reads BlueZ's own database over the same link: its GAP Device Name ("red
#1" on the rig) and its services (1800, 1801, 180a). It then calls
`request-security`: the provider (`pairing-gatt-provider.toit`, Just Works)
sends a Security Request, BlueZ asks its agent to authorize the pairing
(the script answers "yes" after six seconds; any other answer rejects it and
ends the link), pairs and encrypts, and the board prints `security=1`. The
script removes the
board from BlueZ first: a bond kept from an earlier campaign makes BlueZ
encrypt with a key the freshly flashed board no longer has, and it then
ends the link with an authentication failure.

## Controller-based privacy

The rig's Realtek dongles have no link-layer privacy, so
`tests/ble-hardware/private-resolve.sh` runs between two boards. The
original ESP32 runs `v2-peripheral.toit` beside
`private-gatt-provider.toit` and advertises from resolvable private
addresses of a fixed test IRK. ESP32-S3 Board1 runs
`private-resolving-provider.toit`, which loads the peripheral's identity and
IRK into its controller's resolving list, and `private-central.toit`: the
scan report names the peripheral by identity, and the central connects by
identity twice, the second time without scanning while the peripheral uses
a fresh RPA (`PRIVATE_CENTRAL COMPLETE`).

## Legacy pairing

Legacy pairing and bond resumption were verified on hardware against a
NimBLE peripheral with Secure Connections off (2026-09-29); that check went
with NimBLE. A legacy-only peer for the rig would be a Bumble peripheral on
the second dongle; until then the software tests
(`tests/ble-security-legacy-test.toit` and the SMP tests) cover it.

## Nightly run

`tests/ble-hardware/nightly.sh` runs pair and resume against BlueZ, the
three-board revocation campaign, both benchmark variants and the two `ble`
package checks in sequence, one line of pass/fail per step plus the markers
each step printed. It expects the campaign directories under `build/`
(`ble-resume-features-003`, `ble-mic-003`, `ble-bench-001`) and the boards
flashed as those campaigns leave them; wire it to cron on the rig host.
