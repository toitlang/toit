# Nightly CI failure tracking

Tracking the failures in the scheduled nightly CI (`.github/workflows/ci.yml`,
`cron: '00 2 * * *'`, job runs with `DO_MORE_TESTS` / `DO_HW_TESTS`).

Branch for fixes: `floitsch/ci-failures`.

Last master commit at time of investigation: `3109e1d3` (2026-06-13). No code
changes landed between 2026-06-13 and 2026-06-18, which is an important datum
for separating code regressions from environmental/hardware issues.

---

## 1. Windows bot — `tests/tls-system-cert.toit`  [DIAGNOSED — not our code]

**How/when it failed on CI**
- Nightly `build (windows-latest, 5)` failed 2026-06-17 and 2026-06-18.
- 2026-06-13/14/15/16 nightlies **passed** on Windows. Same SDK code (no commits
  since 06-13).
- Failure is **not** a TLS error. It is a **TCP connect timeout** (`tcp-connect_`,
  WSAETIMEDOUT) while connecting to one of the 11 real websites the test probes
  to verify the Windows system root certs. 8 sites connect fine (amazon.com,
  adafruit.com, dkhostmaster.dk, dmi.dk, pravda.ru, elpriser.nu, coinbase.com,
  helsinki.fi); one of the remaining 3 (`lund.se`, `web.whatsapp.com`,
  `digimedia.com`) times out at the TCP layer.

**Reproduce?**
- No. The test is Windows-only (`if system.platform != "Windows": return`) and
  all 3 candidate sites are reachable from the dev machine. The block is specific
  to the GitHub Windows runner egress.

**Root cause**
- External: a third-party website became unreachable from GitHub's Windows
  runners around 06-17. Identical SDK code passed before and fails after → not a
  Toit/ESP-IDF regression. The TCP connect fails *before* any TLS/cert code runs.

**Action taken**
- Commit `ee61f744`: print the culprit host in the failing branch. The test
  computed `*** Incorrectly failed to connect to $host ***` but never printed it
  (the underlying exception propagated and crashed the test first), so the CI log
  never revealed which site failed. Now the next Windows run names the site.

**Next step / how to make it fixable**
- Re-run the Windows build (next nightly, or a dispatch) to read the printed host.
- Then decide: drop/replace that site, or make the test tolerate a single
  TCP-unreachable site (without masking real cert failures). NOT yet done —
  needs the culprit identified first.

---

## 2. Serial (hardware) job — esp32 / esp32s3

The `serial` job runs `make test-hw` on the self-hosted runner. The step is
mislabeled "Test Raspberry Pi" but runs the whole hw suite (esp32, esp32s3, pi).

### 2a. esp32 (all "Not Run") — board-move cascade, NOT a real failure
- On some nightlies (e.g. 06-14, 06-18) `setup-board1-esp32` / `setup-board2-esp32`
  **Timeout** at 80s, and every esp32 test (tests 9-60) is then "Not Run"
  (FIXTURES_SETUP failed → dependents skipped).
- Cause: the esp32 boards were moved to the local machine, so the CI runner can't
  reach them. This is expected. Need to confirm esp32 tests pass locally.

### 2b. esp32s3 — genuine failures (consistent across 6 nightlies, 06-13..06-18)

| Test | CI result | Notes |
|------|-----------|-------|
| `rmt-test.toit-esp32s3`            | Timeout 120s | 6/6 |
| `espnow2-board1.toit-esp32s3`      | Failed       | 6/6 |
| `spi-board1.toit-esp32s3`          | Failed (ASSERTION) | 6/6 |
| `uart-big-data-board1.toit-esp32s3`| Failed       | 6/6 |
| `uart-io-data-board1.toit-esp32s3` | Failed/Timeout | 6/6 |
| `uart-small-data-board1.toit-esp32s3`| Timeout    | 6/6 |
| `i2s-board1.toit-esp32s3-pcm8`     | Timeout      | 6/6 — i2s known-broken |
| `i2s-board1.toit-esp32s3-msb8-slave`| Failed      | 6/6 — i2s known-broken |

