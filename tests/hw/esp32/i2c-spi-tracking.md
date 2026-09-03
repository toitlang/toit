# I2C and SPI hardware-test tracking

This document tracks the remaining verification work for the asynchronous I2C
and SPI controller/target stack. A box is checked only after the test has run on
the hardware named in the entry with the current code and ESP-IDF submodule.

## Completion criteria

- All relevant sources build for ESP32 and ESP32-S3.
- The complete I2C/SPI CTest selection passes twice on each variant: once after
  flashing the firmware and once without rebooting the boards.
- SPI CS setup and hold behavior is checked with an independent RMT probe.
- Expected bounded-queue overflow is distinguished from driver data loss.
- Controller operations, target waits, and abort/close paths do not block a
  Toit primitive.
- Retryable allocation failures leave no native resources behind and do not
  report OOM asynchronously.
- Recoverable electrical faults and transaction aborts leave the peripheral
  reusable.

## Work items

### 1. Clean baseline

- [x] Build the host SDK.
- [x] Build the ESP32 firmware envelope.
- [x] Build the ESP32-S3 firmware envelope.
- [x] Run `git diff --check` and analyze the changed Toit tests.
- [x] Run all I2C/SPI tests once on ESP32.
- [x] Run all I2C/SPI tests once on ESP32-S3.

### 2. SPI CS timing

- [x] Capture CS and SCLK independently with RMT at 100 kHz.
- [x] Verify that each transfer contains exactly 32 valid SCLK pulses.
- [x] Verify every setup-cycle value from 0 through 16 on ESP32-S3.
- [x] Verify every hold-cycle value from 0 through 16 on ESP32-S3.
- [x] Verify every setup-cycle value from 0 through 16 on classic ESP32 after marking
  single-data-line controller devices as half-duplex.
- [x] Fix classic ESP32 hold-cycle programming and verify every representable
  value from 0 through 15. Reject 16 in the Toit API because the hardware field
  is only four bits wide.
- [x] Compare the relevant SPI LL implementation with recent ESP-IDF master.
  Master has the same incomplete programming and documents 0 through 16 even
  though its ESP32-specific test limits the maximum to 15.
- [x] Make the timing test assert every supported value on both variants.

### 3. Allocation-failure behavior

- [x] Inventory every allocation in the new I2C and SPI primitives and classify
  it as synchronous/retryable or callback/ISR-time.
- [x] Exercise retryable OOM cleanup using deterministic allocation-failure
  injection where the runtime supports it.
- [x] Verify that retrying target initialization does not leak pins,
  peripherals, event resources, DMA memory, or ESP-IDF handles.
- [x] Verify that retrying controller construction and transfer setup does not leak buses, devices,
  event resources, DMA memory, or ESP-IDF handles.
- [x] Verify that callbacks and completion-status primitives never synthesize
  an asynchronous OOM.

The runtime has no allocation-site failure injector. The hardware OOM test
therefore requests allocations that cannot succeed. Each primitive is retried
four times by the VM; a leaked pin or peripheral would make a later attempt
fail with `ALREADY_IN_USE` instead of the expected retryable OOM. A normal
construction on the same pins immediately afterwards verifies final cleanup.

| Allocation site | Classification and cleanup |
| --- | --- |
| I2C target and register-target construction | Proxy first; all queues, buffers, driver handles, and resources are allocated synchronously. Scoped cleanup owns each partial state until the registered resource destructor takes ownership. |
| I2C controller bus/device construction | Proxy and Toit resource first. Queue/driver handles are released on every later failure; devices unlink themselves from the bus if callback registration fails. |
| I2C probe/read/write/write-read setup | Persistent address, TX, and RX buffers are allocated before publishing the in-flight operation. RX failure frees TX; dispatch failure retires all buffers. |
| SPI target and buffer-target construction | Proxy first; host slot, event queue, DMA storage, index arrays, resource, and driver are acquired in order with scoped cleanup or destructor ownership at every boundary. |
| SPI target/controller transfer setup | TX and RX buffers are allocated before the descriptor is queued. Second-buffer and queue failures free all partial state synchronously. |
| ISR callbacks | Allocation-free: they only update preallocated descriptors, counters, queues, and event bits. Re-arm errors are reported as driver state, never OOM. |
| Completion/status primitives | Copy into memory allocated by Toit before native state is consumed, then release native buffers. No completion path maps an error to OOM. |

