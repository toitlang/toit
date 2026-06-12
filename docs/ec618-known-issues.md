# EC618 known issues (firmware / VM)

Live list of confirmed / under-investigation EC618 firmware+VM bugs found while
building the hardware test suite, each with a reproduction. This is distinct from
[ec618-hw-tests.md](ec618-hw-tests.md), which tracks the tests themselves. Do not
paper these over in test code — the VM/firmware should handle them.

## 1. Closing an ACTIVE UART hangs container teardown → agent wedge

**Status:** root cause identified (high confidence); runtime pinpoint + fix TODO.

**Symptom.** A test container that holds a UART with in-flight TX/RX and then ends
(crash *or* explicit `close`) never finishes tearing down:
`(containers.start ...).wait` in the mini-jag agent
([mini-jag.toit:281](../tests/hw/esp-tester/mini-jag.toit#L281)) never returns, so
`test-running_` stays `true`. The agent keeps reading host pings and feeding the
watchdogs but stays silent forever (it only acks pings when no test is running).
The device looks wedged and needs a manual power-cycle. See issue #2 for why the
watchdogs don't rescue it.

**Root cause.** `UartResourceGroup::on_unregister_resource`
([uart_ec618.cc:95](../src/resources/uart_ec618.cc#L95)) calls the SDK's
`Uart_DeInit(id)` on close/teardown. The code already documents that `Uart_DeInit`
"can block (the OTA-over-UART close-hang)" and the *print* UART works around it by
NOT calling DeInit (lines 85-93); UART1/UART2 still call it. When the UART is
actively transferring, `Uart_DeInit` blocks. `Uart_DeInit` is closed-source (only
declared in `PLAT/core/driver/include/driver_uart.h`; implementation in a
precompiled PLAT lib), so the exact blocking call isn't visible in source. Note
`close` and crash-teardown share this path
([close primitive → unregister_resource, uart_ec618.cc:423](../src/resources/uart_ec618.cc#L423)).

**Reproductions** (run via the mini-jag tester; watch for `run: test exited`):
- Negative — all RECOVER in ~100-170 ms (basic crash path is fine):
  bare `throw`; open idle UART2 + throw; blocked write-task + throw; UART1+UART2 +
  throw.
- Positive — WEDGES: 921600, UART1+UART2, many `task:: test.out.write` while the
  ESP32 echo flows, then throw → dies with `CLOSED`, `.wait` never returns.
- Cleanest positive — explicit close, no crash:

  ```toit
  import ec618 show Ec618
  main:
    port := Ec618.uart2 --baud-rate=921600
    task:: catch: 400.repeat: port.out.write (ByteArray 4096: it & 0xff)
    sleep --ms=20                 // Let TX get going (controller active).
    print "closing while TX active"
    port.close                    // hangs here if the bug is real
    print "closed OK"             // never reached
  ```

**Pinpoint TODO.** Add `printf` around
[uart_ec618.cc:95](../src/resources/uart_ec618.cc#L95)
(`"deinit N begin"` / `"deinit N end"`), OTA a debug build, run the close-active
repro: "begin" without "end" confirms `Uart_DeInit` is the blocking call.

**Fix direction.** Quiesce the controller before `Uart_DeInit`: `Uart_TxStop(id)`
+ stop RX + abort/await pending transfers so DeInit can't block. (Tests must NOT
work around this with `try/finally` — the VM must tear a crashed container down
cleanly.)

## 2. Neither HARDWARE watchdog catches an IDLE application wedge — FIXED with a software watchdog

**Status:** FIXED (2026-06-10, HW-verified). The `ec618.watchdog` API is now a
software watchdog (a dedicated FreeRTOS task in
[primitive_ec618.cc](../src/primitive_ec618.cc)) with the WDT module as a
busy-lockup backstop. Verified on quirky-plenty: an idle, unfed device resets
at exactly the configured timeout (60 s armed → `[toit] FATAL: watchdog
timeout` + reset at +59.8 s, periodic), and a fed device (ping every 2 s)
stays up indefinitely.

**Symptom (historical).** When issue #1 wedged the agent, NEITHER the main WDT
nor the AON watchdog reset the device — a manual power-cycle was required.

**Why the main WDT can't do it (HW-verified).** Its 32 kHz functional clock
(`FCLK_WDG` ← `CLK_32K_GATED`) is gated whenever the chip enters tickless
idle/WFI, so it counts only CPU-ACTIVE time; the clock mux has no always-on
source. (NOT the `WDT_enterLowPowerStatePrepare` SLEEP1 callback — an entry
counter proved normal idle never enters `SLPMAN_SLEEP1_STATE`.) Verified with
the vendor-exact `luat_wdt_setup` sequence: armed 10 s, feeds stopped, 72 s of
idle — no reset. It DOES fire on a busy hang, which is exactly what the
backstop role uses.

**Why the AON watchdog can't do it (HW-verified).** It belongs to the
PLATFORM: the boot ROM arms it (~27 s) and the CP core then auto-feeds it —
its target register (`0x4D020318`) slides forward keeping `target − slowcnt`
pinned at ~20 s with every AP-side feeder provably silent. Disassembly
(`ApmuFeedWtdg`/`ApmuWtdgStop` in `libdriver_private.a`): feed writes
`target = slowcnt + 0xA0000` (20 s) at `0x4D020318`; enable is bit 31 of
`0x4D020320`; the API has no Start and feed preserves a cleared enable bit.
It fires only when no healthy CP runs (the early-bring-up ~27 s reboot loops;
`CONFIG_TOIT_EC618_VM_WATCHDOG=0` stops it at boot for CP-less debugging) and
must be stopped before hibernate, where the CP stops feeding
([toit_ec618.cc](../src/toit_ec618.cc)).

**The fix.** `watchdog-start` spawns a high-priority FreeRTOS task (priority
30, above the Toit task's 20 — independent of the Toit scheduler, so it
survives a wedged VM; its timed waits wake the chip from tickless idle, so the
timeout is wall-clock). It checks the feed deadline and calls
`ec618_system_reset()` when it passes, printing
`[toit] FATAL: watchdog timeout (...) — resetting` first. The task also kicks
the WDT module (10 s of active time, interrupt+reset mode): a lockup hard
enough to starve even this task accumulates active time on the unfed WDT and
gets the hardware reset instead. The old scheduler-fed-AON "VM-liveness guard"
is gone (`OS::feed_watchdog` is a no-op — the CP feeds the AON regardless).

## 3. `Container.wait` throws a spurious `CLOSED` under GC pressure — FIXED

**Status:** FIXED (lib/system/containers.toit), HW-verified 2026-06-10.

**Symptom.** A test container that allocated heavily (uart2-bigdata) finished,
and the mini-jag agent then *died*: its `(containers.start ...).wait` threw
`CLOSED` instead of returning the exit code, the unhandled exception killed the
agent process, watchdog feeds stopped, and the software watchdog reset the
device 60 s later. Decoded trace: `Container.wait` → `throw "CLOSED"` from
`run-installed.<lambda>`. A trivial failing container did NOT reproduce it —
only memory-churning ones did. (Distinct from issue #1: there the agent stays
alive but silent; here the agent process is gone and the watchdog does fire.)

**Root cause (proven with host probes).** A task blocked on a monitor is not a
GC root — it is only reachable through whatever can wake it. The exit-code
notification that wakes `Container.wait` is delivered through
`ServiceResourceProxyManager_`'s **weak** map, so a waited-on `Container` that
is otherwise only referenced from the blocked task's stack forms an
unreachable {container, latch, task} cluster. A GC collects it, the
`ServiceResourceProxy` finalizer closes the proxy, `result_.set null` wakes the
waiter, and `wait` throws `CLOSED`. Host probes: a temporary's finalizer fires
mid-`wait` under forced GC; a strongly-rooted one never does.

**The fix.** `Container.wait` registers the container in a static
`waited-on_` set for the duration of the wait (plus an identity `hash-code`
field, same pattern as `ContainerResource`). Containers with a pending wait
are now strongly rooted, so the notification path stays alive. Defense in
depth: mini-jag wraps the wait in `catch` (reports
`run: test wait failed error=...` instead of dying) and the host tester
recognizes that line and fails fast.

## 4. UART RX silently loses data at high baud; driver ring discards ALL on overflow

**Status:** confirmed + characterized 2026-06-10; fix TODO (flow control).
Regression canary: `tests/hw/ec618/uart2-ring-ec618.toit`.

**Symptoms** (modest-affair, uart2-bigdata, 256 KiB/direction, ESP32 sender):
- RX is clean through 3 MBd (one marginal 8-byte loss seen once at 3 MBd),
  but at 4 MBd every run loses 8–21 bytes mid-stream (`count` short, CRC
  mismatch, `first-bad` mid-stream), with `uart.Port.errors` staying **0**.
- The driver's RX ring is exactly **32 KiB** regardless of the 4 KiB
  `RxCacheLen` we pass to `Uart_BaseInitEx`, and a burst that exceeds it while
  the reader is stalled leaves **zero** readable bytes — the closed-source
  driver throws away the whole buffer on overflow, silently (no
  `UART_CB_ERROR`).
- Reads of ~15 KiB were observed mid-test: the Toit reader can stall ~37 ms
  (GC pause); the ring absorbs that at ≤3 MBd (≤11 KiB) with room to spare,
  so the live 8–21-byte losses are NOT ring overflow — they look like
  hardware RX FIFO overrun during interrupt-latency spikes, which the driver
  does not report. (IRQ priority setup lives in the prebuilt PLAT blob.)

**Worse — overflow WEDGES RX until reopen (confirmed 2026-06-10).** After one
ring overflow, RX on that port delivers NOTHING — including later bursts that
fit comfortably — until the port is closed and reopened (`Uart_BaseInitEx`);
`set-baud` (`Uart_ChangeBR`) does not recover it, and `errors` stays 0 at
921600 (at 3 MBd the error callback fires, but only because the un-drained HW
FIFO then overruns). Probe chain: overflow burst → 0 bytes; next 8 KiB burst →
0 bytes; reopen → 8 KiB clean.

This is what the full-duplex test (`uart2-duplex-ec618.toit`) hits: with the
EC618 sending 256 KiB while receiving 256 KiB, the receiver task falls behind
the 32 KiB ring once (TX writes block the VM in `Uart_TxTaskSafe` ~44 ms per
4 KiB chunk at 921600), the ring overflows, and RX is dead for the rest of the
run — `count=0` in every phase while the ESP32 receives the EC618's full
stream with a perfect CRC. **TX under duplex is flawless; RX dies.** No
lockup: the device survives and reports (the historical "lockup when sending
and receiving at high rates" may well have been this plus the issue-#1 close
hang / issue-#3 agent death on teardown). Duplex of ≤32 KiB with the reads
deferred until after TX works perfectly — RX-during-TX itself is fine at the
driver level.

**Consequences.**
- Sustained ≥4 MBd RX without flow control is lossy; the `errors` counter
  cannot be used to detect it.
- Any reader stall > ring/baud (e.g. 80 ms at 3 MBd, 290 ms at 921600) does
  not just lose data — it silently KILLS RX on that port until reopen.
- Full-duplex above trivial sizes is currently unusable without the fix below.

**Fix path.**
1. First try `Uart_RxBufferClear(id)` as an unwedge (the create path already
   calls it) — if it revives the ring, the driver can detect-and-clear; the
   hard part is detection (no error signal at ≤2 MBd).
2. The real fix: move EC618 UART RX off the closed `Uart_*` core driver onto
   the open CMSIS driver (`bsp_usart.c`) with our own ring — gives us overrun
   accounting, drop-oldest/newest policy, and no wedge.
3. RTS/CTS flow control (the create primitive already resolves RTS/CTS pads;
   needs rig wiring + an exhaustive test) so the hardware paces the sender.
4. Independently: re-test whether the 32 KiB ring tracks the requested
   `RxCacheLen` at all (we pass 4 KiB and get 32 KiB).

## 5. AGPIOWU pads (40..42 / GPIO20..22): GPIO input works, OUTPUT never reaches the wire

**Symptom.** With the AON IO LDO powered (`slpManAONIOPowerOn`), the plain
AGPIO pads (43..48) drive fine as GPIO outputs (PAD44/PAD47 exact-pulse
verified on the rig). The wakeup-capable trio (pads 40..42 = WAKEUP_PAD_3..5,
the board's "AGPIOWU" pins) does NOT: GPIO *reads* follow the wire perfectly
(PAD42 tracked an externally driven rail through 20 s steady-high and
steady-low phases), but a configured GPIO *output* never appears on the wire.

**What was tried (all HW-tested, none unblocked the output).**
- `slpManSetWakeupPadCfg(WAKEUP_PAD_x, false, ...)` — the documented "set pin
  as wakeup pad **or aonio**" release; tried per-pad and for all three at
  once (the WAKEUP_PAD_3..5 <-> pad 40..42 order is unverified).
- The vendor's undocumented AON register write `*(uint32_t*)0x4D020170 = 0x1`
  (from `example_gpio`'s `all_gpio_init_output`, which precedes its AGPIOWU
  output demo).
- Iomux ALT0 + GPIO controller output config — identical to what works on
  pads 43..48.

**Not yet tried.** `slpManAONIOVoltSet(IOVOLT_3_30V)` (the example sets it;
an output at a mis-set voltage could read as low, though pads 43..48 read
fine at the default), the example's `slpManAONIOLatchEn` dance, and the
ordering magic-write-BEFORE-first-LDO-power-on. Revisit with the deep-sleep
work, where the wakeup-pad configuration gets exercised anyway.

**Repro.** `tests/hw/ec618/aon-wu-output-repro-ec618.toit` (standalone;
drives PAD42, whose net is the rig's BMP280 power rail — the sensor coming
up, or the ESP32 reading IO13 high, would mean the output works).

**Driver state.** `gpio_ec618.cc` releases the wakeup function on open and
restores it (wakeup input, pull-up — the boot state) in `pad_release`;
correct per the docs and harmless, but not sufficient for output.

## 6. Blob I2C no-block engine swallows shape-changing transfers — WORKED AROUND

**Symptom.** With consecutive `I2C_MasterXfer` no-block transfers of
DIFFERENT shapes (e.g. a 1-byte register read followed by a 6-byte burst),
the second transfer often never touches the bus: the completion callback
fires instantly and `I2C_WaitResult` reports done/success while the rx
buffer stays unwritten (reads "all 0xFF"). Sometimes the engine instead
double-fires the callback or genuinely runs the transfer into a -13
per-byte timeout. Deterministic for a given op sequence. Surfaced when the
`Ec618.i2c1` factory defaulted the bus to 100 kHz; the same sequences at
400 kHz behaved (not fully explained — same shapes, same code).

**Diagnosis.** Driver-level tracing showed the swallowed transfer never
takes the engine to the busy state (`I2C_WaitResult` stays "complete"
through the whole window) — `I2C_MasterXfer` returns void, so the
rejection is silent. The sensor and wiring were exonerated by replaying
the exact failing sequence from the ESP32 (flawless), and the sync
`I2C_BlockRead/Write` paths are unaffected.

**Workaround (shipped).** `transfer_start` rebuilds the controller for
every transfer: `GPR_swResetModule(I2Cx_RESET_VECTOR)` +
`I2C_MasterSetup(speed)` + `I2C_UsePollingMode(0)`. Microseconds on an
idle bus, and every transfer is the engine's first. (Tried and
insufficient: the reference's error-only GPR reset, per-transfer
`I2C_ChangeBR`, polling-mode reassertion alone.)

**Real fix (future).** Move I2C off the closed blob onto the open CMSIS
driver (`Driver_I2C1`), the same direction as the UART RX rewrite (#4).

## 7. CMSIS UART DMA-RX engine corrupts the heap under flood — AVOIDED (IRQ mode)

**Symptom.** Full-duplex flood on the CMSIS-driven UART2 (256 KiB each way,
≥921600 baud) ends in heap corruption: hardfault inside the interpreter on
a garbage address whose bytes look like RX stream data, or a VM fatal
("Unexpected class tag"), or — when the scribble lands somewhere quieter —
a container-exit wedge. One-direction traffic with a keeping-up reader is
clean; corruption tracks bursty/starved RX (many mid-transfer rx-timeouts).

**Root cause (two layers, both in `bsp_usart.c`).**

1. *Protocol misunderstanding (ours, fixed in `uart_ec618.cc`):*
   `ARM_USART_EVENT_RX_TIMEOUT` does NOT terminate the armed `Receive()` on
   this driver. The timeout IRQ path reloads the DMA descriptor and keeps
   streaming into the SAME buffer — and the driver can fire the callback
   from *inside* `Receive()` itself. Our phase-1 callback re-armed
   `Receive()` on every event, re-entering the driver's DMA state machine
   against a live transfer. Fixed: track a `seen` offset, push only the
   delta on RX_TIMEOUT, re-arm only on RECEIVE_COMPLETE.

2. *Zero-length DMA descriptor (the SDK's):* `USART_DmaUpdateRxConfig`
   unconditionally splits every (re)load into a 4-byte `desc[0]`
   (`UART_DMA_BURST_SIZE`) plus a remainder `desc[1]`. The rx-timeout IRQ
   calls it with `left_to_recv`; when a timeout catches the transfer with
   <= 4 bytes left in the user buffer, `desc[1]` is programmed with length
   ZERO — and a zero-length descriptor streams the wire PAST the buffer,
   scribbling everything after the receive chunk on the C heap. With a
   512-byte chunk that is a ~0.8% chance per mid-transfer timeout;
   duplex-with-starved-reader produces hundreds of such timeouts per round,
   so corruption was near-certain. (Same hazard exists in `USART_Receive`'s
   own RECV_COMPLETE path, which loads a zero-length `desc[0]` — not
   reachable with our 512-byte chunks.)

**Resolution (shipped).** `RTE_UART2_RX_IO_MODE = IRQ_MODE` (our
`RTE_Device.h`): UART2 RX uses the driver's IRQ paths — plain
bounds-checked FIFO->buffer copies, no descriptor engine, no DMA aimed at
heap memory, teardown trivially safe. Cost: one IRQ per ~30 RX bytes
(FIFO trigger level), and the 32-deep hardware FIFO replaces the DMA
catch buffer between transfers — overruns at multi-MBd are counted in
`errors` and RX survives. The DMA engine should not be re-enabled for RX
until `USART_DmaUpdateRxConfig` is fixed (e.g. chain `desc[0]` straight to
`desc[2]` when `num <= UART_DMA_BURST_SIZE`) — that means patching the
submodule, so it is documented here instead.

**Note.** `IC_PowupInit` programs the SAME NVIC priority (0x20) for all
XIC lines: the UART and DMA handlers never preempt each other, so ISR
nesting is NOT among the failure modes (verified by disassembly).

## 8. IRQ-mode UART RX: overrun starvation + empty-FIFO underflow in the SDK handler — MITIGATED

Found while validating the IRQ-mode switch from #7 with full-duplex floods.

**Starvation.** The USART irq handler is an else-if chain that checks
LINE_STATUS *before* RX data. Once one hardware overrun latches, every
ISR services the (re-asserting) overrun branch — which drains NOTHING —
and the data branches are starved until the line idles: RX collapses to
one 32-byte harvest per quiet gap while errors climb at irq rate. The
initial overrun is easy to hit because the IRQ-mode default FIFO trigger
(30 of 32) leaves 2 bytes (22 us at 921600) of headroom — less than one
COMPLETE-event ring copy.

**Underflow.** The RX_DATA_REQ branch computes `i = bytes_in_fifo - 1`
with no zero guard: with an empty FIFO it underflows and the handler
reads RBR hundreds of times off the empty FIFO (observed as a hard wedge
that only the WDT busy-backstop clears). An empty FIFO with DATA_REQ
pending is reachable: the rx-timeout branch drains the FIFO completely
while a DATA_REQ is already latched.

**Mitigations (uart_ec618.cc, all slot-side).**
- RX FIFO trigger poked to 16 at open (headroom 16 bytes / ~170 us; the
  clean RTE override is a base change, pending the next full flash).
- The ring push is two memcpys, not a byte loop (the COMPLETE-event copy
  must fit the FIFO headroom).
- The event callback self-heals overruns: on RX_OVERFLOW it pushes the
  chunk delta, then drains the FIFO **down to one byte** into the ring
  (order-preserving; one byte left both stops the overrun from
  re-asserting and keeps the SDK's underflow loop unreachable from our
  drain — the SDK's own timeout-drain can still expose it).
- All task-context driver entries (create-arm, set-baud, teardown) run
  under PRIMASK: Receive() enables RX irqs mid-call and can invoke the
  callback from task context — concurrent callbacks race the ring head
  and a bogus head turns the push memcpy into a wild write.

**Result.** Echo 14/14 (both modes, 9600..4M); TX flood 3x256 KiB with
perfect helper-side CRC; RX flood 99.7% delivered with a deliberately
starved reader, losses counted, clean exits.

**Residual — RESOLVED (2026-06-12).** The remaining ~1-in-3 VM fatal
under set-baud duplex floods was OURS and had nothing to do with the
UART driver: the `read` primitive drained the whole ring into
`ObjectHeap::allocate_internal_byte_array(available)` — but internal
byte arrays must fit one VM heap page (`max_allocation_size()` =
TOIT_PAGE_SIZE - 96, ~4 KB) and the limit is enforced by an ASSERT that
release builds compile out. Any drain > ~4 KB (8 KiB ring, 32 KiB with
--large-buffers) wrote received STREAM BYTES across the following heap
pages — random victims, varying fatal signatures ("Unexpected class
tag" / guard-zone "stack overflow detected" / "unreachable"), and silent
wedges when the scribble landed quietly. Caught by dumping the corrupted
header at FATAL time: 0xf7d8b99a = four consecutive bytes of the test's
gen-byte stream (deltas of 31). Only a reader that SURVIVES the flood
ever drains > 4 KB in one read — which is why the reopen-per-round twin
(whose reader starved out at 2 s and stopped reading) never fataled,
masquerading as a set-baud bug for a whole debugging arc. Fix:
`Process::allocate_byte_array()`, which switches to an external (malloc)
byte array above the internal limit. 5/5 clean runs on the previously
~60%-fatal reproducer.

Lesson for primitive authors: never call
`object_heap()->allocate_internal_byte_array()` with an unbounded size —
use `process->allocate_byte_array()` (same null-on-failure contract).

## 9. UART0 bulk RX collapses after a set-baud — RESOLVED (DMA RX + descriptor patch)

Found while migrating the agent's UART0 from the blob to the CMSIS driver.

**Symptom.** On the uniform CMSIS driver, the test agent on UART0 works
completely at 115200 (handshake, installs, full 480 KB firmware OTAs). After
a CMD-BAUD hop (set-baud power-cycle) to ANY higher rate, small messages
still round-trip fine — but the first multi-KB burst into UART0 RX is
swallowed: at 921600/460800 essentially nothing reaches the reader
(rx-errs=2..4 counted, agent blocks); at 230400 one 2 KB chunk survives,
then the same stall. The same bursts into UART1/UART2 deliver (uart1-echo,
uart2 floods), and the blob-era UART0 did 921600 bulk for days.

**Diagnosis trail (rescue-channel register autopsy + dual-channel watch).**
- The divisor is NOT the problem: a peek32 watch sampling DLL through a
  kill shows div=14 -> 1 at the hop and STAYS at the fast rate through and
  after the swallowed burst. (An earlier div=14 autopsy was a post-reset
  red herring.)
- IER stays 0x15 (all RX irqs armed), ADCR=0 (no autobaud), MFCR sane.
- The burst produces 2-4 RX_OVERFLOW/error events and then silence: the
  overrun starvation of #8 eats the burst, and the storm can END with
  bytes stranded in the hardware FIFO and no interrupt edge left to
  deliver them (DATA_REQ appears edge-triggered at the threshold and the
  idle-timeout was consumed during the storm).
- An RX FIFO trigger of 1 is NOT a fix: the RX_DATA_REQ handler then
  drains the FIFO completely, so the idle-timeout (which needs a byte
  waiting) never fires for short messages — single-byte pings land in the
  driver buffer with no completion event. Deaf agent; OTA trial rolled
  back twice proving it.
- Mitigations shipped (help but insufficient): the read primitive rescues
  FIFO-stranded bytes whenever the reader looks, and ERROR events now also
  wake blocked readers so the rescue is reachable.

**State.** The rig runs with --fast-baud 115200 (tester default): fully
functional, OTA ~61 s instead of ~24 s. The agent serves a RESCUE listener
on UART2 (via the ESP32 TCP bridge + socat PTY, see
tests/hw/esp-tester/uart-bridge-esp32.toit) when no host contact arrives
on UART0 — built during this hunt and proven end-to-end.

**Wire-tap findings (ESP32 IO18 on the RX net, tap-uart-esp32.toit).**
The wire is BYTE-PERFECT: a failing 2053-byte burst at 921600 reaches the
EC618's pad with the exact expected CRC and zero tap-side errors — the
loss is entirely inside the chip. Sharper still: the same 2048-byte bulk
as a CMD-ARG (no flash activity, ~300 ms gap after the previous exchange)
now PASSES at 921600 on the shipped mitigations, and an install chunk
sent 300 ms after ACK-READY passes too — but a chunk arriving within
~150 ms of the agent's own ack/flash-write still dies (150 ms pacing got
exactly one chunk through). So the failure needs a burst landing in a
>150 ms "hot window" after the agent's own TX + flash work. Host-side
chunk pacing is NOT an acceptable workaround (300 ms x N chunks is slower
than just running at 115200).

**Root cause + resolution (2026-06-12).** The ">150 ms hot window" was
XIP flash stalls: the IRQ-mode RX handlers live in flash and are dead for
the entire duration of every ContainerImageWriter erase/write — exactly
when install/OTA bursts arrive. The closed blob never failed because its
RX was DMA-based: the DMA hardware (and the driver's PLAT_PA_RAMCODE
paths) capture right through the stalls. Fixed by patching the
zero-length-descriptor bug (#7) directly in the submodule fork's
bsp_usart.c (USART_DmaUpdateRxConfig chains desc[0] -> desc[2] when the
remainder is zero; num==0 mirrors the catcher descriptor) and switching
UART0 RX to DMA mode. Result: agent installs and full firmware OTAs at
921600 with rx-errs=0 (~24 s OTA, back to blob parity). UART1/UART2 RX
stay in IRQ mode until DMA RX is validated for them (a fresh-boot UART2
DMA open still wedged on its first bulk burst in one trial — debug with
the rescue toolkit before flipping kRxIsDma).

Two rig bugs found while validating (both fixed): create() must not
Uninitialize a never-initialized driver (closing never-opened DMA
channels wedges the next open — now tracked per controller), and the
UART2 rescue listener now RELEASES the controller the moment the primary
channel hears the host (it used to hold UART2 after any watchdog reset
followed by a routine silence window, failing every uart2 test with
ALREADY_IN_USE).
