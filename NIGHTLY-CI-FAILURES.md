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

**Next concrete step:** instrument the esp-idf RMT *tx* path (transaction queue
state / `rmt_disable` of an in-flight infinite-loop transmit) to confirm the
stuck transaction, then either patch esp-idf or change `out.reset` to fully
flush/recreate the tx channel after a loop transmit. Pragmatic alternative still
available: split `rmt-test` into per-sub-test processes (each passes in isolation).
NOTE: the committed `toolchains/esp32s3/sdkconfig` is stale vs current esp-idf
(`CONFIG_SOC_RMT_SUPPORT_TX_ASYNC_STOP` → `..._SUPPORT_ASYNC_STOP` regenerates on
build); worth ruling in/out.

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
