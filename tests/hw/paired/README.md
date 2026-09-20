# Paired hardware tests

These tests separate board wiring from peripheral behavior. A trusted **tester**
generates stimuli, measures outputs, validates returned data, and issues the
verdict. The **testee** performs the operation being tested. Internal checks such
as storage integrity still execute on the testee under the tester's deadline.

Construct `Session --is-testee --rx=... --tx=...` on the testee, and use
`--no-is-testee` on the tester. Pass each board's local GPIO numbers to the test
functions. Both boards invoke the same functions in the same order. Call
`session.finish` after all cases, and `session.close` in `finally`. The host
runner uses its ordinary completion markers; it does not interpret measurements.

`../esp32h2` supplies entrypoints for the H2/ESP32 breadboard fixture. Other board
pairs can supply different pins and SPI target DMA capabilities without changing
these tests. The waveform observer needs RMT and a pulse counter; the analog
smoke test in the fixture uses the tester's DAC. Do not infer these capabilities
from the testee architecture inside shared tests.

Install dependencies with `toit pkg install` in `tests/hw`.

| Family | Selected coverage |
| --- | --- |
| PWM | Measured high/low durations at 1/2/10 kHz and 25/50/75%; no edges and correct level at 0/100%; initial endpoints; live changes; independent channels; ownership; parent close/reacquisition. |
| UART | 32769 bytes each way concurrently at 115200/921600, including 7-bit even parity; 32 KiB continuous TX at 115200/921600/2.5 Mbaud; consecutive LED-style writes at 2.5 Mbaud. |
| Pixel strips | Actual UART encoded colors and pulse durations; RMT backend retained as a failure reproducer on H2. |
| GPIO/PCNT | Released open drain against opposing pulls, readback, ownership/reopen, 50 edge waits, known pulse train with and without glitch filtering. |
| SPI | Both roles/four modes; DMA boundary sizes through 4092 bytes; cancellation followed by reuse of the same target. |
| I2C | Both roles, NACK recovery, repeated START, long writes, read-into slice guard bytes; fixture entrypoint adds FIFO boundary regression. |
| RMT | Short measured sequences in both directions, long TX across refill boundaries counted by tester. |
| BLE | Both roles; descriptor discovery/read; repeated 1/20/200-byte write/notification exchanges; adapter reopening. |
| I2S | Both directions and clock roles; Philips16 and selected MSB32 configurations; PCM16 failure reproducers; tester validates received buffers and error counters. |
| Runtime | GC, ordinary and multipage storage, floating-point formatting including allocation paths. |

## Measurement limits

The UART waveform tests temporarily close the control UART and use a separate
wired GPIO for readiness. This supports chips with only one available UART.
The tester reopens its receiver before allowing control framing to resume.

Use a resolution that the observer can generate exactly. PWM capture uses
8 MHz, which divides both the classic ESP32 and H2 RMT source clocks.

The long all-zero 8N1 test uses a pulse-counter filter of approximately three bit
times, capped at 12 us. Normal stop bits are rejected; longer idle-high intervals
are counted. A deliberately paused transmission must produce extra edges before
an uninterrupted burst is accepted. This excludes gaps above the filter threshold,
not arbitrarily short pauses.

The 2.5 Mbaud/7-bit RMT test filters transitions below 1 us and checks 90 known
markers and their high durations (under 3.5 us). Its deliberately paused variant
must fail that waveform predicate. This tests consecutive buffered writes as well
as the single long write used by the counter test.

Full pixel waveforms use seven pixels, fitting the classic ESP32 tester's RMT
memory. They complement the long UART continuity test; they do not establish
long RMT pixel-strip continuity. PWM captures use two tester RMT memory blocks;
the testee briefly stops each measured channel to terminate a capture. A pulse
counter independently verifies frequency and detects endpoint glitches.

Sustained duplex is tested through 921600 baud. An unpaced 2.5 Mbaud duplex
workload overran reception on this fixture; passing the 2.5 Mbaud TX waveform
tests must not be read as a guarantee of lossless duplex at that rate.

I2S retains the existing verifier's allowance of 30 stream errors for the known
IDF issue documented in the original suite. Report the actual mismatch count;
a pass does not imply an error-free stream. UART forwarding limits the chosen
I2S rates. I2C uses 50/100 kHz with the fixture's internal pull-ups.

## Scope

This is a selected regression suite, not a copy of every older test matrix.
External sensor integrations, unavailable radios, deprecated API permutations,
platform-specific EC618 contracts, and very long soak tests are not included.
Advanced target APIs, exhaustive I2S slot configurations, watchdog and firmware
update lifecycle tests remain possible additions. The existing ESP32/S3 suite is
not removed by this change. Its BLE/I2S utility imports forward here so removing
that suite later does not remove dependencies of the paired tests.

## I2S format failure reproducers

On the H2/ESP32 fixture, `i2s.toit --arg msb32` (H2 receive/master) exceeds
30 stream mismatches. `msb32-slave` completed with zero mismatches, while
`msb32-writer` completed with 30, exactly at the existing allowance. The latter
is not evidence of a clean stream and may be marginal across repeated runs.

`pcm16-writer` and `pcm16-writer-slave` fail to synchronize the received samples. These cases retain
normal assertions/deadlines and fail normally; they are not converted into
successful tests or given a larger error allowance. Their presence records
coverage gaps exposed by testing different formats with a mixed-chip pair.

## RMT pixel-strip failure reproducer

`regressions.toit --arg pixels-uart` passes on the H2/ESP32 fixture.
`--arg pixels-rmt` fails its pulse-duration assertions with pixel-strip 1.4.0.
That package requests 20 MHz RMT timing; H2's 32 MHz source is divided to
16 MHz by IDF, stretching the pulses relative to the package's requested
resolution. The normal regression selection runs UART pixels; `--arg pixels`
runs both backends and exposes this failure. No timing tolerance is increased
to accept it. Adapting the pixel-strip package/RMT resolution handling is
separate follow-up work.
