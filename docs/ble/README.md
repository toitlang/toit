# Toit BLE host (experimental)

A BLE host written in Toit on top of the standard HCI interface. The vendor
controller keeps the radio, link layer and link encryption; Toit owns HCI
command handling, L2CAP, ATT/GATT, SMP, GAP policy and persistence.

Status: experimental. Controller-only ESP32 builds include the Toit BLE service
in the system container by default. The Toit host is the only supported ESP32
BLE implementation; NimBLE and Bluedroid configurations are rejected at build time.
See [features](features.md) for what is implemented, [open issues](open-issues.md)
for known failures, [design](design.md) for the architecture, and
[measurements](measurements.md) for memory and throughput against NimBLE.

The existing `ble` package API runs on this host through `ble.v2`:
`ble.Adapter` uses the BLE service provider installed on the device
(see "Using the ble package" below).

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

BLE stays in the SDK so the deprecated `ble` API and the built-in system
provider use the same implementation and native transport version.

Applications use `ble.v2`. Custom providers use `ble.service` (the full GATT
provider) or its smaller provider modules, and `ble.transport` for controller
interfaces and transports. `ble.implementation_` and hooks ending in `_` are
private SDK details, used by the built-in providers and protocol tests. They
are not supported application or package extension APIs.

The former `ble.experimental` imports have been removed. Provider subclasses
should import `ble.service.gatt-provider` (or `ble.service`), pairing policy
uses `ble.service.pairing`, and transport implementations live under
`ble.transport`. The raw RPC client is `ble.service.client`. SDK tests that
exercise protocol internals import `ble.implementation_` directly.

| Path | Content |
| --- | --- |
| `lib/ble/host.toit` | The `ble` package's public API implemented on `ble.v2` and its service client |
| `lib/ble/service/` | Public provider extension API, pairing policy, resolving-list entries and RPC client |
| `lib/ble/transport.toit`, `lib/ble/transport/` | Public transport interfaces, ESP32 and Linux transports, diagnostics and tracing wrappers |
| `lib/ble/implementation_/` | The host: `hci`, `acl`, `central` (link owner for both roles) with `link`, `att`, `gatt`, `attribute-server`, `gatt-server`, `smp-*`, `security`, `bond-*` with `storage-key`, `cccd-*`, `privacy`, `scanning`, `advertising*`, `timeouts` (every bound), `cancellation` |
| `lib/ble/implementation_/service/` | Private RPC protocol, request handling, shared host and provider implementations |
| `src/resources/ble_hci_linux.cc`, `ble_hci_esp32.cc` | Native transports (HCI user channel; controller-only VHCI) |
| `tests/ble-*-test.toit` | Software tests on a scripted in-memory transport; `tests/ble-hci-test.toit` doubles as the shared fixture |
| `tests/ble-hardware/` | Board and adapter fixtures; `fixtures/` holds the provider/application images; `bench/` compares provider placement; `campaigns/` holds the multi-board campaigns |
| `tests/ble-interop/` | Optional Bumble (Python) software peer suite and radio observers |
| `examples/ble/service/` | Custom providers using public SDK APIs, plus an advertising application |

## Using the ble package

### Envelope build selection

The default ESP32 system container is assembled at build time.
`CONFIG_TOIT_SYSTEM_BLE` defaults to enabled when
`CONFIG_BT_CONTROLLER_ONLY` provides the native HCI transport. On builds without
that transport, the system snapshot does not import or include the BLE provider.
Disable `CONFIG_TOIT_SYSTEM_BLE` to retain the transport while supplying your own
provider container, without carrying a second provider in the system image.

The build generates `toit-system/boot.toit` in its output directory. This entry
point imports the selected provider modules and passes their installers to the
common boot routine. Further optional providers, such as Ethernet, can use the
same mechanism; their runtime configuration remains separate from code inclusion.

`CONFIG_TOIT_SYSTEM_SOURCE` overrides remain supported: custom entry points are
compiled unchanged and select their own providers. A custom entry point can call
`run` from `system/extensions/esp32/boot.toit` with a block that installs its
providers before applications start. Compiling that source directly, outside the
envelope build, starts only the core services. The existing
`boot-without-ble.toit` remains usable as an explicit no-BLE entry point.

