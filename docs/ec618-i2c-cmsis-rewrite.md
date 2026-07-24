# EC618 I2C rewrite: blob engine -> CMSIS driver

Status: SHIPPED + HW-VALIDATED (2026-06-12). Pattern and lessons carried
over from docs/ec618-uart-cmsis-rewrite.md — same driver family, same
traps. Resolution summary lives in known-issues #6; the surprises found
during implementation, beyond the design below:

- bsp_i2c.c NEVER SHIPPED anywhere, in any mode: the IRQ glue used IRQn
  names that don't exist (never compiled), the per-byte handlers were
  #if 0'd referencing a removed register name, and LuatOS production
  keeps the whole CMSIS branch behind a literal `#if 0` (their I2C is
  the soc_i2c blob, with a GPR reset on error). Our fork implements the
  IRQ-mode master engine: FIFO preload at command issue (the DMA flavor
  arms its channel first the same way), refill/drain from the IRQ
  handler on the FIFO-stall interrupts, real NACK/bus-error/arb-lost
  completion events, single-shot completion behind a busy guard.
- DMA mode was rejected for the channel budget: 7 usable MP channels
  (allocator reserves ch0), the three all-DMA UARTs hold 6 when open,
  and I2C-DMA wants 2 per open bus at Initialize — "2 user UARTs + an
  I2C bus" would be the product ceiling. IRQ mode consumes none.
- The control-mode engine IGNORES the TPR divisor (measured: four
  divisor values, identical pace). SCL = functional clock / fixed
  internal divide; the clock SOURCE was unpinned (gated-26M vs 51M —
  the run-to-run 46/85 kHz drift), and the 51 MHz input is not reliably
  running (pinning it dead-stalled every transfer: DEADLINE_EXCEEDED
  with the engine never advancing). The driver pins 26 MHz before
  clock-enable -> deterministic ~46 kHz; the frequency parameter is
  advisory (floor-rejected below the wire pace); real speed control
  means exploring the engine's "automatic" mode someday. SCR length
  field is 9-bit -> 512-byte transfer cap (longer rejected; chunking
  would insert STOP/START and change the wire protocol).
- Validation: bmp280-ec618 PASS; i2c-torture-ec618 (175 shape-changing
  value-checked transfers per speed, NO reset anywhere) PASS at both
  speeds; i2c-stretch-ec618 PASS — >16-byte TX FIFO refill via a
  25-byte BMP280 register-pair stream, and 150 ms mid-transfer SCL
  squats (ESP32, open-drain only) on a 512-byte read AND write, data
  intact, elapsed = baseline + hold; rc522 SPI regression PASS.
- The nastiest backend bug arrived late: SPIN-CONSUMED transfers (the
  sync paths and bus_probe poll the driver-level completion flag) were
  still letting the completion callback post a Toit event-source
  dispatch. That stale dispatch lands AFTER the next async transfer's
  clear-state, wakes its wait immediately, and finish reports an
  incomplete transfer — a phantom HARDWARE_ERROR on whichever transfer
  happens to FOLLOW a probe (it masqueraded as a transfer-size bug for
  hours because the victim op sat at a fixed position in the test
  round). Fixed with a notify gate: only async transfers signal the
  event source. Symptom fingerprint for posterity: instant
  HARDWARE_ERROR, finish sees last_event==0, register snapshot shows
  MCR=0 (the failing transfer never touched the hardware).
