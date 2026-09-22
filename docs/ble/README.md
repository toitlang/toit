# Using the experimental Toit BLE host

For continuation of this checkout, start with the [2026-09-22 handover](handover.md):
current rig state, preserved work, terminal experiments and next steps.

The host runs in Toit above the controller's HCI interface. Applications normally
use `ble.experimental.service.client`; a separate provider container owns the
controller and protocol state. The implementation is experimental. Consult the
[feature inventory](features.md) and [roadmap acceptance criteria](roadmap.md)
before choosing it for a deployment.

## Start with an advertising application

Two existing examples demonstrate the service boundary without pairing or bond
storage:

- [vhci-advertising-provider.toit](../../examples/ble/vhci-advertising-provider.toit)
  supplies the ESP32 transport to the small advertising provider.
- [service-advertising-updates.toit](../../examples/ble/service-advertising-updates.toit)
  advertises `Toit counter` and updates a manufacturer-data counter from 0 to 9
  over ten seconds, then stops advertising.

The application uses a scoped block:

```toit
client.with-advertising initial.to-raw: | advertiser/service.Advertising |
  // Build the next advertisement and update the existing session.
  advertiser.update next.to-raw
```

The block receives the advertising handle. Leaving the scope closes it; the
complete example also closes the client in `finally`. The scope does not require
an escaping lambda or an application callback task. A successful update means
the controller accepted the data, not that another device received it.

From the repository root, use a built SDK and a **matching controller-only
ESP32 or ESP32-S3 envelope containing just the normal system container**. Its
native configuration must select `CONFIG_BT_CONTROLLER_ONLY=y`, with NimBLE
disabled. The repository's default ESP32 configurations still select NimBLE.
Choose the envelope for the actual chip and use its matching SDK; these commands
assemble applications and do not change the envelope's native configuration.

```sh
ble_sdk=build/host/sdk/bin/toit
ble_base=/path/to/controller-only.envelope
ble_output=build/ble-counter-example
mkdir -p "$ble_output"

"$ble_sdk" compile -s -o "$ble_output/provider.snapshot" \
  examples/ble/vhci-advertising-provider.toit
"$ble_sdk" compile -s -o "$ble_output/counter.snapshot" \
  examples/ble/service-advertising-updates.toit
cp "$ble_base" "$ble_output/application.envelope"
"$ble_sdk" tool firmware -e "$ble_output/application.envelope" \
  container install adv-provider "$ble_output/provider.snapshot"
"$ble_sdk" tool firmware -e "$ble_output/application.envelope" \
  container install counter "$ble_output/counter.snapshot"
"$ble_sdk" tool firmware -e "$ble_output/application.envelope" show
```

The resulting envelope should contain `system`, `adv-provider` and `counter`;
the two examples run at boot. Deploy it through the firmware workflow for your
board and flash layout. Keep the snapshots for decoding exceptions. The provider
stays installed after the counter application exits. An independent BLE scanner
can observe the counter; this example is non-connectable.

Compilation and envelope assembly need no additional Python helper. The normal
ESP32 flashing toolchain has its existing dependencies. Optional independent
[Bumble regression tests](../../tests/ble-interop/README.md) are separate from
ordinary SDK use and Toit protocol tests.

## Choose the installed provider

Provider modules are under `ble.experimental.service`. Each needs a concrete
transport implementation; the advertising example above shows the minimal one.

| Provider module | Included operations |
| --- | --- |
| `advertising-provider` | Non-connectable advertising, including live payload updates |
| `scanning-provider` | Advertising and legacy scanning, including continuous scans |
| `central-provider` | Advertising, scanning and outgoing GATT connections |
| `gatt-provider` | The preceding operations plus a local GATT peripheral |
| `mixed-provider` | Explicit sharing between two central clients, or one central and one peripheral client, on supporting controllers |

These operation sets do not imply that every operation can run concurrently.
Standalone scanning and advertising are exclusive. See the
[mixed-role policy](mixed-role-services.md) for shared sessions and controller
requirements; original ESP32 does not support that provider.

The compiler tree-shakes each container separately. Choosing a small provider
removes unreachable host code from its image; an application's imports cannot
shrink a separately installed general-purpose provider. Multiple applications
can reuse one provider image. [Measured service sizes](service-sizes.md) compare
these choices, including native firmware and flash-partition effects.

Pairing, privacy and persisted bonds require explicit provider policy. Review
the [API migration inventory](api-migration.md) and [security behavior](security.md)
when adding them. Public keys and automatic pairing approvals in test fixtures
are test configuration; production persistence still needs the key source and
recovery policy described in [deployment requirements](deployment.md).