Occasional/flaky: `uart-baud-rate` (3/6), `run-time` (2/6), `adc` (1/6),
`i2s ...pcm32-inmonoleft` (1/6).

#### Common thread for spi + uart-*-data
- esp32s3 inter-board wiring: UART link on **GPIO4 (pin1)** and **GPIO5 (pin2)**;
  SPI on 21/17/47/38.
- `spi-board1` fails at `SlaveRemote.sync` → `wait-for-ok_` — i.e. **before any
  SPI**, reading the UART handshake byte `0xAA` from board2 and getting `0x00`.
- `uart-big-data` / `uart-io-data` are board2→board1 over GPIO4 only (rx-only).
- `uart-small-data` reads board2→board1 over GPIO4 first.
- => Every consistently-failing data test depends on **board2 transmitting UART
  to board1 over GPIO4**.
- `uart-flush2-board1` / `wait-for1-board1` exercise GPIO4 board2→board1 as a GPIO
  *level* (idle-high), not UART. Their pass/fail isolates wire vs UART-decode.

**Reproduce locally?** Yes — harness set up (`/tmp/hwenv.sh`), both esp32s3 boards
flash fine. (User: only the USB hub was moved Pi→dev machine; the boards/breadboards
are untouched, so the wiring is identical to the nightly runs.)

#### ROOT CAUSE — found & fixed: missing UART RX pull-up

Direct experiments (a minimal board2-sends / board1-receives pair) showed:
- The UART link physically works: board1 receives the exact byte pattern board2
  sends, **but with a spurious leading `0x00`**.
- The `0x00` only appears when board1 opens its RX **before** board2's TX is up.
  If board1 opens its RX after board2's TX has settled idle-high → clean data.
- Setting board1's RX pin `--input --pull-up` before opening the UART → the
  `0x00` disappears.

Mechanism: the current esp-idf's `uart_set_pin` no longer enables an internal
pull-up on the UART RX pin (older esp-idf did `GPIO_PULLUP_ONLY`). With no pull-up
the RX line floats while the peer isn't driving, dips below the logic threshold,
and the receiver reads a false start bit → `0x00`. That corrupts the first byte
of every board2→board1 transfer:
- `spi sync` reads `0x00` instead of `0xAA` ("Expected 170, but was 0").
- `uart-*-data` read a shifted/garbage length → wait forever → timeout.
- `espnow2` waits on a board2→board1 UART `ok` that is corrupted.

This is architecture-independent (reproduced the `0x00` on both esp32 GPIO22 and
esp32s3 GPIO4). esp32 happened to pass on the (slower) Pi CI host by timing luck;
locally esp32 `uart-small-data` also times out. Not a code regression in our repo
(no master commits May 24–Jun 7); triggered by the esp-idf behavior.

**Fix (committed):** `src/resources/uart_esp32.cc` — after `uart_set_pin`, call
`gpio_set_pull_mode(rx, GPIO_PULLUP_ONLY)` when `rx != -1`. Restores the idle-high
RX line. Benefits every Toit UART user, not just these tests. (Could also be
reported upstream to esp-idf.)

**Validated** with a rebuilt esp32s3 envelope (`make esp32s3`):
- `uart-big-data-board1`  esp32s3: **PASS** (was Failed)
- `uart-io-data-board1`   esp32s3: **PASS** (was Failed/Timeout)
- `uart-small-data-board1`esp32s3: **PASS** (was Timeout)
- `spi-board1` now gets **past the UART sync** (see next item).

#### spi-board1 — second issue: INTERMITTENT (not a deterministic bug)
With the UART sync fixed, `spi-board1.toit-esp32s3` reaches the SPI transfers in
`shared/spi.toit`. First seen failing (validation run): the loopback transfer
("hello" via the MOSI↔MISO 5k resistor) read `#[0,0,0,0,0]`. But it is **flaky**,
not deterministic:

What works (proven):
- board1-only GPIO coupling test (drive GPIO47, read GPIO38 via 5k): correct.
- board1-only SPI loopback **sweep 500 Hz → 4 MHz: all read back correctly.**
- SPI MISO sampling works: drive the line high from board2 → master reads 0xFF.
- RMT capture of the MISO line during a transfer shows it follows MOSI cleanly.
- Full real test, instrumented to print every sub-transfer, **passed all 4
  cpol/cpha modes**: loopback="hello", miso=0→`0x00`, miso=1→`0xFF`.
