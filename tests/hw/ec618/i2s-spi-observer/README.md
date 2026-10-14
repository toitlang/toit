# Independent EC618 I2S observer

This diagnostic observes EC618-master I2S output through ESP32-S3 SPI DMA
while sending a patterned I2S stream back to the EC618. It keeps the native
S3 I2S receiver verdict separate from the independent SPI verdict, because
S3 I2S reception can corrupt data that the SPI observer receives correctly.

At 96 kHz/24-bit, SPI checks 1,153,944 consecutive bytes (over two seconds)
and the EC618 checks ten seconds of reverse traffic. The six-block DMA ring
uses ownership checking and rejects a consumer that falls behind. It never
resynchronizes after a corrupted, dropped or replayed payload block. Clock
counts and elapsed time must also agree with the captured length.

Use the wiring in `../wiring.toit`: S3 GPIO1/2 receive EC618 BCLK/WS,
GPIO8 receives EC618 TX, GPIO41 drives EC618 RX, GPIO40 drives GO, and
GPIO39 receives ACK. The S3 needs octal PSRAM. Disconnect DS18B20 DQ as
required by the other I2S fixtures. The SPI chip select is routed internally;
no additional wire is needed.

## Build and host checks

The native observer requires ESP-IDF commit
`defb08e5592ba3c26f602376c027d7dda835c2f1` and its matching toolchain.
It uses private DMA state, so CMake rejects a different revision or modified
SPI driver. `spi-slave.patch` is applied to a component copy under the build
directory. The original SDK is never patched. The rest of this project can
use its normal SDK independently.

From the repository root, after activating that ESP-IDF environment:

```sh
IDF_TARGET=esp32s3 idf.py -C tests/hw/ec618/i2s-spi-observer build
```

Host tests use Toit, CMake and a GCC-compatible C compiler; they do not need
ESP-IDF or hardware. Install the fixture's locked Toit packages first:

```sh
(cd tests/hw/ec618/i2s-spi-observer && toit pkg install)
cmake -S tests/hw/ec618/i2s-spi-observer -B build/ec618-observer-host \
  -DEC618_OBSERVER_HOST_TESTS=ON -DTOIT_EXECUTABLE="$(command -v toit)"
cmake --build build/ec618-observer-host
ctest --test-dir build/ec618-observer-host --output-on-failure
```

Tests cover every 24-bit pattern phase, a damaged initial anchor, final-bit
corruption, replayed/dropped DMA blocks, truncated captures, missing clock
evidence, incorrect buffer-duration verdicts, duplicate records, resets,
and deliberate observer-stall rejection.

## Run on the rig

Save and verify the current S3 application before replacing it. Flash only
`build/ec618_spi_observer.bin` at `0x10000`, using the device's verified
persistent serial path. Do not use `idf.py flash` or the generated full-flash
command: those also replace the bootloader and partition table. Restore and
flash-verify the original application after the diagnostic, then check the
normal S3 fixture and EC618 agent.

Run from the repository root with the EC618-compatible compiler, persistent
ports, and exact deployed base identity in the variables below:

```sh
flock -n /tmp/toit-ec618-rig.lock toit run tests/hw/ec618/i2s-spi-observer/run.toit -- \
  "$TOIT_EXE" "$EC618_BOARD_PORT" "$EC618_I2S_PEER_PORT" \
  96000 24 1 1 0 default "$EC618_EXPECT_BASE" > capture.log 2>&1
```

Arguments after the ports are sample rate, sample width, PSRAM flag, SPI
sampling mode (0 or 1), deliberate observer stall in ms (0 or 100), EC618
buffer duration (`default` or `100`), and expected base identity. Repeat
with the other sampling mode. A 100-ms EC618 buffer request may fail with
`MALLOC_FAILED`; it is not silently reduced and is not a qualified workaround
for the intermittent default-buffer failure.

Preserve the runner's exit status. It requires the EC618 and both native
S3 receivers to pass. Independently assess the SPI stream and EC618 reverse
payload using:

```sh
toit run tests/hw/ec618/i2s-spi-observer/check-stream.toit -- \
  96000 24 capture.log default
```

A clean independent verdict does not convert a failed native verdict into
a pass. For fault injection, use a 100-ms observer stall with default EC618
buffers. `check-stall.toit -- capture.log` must accept that rejection and
`check-stream.toit` must reject the truncated capture. This qualifies the
observer's failure detection, not payload continuity during that stall.

The integrated v5 rig has both successful captures and intermittent EC618
underrun/overrun failures. Keep those failures visible. These finite captures
do not establish indefinite streaming, first-frame fidelity, or electrical
timing margins. See `docs/ec618-todo.md` for the qualification record.