For a tested persistence deployment, [vhci-cccd-provider.toit](../../examples/ble/vhci-cccd-provider.toit)
and [service-cccd.toit](../../examples/ble/service-cccd.toit) separate a fixed-database
provider from its application. Independent tests on ESP32 and S3 retain subscriptions
through container replacement and board reset. See [the persistence evidence and
remaining requirements](cache-policy.md#independent-service-container-persistence)
before adapting the fixture's public test keys or fixed database policy.

## Handle termination and recovery

Prefer `with-advertising`, `with-connection` and `Connection.subscribe` when a
block expresses the resource lifetime. These scopes attempt cleanup on return,
exception and cancellation. If the body already failed, its error is preserved;
otherwise a cleanup error is reported. `Session.serve` closes its peripheral
session when serving ends. Explicit handles still require explicit cleanup,
and the application should close its `Client` in `finally`.

Choose recovery from the operation that failed:

| Observation | Application action |
| --- | --- |
| A capability is absent, or `GATT_UNSUPPORTED_SERVICE_OPERATION` | Choose a provider that implements the operation. Retrying the same omitted operation does not add support. |
| `GATT_SERVICE_BUSY` | Let the current owner finish cleanup before opening another session. Admission includes pending setup and teardown; a failed controller close can keep the provider unavailable. |
| `AttributeError` | Inspect its request, handle and ATT code. The peer rejected that operation; this does not by itself mean the provider died or authorize fresh pairing. |
| A subscription `receive` fails, including overflow | Leave the subscription scope. Delivery may already have consumed a queued value, so retrying the receive cannot establish that no data was lost. |
| A low-level `Session.next` fails | Close the session. The provider may already have delivered the request; `Session.serve` performs this cleanup for its own pulls. |
| The provider process exits | Close the old client and discard its connections, subscriptions, request tokens and database views. Open a new client after the replacement provider is ready. Old handles do not refer to the replacement. |

After reconnecting, discover handles again. For peers with Service Changed,
use a fresh `Connection.database` view inside `with-service-changed`; a change
invalidates existing views. Do not reuse numeric handles merely because the
peer address is unchanged. Reapply the application's required encryption and
authentication checks when creating the replacement connection.

An interrupted write or RPC can have an uncertain result: the peer or provider
may already have applied it. Do not automatically replay it. Applications that
need recovery across disconnects should include operation identifiers or query
application state to resolve that uncertainty. Write Commands and notifications
do not acknowledge peer receipt; an indication confirms protocol reception,
not delivery to or processing by the receiving application.

For peripheral serving, `Session.termination-reason` retains the cause observed
by the serving loop or watcher. Inspect it after joining the serving task. It
can be null, or an RPC error after provider loss, and it does not itself prove
that controller cleanup has finished. Accepted writes remain committed if their
accepted-write callback later fails or times out.

A restarted trusted provider has a new runtime PID. Obtain that PID from the
trusted launcher and create a new pinned client; do not fall back to an unpinned
service with the same name. For stored bonds, recreating the registry after an
ambiguous storage failure is not a recovery policy—follow the
[deployment requirements](deployment.md).

Heap exhaustion commonly requires a board reset. Cleanup is best effort in that
case; applications need not assume the provider can recover. The separate
[primitive allocation guarantees](native-checks.md) still apply: native calls
must allow GC and retry at primitive boundaries without silently consuming data.

Scoped evidence for these contracts is in `ble-service-scope-errors-test`,
`ble-service-provider-restart-test`, `ble-service-provider-pin-test`,
`ble-service-termination-test`, `ble-service-pull-pressure-test` and
`ble-service-notification-rpc-pressure-test`. It does not close the broader
hardware reliability and deployment gates in the roadmap.

## Linux and further development

Linux uses a dedicated adapter through an exclusive HCI user socket. Follow the
[native launcher setup](../../examples/ble/README.md#linux-hci-ownership), which
checks adapter identity, reserves it and restores its original power state.
Adapter indexes can change across reconnects. Resolve the intended adapter by
MAC and verify it again at acquisition; select serial boards by their full
`/dev/serial/by-id/` path. The [rig inventory](board-matrix.md#persistent-rig-identities)
records the development devices. The ESP32 provider above opens its on-chip
controller. Native Windows and macOS controller transports are not implemented.

The [design](design.md) explains managed packet ownership, primitive GC retries
and service lifetimes. The [test plan](conformance-tests.md) maps protocol coverage
and independent tests. [Implementation evidence](progress.md) retains failures
and scoped results; the [board matrix](board-matrix.md) records hardware campaigns.
The longer [examples README](../../examples/ble/README.md) includes historical
experiments whose temporary build helpers are not distributed SDK tools.
