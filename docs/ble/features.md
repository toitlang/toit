# Feature inventory

Service protocol 0.27 (`service/api.toit`). This lists what the host implements,
its fixed limits, and the gaps that must close before it can replace NimBLE.

## Implemented

| Area | Implementation |
| --- | --- |
| Controller access | Linux HCI user channel (exclusive adapter ownership); ESP32 and ESP32-S3 controller-only VHCI. No macOS or Windows transport. |
| HCI | Reset, identity and feature discovery, event masks, command credits, Command Status vs Command Complete, LE scan/advertise/connect/disconnect, ACL fragmentation and reassembly, shared ACL transmit budget with per-link quota, optional controller-to-host flow control, legacy and extended (1M PHY) connection commands, finite extended advertising for accept. |
| Scanning | Legacy passive and active scanning, duplicate filtering, bounded report queue with drop counter, optional timed RPA rotation. |
| Advertising | Legacy connectable and non-connectable advertising, live payload updates, optional timed RPA rotation. |
| Connections | Bounded live registry (default one link, up to 16), connection parameter update from either role, disconnect with reason, Data Length Extension (a supporting controller gets 251-octet defaults at initialization and each link reports its negotiated lengths), LE 2M PHY (1M/2M defaults at initialization; a link owner asks for 2M after a connection it initiated when the peer supports it, and `Link.phy` reports the update; the original ESP32 controller has no 2M). |
| L2CAP | Fixed ATT, signaling and SMP channels; connection parameter requests in both directions (a peripheral asks with a new identifier per request and waits for the central to apply it; central-role links apply valid peer requests by default); rejection of other channels. |
| ATT/GATT client | MTU exchange (23 to 517), primary service, included service, characteristic and descriptor discovery, read by UUID, read multiple (both forms), read, read long, write, write long (prepare/execute), write command, up to eight scoped subscriptions with a shared bounded queue, indications with confirmation, Service Changed monitor with a connection-local database revision. In both roles: on a peripheral link the client shares the bearer with the server (one MTU, the central's requests served while a client request waits). |
| ATT/GATT server | Read Multiple (both forms); static database of 64 attributes by default and up to 512 on request (providers allow 256 by default; the application API sizes it from its definition), values up to 512 bytes, secondary and included services, Service Changed by default, Robust Caching (Database Hash, Client Supported Features, Database Out Of Sync for change-unaware bonded clients; [gatt-cache.md](gatt-cache.md)), dynamic reads and pre-commit write validation through scoped handlers, prepared writes with atomic execute, notifications (single and batched through one RPC) and single-outstanding indications, user description and extended properties descriptors, per-attribute encryption and authentication requirements. |
| SMP | Secure Connections Just Works, Numeric Comparison and Passkey Entry in both roles, f4/f5/f6/g2 with AES-CMAC, P-256 through mbedTLS with invalid-point and debug-key rejection, constant-time confirm comparison, identity (IRK) distribution, retry admission policy. LE legacy Just Works and Passkey Entry in both roles with 128-bit keys, long term key distribution (EDIV/Rand) and resumption of legacy bonds; verified on hardware against a NimBLE legacy peripheral (`tests/ble-hardware/legacy-bond.sh`). |
| Encryption | LE Start Encryption on central links, LTK request replies on peripheral links, encryption change tracking, links that require encryption for their lifetime. |
| Privacy | Host-side RPA generation and resolution, host-selected random addresses for scanning, advertising and connecting. Controller-based resolution where the controller has link-layer privacy: the provider's `resolving-list` loads bonded peers (identity and IRK), reports and connections then name them by identity (address types 2 and 3), and centrals connect to a rotating peer by its identity; verified between two boards with `tests/ble-hardware/private-resolve.sh` (the rig's dongles lack link-layer privacy). |
| Peripheral sessions | A provider whose `peripheral-session-limit` is above one serves that many centrals at once on a shared host, advertising again while connected; central sessions are refused meanwhile. |
| Application API | `ble.v2` ([api.md](api.md)): connect and disconnect events in both roles, link details and PHY/parameter requests, transmit power control (ESP32 vendor API; per link on the ESP32-S3), handlers with the central's connection, batched notifications, GATT client in both roles, secondary and included services, subscriptions with or without a scope, pairing started by a peripheral application (Security Request). Verified on the original ESP32 and the ESP32-S3 with `tests/ble-hardware/next-check.sh`. |
| Link operations | Read PHY, data length, connection parameters, RSSI (Read RSSI) and transmit power (Read Transmit Power Level) of any link; LE Set PHY with preferences, waiting for its completion and for the automatic 2M request made after connecting; disconnect reason. |
| `ble` package | The existing public API (`Adapter`, `Central`, `Peripheral`, remote and local services, characteristics and descriptors) runs unchanged on this host: `Adapter` falls back to the BLE service provider when the firmware has no native host (`lib/ble/host.toit`). Scan, connect by identifier, discovery, read, write, subscribe and notifications on the central side; services, characteristics with callback reads and writes, descriptors, advertising and notifications on the peripheral side. Writes with a response pass through the application's write handler before the response leaves; write commands are committed by the provider at once. Verified on hardware with the unchanged `examples/ble/heart_rate.toit` (`tests/ble-hardware/compat.sh`). |
| Bonds | Encrypted (AES-GCM) bond records bound to namespace and slot, an in-memory table with snapshots, resumption owners, revocation markers, an administration service, protected per-bond CCCD storage, offline database migration. |
| Service layer | Scanning and GATT providers (the GATT one serves both roles) configured through hooks (privacy, pairing, session limits, mixed roles, resolving list, bonded peers), bounded request mailbox for server handlers, client-side scoped blocks, capability discovery, provider PID pinning. |

