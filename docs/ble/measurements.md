# Measurements against NimBLE

Same board (original ESP32, revision 1.0, 08:3a:f2:23:4d:aa), same controller
firmware, same central (Edimax dongle with the Toit host on Linux), measured
on 2026-09-23 with `tests/ble-hardware/bench/` and `build/ble-bench-001/run.sh`.
The peripheral advertises one service with one notifying 20-byte
characteristic; the central connects, requests a 15 ms interval, subscribes,
counts notifications for five seconds, disconnects, and repeats. Memory is
`system.process-stats` after a forced GC: system free heap, largest free
block, and the process's own allocated bytes.

| Peripheral | Notifications/s | Free while advertising | Largest block | Process allocated |
| --- | --- | --- | --- | --- |
| NimBLE host, `ble` package, one container | 755–775 | 105.5 KB | 98 KB | 1.5 KB |
| Toit host, direct (one container owns the controller) | 375–460 | 109.4 KB | 102 KB, 90 KB after 5 cycles | 6–9 KB |
| Toit host, provider + application containers, one RPC per notification | 160 | 95.4 KB (115 KB with the BR/EDR memory released, see below) | 82 KB, 78 KB after 10 cycles (86 KB released) | provider 12–15 KB (20 KB reserved), app 2 KB |
| Toit host, provider + application containers, `notify-values` in batches of 32 | 376 | same | same | same |

With 244-byte notifications at ATT MTU 247 and Data Length Extension (both
stacks negotiate 251-octet link-layer PDUs with the same dongle):

| Peripheral | Notifications/s | Bytes/s |
| --- | --- | --- |
| NimBLE host, `ble` package | 264–268 | 65 KB/s |
| Toit host, direct | 330–332 | 81 KB/s |
| Toit host, provider model, one RPC per notification | 157–159 | 39 KB/s |
| Toit host, provider model, `notify-values` in batches of 32 | 310 | 76 KB/s |
| Toit host, direct, on ESP32-S3 Board1 with the LE 2M PHY (`BENCH_BOARD=s3 run.sh direct`) | 584–590 | 143 KB/s |

The S3 row is the same central and payload with the 2M PHY negotiated
(`phy=2/2` in the central's log; the original ESP32 has no 2M PHY) and the
S3's faster core: 1.6 ms of interpreter time per notification, a fifth of
the calls under 1 ms.

Free heap at boot before any BLE code: 142–149 KB. All three recover their
idle figure after every disconnect; over forty connect/notify/disconnect
cycles (`run.sh toit 40`, `run.sh direct 40`, with the BR/EDR memory
released) free heap after disconnect stays at 141.2 KB in the provider model
and 120.2 KB in the direct variant to the byte, and the largest free block
(86 KB and 110.6 KB) does not move after the first cycle.

## Reading the numbers

- **Memory.** The Toit host itself costs no more system memory than NimBLE:
  the direct variant has 4 KB more free heap while advertising than the
  NimBLE variant, because the NimBLE host's tasks and pools leave the free
  heap while the Toit host's state lives in the (compactable) process heap.
  The provider model costs about 14 KB on top: a second process (8 KB
  reserved at start, 20 KB reserved while connected) and the RPC buffers.
  The controller-only transport now calls
  `esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT)` before initializing
  the controller on the original ESP32, which returns the unused BR/EDR
  memory: free heap while advertising rose from 95–100 KB to 115 KB and
  while connected from 91 KB to 106 KB in the provider model, so the
  provider model now has about 10 KB more free heap than the NimBLE build
  and the direct variant about 24 KB more. The NimBLE backend does not make
  the call; the same one-line change is proposed for it separately.
- **Throughput.** Per notification the Toit host spends a flat 1.9–2.1 ms of
  interpreter time on the ESP32 (no call under 1 ms, so it is CPU bound, not
  credit bound); the same path costs 23 µs on the Linux host. NimBLE, native,
  keeps the controller busier. One RPC round trip costs 2.5 ms on the board,
  which is why the provider model manages one notification per 6 ms: the
  application waits for the provider to submit each notification before the
  next call.

## Consequences

1. The notify path is the place to optimise in the host: every call arms a
   timer for its send bound, copies the value three times (ATT PDU, L2CAP
   PDU, ACL packet), and pays a credit-account round trip through two
   monitors. The fast path for the common case (credit available, single
   fragment) is in place; deeper changes (a pre-framed send buffer, fewer
   monitor transitions) remain possible.
2. Per-notification RPC is a floor of about 2.5 ms per call on the ESP32
   whatever the host does, so the service API has `Session.notify-values`,
   one round trip for up to 32 values; with it the provider model reaches the
   direct host's rate.
3. With large values the picture inverts: at 244 bytes the Toit host moves
   more bytes than NimBLE (81 against 65 KB/s direct, 76 KB/s batched through
   the provider). The per-notification interpreter cost is then a smaller
   share, and the NimBLE backend's own per-write overhead (mbuf allocation,
   the `ble` package's value copy and RPC-free but task-switching path)
   dominates instead. Data Length Extension is on in both.
4. A 2× gap on 20-byte notifications is the expected price of an interpreted
   host; it is within "some performance loss is acceptable". The credit fast
   path and single-fragment framing (23 to 17 µs per notification on Linux)
   moved the board from 2.0 to about 1.8 ms per notification; the rest is
   spread over monitors, timers and allocations with no single hot spot.

## Provider in the system container (2026-09-30)

Same benchmark, five cycles, on the firmware with the provider built into
the system container (`system/extensions/esp32/ble.toit`, `run.sh system`)
against a separate provider container on a firmware without the built-in
one (`run.sh toit`). The built-in provider adds 157 KB to the system image
(172 KB to 329 KB); a separate provider container is 323 KB. Both together
with an application no longer fit the 1.7 MB firmware partition.

| Provider | Free while advertising | Free while connected | Free after disconnect | RPC round trip | Notifications/s, single | Notifications/s, batched |
| --- | --- | --- | --- | --- | --- | --- |
| System container | 120.1 KB | 115.5 KB | 150.4 KB | 2.65 ms | 157 | 320 |
| Separate container | 114.9 KB | 106.1 KB | 141.1 KB | 2.50 ms | 153 | 264 |

The system container is the better place: 5 to 9 KB more free heap, about
180 KB less flash, and batched notifications 20% faster, with one process
fewer competing for the CPU.

