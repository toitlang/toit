# Toit BLE host (experimental)

A BLE host written in Toit on top of the standard HCI interface. The vendor
controller keeps the radio, link layer and link encryption; Toit owns HCI
command handling, L2CAP, ATT/GATT, SMP, GAP policy and persistence.

Status: experimental and opt-in. NimBLE remains the default ESP32 backend.
See [features](features.md) for what is implemented, [open issues](open-issues.md)
for known failures, and [design](design.md) for the architecture.

| Document | Content |
| --- | --- |
| [design.md](design.md) | Architecture, task/cancellation model, memory ownership rules, service model |
| [features.md](features.md) | Implemented features, limits, gaps relative to NimBLE |
| [security.md](security.md) | SMP Secure Connections, encryption boundary, attribute security, bonds |
| [gatt-cache.md](gatt-cache.md) | Database layout, Service Changed, client invalidation, CCCD persistence and migration |
| [deployment.md](deployment.md) | What a production deployment must still supply (keys, trusted launch, recovery) |
| [hardware.md](hardware.md) | The test rig, permissions, flashing, Linux adapter ownership, interop suite |
| [open-issues.md](open-issues.md) | Unresolved failures and how to debug them |
| [references.md](references.md) | Specification editions used |

## Layout

| Path | Content |
| --- | --- |
| `lib/ble/experimental/` | The host: `hci`, `acl`, `central` (link owner for both roles), `att`, `gatt`, `attribute-server`, `gatt-server`, `smp-*`, `security`, `bond-*`, `cccd-*`, `privacy`, `scanning`, `advertising*` |
| `lib/ble/experimental/service/` | RPC service: `api` (selector, method indices), `client`, `provider` base and the provider variants |
| `src/resources/ble_hci_linux.cc`, `ble_hci_esp32.cc` | Native transports (HCI user channel; controller-only VHCI) |
| `tests/ble-*-test.toit` | Software tests on a scripted in-memory transport; `tests/ble-hci-test.toit` doubles as the shared fixture |
| `tests/ble-hardware/` | Board and adapter fixtures; `fixtures/` holds the provider/application images |
| `tests/ble-interop/` | Optional Bumble (Python) software peer suite and radio observers |
| `examples/ble/experimental/` | A minimal advertising provider and application |

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
