# Handover: I2S TX burst fix (hardware validation)

Delete this file before the branch is merged.

## Goal

Validate on the ESP32 and ESP32-S3 test rig that the ESP-IDF fork fix
[toitware/esp-idf#136](https://github.com/toitware/esp-idf/pull/136) works.
Then land it, and simplify the I2S backend of the pixel-strip package.

## Background

When an `i2s_channel_write` ends in the middle of a DMA buffer, the next write
appends to that buffer (`curr_ptr`/`rw_pos` in
`components/esp_driver_i2s/i2s_common.c`). If the bus ran out of data in
between, the DMA has already started sending, or even finished, that buffer.
The appended data is then dropped, or sent a full DMA ring later, out of order.
Continuous audio never hits this. Bursty writers do. WS2812 pixel strips over
I2S lost the start of every frame after the first.

The pixel-strip package works around it today:
- [toit-pixel-strip#32](https://github.com/toitware/toit-pixel-strip/pull/32)
  stops, preloads and restarts the bus for every frame.
- [toit-pixel-strip#35](https://github.com/toitware/toit-pixel-strip/pull/35)
  also sleeps for the frame's wire time before returning.

The fix (#136): the TX EOF interrupt sets `curr_started` when the finished
buffer, or the next buffer in the ring that the DMA has just moved to, is the
writer's `curr_ptr`. `i2s_channel_write` checks the flag on entry. If it is
set, the write leaves the rest of that buffer silent (auto clear) and continues
with the next free buffer. `curr_ptr` and `curr_started` change together under
`g_i2s.spinlock`. Writers that stay ahead of the DMA are unaffected.

## What is on this branch

- `third_party/esp-idf` points to `9cf93bbb1b`, branch
  `floitsch/i2s-tx-resume` of toitware/esp-idf. The base is `bf81d4c8cd`, the
  head of `patch-head-5.4.2`, which `master` uses.
- `tests/hw/esp32/i2s-burst-test.toit` is new. It passes the analyzer but has
  never run on hardware.
- This file.

## Status

Done:
- The patched firmware builds for `esp32` (legacy DMA interrupt) and `esp32s3`
  (GDMA).
- A Python model of the ring, the free queue and the EOF interrupt behaves as
  expected: with bursty writes the original logic is corrupted, the patched
  logic is not, and both give identical output when streaming continuously.

Not done:
- Any hardware run, of the fix or of the new test.

## The test

`i2s-burst-test.toit` uses the single-board loopback of the existing i2s tests.
On board 1, I2S TX (slave) is wired to I2S RX (master); see `Variant.i2s-data1`
in `tests/hw/esp32/variants.toit`. Board 2 is not used.

- The bus runs at 10 kHz, 16-bit stereo, so it sends 40 bytes/ms. A DMA buffer
  (960 bytes) lasts 24 ms, and the ring of 6 buffers lasts 144 ms.
- The test sends 105 bursts: 3 rounds of 7 sizes (4 bytes to 4 KB) × 5 pauses
  (0, 5, 30, 100 and 300 ms).
- Each 4-byte frame of a burst repeats one non-zero value, so how the receiver
  aligns samples doesn't matter. The bus emits zeros when it runs out of data.
  The non-zero bytes received must therefore equal the bursts exactly: nothing
  lost, reordered or duplicated.
- On a mismatch the test prints the burst, its size, the pause before it and
  the bytes around the mismatch.

## Steps

The general hardware-test instructions are in `tests/hw/README.md`: the
`esp32-test.env` file, the envelope variables and `make rebuild-cmake-hw`.

1. Check out the branch:
   ```sh
   git fetch origin floitsch/i2s-tx-resume
   git checkout floitsch/i2s-tx-resume
   git submodule update --init --recursive
   ```

2. Baseline: show that the test catches the bug with the unpatched driver.
   ```sh
   git -C third_party/esp-idf checkout bf81d4c8cd
   IGNORE_SUBMODULE=1 make esp32 esp32s3
   source esp32-test.env
   export TOIT_EXE_HW=$PWD/build/host/sdk/bin/toit
   export ESP32_ENVELOPE=$PWD/build/esp32/firmware.envelope
   export ESP32S3_ENVELOPE=$PWD/build/esp32s3/firmware.envelope
   make rebuild-cmake-hw
   ctest --verbose --test-dir build/hw -C esp32 -R "i2s-burst-test.toit-esp32$"
   ctest --verbose --test-dir build/hw -C esp32s3 -R "i2s-burst-test.toit-esp32s3$"
   ```
   Expected: both **fail** with `First mismatch at byte ...`, on a burst that
   follows a pause.

3. With the fix:
   ```sh
   git submodule update third_party/esp-idf   # Back to 9cf93bbb1b.
   make esp32 esp32s3
   ctest --verbose --test-dir build/hw -C esp32 -R "i2s-burst-test.toit-esp32$"
   ctest --verbose --test-dir build/hw -C esp32s3 -R "i2s-burst-test.toit-esp32s3$"
   ```
   Expected: both **pass** with `105 bursts, ... bytes received intact`.

4. Regressions with the fix. All other i2s tests must behave as they do on
   `master`:
   ```sh
   ctest --verbose --test-dir build/hw -C esp32 -R "i2s-"
   ctest --verbose --test-dir build/hw -C esp32s3 -R "i2s-"
   ```
   If one fails, run it on the baseline firmware too, to tell a regression from
   a known failure.

## If the results differ

- **The baseline passes:** the test doesn't reproduce the bug, so a pass with
  the fix proves nothing. Find out why before going on. For example, check
  whether the pauses actually drain the ring. Then make the test reproduce it.
- **Failures with the fix:** check which burst fails and the pause before it.
  - Failures after a pause: the patch doesn't cover that case.
  - Failures at a burst's very first bytes: this may be the known remaining
    race. After a drain, the writer can get the buffer that the DMA sends
    next, possibly while it is still copying. The copy normally wins easily,
    so this should be rare.
- **`in.errors --overrun` is non-zero:** the reader, which loops over every
  byte in Toit, can't keep up. Make it cheaper. For example, skip chunks that
  are all zero before looping over their bytes.
- **The host tools fail to build with `Package 'github.com/toitlang/pkg-host-1.21.0' not found`:**
  delete `tools/.packages/package-timestamp` and
  `tools/.packages-bootstrap/package-timestamp`, then run
  `make download-bootstrap-packages`.

## After the hardware passes

1. Mark toitware/esp-idf#136 as ready and merge it into `patch-head-5.4.2`.
2. On this branch, point `third_party/esp-idf` at the merged commit, delete
   this file, and open the toit PR (submodule bump and new test).
3. Once an SDK release contains the fix, simplify `I2sPixelStrip` in
   toitware/toit-pixel-strip:
   - Start the bus once, then write each frame (with its leading zero bytes as
     the reset interval) per `output`.
   - Drop the per-frame stop/preload/start and the sleep from #35.
   - Make `close` push the last frame out before stopping.
   - Raise the package's SDK constraint.

   Keep #35's sleep version until that release.

## Report back

For each chip (ESP32, ESP32-S3), report the baseline and patched results of
`i2s-burst-test`, including the failure output, and any i2s regressions.
