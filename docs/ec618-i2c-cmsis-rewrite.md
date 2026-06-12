# EC618 I2C rewrite: blob engine -> CMSIS driver

Status: design (2026-06-12). Pattern and lessons carried over from
docs/ec618-uart-cmsis-rewrite.md — same driver family, same traps.

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
  already gone) and the soc_i2c jump-table entries with it.

## Driver surface (scouted)

- `Driver_I2C0/1` (CMSIS structs): Initialize(cb)/Uninitialize/
  PowerControl/MasterTransmit/MasterReceive/Control/GetStatus.
  DATA bindings — already excluded from JT veneering (gen-plat-jt
  DATA-SYMBOLS); slots bind them by absolute base address (frozen-base
  caveat applies, same as Driver_USARTn).
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
3. **Cleanup**: drop the dead soc_i2c JT entries via gen-plat-jt
   --exclude (index shift folds into the same full flash), delete the
   blob glue, resolve known-issues #6, update memory/docs.

## Base-change plan (ONE full flash)

RTE IO_MODE flip + JT exclusion/renumber + driver rewrite all land in
one build: flash once, validate phases 1-3 on hardware, then iterate
slot-only (OTA) for fixes that don't touch jt_data / shared DRAM —
fingerprint-checked against /tmp/fp_ref.elf as usual.
