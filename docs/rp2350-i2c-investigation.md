# RP2350 to ESP32 I2C fast-mode investigation

This note records the offline analysis of partial writes observed with an
RP2350 controller and a classic ESP32 target. It separates the proven receive
data corruption from the still-unproven cause of the target's earlier NACK.

## Firmware and inspected source revisions

The ESP32 ran the official Jaguar firmware for Toit SDK
`v2.0.0-alpha.199`, as recorded by the
[`jag firmware update` log](../tests/hw/rp2350/results/2026-09-19-esp32-alpha199-update.log).
The `v2.0.0-alpha.199.8+89aa008c` identifier in decoded RP2350 system traces
describes the RP/host-compiled program sources at Toit commit
[`89aa008cfb7ecb2847950c01644121d5c640dbbe`](https://github.com/toitlang/toit/commit/89aa008cfb7ecb2847950c01644121d5c640dbbe).
It is not the ESP32 firmware version.

The ESP-IDF source inspected locally is revision
[`1d89388f11383182b35c06fe44278847235b3a53`](https://github.com/toitware/esp-idf/commit/1d89388f11383182b35c06fe44278847235b3a53),
including Toit's I2C target-v2 changes. The relevant local function is
[`i2c_slave_isr_handler`](https://github.com/toitware/esp-idf/blob/1d89388f11383182b35c06fe44278847235b3a53/components/esp_driver_i2c/i2c_slave_v2.c#L467-L545).

The official `v2.0.0-alpha.199` ESP32 envelope was later extracted and its app
image inspected with `esptool image-info`. Its application metadata reports
`ESP-IDF: v5.2-dev-13492-g1d89388f11`, which maps the tested official native
firmware to the same ESP-IDF revision. Its Toit application version is
`e2b044e`; that short application identifier is independent of the ESP-IDF
submodule revision.

The RP2350 test evidence is preserved in:

- `tests/hw/rp2350/results/2026-09-19-i2c-alpha199-diagnostic-v35.log`
- `tests/hw/rp2350/results/2026-09-19-i2c-alpha199-baseline-v36.log`
- `tests/hw/esp32/results/two-esp-i2c/async-baseline-alpha199.log`
- `tests/hw/esp32/results/two-esp-i2c/corruption-alpha199.log`
- `tests/hw/esp32/results/two-esp-i2c/official-alpha199-image-info.log`

## Local stale-count bug and matching hardware signature

At ISR entry, `i2c_slave_isr_handler` reads the hardware RX FIFO count once.
It then processes interrupt causes in this order:

1. `I2C_INTR_SLV_RXFIFO_WM` drains the snapshotted byte count.
2. `I2C_INTR_SLV_COMPLETE` drains the same snapshotted count again.
3. On chips that report a stretch cause, `I2C_INTR_STRETCH` receives that same
   count and may drain it again for an address-match or RX-full cause.

When watermark and completion are co-latched with 32 bytes in the classic
ESP32 FIFO, the watermark branch drains those 32 bytes correctly. The
completion branch then reads 32 more bytes from an already-drained FIFO and
appends them to the software ring buffer.

The two RP2350-to-ESP32 hardware observations have this exact signature:

| Run | Target length | First mismatch | Correct prefix before final drain | Extra suffix |
| --- | ---: | ---: | ---: | ---: |
| I2C0, 400 kHz, requested 1025 | 432 | 400 | 400 | 32 |
| I2C1, 400 kHz, requested 257 | 112 | 80 | 80 | 32 |

`SOC_I2C_FIFO_LEN` is 32 in the inspected classic ESP32 source. In both cases
the received length minus the first mismatch is exactly one FIFO. The official
envelope metadata now confirms that the tested firmware contains the inspected
ESP-IDF revision with the stale-count bug. The signature is therefore strong
evidence that the double drain produced the extra suffix. The deterministic
A/B below directly proves the same bug and patch under a forced co-latched
interrupt state. It does not replay the original RP transfer, so the mapping
from that transfer to this source defect still rests on its matching signature.

## Two-ESP controller comparison

The separate classic ESP32 rig uses direct SDA GP16 and SCL GP17 wiring. Both
boards were backed up before being flashed with the version-matched official
`v2.0.0-alpha.199` envelope. The standard asynchronous controller/target test
passed, including controller contention, cancellation and recovery. Its timing
probe measured an 11 microsecond median SCL-low period at 50 kHz and 2
microseconds at 400 kHz.

`i2c-corruption-board1.toit` and `i2c-corruption-board2.toit` then ran three
repetitions of 257-byte and 1,025-byte writes at both 100 kHz and 400 kHz. All
12 writes completed without a controller error. The target reported the exact
expected length and contents with `dropped-receive-count == 0` in every case.

This comparison proves that the official target firmware and the rig wiring
can receive a 1,025-byte fast-mode transfer from Toit's ESP32 asynchronous
controller. It does not reproduce the RP2350 failure and therefore does not
exercise the stale-count branch combination. It narrows the remaining cause to
a difference in controller waveform or pacing, electrical conditions on the
RP fixture, or target-side interrupt latency during those specific runs.

## Deterministic stale-count A/B

The standalone helper in
`tests/hw/esp32/esp-idf-i2c-stale-count` forces the relevant interrupt state
without relying on scheduler timing. It is a test-only build: its component
defines `I2C_STALE_COUNT_TEST_ONLY`, and the source refuses to compile without
that definition. It is not linked into Toit or any production firmware.

The native target disables only the interrupt handle allocated to I2C0, then
signals a Toit controller on the other ESP32 to write 20 bytes and issue STOP.
Twenty bytes assert the 16-byte receive watermark but cannot overflow the
classic ESP32's 32-byte FIFO. Once the controller signals completion, the
target records raw interrupt status and FIFO occupancy before re-enabling the
I2C interrupt. This makes watermark and completion pending in the same ISR.

The helper was built twice from ESP-IDF
`1d89388f11383182b35c06fe44278847235b3a53` with the Espressif GCC 14.2.0
toolchain. Variant A used the source unchanged. Variant B used an isolated
copy of the source with only
`tools/rp2350/patches/esp32-i2c-target-fifo.patch` applied. The repository
submodule remained unchanged.

All three repetitions in both variants entered the ISR with raw status
`0x00000893`, FIFO count 20, and `RXFIFO_OVF` clear. The controller reported no
error in either variant. The receive callbacks differed as follows:

| Variant | Callback length | First mismatch | Driver overflow | Raw overflow |
| --- | ---: | ---: | ---: | ---: |
| A, existing ISR | 40 | 20 | false | false |
| B, refreshed count | 20 | none | false | false |

The A result is the exact double drain predicted by source inspection: the
watermark branch consumes the 20 real bytes and the completion branch consumes
20 more bytes using the stale count. The B result proves on hardware that
refreshing the FIFO count before completion removes that corruption while
preserving the valid transaction. The evidence is in:

- `tests/hw/esp32/results/two-esp-i2c/stale-count-a-target.log`
- `tests/hw/esp32/results/two-esp-i2c/stale-count-a-controller.log`
- `tests/hw/esp32/results/two-esp-i2c/stale-count-b-target.log`
- `tests/hw/esp32/results/two-esp-i2c/stale-count-b-controller.log`

This A/B proves the stale-count corruption and its fix. It deliberately avoids
FIFO overflow and therefore does not explain the earlier data-phase NACK on
the RP2350 fixture.

## Patch artifact

`tools/rp2350/patches/esp32-i2c-target-fifo.patch` refreshes the hardware FIFO
count immediately before the completion branch consumes it. It also refreshes
the count before the stretch branch, because a co-latched watermark or
completion branch may already have drained the FIFO.

The second refresh is inactive on the classic ESP32, where
`SOC_I2C_SLAVE_CAN_GET_STRETCH_CAUSE` is false. It preserves the existing event
ordering on stretch-capable chips: completion still publishes the preceding
transaction before a repeated-start address-match is handled, while the
stretch handler receives the FIFO occupancy that exists after completion.

The patch deliberately does not change interrupt masks, FIFO thresholds,
clock stretching, callback semantics, or Toit code. It is a review artifact
and is not applied to the ESP-IDF submodule.

Validate it from the repository root with:

```sh
git -C third_party/esp-idf apply --check \
  ../../tools/rp2350/patches/esp32-i2c-target-fifo.patch
```

## Early NACK remains distinct

The RP2350 observed a data-phase `I2C_NACK` before sending the requested full
payload. The stale-count bug in the inspected local source would explain the
extra corrupt 32-byte suffix after that shortened transaction, but it does not
explain why the target stopped acknowledging after 400 or 80 correct bytes.

Hardware RX FIFO overflow was the leading hypothesis before the instrumented
rerun below. The following statements describe the inspected source, which
the official ESP32 envelope metadata maps to the tested native firmware:

- The classic ESP32 exposes `RXFIFO_OVF` as interrupt bit 2.
- `I2C_LL_SLAVE_EVENT_INTR` and `I2C_LL_SLAVE_RX_EVENT_INTR` omit that bit.
- The target-v2 ISR never samples it.
- `receive_overflow` only records failure to copy an already-drained chunk into
  the software ring buffer, so Toit's `dropped-receive-count == 0` does not
  exclude hardware FIFO overflow.
- The classic ESP32 clock-stretch low-level functions are no-ops. At 400 kHz,
  the configured 16-byte watermark leaves roughly 360 microseconds before a
  32-byte FIFO fills. `CONFIG_I2C_ISR_IRAM_SAFE` is disabled in the local
  `toolchains/esp32/sdkconfig`; if the official firmware uses the same setting,
  cache-disabled intervals can defer service. The corresponding margin at
  100 kHz is about 1.44 milliseconds, consistent with the successful low-speed
  runs but not conclusive.

The native ESP diagnostic subsequently ran on the actual RP2350 fixture and
sampled the port's raw `RXFIFO_OVF` bit in the receive callback. The result is
described below. It did not reproduce the NACK and the raw overflow latch
remained clear, so hardware FIFO overflow is not supported as the cause under
the native-target conditions.

If overflow is confirmed, handle it separately from this patch: enable the
overflow interrupt, latch the transaction's overflow state, drain or reset the
FIFO as required by the peripheral, and report the completed transaction as
overflow so Toit discards and counts it. An IRAM-safe ISR and a lower watermark
can then be tested independently as reliability improvements. Those changes
should not be bundled with the proven stale-count fix.

## Actual RP2350 raw-overflow diagnostic

`tests/hw/rp2350/esp-idf-i2c-overflow-target` is a test-only native target for
the actual `opposite-singer` fixture. It uses ESP UART1 on TX GPIO4 and RX
GPIO34 for control, and switches ESP I2C0 between GPIO19/27 for RP I2C0 and
GPIO32/33 for RP I2C1. The callback records received length and contents, the
driver's software-overflow flag, raw I2C interrupt status, interrupt enable
status, hardware FIFO occupancy, and the raw `RXFIFO_OVF` latch. The target was
built from exact IDF revision
`1d89388f11383182b35c06fe44278847235b3a53` with only the reviewed stale-count
patch applied.

`i2c-overflow-diagnostic-rp2350.toit` retained controller ACK checking. It ran
a 257-byte control at 100 kHz, then 65-, 257-, and 1,025-byte writes twice at
400 kHz on each RP controller. All 14 transfers completed without a controller
error. Every callback had the expected length and contents, both overflow
flags were clear, and FIFO occupancy was zero. Raw status was `0x00000013` and
the interrupt-enable register was `0x00000880`; overflow bit 2 was clear and
not enabled in every callback and follow-up sample.

The result proves that both RP controllers can send the tested fast-mode
lengths over the production wiring without overflowing the classic ESP32 FIFO
when the native target is running. It does not reproduce the earlier Jaguar
target's data-phase NACK. The remaining cause is therefore a difference in the
Jaguar/Toit target runtime, scheduling, or target configuration during those
runs, rather than evidence of a general RP controller or wiring failure. The
raw evidence is in
`tests/hw/rp2350/results/2026-09-19-i2c-overflow-patched-rp.log`.

The first UART control line contained stale reset-time input and produced one
`ERROR invalid-command`. A `SYNC` handshake discarded it before any I2C
transfer. This is fixture-control noise and is kept in the log so it cannot be
mistaken for an I2C result. The existing deterministic A/B remains the direct
test of the stale-count patch; the natural RP run did not co-latch the buggy
interrupt combination.

## Instrumented Jaguar target on the RP fixture

A separate test-only Jaguar build kept the original stale-count behavior and
added counters to the classic ESP32 target-v2 ISR. The counters record the ISR
allocation core, cores that serviced the transaction, entry causes, raw
interrupt status, maximum FIFO occupancy, and the maximum cycle-count gap
between ISR entries within one transaction. The build used the same local
ESP-IDF revision identified above with `CONFIG_I2C_ISR_IRAM_SAFE` disabled.
The instrumentation patch is
`tools/rp2350/patches/esp32-i2c-target-isr-diagnostics.patch`; it applies with
`git apply --check` and is not applied to the submodule.

The bounded controller test used ACK checking and ran ten 1,025-byte writes on
RP I2C0 followed by ten 257-byte writes on RP I2C1, all at 400 kHz. The target
was closed after every transfer so its task-context teardown could print the
completed ISR counters. Reset-time UART bytes were skipped until the first
literal `ARM ` command. The exact test programs are:

- `tests/hw/rp2350/i2c-jaguar-isr-diagnostic-rp2350.toit`
- `tests/hw/rp2350/i2c-target-isr-diagnostic-esp32.toit`

The first run produced one shortened I2C0 transaction before target STATUS was
echoed to the ESP console. It reached FIFO occupancy 32, co-latched watermark
and completion, and had a maximum within-transaction ISR gap of 246,804 cycles.
The other 19 transfers in that run completed with maximum FIFO occupancy 16 or
17 and gaps from about 103,000 to 107,000 cycles.

The bounded repeat echoed target STATUS and directly correlated six shortened
transactions with the ISR state:

| Controller | Requested | Received | First mismatch | Extra suffix | Maximum FIFO | Maximum ISR gap |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| I2C0 | 1,025 | 528 | 496 | 32 | 32 | 315,006 cycles |
| I2C0 | 1,025 | 864 | 832 | 32 | 32 | 295,899 cycles |
| I2C0 | 1,025 | 624 | 592 | 32 | 32 | 299,883 cycles |
| I2C0 | 1,025 | 848 | 816 | 32 | 32 | 236,793 cycles |
| I2C1 | 257 | 160 | 128 | 32 | 32 | 256,410 cycles |
| I2C1 | 257 | 272 | 240 | 32 | 32 | 258,252 cycles |

Every shortened transaction had all of the following properties:

- FIFO occupancy reached the hardware limit of 32 bytes.
- Watermark and completion were co-latched in the final ISR.
- The final 32 bytes were the stale-count duplicate suffix.
- The raw `RXFIFO_OVF` bit remained clear.
- The longest service gap was 236,793 to 315,006 cycles, about 0.99 to
  1.31 milliseconds at the ESP32's 240 MHz clock.

Clean transfers in the same run had FIFO occupancy 16 or 17, did not co-latch
watermark and completion, and had maximum ISR gaps around 103,000 to 107,000
cycles, about 0.43 to 0.45 milliseconds. All observed shortened transfers were
allocated on core 1, although core-1 allocation alone was not sufficient to
cause a failure.

This is direct evidence that the early transaction termination coincides with
the target FIFO becoming full after an unusually long ISR service interval.
The clear `RXFIFO_OVF` latch does not disprove saturation: the peripheral can
stop acknowledging the next byte when no FIFO slot is available, before an
additional byte is accepted and classified as overflow. The capture did not
retain the RP controller's per-transfer exception text, so it does not by
itself prove `I2C_NACK`; the earlier v35 log supplies that controller-side NACK
evidence for the same shortened-transfer signature.

The evidence identifies FIFO saturation as the proximate condition and the
stale-count bug as the independent cause of the 32-byte corrupt suffix. It does
not yet isolate why the Jaguar runtime occasionally delays the non-IRAM ISR.
The next bounded A/B should enable `CONFIG_I2C_ISR_IRAM_SAFE` in an isolated
build and rerun these exact programs. If that eliminates the long gaps and
full-FIFO terminations, it supports cache-disabled intervals as the cause. A
bounded intermittent sample and the resulting code-placement changes would
not identify that cause by themselves. If it does not, a second independent
A/B can lower the receive watermark while retaining the same ISR placement.
Reliable truncation or overflow detection needs separate investigation: a
full FIFO can occur during a valid write, and the failing captures did not set
the raw overflow latch. It must not be treated as a transaction failure by
itself.

The diagnostic protocol now mirrors each RP2350 controller result as a
`RESULT` line on the ESP32 serial console before reading target status. This
preserves the exact controller exception in the next A/B capture even if the
RP2350 USB console attaches after the transfer.

### Prepared IRAM-safe A/B

The paired local diagnostic builds use ESP-IDF revision
`1d89388f11383182b35c06fe44278847235b3a53`, the unchanged ISR-counter patch,
and the official alpha.199 system snapshot. Their envelope metadata therefore
reports SDK `v2.0.0-alpha.199`, but the native firmware is a local Toit build
from `v2.0.0-alpha.199.8+89aa008c` and is not the official Jaguar firmware.

Enabling `CONFIG_I2C_ISR_IRAM_SAFE` alone exceeded the classic ESP32's default
128 KiB IRAM link region by 3,056 bytes. Both sides of the prepared A/B enable
ESP-IDF's `CONFIG_ESP_SYSTEM_ESP32_SRAM1_REGION_AS_IRAM` option and include the
matching bootloader. The generated configuration headers then differ by one
definition only: `CONFIG_I2C_ISR_IRAM_SAFE`. The control uses 0x1fa57 bytes of
`.iram0.text`; the IRAM-safe build uses 0x207eb bytes. The reproducible config
changes are separate so the memory-layout option can be applied to both:

- `tools/rp2350/patches/esp32-i2c-target-iram-ab-common.patch`
- `tools/rp2350/patches/esp32-i2c-target-iram-safe.patch`

The final ELF confirms the target ISR closure is in IRAM. In this build the
IDF target ISR and RX helper are at `0x4008ae80` and `0x4008ae24`; Toit's
receive callback, request callback, and event signal method are at
`0x4008101c`, `0x400810a4`, and `0x40080fec`. Their direct FreeRTOS ISR callees,
including `xQueueGenericSendFromISR`, `xStreamBufferSendFromISR`, ring-buffer
helpers, and critical-section functions, are all in the `0x4008`/`0x4009`
IRAM range or in ROM. The cycle/core instrumentation helpers inline to CPU
register access. IDF allocates the target state and buffers from internal RAM,
and callback registration rejects callback code outside IRAM or user data
outside internal RAM when the option is enabled. Toit's event queue and
message buffer also explicitly use `MALLOC_CAP_INTERNAL`.

The ignored build artifacts are under
`.cache/rp2350-i2c-jaguar-diagnostic/iram-ab`:

| Build | Envelope SHA-256 |
| --- | --- |
| common-layout control | `5ab810306992f0519b2d9f716fc006977e7c300fafc6ad1292ba6c4322dd91ff` |
| IRAM-safe target ISR | `18ce29f706e8103ac30cfb6db6e41e876d2bc5c451584584640ab5b0cfb57038` |

These artifacts compiled and linked, and both diagnostic Toit programs
analyzed with warnings treated as errors. The physical comparison used the
common-layout control first and then the IRAM-safe build, preserved the ESP32
serial `RESULT` lines, and restored the official Jaguar image afterward.

### IRAM-safe A/B result

The matched physical comparison ran exactly 20 transfers per variant: ten
1,025-byte writes on I2C0 and ten 257-byte writes on I2C1, all at 400 kHz. The
RP controller reported `I2C_NACK` for every shortened transaction. The other
18 control transfers and 17 IRAM-safe transfers completed with exact length
and contents.

| Variant | Controller/repetition | Received | First mismatch | Extra suffix | Maximum FIFO | Co-latched | Raw overflow | Maximum ISR gap |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Control | I2C0/2 | 112 of 1,025 | 80 | 32 | 32 | 1 | 0 | 258,156 cycles |
| Control | I2C0/6 | 512 of 1,025 | 480 | 32 | 32 | 1 | 0 | 314,685 cycles |
| IRAM-safe | I2C0/8 | 512 of 1,025 | 480 | 32 | 32 | 1 | 0 | 323,034 cycles |
| IRAM-safe | I2C0/9 | 496 of 1,025 | 464 | 32 | 32 | 1 | 0 | 252,276 cycles |
| IRAM-safe | I2C1/2 | 256 of 257 | 224 | 32 | 32 | 1 | 0 | 318,390 cycles |

Moving the target ISR closure into IRAM did not eliminate the long service
gaps, full-FIFO terminations, controller NACKs, or stale-count suffix. This
bounded result does not support cache-disabled execution as the sole cause of
the delayed service. It does not rule out cache effects in other schedules:
the failure is intermittent, and changing placement also changes code layout.
The source of the roughly 1.05 to 1.35 millisecond service gaps remains
unresolved. The stale-count fix remains justified independently by the
deterministic A/B above.

The paired evidence is in:

- `tests/hw/rp2350/results/2026-09-20-i2c-iram-ab-control-rp.log`
- `tests/hw/rp2350/results/2026-09-20-i2c-iram-ab-control-esp.log`
- `tests/hw/rp2350/results/2026-09-20-i2c-iram-ab-iram-safe-rp.log`
- `tests/hw/rp2350/results/2026-09-20-i2c-iram-ab-iram-safe-esp.log`
- the matching `*-stage.log`, `*-deploy.log`, `*-update.log`, and
  `*-SHA256SUMS` files in the same directory

### Bounded physical run plan

Run exactly one 20-transfer control and one 20-transfer IRAM-safe treatment.
Do not rerun an unchanged variant after an unexpected failure; preserve its
logs and proceed directly to restoration. The ESP peer no longer pulses RUN,
because an RP2350 hardware reset would discard the candidate staged in RAM.
The order for each variant is therefore fixed: update the ESP native image,
stage the RP image with `--no-reboot`, deploy the waiting peer, then open both
serial captures and activate the RP candidate.

The RP fixture is built by replacing the application container in immutable
`healthy-v59.envelope`; no native relink is involved. It is noncritical, calls
`firmware.validate` before testing, and leaves the OTA console alive after it
finishes. Its raw image SHA-256 is
`c60fed8c92a8d00beeb473882befb978a4cd710e02a7057447c4e7ebfc36ec0d`.
It uses the frozen version-59 native source base after the SPI matrix and the
RP RegisterTarget repeated-read cursor fix. Do not rebuild either A/B envelope
or the diagnostic image between variants.

From the repository root, first set and verify the immutable inputs:

```sh
set -eu
set -o pipefail

AB="$PWD/.cache/rp2350-i2c-jaguar-diagnostic/iram-ab"
RESULTS="$PWD/tests/hw/rp2350/results"
RP_PORT=/dev/serial/by-id/usb-Raspberry_Pi_Pico_DC67867C6256ED2B-if00
ESP_PORT=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_d237166db89bea11bb5c10bfec257580-if00-port0
UPLOADER="$PWD/build/rp2350-ota-upload/ota-upload"
RP_TEST="$AB/i2c-jaguar-isr-diagnostic-v59.bin"
PEER="$PWD/tests/hw/rp2350/i2c-target-isr-diagnostic-esp32.toit"

RP_RESTORE="$PWD/.cache/rp2350/healthy-v59.bin"
RP_RESTORE_SHA=e378fd6a5a9a35a7675e25c7fc451ce2ca8b58718afb5c5241c78ba6a134cd7a

ESP_RESTORE="$PWD/.cache/rp2350-i2c-overflow-target/esp-backup/opposite-singer-alpha199-before-i2cdiag.bin"
ESP_RESTORE_SHA=2eb156fb9118073ffbcc9560f5773505a4edb5a7b82d004721910e9b6a3f0ca1

(cd "$PWD" && sha256sum -c "$AB/ARTIFACT-SHA256SUMS")
printf '%s  %s\n' "$RP_RESTORE_SHA" "$RP_RESTORE" | sha256sum -c -
printf '%s  %s\n' "$ESP_RESTORE_SHA" "$ESP_RESTORE" | sha256sum -c -
if fuser "$RP_PORT" "$ESP_PORT"; then
  echo 'A serial port is already open; stop before touching the rig' >&2
  exit 1
fi
```

For each variant, reserve fresh result names. The capture helper creates its
two output files exclusively and flushes every line, so the first failure is
retained if the tool or device later stops. It opens both consoles before
sending `TOIT-OTA REBOOT`, reconnects the RP USB console after activation,
periodically records `INFO`, and stops after both completion markers or 120
seconds.

```sh
run_variant() {
  label="$1"
  esp_envelope="$2"
  prefix="$RESULTS/2026-09-20-i2c-iram-ab-$label"

  for suffix in esp-update rp-stage peer-deploy rp esp; do
    test ! -e "$prefix-$suffix.log"
  done

  jag firmware update "$esp_envelope" --device opposite-singer \
    2>&1 | tee "$prefix-esp-update.log"
  jag firmware --device opposite-singer \
    2>&1 | tee -a "$prefix-esp-update.log"

  "$UPLOADER" --port "$RP_PORT" --no-reboot "$RP_TEST" \
    2>&1 | tee "$prefix-rp-stage.log"
  jag run "$PEER" --device opposite-singer \
    2>&1 | tee "$prefix-peer-deploy.log"

  python3 tests/hw/rp2350/i2c-iram-ab-capture.py \
    --rp-port "$RP_PORT" --esp-port "$ESP_PORT" \
    --rp-log "$prefix-rp.log" --esp-log "$prefix-esp.log" \
    --seconds 120

  sha256sum "$prefix"-*.log > "$prefix-SHA256SUMS"
}

run_variant control "$AB/control-alpha199.envelope"
run_variant iram-safe "$AB/iram-safe-alpha199.envelope"
```

The control and treatment use the same RP binary, peer source, transfer order,
and common SRAM1-as-IRAM layout. Their generated ESP configuration headers
differ only in `CONFIG_I2C_ISR_IRAM_SAFE`. The cached RP and peer snapshots,
both native ELFs, both linker maps, and all envelope hashes are retained under
`$AB`; keep that directory until any first-failure trace has been decoded.

Restoration is mandatory after success or failure. Restore the original
4 MiB ESP image byte-for-byte using the recorded CP2102N port, verify it, then
restore the RP image through the normal validating OTA path:

```sh
ESPTOOL_PY=/home/flo/.espressif/python_env/idf5.4_py3.14_env/bin/python
"$ESPTOOL_PY" -m esptool --chip esp32 --port "$ESP_PORT" --baud 460800 \
  write_flash --flash_size keep --verify 0x0 "$ESP_RESTORE" \
  2>&1 | tee "$RESULTS/2026-09-20-i2c-iram-ab-esp-restore.log"
"$ESPTOOL_PY" -m esptool --chip esp32 --port "$ESP_PORT" --baud 460800 \
  verify_flash --diff no 0x0 "$ESP_RESTORE" \
  2>&1 | tee -a "$RESULTS/2026-09-20-i2c-iram-ab-esp-restore.log"
jag firmware --device opposite-singer \
  2>&1 | tee -a "$RESULTS/2026-09-20-i2c-iram-ab-esp-restore.log"
jag ping --device opposite-singer \
  2>&1 | tee -a "$RESULTS/2026-09-20-i2c-iram-ab-esp-restore.log"

"$UPLOADER" --port "$RP_PORT" "$RP_RESTORE" \
  2>&1 | tee "$RESULTS/2026-09-20-i2c-iram-ab-rp-restore.log"

if fuser "$RP_PORT" "$ESP_PORT"; then
  echo 'A serial port remains open after restoration' >&2
  exit 1
fi
```

The expected ESP restore SHA-256 above is the fresh image read immediately
before the prior instrumented-Jaguar run. It contains NVS and WiFi identity and
must remain ignored. Successful restoration requires both `verify_flash`'s
digest match and Jaguar reporting official SDK `v2.0.0-alpha.199` under the
`opposite-singer` identity. The normal RP uploader must report activation and
validation of the chosen healthy image before the rig is released.

The physical A/B restoration met those checks. The full 4 MiB ESP backup,
SHA-256
`2eb156fb9118073ffbcc9560f5773505a4edb5a7b82d004721910e9b6a3f0ca1`,
was written back and a separate `verify_flash --diff no` comparison reported
`digest matched`. Jaguar then reported official SDK `v2.0.0-alpha.199` for
`opposite-singer`, and `jag ping` received a pong. The RP was restored through
the validating OTA path to immutable healthy-v59 image SHA-256
`e378fd6a5a9a35a7675e25c7fc451ce2ca8b58718afb5c5241c78ba6a134cd7a`.
The uploader observed validation on partition 0; the final query returned
`TOIT-OTA INFO 1 0 0 4194304`. No process held either serial port after the
checks. The restoration evidence is in
`tests/hw/rp2350/results/2026-09-20-i2c-iram-ab-esp-restore.log` and
`tests/hw/rp2350/results/2026-09-20-i2c-iram-ab-rp-restore.log`. The ESP log
also retains two rejected command-line spellings from before the successful
write. Esptool rejected both during argument parsing, before opening the
serial port; the corrected `--flash_size keep` invocation and both successful
verification records follow them. Their final hashes are recorded in
`tests/hw/rp2350/results/2026-09-20-i2c-iram-ab-restoration-SHA256SUMS`.

The complete raw ESP serial capture, including clean controls and native ISR
counters, is
`tests/hw/rp2350/results/2026-09-19-i2c-jaguar-isr-diagnostic-esp.log`.

## Rig restoration

Before flashing the two-ESP rig, both complete 4 MiB flash images were saved
under the ignored `.cache/two-esp-i2c-backups` directory. Their SHA-256 hashes
are recorded in
`tests/hw/esp32/results/two-esp-i2c/before-sha256.txt`; the binaries remain
ignored because they contain the boards' NVS and WiFi configuration.

After the A/B run, both full images were written back and esptool verified the
written data. Fresh boot captures confirmed the original identities: board 1
returned to `v2.0.0-alpha.198.40+floitsch-spi-target-resource-rebased.0f92dcf86`
and board 2 returned to `v2.0.0-alpha.198.18+14d2e020` with its
`INVALID_KEY_NATIVE` workload. The restore and boot logs are in
`tests/hw/esp32/results/two-esp-i2c`.

The actual RP fixture's `opposite-singer` ESP32 was also backed up as a complete
4 MiB image under the ignored `.cache/rp2350-i2c-overflow-target` directory
before the native diagnostic was flashed. Its SHA-256 was
`7218e7aae195a08f8a58522718ac43d195f3b23313ef6b35afa82dd1ddc4cdda`.
The full image was restored after the run; esptool verified the written data,
and `jag ping --device opposite-singer` received a pong. The RP2350 was then
restored through OTA to immutable healthy-v46 image SHA-256
`1c67a83b49d714ebf7c0ff6d89618a0cb583479219c66ce1abbd4ce50ed6d18a`.
The uploader observed validation on partition 0, and the final console query
returned `TOIT-OTA INFO 1 0 0 4194304`.

For the instrumented Jaguar run, a fresh complete backup was saved under the
same ignored cache directory before flashing. Its SHA-256 was
`2eb156fb9118073ffbcc9560f5773505a4edb5a7b82d004721910e9b6a3f0ca1`.
After the test, that image was written back byte-for-byte and `esptool
verify_flash` reported a digest match. `jag firmware --device opposite-singer`
then reported the restored official SDK `v2.0.0-alpha.199`. The RP2350 was
restored through OTA to immutable healthy-v54 image SHA-256
`b863122e87706d63a14852f88b03f07615b9d2f1f012bee009e12dfefc3ecb2a`.
The uploader observed validation on partition 0, and the final query returned
`TOIT-OTA INFO 1 0 0 4194304`.

## Comparison with the ESP32-H2 bring-up fix

The ESP32-H2 bring-up independently found a controller-side problem fixed by
ESP-IDF commit `3775219607e957cec38247a052148741eddaf662`
(`fix(i2c): drain TX FIFO before a repeated START`). In `i2c_master.c`,
`s_i2c_write_command` now drains the pending write before both another WRITE
and a RESTART command. Otherwise, the START handler can queue the next address
byte into a full TX FIFO and overwrite pending data. Its hardware regression
covers FIFO boundaries through 1,024 bytes, both controller roles, and NACK
recovery.

That change is independent of the target RX stale-count patch recorded here.
The latter changes `i2c_slave_v2.c` to refresh the RX count before COMPLETE and
STRETCH handling after a preceding watermark branch may have drained the FIFO.
The H2 commit leaves that file unchanged, and this port leaves the ESP-IDF
submodule at `1d89388f11383182b35c06fe44278847235b3a53`: the target patch is
provided for separate review, not applied to the pinned SDK. Both fixes are
needed to address both defects; neither establishes a fix for the long ISR
service gaps observed in the Jaguar experiment.
