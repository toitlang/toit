# Nightly serial hardware failures, July 21–August 5, 2026

## Summary

The serial job had three different failure regimes in this period. They should
not be treated as one collection of flaky hardware tests:

1. On July 21–23 and August 2–5, all four setup fixtures failed because the
   serial devices did not exist. The dependent test results are `Not Run`, not
   test failures.
2. On July 24–26, the rig was present but physically unhealthy. Many wired
   ESP32-S3 tests failed assertions and, importantly, many tests really did
   start and then run until CTest timed them out. The dominant example is the
   entire S3 I2S matrix. This is consistent with bad wiring, power, or a missing
   common ground, but the timeouts are real and need better in-test deadlines.
3. On July 27–August 1, 30 of 31 CTest timeouts happened before the test
   container was launched. They are failures in the serial mini-jag control
   protocol, mostly while waiting for one board to be recognized as ready. The
   remaining timeout, `ble3-board1.toit-esp32` on July 30, is a genuine
   intermittent BLE test hang after the test had run 49 iterations.

The most effective greening work is therefore to put bounded, retryable phases
around serial startup and container transfer, and bounded operations inside
long-running hardware tests. A rig preflight would also turn bad setup nights
into one clear, early failure instead of dozens of misleading test names.

## Scope

The previous hardware-test repair exercise ended with
`df1538603` (`Recover from ESP tester UART data loss`, July 20), following the
serial-control changes in `43a8f4641` and `958f176ac`. I reviewed every
scheduled serial job from the next nightly, July 21, through August 5. Hardware
test changes landed again on August 3, but those runs have no test results
because the rig was already disconnected.

The CTest failure counts below include fixture failures and their dependent
`Not Run` tests. They are useful for locating a run, but not for counting broken
test cases.