- Debugging tax worth recording, with the post-mortem correction: the
  "stale slot ghost" theory that grew during the hunt was WRONG. The
  slot-marker machinery was subsequently live-verified end to end
  (marker peeked before/after a full OTA: seq advances exactly +3 for
  stage/consume/validate, records correct, right slot boots) — the
  "evidence" was (a) slot-letter bookkeeping confusion (OTAs ping-pong
  slots every cycle) and (b) instrumentation printfs that sat AFTER the
  early-return on exactly the failing path, making the new build look
  like the old one. Plus one unpowered-sensor episode (helpers are
  one-session: a test's Q kills the power switch for the next run).
  Lessons: instrument every exit of a function, not just the branch you
  suspect; and record the slot letter with every OTA. Wire-state
  printfs in the rare error paths stay in the driver.

## Why

- Known-issues #6: the closed no-block engine (soc_i2c.h, PLAT blob)
  silently swallows a transfer whose shape differs from the previous one
  — callback fires instantly, WaitResult claims success, buffer
  untouched. Current workaround rebuilds the whole engine per transfer
  (GPR_swResetModule + I2C_MasterSetup before EVERY transfer).
- The open CMSIS driver (bsp_i2c.c, 1520 lines, fully auditable) is
  IRQ-driven with a real state machine; if a #6-class bug exists there
  we can FIX it at the source (cf. the zero-length-descriptor patch in
  bsp_usart.c).
- `xfer_pending` on MasterTransmit/MasterReceive gives a native
  repeated-start (write-then-read without STOP) — cleaner than the
  blob's opaque op codes, and what register reads actually want.
- Removes the last blob driver the Toit port depends on (UART blob is
  already gone) and its `soc_i2c` base dependencies with it.

## Driver surface (scouted)

- `Driver_I2C0/1` (CMSIS structs): Initialize(cb)/Uninitialize/
  PowerControl/MasterTransmit/MasterReceive/Control/GetStatus.
  DATA bindings; slots resolve them directly against the selected frozen
  base, just like `Driver_USARTn`.
- Events via `cb_event(ARM_I2C_EVENT_*)` from I2C_IRQHandler:
  TRANSFER_DONE / TRANSFER_INCOMPLETE / ADDRESS_NACK / ARBITRATION_LOST
  / BUS_ERROR. Completion model maps 1:1 onto the existing
  Ec618EventSource Event::i2c_type(id) wiring.
- RTE gates compilation: `RTE_I2Cn_IO_MODE` POLLING (current — no IRQ
  struct, no cb_event, synchronous only) / IRQ / DMA. The async design
  needs **IRQ_MODE for both controllers** -> RTE change -> BASE CHANGE,
  full flash. (DMA would burn 4 channels for transfers that are tens of
  bytes; IRQ is right. The stale RTE_I2C1_DMA_*_EN=1 leftovers are
  gated out by IO_MODE and go away with the flip.)
- Initialize() muxes the RTE pins (I2C0: pads 27/28 "AUDIO" route,
  I2C1: pads 19/20) and is once-only (I2C_FLAG_INIT no-op guard — the
  same trap as USART's; keep the cmsis_initialized[] tracker
  discipline). Our multi-routing support stays OUR job: after
  Initialize, un-mux the RTE pins and mux the user's pads (the existing
  dance from i2c_ec618.cc).
- Initialize() registers slpMan backup/restore callbacks
  (PM_FEATURE_ENABLE) — free groundwork for the deep-sleep arc.
- Control(ARM_I2C_BUS_SPEED) only accepts 100k/400k/1M, and the TPR
  write is `|=` (stale divisor bits on re-config). For arbitrary Hz we
  compute and ASSIGN TPR ourselves: clk = I2C_GetClockFreq;
  TPR = ((clk/f)/2)<<SCLH | ((clk/f)/2)<<SCLL.
- ARM_I2C_BUS_CLEAR and ARM_I2C_ABORT_TRANSFER are EMPTY STUBS: there
  is no driver-level abort. Quiesce/teardown needs its own recipe (cf.
  UART's CONTROL_RX 0); the wire_high() dead-bus peek and bus_free()
  guard from the current driver carry over unchanged.
- Slave mode: HW capable (SAR, general call, 7/10-bit) but
  I2C_SlaveTransmit is an empty `return ARM_DRIVER_OK` stub — slave
  support is NOT part of this rewrite.

## Design

Keep the Toit-facing protocol byte-identical: lib/i2c.toit's
device_transfer_start (true=started / false=platform-unsupported) +
device_transfer_finish + Ec618EventSource completion, per-bus mutex,
sync fallback on other platforms. Only the backend of
src/resources/i2c_ec618.cc changes:

- transfer_start: bus_free()/wire_high() guards, then
  MasterTransmit(addr, buf, n, pending) or MasterReceive(...) —
  write-then-read becomes MasterTransmit(..., pending=true) followed by
  MasterReceive on the cb. Driver-owned malloc'd buffers stay (GC moves
  heap objects during async transfers).
- cb_event -> Ec618EventSource::send_event_from_isr(Event::i2c_type(id),
  event_bits); transfer_finish inspects GetStatus()/the recorded event
  for ADDRESS_NACK vs BUS_ERROR vs done, copies rx out, returns the
  result code.
- create/open: tracker-gated Uninitialize-first, Initialize(cb),
  PowerControl(FULL), TPR assign for the requested Hz, RTE-pin un-mux +
  user-pad mux.
- close: quiesce (wait not-busy with deadline), PowerControl(OFF),
  Uninitialize, pad_release.
- The per-transfer GPR reset DIES. If shape-change swallowing
  reproduces on the CMSIS engine, fix it in bsp_usart-style at the
  source (submodule fork) instead of resetting around it.

## Phases

1. **I2C1 on CMSIS** (the rig's BMP280 bus, pads 23/24): full async
   path, HW-verified with bmp280-ec618 + the bmp280 package test, plus
   a shape-change torture loop (alternating 1/2/6-byte reads — the #6
   repro) WITHOUT the GPR reset.
2. **I2C0 same path** (pads 13/14 route; no device currently wired —
   validate scan/clock on the wire-tap or rewire the sensor if needed).
3. **Cleanup**: drop the dead `soc_i2c` dependencies, delete the blob glue,
   resolve known-issues #6, and update memory/docs.

## Base-change plan (ONE full flash)

The RTE IO_MODE flip and driver rewrite landed in one base build. Later
slot-only fixes link directly against that selected base and carry its id in
SRL3, so the device rejects a mismatch before writing.
