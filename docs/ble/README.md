# Toit BLE host (experimental)

A BLE host written in Toit on top of the standard HCI interface. The vendor
controller keeps the radio, link layer and link encryption; Toit owns HCI
command handling, L2CAP, ATT/GATT, SMP, GAP policy and persistence.

Status: experimental and opt-in. NimBLE remains the default ESP32 backend.
See [features](features.md) for what is implemented, [open issues](open-issues.md)
for known failures, [design](design.md) for the architecture, and
[measurements](measurements.md) for memory and throughput against NimBLE.

The existing `ble` package API runs on this host unchanged: on firmware
without a native BLE host, `ble.Adapter` uses the BLE service provider
installed on the device (see "Using the ble package" below).

| Document | Content |
| --- | --- |
| [design.md](design.md) | Architecture, task/cancellation model, memory ownership rules, service model |
| [features.md](features.md) | Implemented features, limits, gaps relative to NimBLE |
| [security.md](security.md) | SMP Secure Connections, encryption boundary, attribute security, bonds |
| [gatt-cache.md](gatt-cache.md) | Database layout, Service Changed, client invalidation, CCCD persistence and migration |
| [deployment.md](deployment.md) | What a production deployment must still supply (keys, trusted launch, recovery) |
| [hardware.md](hardware.md) | The test rig, permissions, flashing, Linux adapter ownership, interop suite |
| [measurements.md](measurements.md) | Memory and notification throughput against NimBLE on the same board |
| [open-issues.md](open-issues.md) | Unresolved failures and how to debug them |
| [references.md](references.md) | Specification editions used |

## Layout

| Path | Content |
| --- | --- |
| `lib/ble/host.toit` | The `ble` package's public API on top of the service client; chosen by `ble.Adapter` when no native host exists |
| `lib/ble/experimental/` | The host: `hci`, `acl`, `central` (link owner for both roles) with `link`, `att`, `gatt`, `attribute-server`, `gatt-server`, `smp-*`, `security`, `bond-*` with `storage-key`, `cccd-*`, `privacy`, `scanning`, `advertising*`, `timeouts` (every bound), `cancellation` |
| `lib/ble/experimental/service/` | RPC service: `api` (selector, method indices), `client`, `provider` base and the provider variants |
| `src/resources/ble_hci_linux.cc`, `ble_hci_esp32.cc` | Native transports (HCI user channel; controller-only VHCI) |
| `tests/ble-*-test.toit` | Software tests on a scripted in-memory transport; `tests/ble-hci-test.toit` doubles as the shared fixture |
| `tests/ble-hardware/` | Board and adapter fixtures; `fixtures/` holds the provider/application images; `bench/` the NimBLE comparison; `campaigns/` the multi-board campaigns |
| `tests/ble-interop/` | Optional Bumble (Python) software peer suite and radio observers |
| `examples/ble/experimental/` | The provider container to deploy with `ble` package applications, plus a minimal advertising provider and application |

## Using the ble package

An application written against the `ble` package (`Adapter`, `Central`,
`Peripheral`, ...) needs no change: build the controller-only firmware
(`make BLE_HOST=1 esp32`), install a provider container beside the
application (`examples/ble/experimental/gatt-provider.toit` is the one to
start from), and `Adapter` picks the provider when the native host is absent. `examples/ble/heart_rate.toit`
runs this way unchanged; `tests/ble-hardware/compat.sh` is the check. The
peripheral serves as many centrals at once as the provider's
`peripheral-session-limit` allows (one by default) and keeps advertising
while connected; bonding and pairing policy belong to the provider.

## Using the service from an application

Applications import `ble.experimental.service.client` and talk to a provider
container that owns the controller. The provider is chosen at deployment time:

| Provider module | Operations |
| --- | --- |
| `advertising-provider` | Non-connectable advertising with live payload updates |
| `scanning-provider` | Advertising and legacy scanning |
| `central-provider` | Scanning and outgoing GATT connections |
| `gatt-provider` | The above plus a local GATT peripheral |
| `mixed-provider` | Two central clients, or one central and one peripheral client, on controllers that support extended advertising (not the original ESP32) |
| `pairing-provider`, `private-*-provider`, `bond-admin-provider` | Policy subclasses adding fresh pairing, host-generated private addresses, and bond administration |

Each provider is a subclass that supplies `open-transport` (an
`esp32.Esp32Transport` on a controller-only ESP32 build, or a
`linux.LinuxTransport` on Linux) and any security or address policy through
overridable hooks. Applications never receive key material or controller
handles over RPC.

Minimal advertising example:

```toit
import ble.experimental.service.client as service

main:
  client := service.Client
  client.open
  try:
    client.with-advertising #[2, 1, 6, 5, 9, 'T', 'o', 'i', 't']: | advertiser/service.Advertising |
      sleep --s=10
  finally:
    client.close
```

The full pair is in `examples/ble/experimental/advertising-provider.toit` and
`advertising-counter.toit`. Build an envelope from a controller-only firmware
(`CONFIG_BT_CONTROLLER_ONLY=y`, no NimBLE) and install both snapshots as
containers; see [hardware.md](hardware.md).

Prefer the scoped forms (`with-advertising`, `with-connection`,
`Connection.subscribe`, `Session.serve`): they release the controller on
return, exception and cancellation. Explicit handles need explicit `close`.

## Using the host directly

`examples/ble/experimental` and the fixtures under `tests/ble-hardware/fixtures`
show the direct API: create an `hci.Controller` over a transport, call
`hci.initialize`, then build a `central.Central` (link owner), `att.Client` or
`gatt-server.Server` on it. The direct API is what the providers wrap; it runs in
the caller's process and is intended for tests and providers, not applications.
