# Feature inventory

Service protocol 0.25 (`service/api.toit`). This lists what the host implements,
its fixed limits, and the gaps that must close before it can replace NimBLE.

## Implemented

| Area | Implementation |
| --- | --- |
| Controller access | Linux HCI user channel (exclusive adapter ownership); ESP32 and ESP32-S3 controller-only VHCI. No macOS or Windows transport. |
| HCI | Reset, identity and feature discovery, event masks, command credits, Command Status vs Command Complete, LE scan/advertise/connect/disconnect, ACL fragmentation and reassembly, shared ACL transmit budget with per-link quota, optional controller-to-host flow control, legacy and extended (1M PHY) connection commands, finite extended advertising for accept. |
| Scanning | Legacy passive and active scanning, duplicate filtering, bounded report queue with drop counter, optional timed RPA rotation. |
| Advertising | Legacy connectable and non-connectable advertising, live payload updates, optional timed RPA rotation. |
| Connections | Bounded live registry (default one link, up to 16), connection parameter update from either role, disconnect with reason, Data Length Extension (a supporting controller gets 251-octet defaults at initialization and each link reports its negotiated lengths), LE 2M PHY (1M/2M defaults at initialization; a link owner asks for 2M after a connection it initiated when the peer supports it, and `Link.phy` reports the update; the original ESP32 controller has no 2M). |
| L2CAP | Fixed ATT, signaling and SMP channels; parameter request/response; rejection of other channels. |
| ATT/GATT client | MTU exchange (23 to 517), primary service, characteristic and descriptor discovery, read, read long, write, write long (prepare/execute), write command, up to eight scoped subscriptions with a shared bounded queue, indications with confirmation, Service Changed monitor with a connection-local database revision. |
| ATT/GATT server | Static database of at most 64 attributes, values up to 512 bytes, Service Changed by default, dynamic reads and pre-commit write validation through scoped handlers, prepared writes with atomic execute, notifications (single and batched through one RPC) and single-outstanding indications, user description and extended properties descriptors, per-attribute encryption and authentication requirements. |
| SMP | Secure Connections Just Works and Numeric Comparison in both roles, f4/f5/f6/g2 with AES-CMAC, P-256 through mbedTLS with invalid-point and debug-key rejection, constant-time confirm comparison, identity (IRK) distribution, retry admission policy. LE legacy Just Works in both roles with 128-bit keys, long term key distribution (EDIV/Rand) and resumption of legacy bonds; verified on hardware against a NimBLE legacy peripheral (`tests/ble-hardware/legacy-bond.sh`). |
| Encryption | LE Start Encryption on central links, LTK request replies on peripheral links, encryption change tracking, links that require encryption for their lifetime. |
| Privacy | Host-side RPA generation and resolution, host-selected random addresses for scanning, advertising and connecting. |
| Peripheral sessions | A provider whose `peripheral-session-limit` is above one serves that many centrals at once on a shared host, advertising again while connected; central sessions are refused meanwhile. |
| `ble` package | The existing public API (`Adapter`, `Central`, `Peripheral`, remote and local services, characteristics and descriptors) runs unchanged on this host: `Adapter` falls back to the BLE service provider when the firmware has no native host (`lib/ble/host.toit`). Scan, connect by identifier, discovery, read, write, subscribe and notifications on the central side; services, characteristics with callback reads and writes, descriptors, advertising and notifications on the peripheral side. Writes with a response pass through the application's write handler before the response leaves; write commands are committed by the provider at once. Verified on hardware with the unchanged `examples/ble/heart_rate.toit` (`tests/ble-hardware/compat.sh`). |
| Bonds | Encrypted (AES-GCM) bond records bound to namespace and slot, an in-memory table with snapshots, resumption owners, revocation markers, an administration service, protected per-bond CCCD storage, offline database migration. |
| Service layer | Five provider variants plus policy subclasses, bounded request mailbox for server handlers, client-side scoped blocks, capability discovery, provider PID pinning. |

## Fixed limits

| Limit | Value |
| --- | --- |
| Database attributes | 64 |
| Application value | 512 bytes |
| ATT MTU | 517 |
| Reassembled L2CAP payload | 65 bytes default, up to 1024 |
| Client subscriptions | 8, sharing a 32-packet queue |
| Native ESP32 ingress queue | 8 packets of 1029 bytes, 2 slots reserved from advertising reports |
| Peripheral accept | one session per provider, advertising bounded to 60 seconds |
| Central sessions per provider | 1, or 2 with the mixed provider |
| Pairing attempts | one per owner object |

## Gaps relative to the NimBLE backend

These are needed for parity with `lib/ble` as applications use it today:

- Passkey Entry (SC and legacy) and OOB. A legacy peer that requires MITM protection, or offers only keys shorter than 128 bits, is refused.
- Controller-based privacy (resolving list); today the host resolves RPAs itself and cannot connect to a rotating peer without scanning first.
- Extended advertising PDUs (only legacy PDUs over extended commands are used).
- Unbounded peripheral advertising (a session's wait for a central is bounded at 60 s; the `ble` package backend simply starts the next session).
- More than two concurrent connections in the service layer; the controller supports up to `CONFIG_BTDM_CTRL_BLE_MAX_CONN`.
- Larger databases, included services, Read By Type by UUID and Read Multiple on the client side, Database Hash and Client Supported Features.
- In the `ble` package on this host: `bonded-peers`, and the `--bonding`/`--secure-connections` flags (pairing policy is the provider's).

## Verification state

All 181 software tests run in the ordinary CTest suite on a scripted in-memory
transport. Hardware coverage exists for every feature above on the rig described
in [hardware.md](hardware.md), against BlueZ, Bumble and NimBLE peers, but it is
manual, and the failures in [open-issues.md](open-issues.md) remain.