### 4. Fault injection and stress

- [x] I2C: hit the configured in-transaction SCL timeout, and separately hold
  SCL low before START to verify deadline abort and recovery on the same bus.
- [x] I2C: interrupt a transaction at FIFO boundaries and verify that the next
  read/write succeeds.
- [x] I2C: repeat target queue overflow and oversized-transaction overflow and
  check exact dropped counters.
- [x] SPI: abort idle and active target transactions repeatedly with DMA both
  enabled and disabled.
- [x] SPI: release CS after representative byte and non-byte-aligned clock
  counts, then verify target reuse.
- [x] SPI: switch ESP32-S3 mode-2 targets between full-duplex, receive-only,
  and transmit-only configurations and verify that neither direction shifts by
  one bit.
- [x] SPI: repeat buffered-target queue overflow and check exact ordering and
  dropped counters.
- [x] Run a longer mixed-operation stress loop on each chip variant.

The recoverable external-SCL case deliberately holds SCL before START and uses
a Toit task deadline: `Device.timeout-us` is a hardware limit on an SCL-low
interval after a transaction has started, not a deadline for waiting for an
idle bus. The separate in-transaction clock-stretch test verifies
`I2C_TIMEOUT`. Both paths abort and reuse the same controller bus. FIFO
boundaries are covered on both sides of 32 bytes and by reads through 1,024
bytes. The contention loops and three repetitions of every abort/close and
overflow scenario provide the mixed-operation stress pass.

### 5. Final matrix

- [x] ESP32 first run after setup: all I2C/SPI tests pass.
- [x] ESP32 immediate second run: all I2C/SPI tests pass.
- [x] ESP32-S3 first run after setup: all I2C/SPI tests pass.
- [x] ESP32-S3 immediate second run: all I2C/SPI tests pass.
- [x] Record commit IDs for Toit and ESP-IDF below.
- [x] Commit the tests and fixes on the appropriate stacked branches and push
  every affected child branch.

## Existing coverage

| Area | Covered cases |
| --- | --- |
| I2C target | 7-bit and 10-bit addresses, direct read/write, combined write-read, FIFO-boundary sizes, dynamic response, clock stretching, bounded receive queues, oversized transactions, broadcast, close/reconfigure |
| I2C register target | 8-bit and 16-bit register addresses, wraparound, reads larger than the FIFO, pointer continuation, live updates, overflow accounting, broadcast |
| I2C controller | asynchronous scheduling, contention, 50/100/400 kHz operation, NACK, timeout, address-width collision, clock-stretch recovery, invalid arguments |
| SPI target | modes 0-3, transmit/receive/full duplex, direction changes between target instances, MSB/LSB order, DMA and non-DMA, 50 kHz through 5 MHz, sizes 1 through 4092, idle/active abort, close and reuse |
| SPI buffer target | native response updates, fill byte, bounded queues, maximum DMA transfer, partial classic-DMA receive, wait timeout, active close and reuse |
| SPI controller | modes 0-3, full-duplex loopback, asynchronous transfer, bus reservation, keep-CS-active ownership |

## Evidence log

