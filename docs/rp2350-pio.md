# Programmable I/O on RP2350

`rp2350.pio` loads assembled PIO programs, allocates state machines and pins,
and transfers little-endian 32-bit FIFO words with DMA. Programs are immutable
hardware-independent descriptions; state machines own hardware until closed.

## Programs

Use the pinned Pico SDK's assembler and the [Toit generator](../tools/pio/README.md):

```sh
python3 tools/pio/compile.py --pioasm build/pioasm/pioasm \
  driver.pio -o driver_program.toit
```

A `.program capture` exports `CAPTURE-PROGRAM`. Public labels and constants are
exported as prefixed Toit constants. The generator preserves origin, wrap,
side-set, shift settings, pin counts, FIFO mode, PIO version, GPIO ranges, clock
divider and MOV STATUS configuration. Embedded C initialization helpers are
not translated. Configure those settings explicitly in Toit.

A future dynamic builder or Toit-light compiler can produce the same `Program`.
The separation between a generated program, exported entry labels, loading and
starting follows the [ESP32 ULP workflow](https://docs.espressif.com/projects/esp-idf/en/v4.2/esp32/api-guides/ulp.html).
PIO exchanges data through FIFOs and DMA; ULP instead exposes RTC shared memory.
These need different data APIs even though their program lifecycle is similar.

## State machines

```toit
import rp2350.pio
import .driver_program

main:
  machine := pio.StateMachine CAPTURE-PROGRAM
      --frequency=10_000_000
      --in-pins=[32]
  try:
    machine.start
    samples := machine.read 32_768
    print "Captured $(samples.size) bytes"
  finally:
    machine.close
```

Allocation selects a PIO block and state machine, shares identical instruction
images within a block, and reserves the pins against other Toit peripherals.
RP2350B's GPIO window is selected automatically. A single machine cannot use
both GPIO 0–15 and GPIO 32–47. Pin lists describe consecutive groups. Pin
mappings and directions are separate: `--output-pins` enables output drivers,
and `--high-pins` selects initially high outputs. Other reserved pins are inputs
without pulls. Absolute `WAIT GPIO` pins must be included in `--wait-pins`.

Machines begin paused. `start`/`resume` retains registers and FIFO contents;
`pause` stops instruction execution; `reset` clears registers, FIFOs, clock
phase and reserved IRQ flags and restores entry and pin levels. Reset requires
all transfers to have been reclaimed or closed. `frequency` reports the actual
rounded state-machine frequency.

Reserve host IRQ flags with `--irqs=[0]`, then use `wait-for-irq 0` to wait and
acknowledge. Flags 0–3 are exclusive per PIO block and coalesce. Flags 4–7 remain
available for PIO-to-PIO signaling. A program may use `irq wait 0` to wait for
the host acknowledgment. There is no generic protocol-completion `flush`:
DMA completion says that storage is reusable, not that the last bit has left
the pins. Drivers should put an IRQ at the appropriate protocol boundary.

## Transfers and ownership

`write` copies its input and waits for DMA completion; `read byte-count`
receives into native memory and returns a fresh external byte array. Byte
counts must be positive multiples of four. Shift direction and thresholds
control how FIFO words map to wire bits. `read-word` and `write-word` are
conveniences; bulk transfers avoid per-word primitive calls.

For overlapping work, use `submit-write` or `submit-read`. Each machine permits
one outstanding transfer in each direction, including a completed transfer
whose storage has not yet been reclaimed. Default `submit-read buffer` copies
received data back into that buffer when `take-buffer` is called.

```toit
buffer := ByteArray.external 4096
transfer := machine.submit-read buffer --no-copy
try:
  transfer.wait
  buffer = transfer.take-buffer
finally:
  transfer.close
```

`--no-copy` follows system messaging's opt-in ownership convention. After a
successful submission, treat the original buffer as consumed. Whole aligned
external byte arrays in DMA-addressable SRAM are transferred without a copy:
the old heap proxy is neutered and remains unusable through every alias.
Internal arrays, slices and incompatible external storage fall back to copying.
`take-buffer` returns a fresh proxy; it never revives an old one. Failed
submission does not consume the input.

A transfer supports `wait`, `is-complete`, `transferred`, `cancel`, `take-buffer`
and `close`. `cancel` only requests cancellation. `wait` reports cancellation
or DMA errors; `take-buffer` permits reclamation even after those failures.
After partial reception, `transferred` gives the valid byte count and the
remaining bytes are zero. Reclamation is allowed once. Closing a transfer
cancels and waits before releasing storage; closing a machine wakes waiters
and defers native cleanup until DMA has stopped. A closed machine cannot
return outstanding buffers.

All waits suspend Toit tasks. Native primitives do not poll for FIFO space,
wait for DMA, or call the SDK's blocking DMA abort helper. Interrupts wake the
shared peripheral dispatcher, which publishes resource events. DMA never
retains a pointer into movable Toit heap storage.

## Validation

Host tests cover program validation, assembler metadata and generated output,
and the pixel-strip package’s WS2812 capture decoder:

```sh
python3 tools/pio/test_compile.py
build/host/sdk/bin/toit run tests/pio/program-test.toit
build/host/sdk/bin/toit run ../toit-pixel-strip/tests/hw/ws2812-test.toit
```

`tests/hw/rp2350/pio-rp2350.toit` checks copy/consume/fallback behavior,
allocating reads and word I/O, movable buffers during GC, 32 KiB DMA,
GP34 output/input loopback, cancellation including partial reads, close with
pending DMA and concurrent buffer reclamation, blocked waiters and orphan
finalization, sharing a full instruction memory across all twelve machines,
GPIO ownership, upper GPIO windows, and persistent IRQ/reset.

The pixel-strip fixture uses the existing bring-up rig: ESP32 `opposite-singer`
GPIO22 → RP2350 GPIO32, with UART coordination on ESP4/34 ↔ RP1/16. See the
[rig wiring](../tests/hw/rp2350/README.md). Build and activate the RP2350 firmware
with `../toit-pixel-strip/tests/hw/pixel-capture-rp2350.toit` as its application,
then run `../toit-pixel-strip/tests/hw/peer.toit` with Jaguar. The fixtures,
decoder and results live in the package’s `tests/hw/` directory.
See [the package workflow](../../toit-pixel-strip/tests/hw/README.md).

The fixture samples at 10 MHz and compares complete frames and pulse widths
for UART, RMT and I2S, at 20 and 200 LEDs with four data patterns. Successive
frames reuse the same caller buffer with changed contents. Concurrent
rendering/allocation/GC, 16 kHz stereo I2S input, and measured UDP echo traffic
exercise scheduling and DMA.
Captures establish wire behavior; they do not test LED power delivery or
WROVER/PSRAM, which needs the additional board.

See the [recorded hardware results](../../toit-pixel-strip/tests/hw/results/README.md)
for the PIO contract checks, three clean pixel-strip capture passes, fixes and
remaining hardware coverage.
