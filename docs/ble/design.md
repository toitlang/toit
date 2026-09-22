# Design

A BLE host in Toit above the standard Host Controller Interface, keeping the
vendor controller for radio timing, the link layer and link encryption.

## Why

- NimBLE's callback model does not fit Toit's task/monitor paradigm and its host uses a lot of ESP32 memory that cannot be compacted.
- Protocol objects, pending requests, values and packet bytes on the managed heap can be moved by the compacting collector instead of fragmenting native memory.
- Toit code cannot overflow a buffer; the native surface shrinks to a packet transport.
- The same host runs on any controller reachable over HCI, so a Linux dongle, an ESP32 and a future UART/USB controller share one implementation.

## Architecture

```
Toit application
  -> ble.experimental.service.client   (RPC, resource handles, scoped blocks)
  -> provider container: service/*     (admission, request mailbox, policy hooks)
       -> gatt-server / att.Client / scanning / advertising
       -> central.Central              (link owner: connect, accept, encryption, credits, per-link inbox)
       -> hci.Controller               (serialized commands, credits, receive task, reports queue)
       -> Transport                    (complete H4 packets: receive, send, send-if, close)
            -> native: ble_hci_linux.cc (HCI user channel + epoll)
            -> native: ble_hci_esp32.cc (VHCI callbacks + bounded lock-free queue)
```

The transport deals in complete HCI packets including the packet-type byte.
Receive returns one owned byte array; send completes when the transport
accepted the bytes. Neither implies the controller did anything: the HCI layer
separately tracks Command Status, Command Complete and the later event that
completes an asynchronous procedure. `send-if` submits only if a scoped
predicate still holds at the moment of submission, which is how a link that
ended during a credit wait never emits a stale packet.

`hci.Controller` owns the transport and one background receive task. It
serializes commands, honours command credits, and routes: command responses
to the pending latch, advertising reports to a lossy bounded queue, everything
else to a bounded control/ACL queue. `hci.initialize` performs the reset,
identity and buffer-size discovery and sets event masks.

`central.Central` (a link owner for both roles despite its name) claims the
controller's event stream, keeps a registry of live links keyed by HCI handle,
runs connect and accept procedures with cancellation, tracks encryption and
parameter updates per link, and fragments/reassembles ACL. Each `Link` is one
connection lifetime: a reused HCI handle after disconnect is a different
`Link`, so late events and requests cannot act on the wrong connection.

`att.Client` and `gatt-server.Server` each claim one link's PDU stream and run
their own receive task. ATT requests are serialized per link; notifications,
indications and HCI events progress independently.

## Tasks, blocks and cancellation

- Receive tasks validate and dispatch in bounded batches and never call application code inline.
- Callers wait on latches and monitors with explicit pending-operation objects; every pending operation has a deadline and an abort path.
- Application handlers are scoped blocks on the caller's task, never stored callbacks. Across RPC the block stays in the client; the provider sends a request record and the client replies with a token.
- Cancellation cancels the underlying procedure where possible and accounts for late events. When an HCI timeout leaves command ownership uncertain, the controller is failed rather than guessing which response belongs to which command.
- Uncertain completions (an interrupted write, an RPC that may have been applied) are reported, never retried automatically.

The current implementation encodes these rules with `critical-do` blocks and
zero-length sleeps as explicit cancellation points. A simpler contract is
planned; see the review document.

## Memory ownership

GC happens at primitive boundaries, so native code must be retryable without
losing packets or retaining pointers into movable memory:

1. Linux ingress peeks the packet length, allocates the managed array, then consumes. Allocation failure leaves the packet in the socket.
2. ESP32 ingress copies into a preallocated native queue from the VHCI callback under a critical section, signals the event queue, and never allocates Toit objects. The receive primitive allocates before dequeueing.
3. Transmit borrows the managed pointer only for the synchronous native send; VHCI and `send()` both copy before returning.
4. Queues at every stage are bounded. Advertising reports may be dropped with a counter; connection data is never silently dropped, the affected link or controller fails instead.
5. Values retained for the application (notifications, read results) own stable bytes independent of packet buffers.
6. State is published only after all allocations for the change have succeeded, so an allocation failure cannot leave a half-applied write.

RPC copies byte arrays above 128 bytes into external storage; the client
snapshots outgoing arrays so caller buffers are not neutered.

## Credits and flow control

Command credits, controller ACL transmit credits, host receive capacity and
transport readiness are four separate budgets. Transmit credits are a
controller-wide pool with a per-link quota and FIFO waiters; disconnect
releases a link's outstanding packets. Optional controller-to-host flow control
returns Host Number Of Completed Packets only after a packet was consumed or
admitted to another bounded stage.

## Service model

One provider process owns a controller and arbitrates access for application
containers through `system.services`. Connections, subscriptions, scans and
advertising sessions are `ServiceResource`s, released on client close or death.
Providers are subclasses with policy hooks (`open-transport`,
`create-security-owner`, `local-random-address`, `create-cccd-store`, ...);
no key material or controller handle crosses RPC.

Tree shaking works per container: a small provider omits the protocol code it
does not serve, but an application import cannot shrink an installed provider.

## Specification baseline

Core Specification 6.3 with Supplement v15, Assigned Numbers and the GATT
Supplement; see [references.md](references.md). Comments cite volume, part and
section beside the rule they implement.
