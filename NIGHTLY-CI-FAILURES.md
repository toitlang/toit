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

### rmt-test — ROOT CAUSE FOUND & FIXED (open-drain mode leaks across channel close)

`rmt-test.toit-esp32s3` Timeout (120s); `rmt-test.toit-esp32` also fails. Now
**fixed** and validated on s3 (3/3 clean runs, ~10s each, was a 120s timeout).

#### Symptom
The full test runs its sub-tests in sequence and hangs in a `wait-for-data`
(an RMT receive that never completes). Which sub-test hangs is timing-sensitive
(any instrumentation shifts it between `test-bidirectional` and `test-loop-count`),
which sent the earlier investigation down a "timing-dependent TX stall" path. That
was a **mis-diagnosis**: the engine is fine, the receiver just never sees a signal.

#### Root cause (confirmed on hardware with a register monitor + an isolated repro)
Open-drain GPIO mode leaks across an RMT channel's lifetime.
- `rmt_new_tx_channel()` enables open-drain via `gpio_ll_od_enable()` (the
  `pad_driver` bit) when a channel is created with `--open-drain`, but nothing ever
  clears it. `gpio_output_disable()` on channel deletion only clears the GPIO
  *output-enable* bit, **not** `pad_driver`.
- `test-bidirectional` uses `pin1`/`pin2` as `--open-drain` (with `pin3` as a shared
  pull-up). After it closes, `pin1`/`pin2` are **left in open-drain mode**.
- The next push-pull user, `test-loop-count` (`out := rmt.Out pin1`, no pull-up),
  therefore can only drive the line **low**; "high" becomes high-Z and floats. A
  pulse counter still sees edges (so the old "TX emits / RX gets nothing" data), but
  the RMT **receiver never sees a clean high level**, never detects the symbol /
  idle, and `in.wait-for-data` blocks forever.

Definitive evidence at the s3 hang (passive per-channel register dump):
`TX0` completed its loop (`loop-end` ISR fired once), but `RX0` was correctly armed
(`rx_en=1`, `mem_owner=HW`, `idle_thres=120`) with its write pointer still at the
memory base — i.e. **zero symbols received**. An isolated probe that merely
pre-conditions `pin1`/`pin2` into open-drain (then closes those channels) and runs
the push-pull loop sequence **reproduces the hang with no other sub-tests involved**.

#### Fix
`third_party/esp-idf/components/esp_driver_rmt/src/rmt_tx.c`, in
`rmt_new_tx_channel()`: establish the configured drive mode explicitly —
`gpio_ll_od_enable()` when `io_od_mode`, else `gpio_ll_od_disable()`. A push-pull
channel now always gets push-pull regardless of the pin's prior history. (Upstream
esp-idf master has the same latent bug; not fixed there. Architecture-independent —
benefits esp32 too, where the same driver/test combination fails.)

**Validated:** clean s3 envelope (`make esp32s3`, no instrumentation),
`rmt-test.toit-esp32s3` **Passed 3/3** (~10s). esp32 envelope still needs a rebuild
+ re-run to confirm the same fix there.

#### Side finding (not a CI failure, not yet fixed)
Our `rmt_encode_simple()` (`rmt_encoder.c`) has the bug fixed upstream by
`e159e69c56 "fix(rmt): fix the state of the simple encoder with mem full"`: when the
simple/custom encoder finishes exactly at a memory-block boundary it sets
`RMT_ENCODING_COMPLETE` but not `RMT_ENCODING_MEM_FULL`, so the caller writes a stray
EOF marker. Our copy encoder already handles the boundary; the simple encoder
(`rmt.Encoder` byte/pattern path) does not. `test-encoder` does not currently hit the
exact boundary, so the test passes — worth backporting regardless.

#### esp32 rmt-test — FIXED (TX idle-level switch glitch)
The esp32 `rmt-test` failed early (`test-simple-pulse`: `Expected <2>, but was <4>`),
returning a spurious leading signal, e.g. `(0:1)(1:50)(0:0)(1:50)` instead of
`(1:50)(0:0)`. Originally mis-read as an RX "records the idle level" behavior.

Real root cause (found with a hardware probe — pre-settling the line to the idle
level makes the leading signal vanish): it is a **TX-side glitch**. `rmt_new_tx_channel`
set the initial idle level high for `io_loop_back` channels, and Toit sets
`io_loop_back` on *every* channel, so every push-pull output idled high. When it then
transmits with `done-level=0`, the driver switches the idle level to 0 immediately
before `tx_start`; on the esp32 a receiver records that idle-level switch as a brief
leading glitch (the esp32s3 does not). A data-driven "strip the leading idle in the
library" approach was tried and **rejected**: the receiver can't know the relevant idle
level (start-level vs done-level differ — it broke esp32s3), and buffer-filling
receptions lose the end-marker outright.

**Fix:** key the high idle level on `io_od_mode` (open-drain) instead of `io_loop_back`,
matching the workaround's own stated intent. Push-pull channels now idle low and don't
glitch; open-drain channels are unchanged. Validated: `rmt-test` passes **3/3 on esp32
and on esp32s3**.
