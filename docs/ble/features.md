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
| Connections | Bounded live registry (default one link, up to 16), connection parameter update from either role, disconnect with reason, Data Length Extension (a supporting controller gets 251-octet defaults at initialization and each link reports its negotiated lengths). |
| L2CAP | Fixed ATT, signaling and SMP channels; parameter request/response; rejection of other channels. |
| ATT/GATT client | MTU exchange (23 to 517), primary service, characteristic and descriptor discovery, read, read long, write, write long (prepare/execute), write command, up to eight scoped subscriptions with a shared bounded queue, indications with confirmation, Service Changed monitor with a connection-local database revision. |
| ATT/GATT server | Static database of at most 64 attributes, values up to 512 bytes, Service Changed by default, dynamic reads and pre-commit write validation through scoped handlers, prepared writes with atomic execute, notifications (single and batched through one RPC) and single-outstanding indications, user description and extended properties descriptors, per-attribute encryption and authentication requirements. |
| SMP | Secure Connections Just Works and Numeric Comparison in both roles, f4/f5/f6/g2 with AES-CMAC, P-256 through mbedTLS with invalid-point and debug-key rejection, constant-time confirm comparison, identity (IRK) distribution, retry admission policy. |
| Encryption | LE Start Encryption on central links, LTK request replies on peripheral links, encryption change tracking, links that require encryption for their lifetime. |
| Privacy | Host-side RPA generation and resolution, host-selected random addresses for scanning, advertising and connecting. |
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

- LE Read Remote Features after connection (every mainstream host does it; its absence is the likely trigger of the BlueZ resumption failure, see [open issues](open-issues.md)).
- 2M PHY.
- Legacy (non Secure Connections) pairing, Passkey Entry and OOB. The current NimBLE configuration permits legacy pairing by default.
- Controller-based privacy (resolving list); today the host resolves RPAs itself and cannot connect to a rotating peer without scanning first.
- Extended advertising PDUs (only legacy PDUs over extended commands are used).
- Unbounded peripheral advertising and more than one peripheral connection.
- More than two concurrent connections in the service layer; the controller supports up to `CONFIG_BTDM_CTRL_BLE_MAX_CONN`.
- Larger databases, included services, Read By Type by UUID and Read Multiple on the client side, Database Hash and Client Supported Features.
- The existing `ble` package API on top of this host, so current applications and Jaguar run unchanged.

## Verification state

All 181 software tests run in the ordinary CTest suite on a scripted in-memory
transport. Hardware coverage exists for every feature above on the rig described
in [hardware.md](hardware.md), against BlueZ, Bumble and NimBLE peers, but it is
manual, and the failures in [open-issues.md](open-issues.md) remain.
