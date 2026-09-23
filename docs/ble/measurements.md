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
| Toit host, provider + application containers | 160 | 95.4 KB | 82 KB, 78 KB after 10 cycles | provider 12–15 KB (20 KB reserved), app 2 KB |

Free heap at boot before any BLE code: 142–149 KB. All three recover their
idle figure after every disconnect (no growth over ten cycles); the largest
free block shrinks once after the first cycle and then stays.

## Reading the numbers

- **Memory.** The Toit host itself costs no more system memory than NimBLE:
  the direct variant has 4 KB more free heap while advertising than the
  NimBLE variant, because the NimBLE host's tasks and pools leave the free
  heap while the Toit host's state lives in the (compactable) process heap.
  The provider model costs about 14 KB on top: a second process (8 KB
  reserved at start, 20 KB reserved while connected) and the RPC buffers.
  `esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT)` is not called by
  either build and would return the BR/EDR controller memory on the original
  ESP32 in both.
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
   monitors. A fast path for the common case (credit available, single
   fragment) is planned before any deeper change.
2. The service API needs a batched notification call so one RPC carries many
   values; per-notification RPC is a floor of about 2.5 ms per call on the
   ESP32 whatever the host does.
3. Data Length Extension is the other half of throughput for large values; it
   is a protocol-parity item, not a host cost.
4. A 2× gap on 20-byte notifications is the expected price of an interpreted
   host; it is within "some performance loss is acceptable". The provider
   model's 5× is not, and is addressed by 2.
