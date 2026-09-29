# Application API (experimental)

`import ble.experimental.next as ble` is a new application API for the Toit
BLE host, designed around what the host does rather than around NimBLE. It
runs wherever the BLE service runs (controller-only ESP32 firmware with a
provider container, or Linux through `ble.experimental.next.linux`) and sits
beside the unchanged `ble` package, which keeps working. If it does not earn
its place it can be dropped without touching anything else.

Code: `lib/ble/experimental/next.toit` and `lib/ble/experimental/next/`.
Tests: `tests/ble-next-*-test.toit`. Examples: `examples/ble/experimental/next-*.toit`.

## Principles

1. **Objects with lifetimes, no global callbacks.** Every connection is an
   object from the moment it exists until it is closed. Connecting,
   accepting a central, and the end of a connection are all things the
   application waits for in a task of its choosing.
2. **One `Connection` for both roles.** The same class describes a link to
   a peripheral (after `connect`) and a link from a central (after
   `accept`): peer address, role, MTU, PHY, data length, connection
   parameters, security, RSSI, transmit power, disconnect, and the reason
   it ended.
3. **Blocks for scopes, plain calls for everything else.** Scoped forms
   (`with-connection`, `subscribe`) clean up on every exit, cancellation
   included.
4. **Typed values.** Addresses are `Address` objects (six bytes plus type,
   printed the usual way), UUIDs are the `ble` package's `BleUuid`,
   advertisements are its `Advertisement`, errors carry codes.
5. **Say what the radio does.** Operations document what completion means
   (queued, sent, acknowledged) and what a failure leaves behind, following
   the cancellation contract in [design.md](design.md).

## Overview

```
Adapter ─┬─ scan / find ───────▶ ScanReport
         ├─ connect ─────────────────────────▶ Connection ─▶ RemoteService ─▶ RemoteCharacteristic ─▶ RemoteDescriptor
         ├─ advertise (broadcast only) ─▶ Broadcast
         └─ peripheral ─▶ Peripheral ─ accept ▶ Connection
                            │
                        GattServer ─▶ Service ─▶ Characteristic ─▶ Descriptor
```

## Adapter

```
adapter := ble.Adapter                 // finds the BLE service provider
adapter.capabilities                   // roles and limits of the provider
adapter.address                        // the controller's identity address
adapter.supports-phy-2m
adapter.supports-tx-power-control
adapter.tx-power                       // dBm, or null where the controller does not say
adapter.set-tx-power 9                 // returns the level used, in dBm
adapter.close
```

Transmit power control is a controller feature. The ESP32 controllers have
it through their vendor API (the original ESP32 from -12 to +9 dBm, the
ESP32-S3 from -24 to +20 dBm, in 3 dB steps); Linux adapters do not expose
it, and `set-tx-power` throws `BLE_UNSUPPORTED` there. The setting covers
advertising, scanning and new connections, and the provider applies it
again whenever it restarts the controller.

On Linux, `ble.experimental.next.linux.open 0` installs a provider for hci0
in the calling process and returns an adapter; the adapter must be powered
off in BlueZ and the process needs `CAP_NET_ADMIN`. `--resolve` loads
bonded peers (`resolving-list.Entry`) into the controller's resolving list.

Address types are `PUBLIC`, `RANDOM`, and, for peers the controller
resolved, `PUBLIC-IDENTITY` and `RANDOM-IDENTITY` (`is-identity`). Such a
peer appears in scan reports and as `connection.peer` by its identity, and
`connect` takes its identity address while the peer rotates its RPAs.

## Central role

```
report := adapter.find --service=HEART-RATE
connection := adapter.connect report.address --security=ble.SECURITY-ENCRYPTED
try:
  measurement := (connection.discover-service HEART-RATE).characteristic MEASUREMENT
  measurement.subscribe: | values/ble.Values |
    3.repeat: print values.receive
finally:
  connection.close
```

- `scan` calls its block for every report until the duration ends or the
  block returns false; `find` returns the first report matching a service
  UUID and/or a name.
- `connect` takes `--timeout`, `--mtu` (the ATT MTU this side offers,
  default 247), `--phy` (requested once connected; by default the host
  moves to 2M when both sides support it) and `--security`
  (`SECURITY-NONE`, `SECURITY-ENCRYPTED`, `SECURITY-AUTHENTICATED`: the
  connection throws `BLE_INSUFFICIENT_SECURITY` if it cannot reach the
  level; pairing policy belongs to the provider). `with-connection` is the
  scoped form.
- Discovery works in both roles: as a peripheral, `discover-services` and
  the rest reach the connected central's database (a phone's Current Time
  or Battery service) over the same link while this device serves its own.
- `discover-services`, `discover-service`, `discover-characteristics`,
  `characteristic` and `discover-descriptors` return objects bound to the
  peer's current database; after a Service Changed indication their
  operations throw and the application discovers again.
