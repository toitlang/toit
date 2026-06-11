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

## Phase 1.5 (2026-06-11): the duplex corruption arc — RX moved to IRQ mode

The phase-1 design's transfer contract was wrong, and underneath it the
SDK's DMA RX engine has a memory-corruption bug. Full story in
known-issues #7; the operative facts:

- **RX_TIMEOUT does not end the armed transfer** — the driver reloads the
  descriptor and keeps filling the same buffer, and may invoke the event
  callback from inside `Receive()`. The callback now tracks a `seen`
  offset, pushes only the `[seen..GetRxCount())` delta on RX_TIMEOUT, and
  re-arms ONLY on RECEIVE_COMPLETE (`CmsisRx.seen`, uart_ec618.cc).
- **`USART_DmaUpdateRxConfig` programs a zero-length `desc[1]`** whenever a
  timeout reload happens with <= `UART_DMA_BURST_SIZE` (4) bytes left in
  the chunk; zero length streams the wire past the buffer and scribbles
  the heap (hardfault in the interpreter / "Unexpected class tag" / exit
  wedges). Sidestepped wholesale: `RTE_UART2_RX_IO_MODE = IRQ_MODE` (our
  RTE_Device.h) — plain bounds-checked FIFO reads, no descriptors.
- `ABORT_RECEIVE` is UNSUPPORTED in bsp_usart.c; the real quiesce is
  `Control(ARM_USART_CONTROL_RX, 0)` (masks+clears RX irqs, clears
  rx_busy). set_baud and teardown now use it; `Control(mode, baud)`
  disables the whole UART while swapping the divisor, so it must never
  run against a live transfer.
- The event callback can run in task context (driver calls it from inside
  `Receive()`): event posting picks `send_event` vs `send_event_from_isr`
  by `__get_IPSR()`.
- All XIC NVIC lines share priority 0x20 (`IC_PowupInit` disassembly):
  the UART and DMA ISRs never nest. The PRIMASK guards added around the
  callback body and set_baud/teardown are cheap insurance, not the fix.
- Diagnosis trail: reopen-per-round duplex repro faulted WITHOUT set-baud
  (killed the set-baud theory); RX-only smooth flood clean; TX-only flood
  wedged only at exit; slot-B fault addresses symbolize via
  `link_addr = PC - __vm_b_start + 0x01000000` against the slot-A elf.

Switching RX_IO_MODE recompiles bsp_usart.c → BASE change → full flash
(also dropped the now-undefined `USART2_DmaRxEvent` from the jump table
via `gen-plat-jt --exclude`, which shifts JT indices — full flash covers
that too).

## Phase 1.6 (2026-06-12): IRQ-mode hardening — the flood battery

Validating the IRQ-mode base surfaced three more layers (details in
known-issues #8): the SDK irq handler's else-if overrun starvation, the
2-byte FIFO headroom of the default 30-byte trigger, and the
empty-FIFO `i = bytes_in_fifo - 1` underflow. Plus one of ours: the
FIRST uart2 open since boot was wire-dead until a close/reopen had
GPR-reset the block once — create now cycles FULL->OFF->FULL (the reset
must run clocked; OFF before any FULL bus-hangs).

Battery state (modest-affair, 2026-06-12):
- uart2-echo: 14/14 (reopen + set-baud, 9600..4M).
- TX flood: 3x256 KiB, helper CRC perfect, clean exits.
- RX flood (starved reader): 99.7% delivered, losses counted, clean exits.
- reopen-duplex flood: clean exits every run; RX limited by the polling-TX
  scheduler hogging (phase-2: DMA TX).
- set-baud duplex flood: ~1 in 3 runs hits a varying-signature VM fatal
  mid-flood (OPEN — see #8); otherwise clean reported failures.

The duplex RX numbers are reader-starvation-bound: the polling Send never
blocks at the Toit level, so the writer task monopolizes the interpreter
and the reader's with-timeout reads expire. DMA TX (RTE change, base) is
the planned fix.