- A clean ctest run of the real `spi-board1` **passed**.

Ruled out as the trigger: SPI frequency (incl. the test's 500), board2 holding the
shared pins as input, and a UART being open on board1 at the same time. So the
peripheral, driver, wiring and pins are all fine; when the transfer happens it is
bit-correct. The failure is an **intermittent** wrong read (all-zero) — a
flakiness/timing issue, not a logic bug.

Flakiness rate measured after the fix: **6 passes / 1 fail**. The single failure
was the very first `spi-board1` run right after the USB hub was moved to the dev
machine + the envelope rebuild (boards freshly power-cycled). 6 consecutive
fresh-flash runs afterward all passed (loopback, miso=0, miso=1, all 4 modes).

**Conclusion:** `spi-board1` is effectively resolved by the UART RX pull-up fix
(it was failing at the UART sync). The one observed `0x00` data read was a
power-up transient, not reproducible. No SPI code change needed. (If it recurs on
CI we have the diagnostics to bisect the first-transfer-after-power-up path.)

### i2s — DONE (skip the broken S3 variants)
Confirmed locally on the s3:
- `i2s-board1.toit-esp32s3-philips16` (the generic/typical one): **Pass** — kept.
- `i2s-board1.toit-esp32s3-pcm8`: Timeout — added to `fail.cmake` skip list.
- `i2s-board1.toit-esp32s3-msb8-slave`: Failed — added to `fail.cmake` skip list.
Same esp-idf I2S issue (#15275) as the already-skipped variants.
`pcm32-inmonoleft` only failed 1/6 on CI (flaky) — left enabled, watch it.

### rmt-test — INVESTIGATED, root cause narrowed (NOT yet fixed)
`rmt-test.toit-esp32s3` Timeout (120s); `rmt-test.toit-esp32` also fails (~15s) —
broken on **both** architectures, single-board.

Where it hangs (s3): instrumented the `test` driver; it runs the sub-tests in
sequence and hangs in **`test-bidirectional`** at `in2.wait-for-data` (the RMT
rx-done event never fires). The earlier `test-resource` channel-alloc errors
("no free rx channels") are the **expected** `ALREADY_IN_USE` throws the test
asserts on — not the problem.

Bisected with hardware experiments:
- `test-bidirectional` **in isolation**: passes (`GOT 144 signals`).
- `[test-resource, bidir]`: pass.   `[carrier, glitch-filter, bidir]`: pass.
- `[simple, multiple, long, carrier, glitch, bidir]` (5 middle sub-tests): **HANGS**.
- Simple in/out pulse channel churn (40×, shared pins): clean — no channel leak.
- `test-bidirectional`'s own pattern churned 30×: clean — no self-leak.
- (Gotcha: a `gpio.Pin` created per-iteration and not closed throws
  `ALREADY_IN_USE` on the pin — a test-writing trap, not the bug. The real test
  creates pin1/pin2 once and reuses them.)

**Conclusion:** it is a *cumulative* state issue — only the combination/variety of
the RMT sub-tests' configs (carrier, glitch-filter, open-drain, varying
memory-blocks) leaves residual state that makes a later rx channel's done-event
never fire. Not a Toit channel/pin leak (the close path is synchronous and churn
is clean). Most likely an esp-idf RMT driver / interrupt / event-source state
issue accumulated across many register/unregister cycles with different configs.

#### esp-idf RMT instrumentation result (esp_rom_printf in rx_done/tx_done/arm/transmit)
Built an instrumented s3 envelope and ran the full failing test. Findings:

- **The hang is a timing race (Heisenbug).** With the printf delays added, the
  hang *moved*: `test-bidirectional` now *completes* (`RMT RDONE n=72`) and the
  hang lands one sub-test later, in **`test-loop-count`**. So the bug is
  timing-sensitive, not a fixed location.
- At the hang, the trace shows an armed rx (`RXARM err=0`) **and** a tx
  (`TXSTART err=0`) where *neither* `rx_done` nor `tx_done` ever fires (the
  printf is before the queue-send, so the ISRs genuinely never run — not a
  dropped event). I.e. **the tx starts (`rmt_transmit` returns OK) but never
  completes, so the dependent rx never receives a signal and never completes →
  `wait-for-data` blocks forever.** Same shape for both hang locations: a tx that
  silently fails to deliver hangs the rx that waits on it.
- `test-loop-count` is the clearest case: it does an **infinite** transmit
  (`TXSTART loop=-1`), then `out.reset` (which is `rmt_disable` + `rmt_enable`),
  then `TXSTART loop=4`. For a `loop=-1` transmit `tx_done` never fires; aborting
  it via disable/enable appears to leave the esp-idf tx transaction-queue
  (`trans_queue_depth=1`) in a stuck state, so the following `loop=4` transmit is
  accepted but never runs (no `tx_done`) and the rx waiting on it hangs.

**Conclusion:** a timing-dependent esp-idf RMT **tx-completion** stuck state after
the cumulative mixed tx/rx/loop/reset sequence — not a Toit channel/pin leak and
not a lost rx interrupt per se. Likely an esp-idf RMT driver bug (the tx engine /
transaction queue after an aborted infinite-loop transmit, and under load).

#### Deep investigation results (esp-idf patch history + pulse-counter probing)

1. **Dropped local patch lead (ruled out for s3).** The esp-idf submodule bump
   `08e41458` once carried a Toit-local patch `d1e7c39b "Add workaround for
   spurious RMT-RX events" (#106)` that applied the `fsm != RMT_FSM_RUN` check
   **unconditionally**. The 5.4.2 roll dropped it; `ef015d0e` (May 23) re-added the
   *official* esp-idf fix `ac781c7064` (issue #15948) which guards that check with
   `#if !SOC_RMT_SUPPORT_ASYNC_STOP` → **skipped on esp32s3**. Re-applying it
   unconditionally for s3 was tested on hardware: **does NOT fix the hang.**
   Confirms the esp-idf maintainer's note that #15948 is ESP32-only.

2. **It is a cumulative + timing-dependent race, not the disable/enable rx bug.**
   - `test-bidirectional` and `test-loop-count` both **pass in isolation** and in
     short subsequences; only the full cumulative run hangs.
   - **Ultra timing-sensitive:** even ~10ns `volatile` counters (not just printf)
     make `test-bidirectional` pass, and the hang then moves to `test-loop-count`.
     So it can't be instrumented in the hot path without hiding it (Heisenbug).
   - **The tx is fine.** Pulse-counter probing (non-perturbing) confirmed:
     `out.reset` cleanly stops an infinite (`loop=-1`) transmit, and a subsequent
     `loop=4` transmit produces the expected pulses. The hang is the **rx**
     (`wait-for-data`) not completing (hardware idle never detected / event never
     delivered) **after the cumulative sequence** of varied sub-tests.

**Conclusion:** a cumulative, timing-sensitive RMT rx race that only appears after
many varied RMT operations (carrier, glitch-filter, open-drain, loop) run in one
process on shared pins. Not a Toit channel/pin leak (churn is clean), not the
spurious-rx disable/enable bug, not the tx. Likely esp-idf RMT-driver / event /
interrupt cumulative state; un-instrumentable in the hot path.

#### TWO-BOARD WITNESS + tracker (latest, supersedes everything below)

Used board2 as an independent witness: board1 runs the real rmt-test (reliably
hangs) plus a concurrent task that transmits a probe on GPIO5 (a board-connection
pin wired to board2); board2 counts pulses on GPIO5.

Result: while the main test is hung, **all 116 probe transmits complete ("ok") and
board2 keeps counting pulses** — i.e. the RMT engine is **NOT** stalled engine-wide;
plain transmits keep working. So the hang is **a specific transmit configuration
that stalls**, not a dead peripheral. (board2's count "freezing" earlier was just
its 80s monitor loop ending, not the signal stopping — corrected.)

Combined with the passive register watchdog (loop-count hang): `tx_start=21
tx_done=19` (one real transmit — the `loop=4` after `loop=-1`+`out.reset` — never
fires tx_done), `rx_arm=13 rx_hwdone=12` (the rx just waits for that transmit's
signal), `int_raw=0`, clock fine.

**Honest conclusion:** it is a **TX problem** — a specific RMT transmit stalls (no
`tx_done`, no output) after the cumulative sub-test state; the receive that depends
on it then hangs. It is config-specific (loop-TX after reset in `test-loop-count`;
the dual independent open-drain TX in `test-bidirectional`), **not** engine-wide,
**not** memory corruption, **not** layout/IRAM/ISR-log/clock. Reached via the
ping-pong RX path (disabling ping-pong avoids it).

Tracker: clusters with known, partly-unresolved esp-idf RMT **TX** bugs on the S3 —
- #10429 ESP32-S3 RMT silently fails: a complementary TX channel stops with large
  data (closed "Won't Do") — closest symptom, but uses the sync-manager.
- #13003 ESP32-S3 consecutive RMT transmissions; #17692 rmt_transmit+rmt_disable.
Not an exact match → likely a new variant worth reporting to Espressif with our
repro + the `tx_start>tx_done`, `int_raw=0`, "probe still works" evidence.

**Remaining precision (1 rebuild):** dump the per-channel TX conf/FSM at the hang to
see whether `rmt_transmit` fails to set the TX-start bit (driver) or the HW ignores
it (peripheral state). Then patch esp-idf and/or report upstream. Interim to get CI
green: skip the ping-pong/loop-dependent sub-tests with a tracker reference.

---
(Older notes below — partly superseded; kept for the investigation trail.)

#### CORRECTION + precise root cause (register-level debug)

Earlier "memory corruption (#13419)" was an over-claim — disabling ping-pong only
proves the ping-pong RX path is *involved*, not that it corrupts memory. Ruled out
by experiment: code/IRAM-layout (an unused IRAM fn changed nothing),
`CONFIG_RMT_ISR_IRAM_SAFE=y` (no change), the RX-ISR `ESP_DRAM_LOGE` (LOGE→LOGD, no
change), and the RMT clock (sys_conf is normal at the hang). The ping-pong handlers
are byte-identical to esp-idf master (only LOGE→LOGD differs) → not fixed upstream
in that path either.

Instrumented the esp-idf RX ISRs (threshold/hw-done counters) + the transmit/
tx-done paths + the RMT interrupt & clock registers, dumped by a watchdog task
(sleeps, so no hot-path perturbation — validated by the layout-shift test). At the
hang the counters are **frozen**:
```
tx_start=21 tx_done=19      <- TWO transmits never complete
rx_arm=13   rx_hwdone=12     <- one rx armed, never completes
int_raw=0  int_ena=0x1011000 (rx-ch0 DONE/ERR/THRES enabled)  sys_conf=normal
```
- The rx is innocent: armed, all its interrupts enabled, **but `int_raw=0`** — the
  RX idle-done only fires *after* a pulse, so it is simply waiting for a signal
  that never arrives.
- The real stall is the **TX engine**: a transmit is issued (`rmt_transmit` returns
  OK, `tx_start` increments) but the hardware never runs it (`tx_done` never fires,
  `int_raw=0`, clock fine). In `test-loop-count` the stuck one is the `loop=4`
  transmit that follows a `loop=-1` (infinite) + `out.reset` (disable/enable); in
  `test-bidirectional` (the no-instrumentation hang) it's the open-drain write.

**Precise root cause:** after the cumulative RMT activity, a subsequent **RMT
transmit silently stalls** — `rmt_transmit` accepts it but the HW TX engine never
starts/completes (no `tx_done`, no interrupt). The dependent receive then waits
forever. Triggered via the ping-pong RX path (disabling ping-pong avoids it). It's
an esp-idf new-driver (`esp_driver_rmt`) bug; the TX-after-abort / cumulative state
isn't handled. Next: dump the per-channel TX conf/FSM to see whether `rmt_transmit`
fails to set the TX-start bit (driver) vs. the HW engine ignoring it (state), then
patch esp-idf and/or report upstream with this repro.

(superseded heading kept below for history)
#### ROOT CAUSE CONFIRMED: esp-idf RMT RX ping-pong memory corruption (#13419)

It is **not** a timing race — it is **memory corruption** in the esp-idf RMT RX
ping-pong path. Key insight (Florian): a single `volatile` counter can't flip a
*reproducible* failure via timing, but it CAN if the failure is memory corruption
whose overwrite target moves with the **binary layout** ("code shifting"). That
matches everything: deterministic-per-binary, "any code change moves the hang
between sub-tests", cumulative (corruption accumulates / heap state), and
un-instrumentable.

Matches esp-idf issue **#13419 "RMT in RX Mode causes memory corruption with
ESP32-S3 (SOC_RMT_SUPPORT_RX_PINGPONG)"** — new driver (`esp_driver_rmt`, which is
what Toit uses via `rmt_new_rx_channel`/`rmt_receive`; NOT the legacy
`rmt_legacy.c`). Still **open upstream, no fix**. S3-only (ESP32 has no ping-pong
→ the ESP32 rmt-test fails with a different, non-hang symptom).

Hardware-confirmed on our envelope (esp-idf v5.4.2):
- **Disable `SOC_RMT_SUPPORT_RX_PINGPONG` on s3 → the 120s hang DISAPPEARS** (test
  now Fails fast instead, because large receptions truncate / a follow-on Toit
  "potential dead-lock" — so a blanket disable is too blunt, but it pinpoints the
  ping-pong path as the cause).
- **`CONFIG_RMT_ISR_IRAM_SAFE=y` (ISR in IRAM + buffer forced internal) → still
  hangs.** So it is not ISR-latency / PSRAM-buffer; it is a genuine code bug in
  the ping-pong copy (`rmt_isr_handle_rx_threshold` / `rmt_isr_handle_rx_done`).

**Fix options (decision needed):**
1. Patch the esp-idf RMT ping-pong copy bug in `rmt_rx.c` and upstream it
   (it is Espressif's unfixed bug; needs careful analysis of the threshold/done
   copy + memowner race). Best long-term; we can patch our esp-idf fork.
2. Avoid ping-pong for the affected receives (size rx buffers / reduce reception
   length so the RX never relies on ping-pong) — narrower, test-side.
3. Skip the ping-pong-dependent sub-tests (bidirectional, long-sequence, etc.)
   with a reference to #13419 until upstream fixes it (like the i2s skips).
Report #13419 status to Espressif with our repro either way.

NOTE: the committed `toolchains/esp32s3/sdkconfig` is stale vs current esp-idf
(`CONFIG_SOC_RMT_SUPPORT_TX_ASYNC_STOP` → `..._SUPPORT_ASYNC_STOP` regenerates on
build) — a side effect of the #15948 patch's cap rename; harmless but worth a
refresh.

#### Build note (resolved)
`make esp32s3` works once the pyenv 3.8.18 venv is bypassed (this shell had it
active via VIRTUAL_ENV; the build dir is configured for system python 3.14):
`env -u VIRTUAL_ENV PATH=<path without .pyenv/versions> make esp32s3`.

#### Build note (resolved)
`make esp32s3` works once the pyenv 3.8.18 venv is bypassed (this shell had it
active via `VIRTUAL_ENV`; the build dir is configured for system python 3.14):
`env -u VIRTUAL_ENV PATH=<path without .pyenv/versions> make esp32s3`.
- `espnow2-board1.toit-esp32s3` — wireless. In a combined run it hung/timed out
  with no output (its UART `ok` handshake is fixed by the pull-up, but the
  ESP-NOW exchange is unverified). Needs a separate retest.
- Rebuild the **esp32** envelope (`make esp32`) — shares the UART fix; only the
  s3 envelope has been rebuilt/validated so far.

#### Build-env note
On a fresh shell `make esp32s3` fails: `export.sh` activates the py3.8 IDF env
(system python is 3.8) but `build/esp32s3` was configured with the py3.14 env, so
idf.py refuses without a `fullclean`. Worked around by invoking idf.py with the
py3.14 python directly (recompiles `uart_esp32.cc` + relinks — equivalent result).
