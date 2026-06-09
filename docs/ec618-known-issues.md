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

**Consequences.**
- Sustained ≥4 MBd RX without flow control is lossy; the `errors` counter
  cannot be used to detect it.
- Any reader stall > ring/baud (e.g. 80 ms at 3 MBd, 290 ms at 921600) does
  not lose *some* data, it loses *everything buffered* — applications must
  treat large RX gaps as total, not partial.

**Fix path.** Implement + wire RTS/CTS flow control (the create primitive
already resolves RTS/CTS pads; needs rig wiring + an exhaustive test), so the
hardware paces the sender instead of dropping. Independently: consider sizing
`RxCacheLen` by baud, and re-test whether the 32 KiB ring is connected to the
requested cache length at all.
