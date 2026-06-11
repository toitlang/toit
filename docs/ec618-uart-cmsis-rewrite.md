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