| Date | Serial result | Interpretation |
| --- | ---: | --- |
| [Jul 21](https://github.com/toitlang/toit/actions/runs/29803297398) | 122 / 126 | Four ports absent; tests not run |
| [Jul 22](https://github.com/toitlang/toit/actions/runs/29893030835) | 122 / 126 | Four ports absent; tests not run |
| [Jul 23](https://github.com/toitlang/toit/actions/runs/29981717715) | 122 / 126 | Four ports absent; tests not run |
| [Jul 24](https://github.com/toitlang/toit/actions/runs/30068790496) | 36 / 126 | Connected, rig-wide wired-test failures |
| [Jul 25](https://github.com/toitlang/toit/actions/runs/30144894932) | 40 / 126 | Connected, same rig-wide pattern |
| [Jul 26](https://github.com/toitlang/toit/actions/runs/30189287561) | 36 / 126 | Connected, same rig-wide pattern |
| [Jul 27](https://github.com/toitlang/toit/actions/runs/30240406470) | 7 / 126 | Six serial startup timeouts; ultrasound setup failure |
| [Jul 28](https://github.com/toitlang/toit/actions/runs/30330087114) | 4 / 126 | Two serial startup timeouts; ultrasound and Wi-Fi assertions |
| [Jul 29](https://github.com/toitlang/toit/actions/runs/30424376108) | 5 / 126 | Five serial startup timeouts |
| [Jul 30](https://github.com/toitlang/toit/actions/runs/30514876313) | 6 / 126 | Five serial startup timeouts; one real BLE3 hang |
| [Jul 31](https://github.com/toitlang/toit/actions/runs/30606804885) | 8 / 126 | Eight serial startup timeouts |
| [Aug 1](https://github.com/toitlang/toit/actions/runs/30685594481) | 4 / 126 | Four serial startup timeouts |
| [Aug 2](https://github.com/toitlang/toit/actions/runs/30733877682) | 122 / 126 | Four ports absent; tests not run |
| [Aug 3](https://github.com/toitlang/toit/actions/runs/30787464846) | 130 / 134 | Four ports absent; tests not run |
| [Aug 4](https://github.com/toitlang/toit/actions/runs/30879042483) | 130 / 134 | Four ports absent; tests not run |
| [Aug 5](https://github.com/toitlang/toit/actions/runs/30976572412) | 130 / 134 | Four ports absent; tests not run |

## Findings

### Disconnected-rig runs

On July 21–23 and August 2–5, every setup fixture failed with `cannot open
port '/dev/ttyEsp32...'`. All actual hardware tests were then skipped because
their fixtures failed. There is no evidence about the tests themselves in
these runs.

This currently costs about a minute and produces 122 or 130 entries under
"tests failed", even though only four setup operations were attempted. A
pre-CTest port and identity check would make this a short, explicit "rig
disconnected" result. The job should remain unsuccessful unless it was put
into an explicit maintenance mode; silently making an unexpectedly absent rig
green would hide a real infrastructure problem.

### July 24–26: real test-body timeouts on an unhealthy rig

Across these three nights CTest reported 78 timeouts. Log phase inspection
separates them into approximately 55 tests that had launched their containers
and then stopped making progress, and 23 serial startup/peer-readiness stalls.
The launched timeouts must not be dismissed as harness noise.

The strongest signal is the ESP32-S3 side:

- `gpio-test`, `pulse-counter-test`, `pwm-test`, `spi-keep-active-test`, and
  `uart-io-data-test` failed assertions on all three nights.
- Nearly the complete S3 I2S matrix entered the test and then reached the CTest
  timeout on all three nights. The `pcm16-outmonoright` variant instead failed
  an assertion.
- Board-to-board SPI, UART, pin-hold, wait-for, and ultrasound tests also
  failed or timed out.

The pattern is stable for three nights and disappears on July 27 without a
corresponding hardware-test change that could repair GPIO, I2S, SPI, and UART
together. That makes bad rig wiring, power, or ground the most likely common
cause. It does not make the behavior acceptable: an I2S or peer operation
waiting on a missing signal should terminate with a phase-specific deadline
and a message such as "no clocks observed" rather than consume the generic
CTest timeout.

### July 27–August 1: the serial controller usually did not launch the named test

There were 31 CTest timeouts in the six otherwise usable runs. For 30 of them,
the log never reached `Running test on device` for all required boards:

- In six cases the required mini-jag ready state was never recognized.
- In 24 two-board cases one board became ready or was installed while the
  other board never satisfied the host's ready latch. In a few logs the raw
  `MINI-JAG LISTENING` text is visible for the missing peer, but its framing did
  not match what the host parser requires.
- None of these 30 printed `UART TRANSFER ERROR`, so the retry added in
  `df1538603` did not apply. The process simply waited until CTest's 120- or
  360-second timeout killed it.

The affected names range across ADC, RMT, BLE, sensor, I2S, ESP-NOW, UART, and
pin-hold tests. That distribution and the absence of test-container output are
evidence for a control-path problem, not independent failures in those APIs.

The fragile points are visible in the harness:

- mini-jag acknowledges at 115200 baud, waits 10 ms, switches to 921600, and
  emits a one-shot `MINI-JAG LISTENING` marker;
- the host waits 5 ms before switching its USB-UART adapter;
- the host only accepts the ready marker when it is preceded by a newline;
- `ready-latch.get`, chunk permits, container installation, and test-completion
  latches have no local deadline;
- only an explicit device-side UART FIFO error triggers a transfer retry.

#### Local reproduction on August 6

Using the alpha.196 nightly firmware and compiler on the connected rig, a
repeated `rmt-test.toit-esp32` run passed twice in about six seconds and then
timed out on the third repetition after 120 seconds. The third attempt did not
run RMT code. It completed baud setup, announced that the device was ready,
started container installation, received two `READY FOR CHUNK` requests, and
then made no further progress. It did not report `UART TRANSFER ERROR`.

This reproduces a silent serial-protocol stall on the current machine and also
shows that the vulnerable area is wider than the ready handshake: container
transfer needs its own deadline and recovery protocol.

### `ble3-board1.toit-esp32`: a genuine intermittent test hang

The July 30 BLE3 timeout is different from the other timeouts in that period.
Both boards were installed and launched. Board 1 deployed 48 services; board 2
repeatedly connected, discovered 50 services, and closed the connection. It
completed iteration 48, printed `closed`, and never printed iteration 49. CTest
killed the process at 360 seconds. The ESP32-S3 variant passed that night.

The test source already documents intermittent NimBLE disconnect/recovery
problems and performs 100 iterations. It is marked flaky, but the retry is only
entered when an attempt throws. A hung first attempt never returns to the
runner, so the outer CTest timeout prevents the advertised retry from helping.

A focused local run on August 6 completed all 100 ESP32 iterations in 110.42
seconds. That rules out a deterministic failure while preserving the nightly
evidence of a real intermittent hang.

The test should put deadlines around connect, service discovery, close, and
the pause between iterations, with the iteration and phase included in any
error. It should also guarantee remote-device and adapter cleanup on failure.
A whole-attempt budget slightly above the observed 110-second normal runtime
would then allow the flaky retry to run; the CTest timeout must be large enough
for the chosen number of attempts.

### Ultrasound: likely physical setup

`ultrasound-board1.toit-esp32s3` failed quickly on July 27 and 28 because board
2's pulse measurement returned null. This is an assertion failure, not a CTest
timeout, and is consistent with a bad transducer or rig connection. Fix the
physical setup first. The test could additionally print which echo edge or
measurement was missing so the next failure is self-diagnosing.

### Wi-Fi: the rig-local soft AP was not found

`wifi1-board1.toit-esp32s3` failed only on July 28. This test does not depend on
the runner's configured external access point for the failing phase. Board 2
successfully established a soft AP; board 1 then failed the assertion that the
new SSID was visible on its configured channel. All three whole-test attempts
failed at that same assertion, before the opposite-channel check, connection,
or TCP exchange.

The test allows four scans with 300 ms waits, but prints neither the requested
SSID/channel nor the APs it actually observed. A focused run on August 6 passed
in 41.34 seconds. This looks intermittent, but it tests meaningful scan and
channel-filter behavior. Improve it by logging the requested configuration and
observed `(SSID, channel, RSSI)` set, and consider an explicit AP beacon-settle
period or a longer targeted scan retry before repeating the entire two-board
test.

## Recommended changes, in order

1. **Add phase deadlines and diagnostics to `esp-tester`.** Bound device-ready,
   container header, each chunk request, container commit, run-start, and
   test-completion waits. On expiry, report the board, baud, last protocol
   marker, bytes sent, and current phase. This turns generic 120/360-second
   CTest deaths into actionable failures.
2. **Retry silent pre-test transport failures once.** Reset and reopen the
   affected board for ready-handshake and container-transfer deadlines, not
   only for an explicit `UART TRANSFER ERROR`. Do not retry a test after its
   container has started unless that test is explicitly marked flaky.
3. **Make baud synchronization an exchange at the new rate.** After switching,
   have the host request a sync response (with a bounded retry) instead of
   depending on a single unsolicited marker. At minimum, increase the 5/10 ms
   scheduling margin and recognize the complete unique marker without
   requiring a preceding newline.
4. **Make container transfer recoverable.** Add chunk sequence/offset data and
   acknowledgements so a lost request or lost data can be identified and
   resent. Until then, consider one outstanding chunk instead of two as a
   reliability experiment; it will trade some installation speed for less
   ambiguity on a transport with no flow control.
5. **Add a rig-health preflight.** Before compiling/flashing the suite, verify
   that all four stable device paths open and identify the expected chips.
   Then run a short GPIO/ground/peer-link sentinel, plus one representative S3
   I2S clock/data check. Abort the suite with one "rig unhealthy" result if the
   sentinel fails.
6. **Put deadlines inside hardware operations.** In particular, make I2S,
   wait-for, pulse, and BLE phases fail with their expected signal/state and
   elapsed time. This addresses the real July 24–26 and BLE3 hangs rather than
   reclassifying them as harmless.
7. **Improve wireless failure evidence.** Keep the ultrasound and Wi-Fi tests,
   but log the physical measurement phase and Wi-Fi scan contents. Add only
   narrowly scoped settling/retry behavior; do not blanket-ignore their
   failures.

With items 1–4, most July 27–August 1 failures should either recover or fail in
seconds with a serial phase named. Items 5–7 make the remaining failures
represent the rig or the hardware API being exercised, rather than the outer
CTest watchdog.