### Application use

An application written against the `ble` package (`Adapter`, `Central`,
`Peripheral`, ...) needs no change: build the controller-only firmware
(`make esp32`), whose system container serves BLE
(`system/extensions/esp32/ble.toit`), and `Adapter` uses that provider.
`examples/ble/heart_rate.toit` runs this
way unchanged; `tests/ble-hardware/compat.sh` is the check. The built-in
provider does not pair and lets two centrals connect at once; a deployment
that wants pairing, bonds or other limits installs its own provider
container (`examples/ble/service/gatt-provider.toit` is the one to
start from), which takes precedence by service priority.

## The experimental application API

`import ble.v2 as ble` is a new API designed around the
host: one `Connection` class for both roles, `Peripheral.accept` and
`Connection.wait-closed` as the connect and disconnect events, link details
(PHY, data length, parameters, security, RSSI, transmit power) and
transmit power control. It uses the same provider as the `ble` package;
on Linux `ble.v2.linux.open` installs one in the process. Design, open questions and what it adds: [api.md](api.md).
Examples: `examples/ble/v2-peripheral.toit` and
`next-central.toit`; hardware check: `tests/ble-hardware/next-check.sh`.

## Using the service from an application

Applications normally use `ble.v2`. The lower-level `ble.service.client` talks to a provider
container that owns the controller. The provider is chosen at deployment time:

| Provider module | Operations |
| --- | --- |
| `ble.service.scanning-provider` | Advertising and legacy scanning: the small image (137 KB snapshot) |
| `ble.service.gatt-provider` | Everything: scanning, advertising, outgoing GATT connections and a local GATT peripheral (250 KB, 285 KB with pairing in use) |

`advertising-provider` and `central-provider` are the layers `gatt-provider`
is built from; they can be deployed on their own but are not separate
variants. Policy is set by overriding hooks rather than by choosing a
module: `privacy-irk` (resolvable private addresses for advertising, scanning
and peripheral sessions, rotated every `privacy-rotation-interval`),
the `service.pairing.Support` mixin with its `pairing-io-capability`,
`confirm-pairing` and `require-authentication` hooks (fresh pairing, linked
only into providers that mix it in), `mixed-role-sessions` (one central and one peripheral
client at once, on controllers with extended advertising, not the original
ESP32), and `peripheral-session-limit` (several centrals).

Advanced bond storage, bond administration and custom protocol owners still use
private implementation APIs, including `create-security-owner_`. Their fixtures
exercise SDK internals; they are not examples of a stable public bonding API.

Each provider is a subclass that supplies `open-transport` (an
`ble.transport.esp32.Esp32Transport` on a controller-only ESP32 build, or a
`ble.transport.linux.LinuxTransport` on Linux) and any security or address policy through
overridable hooks. Applications never receive key material or controller
handles over RPC.

Minimal advertising example:

```toit
import ble.service.client as service

main:
  client := service.Client
  client.open
  try:
    client.with-advertising #[2, 1, 6, 5, 9, 'T', 'o', 'i', 't']: | advertiser/service.Advertising |
      sleep --s=10
  finally:
    client.close
```

The full pair is in `examples/ble/service/advertising-provider.toit` and
`advertising-counter.toit`. Build an envelope from a controller-only firmware
(`CONFIG_BT_CONTROLLER_ONLY=y`, no NimBLE) and install both snapshots as
containers; see [hardware.md](hardware.md).

Prefer the scoped forms (`with-advertising`, `with-connection`,
`Connection.subscribe`, `Session.serve`): they release the controller on
return, exception and cancellation. Explicit handles need explicit `close`.

## SDK-internal host tests

The fixtures under `tests/ble-hardware/fixtures` use private implementation
APIs: create an `hci.Controller` over a transport, call
`hci.initialize`, then build a `central.Central` (link owner), `att.Client` or
`gatt-server.Server` on it. The direct API is what the providers wrap; it runs in
the caller's process. These APIs may change with the SDK and should not be
imported by applications or external packages. The examples under
`examples/ble/service` use the public provider API instead.