| Date | Toit commit/worktree | ESP-IDF commit | Variant | Command/test | Result |
| --- | --- | --- | --- | --- | --- |
| 2026-09-02 | `b010aac9` plus local changes | `676c30742c` | ESP32-S3 | `i2c-target-board1.toit` | Pass after target TX-empty refill fix and explicit overflow-test handshake |
| 2026-09-02 | `b010aac9` plus local changes | `676c30742c` | ESP32-S3 | SPI CS timing probe | Setup and hold deltas matched 0, 1, 8, and 16 requested cycles |
| 2026-09-02 | `b010aac9` plus local changes | `676c30742c` | ESP32 | SPI CS timing probe | Setup matched; hold values above 1 exposed unresolved saturation/wrap behavior |
| 2026-09-03 | `b010aac9` plus local changes | `676c30742c` | Host, ESP32, ESP32-S3 | Build, `toit analyze -Werror`, `git diff --check` | Pass |
| 2026-09-03 | `b010aac9` plus local changes | `676c30742c` | ESP32 | Full I2C/SPI CTest selection, fresh setup | 14/14 pass in 125.58 s |
| 2026-09-03 | `b010aac9` plus local changes | `676c30742c` | ESP32-S3 | Full I2C/SPI CTest selection, fresh setup | 14/14 pass in 122.04 s |
| 2026-09-03 | `b010aac9` plus local changes | local CS-hold fix on `676c30742c` | ESP32 | SPI CS timing probe at 100 kHz | Setup 0-16 and hold 0-15 pass; each requested cycle adds 10 us; hold 16 rejected |
| 2026-09-03 | `b010aac9` plus local changes | `676c30742c` | ESP32-S3 | SPI CS timing probe at 100 kHz | Setup and hold 0-16 pass; each requested cycle adds 10 us |
| 2026-09-03 | `b010aac9` plus local changes | `676c30742c` | ESP32 | `i2c-spi-oom-test.toit` | Pass: I2C/SPI target construction and controller transfer setup survive four retryable native OOM attempts; buses, devices, and pins are immediately reusable |
| 2026-09-03 | `b010aac9` plus local changes | `676c30742c` | ESP32-S3 | `i2c-spi-oom-test.toit` | Pass: I2C/SPI target construction (including register target) and controller transfer setup survive four retryable native OOM attempts; resources are reusable |
| 2026-09-03 | `b010aac9` plus local changes | `54f5e254e2` | ESP32 | Focused fault/timing set | 9/9 pass, including repeated target abort/close, exact queue overflow, non-byte CS termination, external-SCL deadline recovery, OOM, and CS setup 0-16/hold 0-15 |
| 2026-09-03 | `b010aac9` plus local changes | `54f5e254e2` | ESP32-S3 | Focused fault/timing set | 9/9 pass, including repeated target abort/close, exact queue overflow, non-byte CS termination, external-SCL deadline recovery, OOM, and CS setup/hold 0-16 |
| 2026-09-03 | `b010aac9` plus local changes | `54f5e254e2` | ESP32 | Full I2C/SPI matrix after setup | 15/15 pass in 132.38 s |
| 2026-09-03 | `b010aac9` plus local changes | `54f5e254e2` | ESP32 | Immediate full matrix with setup fixtures excluded | 12/12 pass in 77.88 s |
| 2026-09-03 | `b010aac9` plus local changes | `54f5e254e2` | ESP32-S3 | Full I2C/SPI matrix after setup | 15/15 pass in 128.64 s |
| 2026-09-03 | `b010aac9` plus local changes | `54f5e254e2` | ESP32-S3 | Immediate full matrix with setup fixtures excluded | 12/12 pass in 72.75 s |
| 2026-09-03 | `b010aac9` plus follow-up changes | `817726ca57` | ESP32-S3 | `spi-target-board1.toit` | Pass: mode 2 full-duplex, receive-only, and transmit-only run consecutively without one-bit shifts; complete target matrix passes in 10.23 s |
| 2026-09-03 | `b010aac9` plus follow-up changes | `817726ca57` | ESP32-S3 | `spi-buffer-target-board1.toit` | Pass: continuously armed full-duplex modes 0-3, bit order, overflow, DMA limits, async controller, and active close in 7.57 s |
| 2026-09-03 | `b010aac9` plus follow-up changes | `817726ca57` | ESP32 | Full I2C/SPI matrix after setup | 15/15 pass in 130.79 s; a second complete setup run also passed 15/15 in 135.42 s |
| 2026-09-03 | `b010aac9` plus follow-up changes | `817726ca57` | ESP32 | Immediate full matrix with setup fixtures excluded | 12/12 pass in 78.13 s |
| 2026-09-03 | `b010aac9` plus follow-up changes | `817726ca57` | ESP32-S3 | Full I2C/SPI matrix after setup | 15/15 pass in 128.76 s |
| 2026-09-03 | `b010aac9` plus follow-up changes | `817726ca57` | ESP32-S3 | Immediate full matrix with setup fixtures excluded | 12/12 pass in 73.46 s |

Add the exact command, result, and any captured timing to this table as each
remaining item is completed.

## Rig observations

During iterative S3 firmware experiments, board 1 intermittently failed the
921,600-baud synchronization before a test container was installed. A fresh
firmware flash recovered it. The final 15-test run and immediate 12-test
no-setup repetition both passed, so no SPI assertion or persistent peripheral
failure accompanied the serial symptom.
