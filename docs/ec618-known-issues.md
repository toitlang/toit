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

## 2. Neither watchdog catches an IDLE application wedge

**Status:** root cause confirmed (code + empirical); fix TODO.

**Symptom.** When issue #1 wedged the agent, NEITHER the user main watchdog nor the
internal AON VM-liveness watchdog reset the device — a manual power-cycle was
required.

**Why the main WDT didn't fire.** It runs off the 32 kHz `FCLK_WDG`. The SDK
registers `WDT_enterLowPowerStatePrepare` as a sleep callback
([wdt.c:124](../third_party/luatos-soc-ec618/PLAT/driver/chip/ec618/ap/src/wdt.c#L124))
that DISABLES `PCLK_WDG`+`FCLK_WDG` for `SLPMAN_SLEEP1_STATE`
([wdt.c:36-44](../third_party/luatos-soc-ec618/PLAT/driver/chip/ec618/ap/src/wdt.c#L36))
— the light sleep entered on *every* tickless idle. So the WDT counter FREEZES
whenever the VM has no work: with no host data the agent blocks in `read-byte`, the
chip idles into SLEEP1, and the WDT stops counting. **Empirically confirmed:** 140 s
of pure idle (no host TX) → the device never reset. The main WDT only fires on a
BUSY hang (CPU active the whole timeout without a feed). It is also fed on *every*
host byte ([mini-jag.toit:166](../tests/hw/esp-tester/mini-jag.toit#L166)) before
the agent decides it can act, so the tester's 3 s pings keep it fed whenever they
reach the agent.

**Why the AON WDT didn't fire.** It is SDK-armed (the API exposes only
`slpManAonWdtFeed`/`slpManAonWdtStop` — no `Start`) and fed once a second from the
scheduler loop (`OS::feed_watchdog`, [os.cc:130-135](../src/os.cc#L130)). The
sleeper container's 1 s timer keeps the scheduler cycling, so the AON WDT stays
fed. It only fires on a TOTAL scheduler stall (a stuck synchronous primitive / GC
deadlock) — not an app-level wedge where the scheduler is healthy.

**The gap.** An idle app wedge (CPU mostly asleep, scheduler healthy) is invisible
to both: the main WDT is frozen by SLEEP1, and the AON WDT is fed by the sleeper.
Both measure raw liveness (bytes arriving / scheduler cycling), not forward
progress.

**Fix direction.** Tie a watchdog feed to forward PROGRESS rather than raw
liveness — e.g. the agent feeds only after completing a command (not on every raw
byte), and/or a progress-gated AON feed — while still surviving legitimate idle.
Resolving issue #1 also removes this specific wedge.