## Fixed limits

| Limit | Value |
| --- | --- |
| Database attributes | 64 by default, up to 512 (`max-attributes` on the provider, 256 by default) |
| Application value | 512 bytes |
| ATT MTU | 517 |
| Reassembled L2CAP payload | 65 bytes default, up to 1024 |
| Client subscriptions | 8, sharing a 32-packet queue |
| Native ESP32 ingress queue | 8 packets of 1029 bytes, 2 slots reserved from advertising reports |
| Peripheral accept | advertises until a central connects (60 seconds per session with mixed roles, see `advertising-timeout`) |
| Sessions per provider | up to 8 central and 8 peripheral sessions (`central-session-limit`, `peripheral-session-limit`; 1 each by default), both roles at once with `mixed-role-sessions`; one session per service client, so the application API opens a client per connection. The controller bounds it further: the original ESP32 images (NimBLE and controller-only alike) allow 2 connections (`CONFIG_BTDM_CTRL_BLE_MAX_CONN`), the ESP32-S3 10 activities. |
| Pairing attempts | one per owner object |

## Differences from the NimBLE backend

No known gap remains for the `ble` package as applications use it today.
Deliberate differences on this host: pairing policy is the provider's, so
the peripheral's `--bonding` and `--secure-connections` flags are advisory,
and `bonded-peers` lists what the provider chooses to list (none by default).

Not implemented, and not offered by the NimBLE backend either: OOB pairing
(a legacy peer that offers only keys shorter than 128 bits is refused),
extended advertising PDUs (more than 31 bytes, Coded PHY; only legacy PDUs
over extended commands are used), periodic advertising, L2CAP
connection-oriented channels and EATT.

## Verification state

All 187 BLE test programs run in the ordinary CTest suite on a scripted in-memory
transport. Hardware coverage exists for every feature above on the rig described
in [hardware.md](hardware.md), against BlueZ, Bumble and NimBLE peers, but it is
manual, and the failures in [open-issues.md](open-issues.md) remain.
