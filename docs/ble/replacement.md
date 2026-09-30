# Replacing NimBLE with the Toit host

The plan for making the Toit BLE host the only BLE implementation: what
changes, in which order, and the numbers that decide the open choices. Each
step is a separate commit series; the ones marked "measure" end with numbers
in [measurements.md](measurements.md).

## Starting point (2026-09-30)

| | NimBLE (default firmware) | Toit host (`BLE_HOST=1`, provider container) |
| --- | --- | --- |
| Firmware binary, ESP32 | 1418 KB | 1327 KB (the NimBLE host is about 91 KB) |
| BLE code in Toit | none | about 233 KB of snapshot beyond a minimal container (321 KB provider snapshot; a service-only program is 88 KB) |
| Free heap while advertising | 105.5 KB | 115 KB with the BR/EDR memory released (provider + application containers) |
| 20-byte notifications | 765/s | 376/s in batches of 32 (one RPC costs 2.5 ms on the ESP32), 375–460/s direct |
| 244-byte notifications | 65 KB/s | 76 KB/s provider model, 81 KB/s direct, 143 KB/s on the S3 at 2M |
| Chips | ESP32, S3, C3, C6 | ESP32, S3 (the controller-only transport is compiled for these two) |
| macOS | `ble` package over CoreBluetooth | none |
| Windows | none | none |

## Steps

1. **`ble.v2`.** `ble.experimental.next` becomes `lib/ble/v2.toit` and
   `lib/ble/v2/`, the stable name for the new API. Documentation, examples,
   tests and hardware checks follow.
2. **Where the provider lives (measure).** Build the default provider into
   the system container (installed at boot like Wi-Fi and storage, lowest
   service priority so a deployment's own provider wins) and compare it with
   a separate provider container: flash added to the system image, heap
   while idle and while serving, and the small-notification rate. Decide on
   the numbers. Done: the system container wins on every count
   ([measurements.md](measurements.md)); `system/extensions/esp32/ble.toit`
   installs the default provider at boot, strongly unpreferred, so a
   deployment's own provider (installed as a container) takes precedence.
   Found on the way: a firmware with both the built-in provider and a
   separate provider container plus an application exceeds the 1.7 MB
   partition, one more reason for step 3.
3. **Smaller provider.** The default provider should not carry what it
   does not use: pairing (SC and legacy), ECDH, bonds and privacy become
   opt-in through the hooks so tree shaking can drop them. Target: well under
   the 233 KB above.
4. **Faster small notifications.** The 2.5 ms RPC per operation is the
   bottleneck; batching already recovers half. Options to measure: fewer
   allocations per RPC, notifying from the provider on a timer the
   application feeds, and the direct host inside the application process
   (375–460/s) as the upper bound of the RPC design.
5. **C3 and C6.** The controller-only transport (`ble_hci_esp32.cc`) and the
   `sdkconfig.ble-host` overlays are extended to the ESP32-C3 and ESP32-C6;
   no board on the rig, so this is compile-verified only until someone
   tries it.
6. **Remove NimBLE.** `BLE_HOST=1` becomes the only firmware: the NimBLE
   sdkconfig options, `src/resources/ble_esp32.cc`, the native classes of the
   `ble` package and the NimBLE hardware fixtures go. The benchmark keeps the
   NimBLE numbers above as its reference.
7. **`ble` on `ble.v2`.** The `ble` package's `Adapter`, `Central`,
   `Peripheral`, `Remote*` and `Local*` classes are reimplemented on
   `ble.v2` (one implementation instead of native plus host backends), with
   `// Deprecated.` notes pointing at `ble.v2`. Behaviour stays as
   documented; the software tests of the compatibility layer and
   `tests/ble-hardware/compat.sh` verify it.
8. **macOS backend.** A `ble.v2` provider over CoreBluetooth (reworking
   `src/resources/ble_darwin.mm`): scanning, connecting, discovery, reads,
   writes, subscriptions, RSSI; a GATT server with handlers and
   notifications. Peers are CoreBluetooth identifiers (`Peer` with a null
   address); `Capabilities` and `BLE_UNSUPPORTED` cover what macOS does not
   offer (PHY, parameters, transmit power, `request-security`, peripheral
   connect and disconnect events, broadcast advertising). Written without a
   Mac at hand; needs a build and a run on one.

## Efficiency goal

Better than NimBLE on every row of the table above, or a documented reason
why not. Flash is the hardest: the Toit host is a full host in bytecode.
