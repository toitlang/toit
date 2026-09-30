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
3. **Smaller provider.** Pairing is now the `service.pairing.Support`
   mixin's opt-in; a provider without it links no SMP, ECDH or bond code
   (a pairing provider container is 281 KB, a plain one 244 KB). The system
   image with the built-in provider is 326 KB at `-O2`, 137 KB of which is
   the host core, against 91 KB for NimBLE's C code: bytecode costs more
   flash, and that is the remaining gap.
   Found: the built-in provider plus a deployment's own provider container
   plus an application exceed the 1.7 MB partition (1327 KB firmware +
   326 KB system + 281 KB provider). Subclassing the provider cannot stay
   the way deployments set policy on the ESP32. Next: one host, the
   system's, with policy delegated over RPC to a small optional policy
   container (IO capability, confirmations, passkeys, bond records, the
   resolving list, session limits); provider subclasses remain for Linux
   and tests.
5. **C3 and C6.** Done, compile-verified only (no board on the rig): the
   controller-only transport builds for every chip with `CONFIG_BT_CONTROLLER_ONLY`,
   `make esp32c3` and `esp32c6` have their overlays, and the
   C3's core without atomic instructions uses ESP-IDF's critical-section
   atomics for the VHCI queue counters.
6. **Remove NimBLE.** Done: `make esp32` (and s3, c3, c6) builds the
   controller-only firmware with the built-in provider; the NimBLE sdkconfig
   options, `src/resources/ble_esp32.cc`, the NimBLE hardware fixtures, the
   legacy-bond hardware check (it needed a NimBLE peer) and the benchmark's
   NimBLE variant are gone. The `ble` package's native classes stay until
   step 7; on the ESP32 they fail to find their primitives and `Adapter`
   falls back to the provider, which `tests/ble-hardware/compat.sh`
   verifies. The benchmark keeps the NimBLE numbers above as its reference.
7. **`ble` on `ble.v2`.** Done: `lib/ble/host.toit` implements the
   package's classes on `ble.v2` (the native classes and their primitives
   are gone from the Toit side; `src/resources/ble_darwin.mm` stays for the
   macOS provider of step 8). `ble.v2` gained what the port needed:
   `bonded-peers`, scan interval, window and limited mode, an unbounded
   scan, the raw report bytes, remote handles, a descriptor value setter
   and the peripheral's MTU. Verified by the software tests and
   `tests/ble-hardware/compat.sh` (two centrals at once).
8. **macOS backend.** Written, not yet run on a Mac:
   `lib/ble/experimental/service/darwin-provider.toit` speaks the service
   protocol over the CoreBluetooth primitives the `ble` package used before
   (`lib/ble/experimental/darwin.toit`, `src/resources/ble_darwin.mm`,
   unchanged). `ble.v2.darwin.open` gives a `ble.v2` adapter;
   `ble.v2.darwin.install` puts the provider in the process for the `ble`
   package (no automatic fallback: that would cost every ESP32 application
   42 KB of snapshot). Peers are `PlatformPeer`s (16-byte identifiers,
   address type 4 on the wire). Supported: scanning (name, service UUIDs,
   manufacturer data re-encoded as advertising data), connecting, service
   and characteristic discovery, reads, writes, subscriptions, the MTU; a
   served database with static values, notifications and incoming writes,
   published once per process; advertising a name and service UUIDs.
   Unsupported, by the primitives or by macOS: descriptors, included
   services, read handlers and write validation, the identity of
   connected centrals and their connect and disconnect events (`accept`
   returns one anonymous peer as soon as advertising runs), PHY,
   parameters, RSSI, transmit power, security, the adapter's address.
   To do on a Mac: build (`make sdk` on macOS), run
   `tests/ble-hardware/darwin-check.toit` against any BLE peripheral, and
   fix what the first run finds.

4. **Faster small notifications** (open). The measured chain: one RPC
   costs 2.5 ms, batching 32 values per RPC reaches 320/s in the system
   container, and the direct host (no RPC at all) 375–460/s, against
   NimBLE's 765/s. So the RPC is not the only limit: the host sends one ACL
   packet per notification and refills controller credits from the
   interpreter, about six packets per 15 ms connection event where NimBLE
   fits eleven. The next step is in the host's transmit path (more packets
   in flight per credit round), not in the service layer.

## Where it stands (end of 2026-09-30)

| | NimBLE (was) | Toit host (now) |
| --- | --- | --- |
| Firmware binary, ESP32 | 1418 KB | 1327 KB |
| System image | 172 KB | 326 KB (the provider; 137 KB of it is the host core) |
| Free heap while advertising / connected | 105.5 KB / — | 120 KB / 115.5 KB |
| 20-byte notifications | 765/s | 320/s batched, 157/s single |
| 244-byte notifications | 65 KB/s | 76 KB/s (143 KB/s on the S3 at 2M) |
| Chips | ESP32, S3, C3, C6 | the same (C3, C6 compile-verified) |
| macOS | `ble` over CoreBluetooth | `ble` and `ble.v2` over the CoreBluetooth provider, untested on a Mac |
| Pairing, bonds, privacy, GATT client as peripheral, per-connection details | mostly absent | present (provider policy) |

Flash is the remaining regression (63 KB more in total for an ESP32 with the
built-in provider), small notifications the remaining throughput gap.
Better than NimBLE on every other row.