- `RemoteCharacteristic`: `read`, `write` (with response), `write
  --no-response` (Write Command), `subscribe [block]` (notifications, or
  indications when the characteristic has only those), `subscribe` without
  a block (a `Subscription` with `receive` and `close`, for values read
  outside one scope), `can-read` and the other property tests. Peer refusals throw `AttError` with the ATT code.

## Peripheral role

```
server := ble.GattServer
service := server.add-service HEART-RATE
measurement := service.add-characteristic MEASUREMENT --notify
service.add-characteristic CONTROL --write
    --security=ble.SECURITY-ENCRYPTED
    --validate=(:: | connection value | if value.is-empty: throw (ble.AttError ble.AttError.VALUE-NOT-ALLOWED))
    --on-write=(:: | connection value | print "$connection.peer wrote $value")

peripheral := adapter.peripheral server
    --advertisement=(ble.Advertisement --name="Toit" --services=[HEART-RATE])

while true:
  connection := peripheral.accept          // advertises until a central connects
  print "connected: $connection.peer"
  task::
    print "disconnected: $connection.peer, $connection.wait-closed"
    connection.close
```

- `add-service --secondary` declares a service that centrals reach only
  through another service's include; `service.include other` includes an
  earlier service of the same server.
- The `GattServer` is defined once and frozen when a `Peripheral` uses it.
  The provider builds a database from it for every connected central, so
  all centrals see the same attributes and one value per characteristic:
  `characteristic.value = bytes` updates every connection, a central's
  write becomes the value for all of them, `notify` sends to every
  subscribed central (or only `--to` one), `notify-values` sends up to 32
  values in one round trip per central, `indicate --to` waits for the
  confirmation.
- Handlers get the `Connection`: `--on-read` returns the value for each
  read, `--validate` runs before a write is applied and refuses it by
  throwing an `AttError`, `--on-write` runs after it was applied. Without
  handlers, reads return the value and writes replace it.
- `accept` is the connect event and returns the central's `Connection`;
  `connection.wait-closed` is the disconnect event and returns the
  `DisconnectReason`. `peripheral.connections` lists the connected ones.
  Several centrals can be connected at once, up to the provider's
  peripheral session limit; `accept` advertises again while others stay
  connected and waits when all slots are taken.
- Connectable advertising runs only while an `accept` waits.
  `set-advertisement` changes it, also while an accept waits. When the
  advertisement has no Flags field, the API adds LE General Discoverable.
- `adapter.advertise` broadcasts without accepting connections (a beacon)
  and returns a `Broadcast` to update or stop.

## Connection

| Member | Meaning |
| --- | --- |
| `peer` | the peer's `Address` |
| `role` | `ROLE-CENTRAL` (this device connected) or `ROLE-PERIPHERAL` (a central connected to it) |
| `mtu` | the negotiated ATT MTU |
| `phy` | the current `Phy` (tx and rx: `PHY-1M`, `PHY-2M`, `PHY-CODED`) |
| `request-phy` | asks for a PHY (both directions, or `--tx` and `--rx`); returns the `Phy` the controllers settled on |
| `data-length` | negotiated link-layer payload octets, tx and rx |
| `parameters` | connection interval, latency and supervision timeout |
| `request-parameters` | asks for new connection parameters: directly as central, through the central as peripheral |
| `security` | `SECURITY-NONE`, `SECURITY-ENCRYPTED` or `SECURITY-AUTHENTICATED`, as achieved now |
| `rssi` | the controller's RSSI for this link, in dBm |
| `tx-power` | the controller's current transmit power on this link, in dBm |
| `disconnect` | ends the link and waits until it has ended |
| `wait-closed` | waits for the end and returns the `DisconnectReason` |
| `is-closed` | whether the link ended |
| `close` | disconnects if needed and releases the connection |

After the link ended, the connection keeps its last PHY, data length and
parameters readable until `close`.

## Errors

Operations throw strings for local misuse and state (`BLE_CLOSED`,
`BLE_UNSUPPORTED`, `INVALID_ARGUMENT`, `BLE_SERVICE_NOT_FOUND`) and
`AttError` for a peer's ATT error (code, handle, request opcode). A link
that ended under an operation makes it throw; `wait-closed` says why.

## What it adds over the `ble` package

- Connect and disconnect events in the peripheral role, with the peer and
  the reason.
- Link details in both roles: PHY (and requests for one), data length,
  connection parameters (and requests), RSSI, transmit power, security.
- Transmit power control where the controller has it.
- Per-connection handler context: every read and write handler knows which
  central it serves.
- Batched notifications, write validation that can refuse with an ATT
  code, typed addresses and errors.

## Open questions

- **Name and place.** `ble.experimental.next` marks it as a candidate. If it
  replaces the `ble` package API, it moves to `import ble`.
- **Pairing from the application.** Pairing and bonding policy (IO
  capabilities, confirmation, bond storage) stay in the provider, as
  today. The API lets an application require a security level and read
  what was achieved; it does not start pairing itself.
- **Per-connection transmit power.** The ESP32 vendor API can set it per
  connection handle; the API sets the default for new connections only.
