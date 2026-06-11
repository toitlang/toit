# EC618 UART RX rewrite: blob `Uart_*` → open CMSIS driver (design)

Status: DESIGN (2026-06-11). Fixes known-issues **#4** (32 KiB closed RX
ring, silent discard-ALL on overflow, RX dead until reopen) and very
likely **#1** (close of an active UART hangs in `Uart_DeInit`). Same
direction planned for I2C (#6, currently worked around with a
per-transfer `GPR_swResetModule`).

## Facts (scouted)

- The CMSIS driver is OPEN SOURCE in the SDK:
  `PLAT/driver/chip/ec618/ap/src_cmsis/bsp_usart.c` (~2.2k lines),
  exposing `Driver_USART0/1/2` (`ARM_DRIVER_USART`). We already link the
  access structs (they are in the JT DATA-SYMBOLS exclusion — never
  veneered; the VM binds to the fixed-PLAT structs directly, slot-safe).
- RX modes per controller come from our `toolchains/ec618/project/inc/
  RTE_Device.h`: UART0 RX currently `IRQ_MODE`, UART1 RX `DMA_MODE`,
  UART2 RX `DMA_MODE`. TX: UART0 `UNILOG_MODE` (!), UART1 `DMA_MODE`,
  UART2 `POLLING_MODE`.
- Events: `ARM_USART_EVENT_RECEIVE_COMPLETE`, `_RX_TIMEOUT` (idle line),
  `_RX_OVERFLOW`, `_TX_COMPLETE`/`_SEND_COMPLETE` via the `cb_event`
  installed at `Initialize`. RX_TIMEOUT handling visible at
  bsp_usart.c:1289-1355.
- The current driver (`src/resources/uart_ec618.cc`, 559 lines) uses the
  closed `Uart_BaseInitEx`/`Uart_TxTaskSafe`/`Uart_RxBufferClear` blob
  API; its `uart_cb` already maps blob events onto
  `Ec618EventSource` (`UART_KIND_RX/TX_DONE/ERROR`).

## Design

1. **Own the RX ring.** Per-uart ring lives in the existing `uart_states`
   (NO new file statics — OTA shared-dram contract; grow the existing
   struct only if the layout discipline allows, else heap-allocate at
   open and hang it off the resource). Size from the Toit-side
   `large-buffers` flag (e.g. 4/16 KiB).
2. **RX flow:** `Driver_USARTx->Receive(chunk, n)` re-armed from the
   event callback. On `RECEIVE_COMPLETE`/`RX_TIMEOUT`: copy received
   count (`GetRxCount`) into our ring, re-arm, post `UART_KIND_RX`. On
   ring-full: drop NEWEST (or oldest — pick and document), count it in
   `errors`, post `UART_KIND_ERROR` — overflow must be VISIBLE and
   NON-FATAL (vs the blob's silent discard-all + dead port).
3. **TX stays on the blob initially** (`Uart_TxTaskSafe` works and the
   RS485/flush semantics are HW-proven). Mixing stacks on one controller
   is the risk item: verify TX-via-blob + RX-via-CMSIS coexist (they
   program the same registers; the blob's init may fight
   `Initialize`/`PowerControl`). If they fight, move TX too (CMSIS
   `Send`, keep the synchronous-drain RS485 path).
4. **The print/console UART (UART0)**: PLAT's log + our adopted console
   currently flow through the blob init. First migrate UART2 (the
   data/test lane) ONLY; leave UART0/1 on the blob until UART2 is
   green under `uart2-bigdata`/`-ring`/`-duplex` (the #4 repros), then
   decide whether UART0/1 follow.
5. **Close path:** `Control(ARM_USART_ABORT_RECEIVE)` + `PowerControl
   (ARM_POWER_OFF)` + `Uninitialize` from a NON-active state — expected
   to fix #1's `Uart_DeInit` hang; verify with the close-hang repro in
   docs/ec618-known-issues.md #1.
6. **Validation:** uart2-echo (all bauds), uart2-bigdata (expect 4 MBd
   RX to stop losing bytes or at least COUNT losses), uart2-ring
   (overflow now visible + recoverable), uart2-duplex (expect PASS),
   uart2-config matrix, RS485, flush. Each is an existing checked-in
   test.

## Constraints / gotchas

- JT: `Driver_USART*` structs must stay excluded from veneering; any NEW
  PLAT functions reached (e.g. `GetRxCount` is via the struct — no new
  JT entries needed in theory; verify the link).
- OTA layout: no new VM file statics. RTE_Device.h changes (e.g. UART2
  RX ring/DMA descriptors) change the BASE → full flash.
- The event callback runs at IRQ level: ring copy must be bounded;
  `send_event_from_isr` only.
- DMA RX (RTE UART2) + idle-line timeout is the throughput path the
  4 MBd loss investigation needs (descriptor-chained DMA absorbs IRQ
  latency spikes that the blob's single buffer cannot).

## Implementation map (from uart_ec618.cc, scouted 2026-06-11)

Blob surfaces to replace for RX (UART2 first):
- open: `Uart_BaseInitEx(id, baud, tx_cache, rx_cache, ...)` +
  `Uart_RxBufferClear(id)` (uart_ec618.cc:416-425) — for the CMSIS path,
  `Driver_USART2->Initialize(cb)/PowerControl(FULL)/Control(baud,framing)`
  + first `Receive()` arm.
- read primitive: `Uart_RxBufferRead(id, buf, n)` peek+drain
  (uart_ec618.cc:503-512) — becomes a drain of OUR ring.
- uart_cb RX cases (`UART_CB_RX_NEW/_TIMEOUT/_BUFFER_FULL`) — become the
  CMSIS `cb_event` (`RECEIVE_COMPLETE`/`RX_TIMEOUT`/`RX_OVERFLOW`)
  copying `GetRxCount()` bytes into the ring and re-arming `Receive()`.
- close path + set_baud: today via blob; CMSIS `Control(ABORT_RECEIVE)`,
  `ARM_USART_MODE_ASYNCHRONOUS` re-Control for baud.
- `wait_tx` TEMT polling stays (TX remains on the blob in phase 1).

**Base-change alert:** the per-uart RX context (ring pointer, head/tail,
dropped-byte counter, armed-chunk bookkeeping) extends `uart_states[3]`
— a shared-dram file static — so the first CMSIS build is a FULL FLASH
(fingerprint will show the .data shift). Bundle any other pending base
work with it.

Phase plan:
1. `CONFIG`-free branch: in create, `if (id == 2) cmsis_rx_open(...)`,
   read/close/set-baud dispatch on a per-state `cmsis_rx` flag.
2. Validate with uart2-echo (all bauds), then the #4 repros
   (bigdata/ring/duplex — expect duplex to go green, overflow to become
   counted + recoverable).
3. Decide UART0/1 migration + TX migration afterwards.

## Lesson (2026-06-11): Driver_* struct bindings pin the base

The slot binds `Driver_USART2` (and would any CMSIS access struct) by
ABSOLUTE base address. That is only valid while the FLASHED base ==
the BUILT base — the jump table tolerates base drift, direct data
bindings do not. First OTA of the CMSIS UART2 code hardfaulted
(INVSTATE, jump into rotted struct address) because the running base
predated the cmpctmalloc move. Consequence: any build that adds/changes
a Driver_* binding, or any base drift after one exists, requires a FULL
FLASH. The planned frozen-base artifact removes this class entirely.
