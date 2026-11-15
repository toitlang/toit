# nRF5340 hardware fixtures

The wiring fixture checks the connections between an Ebyte E83-2G4M03S-TB and an
ESP32 DevKitC V4 independently of the nRF5340 firmware. The ESP32 runs Toit;
the host temporarily controls nRF GPIO and SAADC registers through SWD.
It does not erase or flash the nRF.

| Signal | nRF pin | Ebyte header | ESP32 GPIO |
| --- | --- | --- | --- |
| GPIO A | P1.00 | P3/20 | 13 |
| GPIO B | P1.01 | P3/22 | 27 |
| nRF UART TX | P1.04 | P2/11 | 32 (RX) |
| nRF UART RX | P1.05 | P2/4 | 33 (TX) |
| I2C SDA | P1.02 | P2/27 | 21 |
| I2C SCL | P1.03 | P2/25 | 22 |
| SPI clock | P0.08 | P2/22 | 18 |
| SPI MOSI | P0.09 | P2/17 | 23 |
| SPI MISO | P0.10 | P2/18 | 19 |
| SPI CS | P0.11 | P2/15 | 4 |
| ADC AIN0 | P0.04 | P3/26 | 25 (DAC1) |
| ADC AIN1 | P0.05 | P3/18 | 26 (DAC2) |
| Ground | GND | P2/28 | GND |

Both boards use 3.3 V I/O and share ground. Power them separately over USB;
do not connect their supply outputs. The present rig has no external I2C
pull-ups. Future I2C tests must use internal pulls and a low clock rate;
high-speed I2C qualification is deferred. The wiring check itself uses static
levels, not UART/I2C/SPI transactions.

`wiring.toit` defines the signal order for both the ESP32 program and host
script. Each direction checks all-low, all-high, walking-one, and walking-zero
patterns using only weak pulls. If every digital pattern passes, the ESP32
drives complementary DAC levels from 0 to 3 V and the nRF samples both ADC
inputs. The analog tolerance is 200 mV: this is a wiring check, not a precision
calibration.

## Running

Use a Toit compiler and ESP32 firmware envelope of the same version. The
initial fixture used Toit v2.0.0-alpha.199 from Jaguar v1.72.0. Set `ENVELOPE`
to the matching ESP32 envelope, and set `ESP_SERIAL` to the persistent path
after identifying the intended board. This rig's ESP32 is:

```
/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_42af3f3035faea118ecb4c185fbcde76-if00-port0
```

From the repository root:

```sh
mkdir -p build/nrf5340-wiring
toit analyze tests/hw/nrf5340/wiring-esp32.toit
toit compile -s -o build/nrf5340-wiring/wiring-esp32.snapshot tests/hw/nrf5340/wiring-esp32.toit
toit tool firmware -e "$ENVELOPE" container install wiring-fixture build/nrf5340-wiring/wiring-esp32.snapshot -o build/nrf5340-wiring/esp32.envelope
toit tool firmware -e build/nrf5340-wiring/esp32.envelope flash --port "$ESP_SERIAL" --baud 460800
```

If the system esptool installation is incomplete, set `ESPTOOL_PATH` to the
standalone esptool included in the matching Jaguar SDK.

Connect the FT2232H adapter's AD0 to SWDCLK, AD1 through 470 ohms to SWDIO,
AD2 directly to SWDIO, and GND to GND. The configuration assumes one FT2232H
adapter is attached. Start OpenOCD in another terminal:

```sh
openocd -f tests/hw/nrf5340/wiring-swd.cfg
```

With Python and pyserial installed, run:

```sh
python tests/hw/nrf5340/check-wiring.py --serial "$ESP_SERIAL" --report build/nrf5340-wiring/results.json
```

The script halts the application core during checks, restores the tested pin
configuration and modified ADC configuration/RAM, and resumes the core if it
was running. It refuses to borrow an active SAADC. Use this on the development
rig with these pins available, not alongside application or network-core code
that actively uses them. Cleanup requires both debug and serial links to remain
connected. The ESP32 fixture is left with all test pins as inputs without pulls.

Register definitions follow Nordic's
[nRF5340 application header](https://github.com/NordicSemiconductor/nrfx/blob/v3.0.0/mdk/nrf5340_application.h)
and pin/header assignments follow the
[Ebyte board schematic](https://www.cdebyte.com/pdf-down.aspx?id=2622).


## Paired Toit GPIO test

For a repeatable run of all wired peripheral suites, build the default envelope
with `tools/zephyr/check-build.sh` and use `check-peripherals.py`. It packages
GPIO, UART, UART flow control, I2C, long I2C reads, SPI, ADC, and PWM against the
same native firmware. The ESP32 must already run the current wired fixture and
both serial paths must identify the intended boards. Use a new log directory
for each run, and supply a known normal application binary for restoration:

```sh
python3 -u tests/hw/nrf5340/check-peripherals.py \
  --toit build/zephyr-check/host/sdk/bin/toit \
  --envelope build/zephyr-check/default/toit.envelope \
  --log-dir build/nrf5340-peripheral-qualification \
  --restore-image build/nrf5340-settings/system-only.bin \
  --esp-serial "$ESP_SERIAL" --nrf-serial "$NRF_SERIAL"
```

The runner removes other bundled applications before installing each test,
requires its PASS marker, VM teardown, and electrical pin-release checks, then
restores the supplied application even if a suite fails. It reads settings and
Toit storage before and after the run and fails on any difference. It never
rewrites those partitions to hide a mismatch. `summary.json` records each
suite's result, fixture request count, input hashes, and restoration outcome.
The ESP32 firmware and network controller are left unchanged. The checks use
100 kHz I2C with internal pull-ups; ADC tolerances measure relative behavior
against the ESP32 DACs, not calibrated accuracy.

Use `--prepare-only` to validate compilation and packaging without hardware;
omit the serial and restoration arguments in that mode. `--tests gpio uart`
selects a subset. A prepared-only result is not a hardware pass. The individual
test commands below remain useful when diagnosing a particular driver.

`gpio-nrf5340.toit` exercises the Zephyr-backed Toit GPIO API. It uses P1.00
(number 32) as the main signal, P1.01 (33) for acknowledgements, and P0.08 (8)
for a second-controller interrupt check. It also checks input pulls and output
levels on every other wired pin. Pin numbering is `32 * port + pin`.

Install the current `wiring-esp32.toit` in the ESP32 envelope using the commands
above. The additional CONFIG and PULSE commands drive outputs; the initial
wiring test must have passed first. Then configure the nRF build from
[the port instructions](../../../docs/nrf5340.md):

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/gpio-nrf5340.toit"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0
```

The runner flashes and verifies the nRF, handles numbered fixture commands,
checks the ESP32's observed levels, and requires both the Toit PASS marker and
VM teardown. It also verifies that an output left open by the process stops
driving high after teardown. Logs are in `build/nrf5340-gpio` and the ESP32 is
returned to inputs without pulls afterward.

The test checks restricted/invalid/duplicate pin errors, pull changes,
push-pull and open-drain output, 50 pulses at 50 Hz and 250 Hz, quiet-line
timeouts, simultaneous waiters, cancellation, close while waiting, repeated
close/reopen, close under pulse traffic, both GPIO controllers, and all wired
signals. These tests exercise real Toit resources; the earlier SWD wiring
checks remain useful for isolating connection problems.


## Paired Toit UART test

The updated `wiring-esp32.toit` fixture supports UART echo, baud changes, and
scheduled transfers. Install it using the envelope commands above. The test
uses P1.04/P1.05 (36/37) against ESP32 GPIO32/33, then alternates with
P0.08/P0.09 (8/9) against ESP32 GPIO18/23. These alternate pins are already
wired for SPI; no physical rewiring is needed. P1.01 remains the handshake pin.

With the Zephyr build environment exported:

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/uart-nrf5340.toit"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --expect 'NRF5340 UART PASS' --release-pin 32 --seconds 90 \
  --log-dir build/nrf5340-uart
```

Coverage includes binary patterns crossing DMA boundaries, concurrent sending
and receiving, a 16385-byte transfer, baud changes from 9600 through 1000000,
even parity, invalid configuration rollback, ownership conflicts, 64 pin-remap
cycles, receive-only and transmit-only ports, read cancellation, closing a
waiting reader, deliberate receive overflow and recovery, both software buffer
sizes, close during RX/TX traffic, and release of an unclosed UART at process
exit. The runner checks TX release electrically using the ESP32's weak pull-down.
The separate flow-control suite below tests RTS/CTS.

### UART hardware flow control

`uart-flow-nrf5340.toit` keeps TX/RX on 36/37 and uses the existing SPI wires
for nRF RTS8 → ESP CTS18 and nRF CTS9 ← ESP RTS23. Install the fixture with
`UART_FLOW_OPEN` support. In its first phase, the ESP drives CTS as a GPIO to
prove that nRF transmission stops and resumes. The next phase enables both
hardware handshakes and sends 32768 bytes while the Toit reader sleeps for two
seconds. It checks both receive-buffer sizes at 115200 and 1000000 baud,
reconfiguration while paused, exact byte order, zero errors and subsequent
reuse. It also closes a paused receiver and a CTS-blocked transmitter, then
leaves blocked TX active for VM teardown. The host checks RTS release.

Compile a snapshot with the matching local SDK and install it into the normal
Zephyr envelope, then extract it to `build/nrf5340-uart-flow/extended.bin`:

```sh
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/nrf5340-uart-flow/extended.bin \
  --expect 'NRF5340 UART FLOW PASS' --release-pin 18 --seconds 60 \
  --log-dir build/nrf5340-uart-flow/extended
```

Before the driver fix, CTS worked but the first delayed-reader case reported
16896 dropped bytes (`build/nrf5340-uart-flow/before.log`). The expanded suite
passed all 35 requests after the fix (`extended.log` in the same directory).
The receiver now withholds DMA buffers when ring space is insufficient,
allowing hardware RTS to stop the sender; a Toit read schedules reception to
restart once space is available. UART modes without flow control retain their
existing overflow behavior. The complete existing UART regression also passed
all 316 requests against the new driver (`regression.log` in the same directory).
The original application was then restored, all 1 MiB of application flash
(including persistent storage) and UICR matched the backup, and the application
was resumed. The fixture is IDLE and network firmware was untouched. The final
checkpoint and new normal/BLE firmware hashes are in
`build/nrf5340-uart-flow/final.json`.

## Console input

`stdio-nrf5340.toit` tests `io.stdin` over the board's USB-TTL connector. The
ESP32 keeps the wired fixture installed; no rewiring is needed. The test covers
29 binary transfers, all byte values, 16385-byte continuous input, sixteen
container reopen cycles, competing readers, cancellation and VM scheduling,
overflow/recovery, concurrent UART echo, and teardown with a blocked reader.
The native ring remains 4 KiB. DMA receives in 256-byte blocks with a 1 ms idle
timeout; TIMER1 serves the console and TIMER0 serves the application UART.

Build a system-only normal envelope, then package and flash the test:

```sh
mkdir -p build/nrf5340-stdio
build/host/sdk/bin/toit compile -s -o build/nrf5340-stdio/test.snapshot \
  tests/hw/nrf5340/stdio-nrf5340.toit
build/host/sdk/bin/toit tool firmware -e build/zephyr-nrf5340/toit.envelope \
  container install stdin-test build/nrf5340-stdio/test.snapshot \
  -o build/nrf5340-stdio/test.envelope
build/host/sdk/bin/toit tool firmware -e build/nrf5340-stdio/test.envelope \
  extract -o build/nrf5340-stdio/test.bin
python3 tools/nrf5340/flash.py build/nrf5340-stdio/test.bin \
  --serial "$NRF_SERIAL" --log-dir build/nrf5340-stdio/flash --seconds 1 \
  --expect '[toit] Zephyr VM starting'
python3 tests/hw/nrf5340/check-stdio.py \
  --serial "$NRF_SERIAL" --esp-serial "$ESP_SERIAL" \
  --log-dir build/nrf5340-stdio/hardware
```

The runner resets the flashed image after attaching its console. It supplies
binary data in response to target requests and verifies every transfer marker,
two distinct shared-reader results, the expected overflow error, concurrent
UART completion, and final VM teardown. It returns the ESP32 fixture to IDLE.
The complete DMA suite passed (`build/nrf5340-stdio/final-hardware.log`), as did
the existing 316-request UART regression (`uart.log`). The earlier single-byte
IRQ implementation failed the long transfer due to software-ring overflow;
its diagnostic evidence is retained in `diagnostic-hardware.log`.

`stdio-power-nrf5340.toit` wraps the existing power suite with a blocked stdin
reader on every boot. Package it into the normal envelope and use the power
suite's runner options below, including both GPIO wake rules. It must report
`STDIN POWER reader waiting` on all four boots and the normal power pass marker.
`stdio-ble-nrf5340.toit` runs the same input suite with an advertiser active;
package it using the BLE-enabled envelope and use `check-stdio.py` unchanged.
The latter checks coexistence and cleanup, not peer reception or GATT traffic.
Both variants passed: the power wrapper completed four boots and 40 fixture
requests (`build/nrf5340-stdio/power.log`), and the BLE wrapper completed all
29 input transfers and final teardown (`ble-hardware.log`). The two host stdio
regressions also pass (`host-stdio.log`). After testing, restore the normal
system-only image, `build/nrf5340-stdio/system-only.bin`. This build is 512000
bytes with 105576 bytes of static RAM; the BLE build is 593920 bytes with
123992 bytes of static RAM. The 4 KiB stdin ring is allocated dynamically.

## Native UART pin lifecycle probe

This separate build isolates routing and release from the Toit UART resource.
It transmits two bytes, checks TX idle levels through the ESP32,
then suspends and remaps UART1 between P1.04/P1.05 and P0.08/P0.09. It does not
decode the transmitted bytes or test RX yet.

With the Zephyr environment from the port instructions exported:

```sh
cmake -S toolchains/zephyr -B build/zephyr-uart-lifecycle -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_BUILD_VM=OFF \
  -DTOIT_ZEPHYR_NATIVE_SOURCE="$PWD/tests/hw/nrf5340/uart-lifecycle.c" \
  -DDTC_OVERLAY_FILE="$PWD/tests/hw/nrf5340/uart-lifecycle.overlay" \
  -DEXTRA_CONF_FILE="$PWD/tests/hw/nrf5340/uart-lifecycle.conf" \
  -DTOIT_ZEPHYR_NATIVE_DEFINITIONS=
cmake --build build/zephyr-uart-lifecycle -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/zephyr-uart-lifecycle/zephyr/zephyr.bin \
  --log-dir build/nrf5340-uart-pm --native --release-pin 32 \
  --expect 'NRF5340 UART LIFECYCLE PASS'
```

The suspend/resume test passed 64 cycles. To reproduce the driver resource
exhaustion found during bring-up, configure
`-DTOIT_ZEPHYR_NATIVE_DEFINITIONS=PROBE_DEINIT` and rebuild. That variant adds
`device_deinit` after suspension and uses `device_init` to reopen. With Zephyr
v4.4.1's default enhanced polling TX, it failed with `-ENOMEM` at cycle 29.
This is a diagnostic variant, not the intended port lifecycle.

## Paired Toit I2C test

Install the current ESP32 fixture, which adds I2C target commands. The primary
bus is P1.02/P1.03 (34/35) against ESP32 GPIO21/22. Remap tests use the existing
SPI wires P0.08/P0.09 (8/9) against ESP32 GPIO18/23. Both boards enable internal
pull-ups; the test explicitly requests 100 kHz. Higher speeds are deferred.

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/i2c-nrf5340.toit"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --expect 'NRF5340 I2C PASS' --release-pin 21 --seconds 120 \
  --cleanup-command 'I2C_CHECK 1024' --cleanup-command I2C_CLOSE \
  --log-dir build/nrf5340-i2c
```

Coverage includes address-only probes, scanning, NACKs, reads, writes through
4096 bytes, repeated START, pin/controller conflicts, the VM remaining runnable
during DMA, simultaneous UART traffic, cancellation, a held-low clock and
subsequent recovery, 64 close/remap cycles, and process exit during a transfer.
The cleanup commands verify the last payload after VM teardown and close the
ESP32 target before checking SDA release. The original ESP32's default-response
limit restricts read payload coverage to 32 bytes. Each read gets a fresh
target to avoid leftover prefetched response bytes.

The separate `i2c-read-nrf5340.toit` suite uses `I2C_QUEUE` to preload a complete
response into the ESP32's native send buffer. It passed reads and repeated
START at lengths 1, 31, 32, 33, 255, 256, 257, 1024 and 4096, checks that a
shorter read leaves the tail of the destination buffer untouched, and confirms
that another VM task runs during a long DMA read. Cancelling a read leaves the
destination unchanged and allows a subsequent operation. Each transaction
uses a fresh target so prefetched response bytes cannot contaminate the next
case. The suite passed 51 fixture requests at 100 kHz using internal pull-ups;
the host also checked SDA release after VM teardown and returned the fixture
to IDLE. Evidence: `build/nrf5340-i2c-read/paired-no-ram-backup.log`.

With the normal Zephyr envelope built and the updated ESP32 fixture installed,
compile, package and run the test:

```sh
mkdir -p build/nrf5340-i2c-read
build/host/sdk/bin/toit compile -s -o build/nrf5340-i2c-read/read.snapshot \
  tests/hw/nrf5340/i2c-read-nrf5340.toit
build/host/sdk/bin/toit tool firmware -e build/zephyr-nrf5340/toit.envelope \
  container install i2c-read build/nrf5340-i2c-read/read.snapshot \
  -o build/nrf5340-i2c-read/read.envelope
build/host/sdk/bin/toit tool firmware -e build/nrf5340-i2c-read/read.envelope \
  extract -o build/nrf5340-i2c-read/read.bin
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/nrf5340-i2c-read/read.bin \
  --expect 'NRF5340 I2C READ PASS' --release-pin 21 --seconds 90 \
  --log-dir build/nrf5340-i2c-read/paired
```

The first programming attempt stalled in FTDI MPSSE and timed out before the
test ran. Reset-and-flash now explicitly discards the old VM's RAM, avoiding
OpenOCD's 8 KiB flash-loader work-area backup read. The retry programmed and
verified successfully. Live deployment inspection still preserves work-area
RAM because it can resume the existing VM. No USB reset was used.
Afterward, the original application was restored and all 1 MiB of application
flash, including the persistent-storage partition, matched its backup. UICR
and all empty key slots also passed rechecking. The application was resumed;
network firmware was untouched. See `build/nrf5340-i2c-read/final.json`.

The native `i2c-lifecycle.c` probe isolates the Zephyr driver from Toit:

```sh
cmake -S toolchains/zephyr -B build/zephyr-i2c-lifecycle -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_BUILD_VM=OFF \
  -DTOIT_ZEPHYR_NATIVE_SOURCE="$PWD/tests/hw/nrf5340/i2c-lifecycle.c" \
  -DEXTRA_CONF_FILE="$PWD/tests/hw/nrf5340/i2c-lifecycle.conf"
cmake --build build/zephyr-i2c-lifecycle -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/zephyr-i2c-lifecycle/zephyr/zephyr.bin \
  --native --expect 'NRF5340 I2C LIFECYCLE PASS' --release-pin 21 --seconds 90 \
  --log-dir build/nrf5340-i2c-lifecycle
```

## Paired Toit SPI test

Install the current ESP32 fixture, which adds SPI target commands. The primary
bus uses P0.08/P0.09/P0.10/P0.11 (clock/MOSI/MISO/CS) against ESP32
GPIO18/23/19/4. Remap tests use P1.04/P1.05/P1.02/P1.03 against ESP32
GPIO32/33/21/22. No physical rewiring is needed.

Run `tools/zephyr/setup.sh` to apply the runtime chip-select patch described in
the port instructions, then build with the Zephyr environment exported:

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/spi-nrf5340.toit"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --expect 'NRF5340 SPI PASS' --release-pin 4 --seconds 120 \
  --cleanup-command SPI_CHECK --log-dir build/nrf5340-spi
```

The suite passed 487 fixture requests. It covers all four modes, 125 kHz through
4 MHz, slices, command/address prefixes, DC, held CS, reservation exceptions,
alternating devices, manual CS, transmit-only and receive-only buses, 4096-byte
DMA transfers with concurrent Toit tasks, cancellation recovery, 64 close/remap
cycles, and process exit during a transfer. The cleanup command verifies the
last payload after VM teardown before checking CS release electrically.

The current suite also covers 4088, 4092, 4096, 4100, 4104, and 8192-byte DMA
transfers in both directions. This expanded suite passed 511 fixture requests
in `build/nrf5340-acceptance/remaining/spi-run.log`.

The combined peripheral run exposed an ESP32 DMA receive issue: an exactly
4096-byte receive buffer lost its final four bytes. An ESP-IDF-only reproducer
also finds the loss with smaller buffers. The fix adjusts the hardware RX
limit and length accounting in [ESP-IDF](https://github.com/toitware/esp-idf/pull/138),
while leaving DMA buffer sizes unchanged. Use ESP32 firmware containing the
[dependency update](https://github.com/toitlang/toit/pull/3320). The fixture
requests the exact receive size and checks the returned length and every
payload byte, so it detects a regression without compensating for it. The fixed driver passed all 511 checks
with the unchanged nRF test image. Local evidence is in
`build/pr-stack/spi-idf-paired.log`; the original failure is recorded in
`build/nrf5340-acceptance/spi-diagnostic/`.

The original ESP32 uses non-DMA transfers for full duplex, limiting those tests
to 64 bytes. Larger tests use DMA separately in each direction. ESP32 receive
DMA tests use modes 0 or 2 and lengths divisible by four. These are fixture
constraints, not nRF buffer limits.

The native probe isolates Zephyr's SPI lifecycle from Toit and passed 384
fixture requests:

```sh
cmake -S toolchains/zephyr -B build/zephyr-spi-lifecycle -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_BUILD_VM=OFF \
  -DTOIT_ZEPHYR_NATIVE_SOURCE="$PWD/tests/hw/nrf5340/spi-lifecycle.c" \
  -DEXTRA_CONF_FILE="$PWD/tests/hw/nrf5340/spi-lifecycle.conf"
cmake --build build/zephyr-spi-lifecycle -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/zephyr-spi-lifecycle/zephyr/zephyr.bin \
  --native --expect 'NRF5340 SPI LIFECYCLE PASS' --release-pin 4 --seconds 90 \
  --log-dir build/nrf5340-spi-lifecycle
```

## Paired Toit ADC test

Install the current ESP32 fixture. `ADC_DAC` changes GPIO25/26 DAC voltages
without releasing the GPIO27 acknowledgement line. The existing wires connect
these DAC outputs to nRF P0.04/P0.05 (AIN0/AIN1). `READ` reports the remaining
GPIO pins while DACs are active; `WAIT` waits for a GPIO level for up to two
seconds. `IDLE` closes the DACs and returns all fixture signals to inputs.

With the Zephyr environment exported:

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/adc-nrf5340.toit"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --expect 'NRF5340 ADC PASS' --release-pin 13 --seconds 90 \
  --cleanup-command IDLE --log-dir build/nrf5340-adc
```

The ADC suite checks both input channels with a
seven-level staircase, raw values, all eight gains, maximum-voltage rounding
and saturation, sample counts crossing the 64-sample native chunk boundary,
concurrent reads, deadlines and task-cancellation recovery, 64
close/reacquire cycles, rejection of deprecated Pin arguments, and process cleanup.
A child leaves both ADCs open; the parent observes its pin ownership and then
reclaims both pins after the child exits. The final electrical release check
uses a separate GPIO output, since an ADC input does not drive the line.

These DACs are not calibrated voltage references: the test allows 200 mV
absolute error relative to the requested DAC voltage. It checks intermediate
steps against the measured endpoints within 80 mV, and compares gains on the
same physical input within 25 mV. Raw and averaged readings must agree within
20 mV. This validates wiring, scaling and lifecycle, not absolute ADC accuracy.
Only AIN0/AIN1 are electrically tested; the other six analog pins are mapped
from the Nordic pin specification.

The native probe tests the underlying driver independently:

```sh
cmake -S toolchains/zephyr -B build/zephyr-adc-lifecycle -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_BUILD_VM=OFF \
  -DTOIT_ZEPHYR_NATIVE_SOURCE="$PWD/tests/hw/nrf5340/adc-lifecycle.c"
cmake --build build/zephyr-adc-lifecycle -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/zephyr-adc-lifecycle/zephyr/zephyr.bin \
  --native --expect 'NRF5340 ADC LIFECYCLE PASS' --release-pin 13 --seconds 90 \
  --cleanup-command IDLE --log-dir build/nrf5340-adc-lifecycle
```

It passed 128 offset calibrations and 512 reads with counts of 1, 2, 17 and 64,
alternating AIN0/AIN1 across 64 voltage-pair changes. The longest 64-sample read
was 3875 microseconds. Calibration uses a separate single-sample sequence;
the data sequence then takes immediate samples with a zero interval.

## PWM

The backend exposes all four Nordic PWM controllers, each with four channels.
The host arithmetic test checks every supported integer frequency and duty
quantization, without accessing a device:

```sh
mkdir -p build/nrf5340-pwm
g++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  tests/hw/nrf5340/pwm-data-test.cc -o build/nrf5340-pwm/pwm-data-test
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  build/nrf5340-pwm/pwm-data-test
```

`pwm-nrf5340.toit` uses nRF pins 32, 36, 8 and 9, wired to ESP32 pins 13, 32,
18 and 23. Run it with those ESP32 pins configured as inputs, with
the wired fixture. It does not use the wired fixture's acknowledgement
protocol. It checks all four controllers independently, four channels on one
controller, resource exhaustion, failed-open rollback, clamping, frequency
changes, sixteen close/remap cycles, rejection of deprecated Pin arguments, child-process
cleanup, and active generators at VM teardown. The deliberate deprecated-Pin test
warnings during compilation are expected.

Waveform measurements use the separate paired fixture below. Check the final
four live outputs externally after VM teardown to verify release.

```sh
build/host/sdk/bin/toit compile -s -o build/nrf5340-pwm/test.snapshot \
  tests/hw/nrf5340/pwm-nrf5340.toit
build/host/sdk/bin/toit tool firmware -e build/zephyr-nrf5340/toit.envelope \
  container install pwm-test build/nrf5340-pwm/test.snapshot \
  -o build/nrf5340-pwm/test.envelope
build/host/sdk/bin/toit tool firmware -e build/nrf5340-pwm/test.envelope \
  extract -o build/nrf5340-pwm/test.bin
```

The snapshot, envelope and binary are prepared. The USB controller was recovered
by the user after it disconnected both the ESP32 and FTDI adapters. Require
`NRF5340 PWM PASS`, successful VM teardown, and independent pin-release checks
when running this suite.

`pwm-paired-nrf5340.toit` adds external measurements through the wired fixture.
Build `wiring-esp32.toit` with the current host SDK and install it into the
matching locally built ESP32 firmware; prepared output is
`build/nrf5340-pwm/esp-fixture.envelope`. The fixture's new PWM commands use PCNT
for frequency (two-second windows, 4..10000 Hz), polling for duty, and 20 MHz RMT
for static endpoints. RMT is armed before the nRF changes level, because an
already static input does not start a capture. Every endpoint cycle includes
the same armed sequence with a PWM train as a positive control. A static test
requires capture completion; timeout is a failure. A completed capture may
contain only a zero-duration idle terminator, as observed on this ESP32. The
test accepts at most two nonzero intervals and checks the final level against
the opposite pull resistor. The PWM-train control must produce multiple
intervals or remain busy until its deadline. `PWM_RELEASE` checks both
pull-down and pull-up, so a driven-low pin cannot pass as released. Raw frequency
counts, sampling totals and capture results appear in the host runner log.

After flashing the ESP32 fixture and packaging `pwm-paired-nrf5340.toit` as
`build/nrf5340-pwm/paired.bin`, run:

```sh
python3 -u tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" --nrf-serial "$NRF_SERIAL" \
  --image build/nrf5340-pwm/paired.bin \
  --log-dir build/nrf5340-pwm/paired-armed \
  --expect 'NRF5340 PWM PAIRED PASS' --seconds 180 \
  --cleanup-command 'PWM_RELEASE 13' --cleanup-command 'PWM_RELEASE 32' \
  --cleanup-command 'PWM_RELEASE 18' --cleanup-command 'PWM_RELEASE 23'
```

The paired suite measures all four independent controllers, shared-frequency
changes, duty ratios, channel reuse, and static endpoints. Endpoint checks use
RMT captures plus opposite-pull GPIO checks. Frequency measurements above
10 kHz and scheduler latency during low-frequency stops remain outstanding.

## Software reset and hardware watchdog

`reset-nrf5340.toit` uses three existing wires as an external phase counter:
ESP32 GPIO13/32/33 drive nRF P1.00/P1.04/P1.05. The ESP32 retains these levels
across nRF resets, so the test requires no flash writes or retained-RAM test
state. P1.01 remains the acknowledgement line. P0.08 against ESP32 GPIO18 is
used to verify output release during software reset and final VM teardown.

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/reset-nrf5340.toit"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --allow-reboots --expect 'NRF5340 RESET WATCHDOG PASS' \
  --release-pin 18 --seconds 60 --log-dir build/nrf5340-reset
```

The suite passed 16 fixture requests across five boots. It checks invalid
timeouts, 64 start/reconfigure/feed/stop cycles, an orderly software reset,
stable cached reset causes, feeding for longer than the original timeout,
waiting beyond a stopped watchdog's deadline, and watchdog expiry during
sleep, a non-yielding Toit loop, and VM shutdown. Watchdog resets must not
retain the previous software-reset flag. The final boot also reopens/stops
the watchdog and completes normal VM teardown.

The runner's `--allow-reboots` resets its handshake counter at each boot marker
and initializes the three phase outputs. The flasher's `--stop-after-expected`
keeps capturing intermediate VM teardowns until the final PASS marker has
appeared. This avoids mistaking the first software-reset teardown for test
completion.

The separate native probe verifies recovery when interrupts cannot run:

```sh
cmake -S toolchains/zephyr -B build/zephyr-watchdog-hang -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_BUILD_VM=OFF \
  -DTOIT_ZEPHYR_NATIVE_SOURCE="$PWD/tests/hw/nrf5340/watchdog-hang.c"
cmake --build build/zephyr-watchdog-hang -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/zephyr-watchdog-hang/zephyr/zephyr.bin \
  --native --allow-reboots --boot-marker 'NRF5340 WATCHDOG PROBE BOOT' \
  --expect 'NRF5340 WATCHDOG IRQ-OFF PASS' --release-pin 18 --seconds 30 \
  --log-dir build/nrf5340-watchdog-hang
```

This probe passed two boots: it arms a 500 ms watchdog, disables interrupts,
spins, then verifies the watchdog reset cause on the next boot.

## Persistent storage and interrupted writes

The storage tests use the existing phase/acknowledgement wires. The ESP32
retains test phase across nRF resets; no rewiring or fixture reflash is needed.
They create named test buckets and regions in the reserved storage partition.
Run the API suite first, then the recovery suite: the latter deliberately
reads the former's persistent values after flashing a different program.

With the Zephyr build environment exported:

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/storage-nrf5340.toit"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --allow-reboots --expect 'NRF5340 STORAGE PASS' \
  --release-pin 18 --seconds 180 --log-dir build/nrf5340-storage

cmake -S toolchains/zephyr -B build/zephyr-nrf5340-storage-recovery -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/storage-recovery-nrf5340.toit"
cmake --build build/zephyr-nrf5340-storage-recovery -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/zephyr-nrf5340-storage-recovery/zephyr/zephyr.bin \
  --allow-reboots --expect 'NRF5340 STORAGE RECOVERY PASS' \
  --require-marker '[toit] recovering flash page' \
  --release-pin 18 --seconds 60 --log-dir build/nrf5340-storage-recovery
```

The API suite passed two boots/two fixture requests: RAM/flash bucket APIs,
large values, alias cache sharing, child-process access, raw region APIs,
unaligned and page-boundary writes, repeated bit clearing, preservation of
neighboring bytes, read-only/bounds checks, capacity exhaustion/reclamation,
and readback after software reset. It retains an 8192-byte raw region and
8197/5003-byte bucket values for the recovery suite.

The recovery suite passed four boots/seven fixture requests. Watchdog resets
at 100, 250 and 400 ms interrupt a roughly 466 ms dense-page rewrite. Every
restart checks all 4096 bytes against the expected old or new page, plus the
unrelated persistent values. The runner requires an explicit boot recovery
message so a test cannot pass solely through already-completed writes. These
timings are for this nRF5340 board/build; requalify them when changing flash
drivers or clock settings. Physical power loss is not tested.

Both suites require normal final VM teardown and check that the final GPIO
output is released. Their logs and verified images are saved under
`build/nrf5340-storage` and `build/nrf5340-storage-recovery`. See
[the port notes](../../../docs/nrf5340.md#persistent-storage) for partition
bounds, journal semantics, latency and wear limitations.

## Persistent Zephyr settings

The board reserves `0xdc000`–`0xdffff` (16 KiB) for Zephyr settings, followed
by the unchanged 128 KiB Toit storage partition. Firmware must fit below
`0xdc000`. `toolchains/zephyr/settings.conf` selects NVS with four 4 KiB
sectors and data CRCs. The normal firmware reserves this area without
enabling the settings subsystem.

With the Zephyr environment from the build instructions:

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340-settings -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DEXTRA_CONF_FILE=settings.conf \
  -DTOIT_ZEPHYR_STARTUP_TEST="$PWD/tests/hw/nrf5340/settings-native.c" \
  -DTOIT_ZEPHYR_PROGRAM=
cmake --build build/zephyr-nrf5340-settings --target toit_envelope -j8
python3 tests/hw/nrf5340/check-settings.py \
  --image build/zephyr-nrf5340-settings/zephyr/zephyr.bin \
  --serial "$NRF_SERIAL" --log-dir build/nrf5340-settings/check
```

The runner requires a new output directory so retries cannot overwrite
backups. It backs up both persistent regions, performs 256 verified updates
of a 512-byte value (forcing NVS collection), tests value and deletion
persistence across two resets, then reflashes the same firmware to verify
that the remaining guard value survives. Only its own
`toit-nrf-qualification` settings keys are deleted. The entire Toit storage
partition must remain byte-for-byte unchanged. This does not inject a
physical power loss or exercise Bluetooth pairing.

The runner defaults to a 250 kHz SWD clock and short, paced reads because
this rig intermittently stalls on sustained FTDI transfers. The general
flash tool also accepts `--adapter-speed 250`; its default remains 1000 kHz.
A timeout is a failed operation, never a passing qualification.

For the optional persistent Bluetooth configuration, append
`bluetooth.conf;settings.conf;bluetooth-security.conf`, use the Bluetooth
overlay, and first run `ble-nrf5340.toit` without a native startup probe. This
seeds the GAP name `Toit nRF5340 test`. Then rebuild with
`TOIT_ZEPHYR_PROGRAM` set to `ble-settings-nrf5340.toit` and
`TOIT_ZEPHYR_STARTUP_TEST` set to `ble-settings-native.c`, and flash again.
The native probe reads the saved name before enabling Bluetooth, then checks
that the live host restores it. The new Toit program never sets the GAP name.
Require `NRF5340 BT STORED NAME PASS`, `NRF5340 BT RESTORED NAME PASS`,
all sixteen `BLE settings reopen` cycles, `NRF5340 BLE SETTINGS PASS`, and VM
teardown. The factory identity supplied by this controller does not require
a `bt/id` record; its absence is not a persistence failure.
The adapter worker loads and commits the `bt` subtree before reporting
readiness on every open. The configuration
uses the shared PSA provider and Secure Connections pairing. Bonding is enabled
per connection when Toit requests `connect --secure`. It does not enable SMP
debug logging or self-tests.

## Container installation and lifecycle

The Zephyr build now bundles the system image and application separately.
`containers-nrf5340.toit` exercises the real container service from an
unprivileged application. Its worker image is carried as an asset so the test
can stream it into the writable registry without modifying native firmware.

```sh
python3 tests/hw/nrf5340/prepare-container-test.py
cmake -S toolchains/zephyr -B build/zephyr-nrf5340 \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/containers-nrf5340.toit" \
  -DTOIT_ZEPHYR_PROGRAM_ASSETS="$PWD/build/nrf5340-containers/controller.assets"
cmake --build build/zephyr-nrf5340 -j4
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --allow-reboots --expect 'NRF5340 CONTAINERS PASS' \
  --release-pin 18 --seconds 180 --log-dir build/nrf5340-containers
```

The suite passed two boots/eight fixture requests. It covers:

- Shared container discovery, start/wait and background event tests.
- Rejection of privileged flash primitives from the application.
- Eight abandoned uploads and an incomplete commit, followed by successful
  installation with 1/7/131/132/133/511/1024-byte writes crossing relocation
  chunk boundaries. The relocated worker and assets occupy 57,344 bytes.
- Worker assets spanning two flash pages, argument transfer, a nonzero exit
  status, and continued operation of the controller.
- Stopping a worker and its child while both own GPIOs, then reclaiming the
  GPIOs and an unclosed storage region. The ESP32 observes both released pins.
- Uninstall/reinstall with the boot flag, software reset, automatic startup,
  explicit startup after reset, and final uninstall/VM teardown.

The worker and controller use the `nrf-containers` bucket and
`nrf-container-held` region. The test does not erase the storage partition.
Logs, generated inputs and the tested firmware are in
`build/nrf5340-containers`. This test supplies the upload through an embedded
asset; PC-side SWD deployment and firmware envelopes are covered below.
When configuring another test, clear the cached asset setting with
`-DTOIT_ZEPHYR_PROGRAM_ASSETS=`.

The storage and reset/watchdog suites were rerun with this boot path and
passed two and five boots respectively. Their regression logs and images are
in `build/nrf5340-container-storage` and `build/nrf5340-container-reset`.

## PC-side deployment

Flash a system-only firmware using [the deployment instructions](../../../docs/nrf5340.md#deploying-applications-from-the-pc),
then run the host and hardware tests:

```sh
python3 tests/hw/nrf5340/test-deploy.py
python3 -u tests/hw/nrf5340/check-deploy.py \
  --firmware build/nrf5340-deploy/base.bin \
  --serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0
```

The hardware runner builds two versions of `deploy-nrf5340.toit` and a larger
image for the capacity check. It uses the `nrf-deploy` bucket and 8192-byte
region, which it retains between versions/runs. It removes only its own test
program IDs before rerunning. The ESP32 fixture is not involved.

Coverage includes matching-firmware verification, SDK mismatch rejection
before contacting hardware, rejection of a different native firmware,
interruption after programming the body but before committing the header,
listing without resuming an intentionally halted core, installation and boot,
idempotent installation, rejecting changed flags and insufficient space,
uninstall/idempotent uninstall, and running a second version with the same
persistent data. Every successful SWD operation verifies the firmware and
checks the storage partition against the expected changed range. The final
check compares unrelated allocations byte-for-byte with the initial snapshot.

The host tests cover relocation/asset bounds, preservation of data and foreign
programs, free-space selection, journal recovery gating, destination bounds,
CRC convention, broken-connection handling, and not restarting after a failed
write. Logs and generated inputs are kept under `build/nrf5340-deploy`.

Ten host tests passed. The hardware suite passed with two 53,248-byte installed
application images, preserving three unrelated allocations and the 507,060-byte
native firmware. Final logs are in `build/nrf5340-deploy/check-small-burst`.
The earlier `check` and `check-final` directories record FTDI stalls in the old
bulk-read path; they are not passing runs. The final run uses 256-byte requests
and had no stall warnings. Eight prior consecutive full-partition reads also
passed using that request size (`build/nrf5340-deploy/read-stress`).

## Zephyr firmware envelopes

Build the host SDK tools, then build a system-only Zephyr firmware with the
`toit_envelope` target described in `docs/nrf5340.md`. The following host checks
prepare two binaries without accessing hardware:

```sh
build/host/sdk/bin/toit run tests/zephyr-firmware-test.toit
python3 tests/hw/nrf5340/prepare-envelope-test.py \
  --firmware build/zephyr-nrf5340/zephyr/zephyr.bin \
  --system-snapshot build/zephyr-nrf5340/boot.snapshot
```

The unit test covers descriptor and extension corruption, truncated and
oversized images, nonzero flash load addresses, relocations outside the program,
asset bounds, duplicate IDs, and growth/shrinkage without changing native bytes.
The CLI test creates, inspects and modifies an envelope; extracts a snapshot
with separate assets and a precompiled image with inline assets; checks SDK,
capacity, conflicting-assets and missing-system rejection; and verifies that
removing the applications restores the system-only binary. Failed extraction
must leave an existing output file unchanged.

Flash the two variants using the board's identified persistent console path:

```sh
python3 tools/nrf5340/flash.py build/nrf5340-envelope/snapshot.bin \
  --serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --log-dir build/nrf5340-envelope/flash-snapshot \
  --expect 'NRF5340 ENVELOPE snapshot PASS' \
  --stop-after '[toit] VM teardown complete' --seconds 30
python3 tools/nrf5340/flash.py build/nrf5340-envelope/image.bin \
  --serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --log-dir build/nrf5340-envelope/flash-image \
  --expect 'NRF5340 ENVELOPE image PASS' \
  --stop-after '[toit] VM teardown complete' --seconds 30
```

Each variant must print one `NRF5340 TOIT PASS` line, its envelope PASS line,
and `VM exited: reason=1 value=0`. The auto-started `probe` checks its 5003-byte
asset pattern, name and noncritical boot flag. It then explicitly starts the
`worker`, whose boot flag is disabled, and waits for its VM smoke test. No ESP32
fixture or GPIO wiring is needed for this test.

## Critical-container lifecycle

`lifecycle-nrf5340.toit` tests the VM's error-restart policy with two envelope
variants, using the existing ESP32 fixture. Build the system-only firmware with
the latest `toolchains/zephyr/main.cc`, then prepare the variants:

```sh
python3 tests/hw/nrf5340/prepare-lifecycle-test.py \
  --firmware build/zephyr-nrf5340/zephyr/zephyr.bin \
  --system-snapshot build/zephyr-nrf5340/boot.snapshot
```

Run `exit.bin` with `--expected-vm-error 23` and `throw.bin` with
`--expected-vm-error 1`. For example:

```sh
python3 -u tests/hw/nrf5340/check-gpio.py \
  --esp-serial /dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_42af3f3035faea118ecb4c185fbcde76-if00-port0 \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/nrf5340-lifecycle/exit.bin \
  --log-dir build/nrf5340-lifecycle/exit \
  --allow-reboots --expected-vm-error 23 \
  --error-release-pin 26 --error-release-pin 32 --error-release-pin 4 \
  --release-pin 26 --seconds 30 \
  --require-marker 'LIFECYCLE ordinary errors, critical success/stop and resource reuse PASS' \
  --require-marker 'LIFECYCLE pending I2C, UART child, SPI and ADC ready' \
  --expect 'NRF5340 LIFECYCLE exit PASS'
```

For the exception variant, change the image, log directory and PASS marker to
`throw`, and the expected VM error to 1. Unexpected errors remain fatal to the
runner. Expected errors must occur in order and must be followed by teardown,
the restart-delay marker, and a recovery boot. The host checks a minimum 700 ms
between receiving the delay marker and the next boot marker, allowing for
console and fixture-command latency around the firmware's one-second delay.

On the first boot, a successful critical exit, two ordinary errors (explicit
exit and uncaught exception), and explicitly stopping a critical container must
leave the controller running. The controller reclaims the workers' GPIO/ADC
resources and remains alive longer than the error-restart delay. It then holds
SPI/ADC resources, starts a child waiting on UART RX with GPIO5 driven high,
and starts an I2C read while the fixture holds SCL low. A separate critical
worker exits with code 23 or throws an exception. The ESP32 checks that GPIO5,
UART TX, and SPI CS stop driving during teardown/backoff. After reset, the
controller verifies the software-reset flag and exercises UART loopback, I2C,
SPI, and ADC. Final VM completion must release GPIO5 again.

After testing, restore a system-only image and keep it as the SWD deployment
reference:

```sh
build/host/sdk/bin/toit tool firmware \
  --envelope=build/zephyr-nrf5340/toit.envelope extract \
  -o build/nrf5340-lifecycle/system-only.bin
python3 tools/nrf5340/flash.py build/nrf5340-lifecycle/system-only.bin \
  --serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --log-dir build/nrf5340-lifecycle/final-flash \
  --expect '[toit] reset cause=' --stop-after '[toit] reset cause='
```

## Native fault policy

The production port installs `k_sys_fatal_error_handler` when
`CONFIG_TOIT_REBOOT_ON_FATAL_ERROR=y` (the default). The following native test
exercises the same handler without adding a fault-injection API to Toit.
Use the Zephyr environment/toolchain setup from `docs/nrf5340.md`:

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340-fault -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_BUILD_VM=OFF \
  -DTOIT_ZEPHYR_NATIVE_SOURCE="$PWD/tests/hw/nrf5340/fault-native.c"
cmake --build build/zephyr-nrf5340-fault -j8
python3 tests/hw/nrf5340/check-fault.py \
  --esp-serial /dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_42af3f3035faea118ecb4c185fbcde76-if00-port0 \
  --nrf-serial /dev/serial/by-path/pci-0000:02:00.0-usb-0:2.3.3.3:1.0-port0 \
  --image build/zephyr-nrf5340-fault/zephyr/zephyr.bin \
  --log-dir build/nrf5340-fault/recovery
```

The six injected faults are a thread-context kernel panic, C `abort()`, an
undefined CPU instruction, a Zephyr assertion failure, a timer-ISR panic, and
an undefined instruction in that ISR. The test verifies actual interrupt
context before the ISR faults. The fixture stores the phase across resets and
checks that the GPIO8 output is released after each reboot. The verifier
requires phases 0 through 6 in order, six matching fault reasons, exactly seven
boots, software-reset flags, and 38 successful fixture requests. Undefined
instructions use Zephyr's ARM-specific reason 36; panic/assert/abort use 4.

To test the optional debugger policy, configure a separate build directory
with the same options and this additional overlay:

```sh
-DEXTRA_CONF_FILE="$PWD/tests/hw/nrf5340/fault-halt.conf"
```

Build it, then run `check-fault.py` with its binary, `--halt`, and `--elf` pointing
to the matching `zephyr.elf`. Use a separate log directory. The paired test
intentionally times out after the first panic; the wrapper then connects over
SWD and verifies that the PC lies inside `arch_system_halt` in that ELF. A
missing console response alone is insufficient. The paired log's missing-PASS
error is expected in this mode; `halt-check.log` records the final verdict.
The test leaves the core debugger-halted until the next flash/reset.

Both policies passed on the E83. Evidence is in `build/nrf5340-fault/recovery`
and `halt`, with `summary.log`, `paired.log`, console and flash logs. The first
run used an incorrect expected generic CPU-fault reason; it is preserved as
`first-run-wrong-reason.log`, separate from the passing run. The full VM ELF's
`symbols.log` and `fail-disassembly.log` under `vm` confirm that Toit's native
`fail()` calls Zephyr's `abort()` and links the production fatal handler.

After the tests, flash a normal VM image again. The system-only reference for
this milestone is `build/nrf5340-fault/system-only.bin`; the full VM smoke test
and final restore are recorded under `vm/retry` and `final-flash` respectively.
The initial full-VM flash hit an FTDI transfer timeout (`vm/run`). After the
process terminated, bounded SWD reads confirmed an incomplete firmware image
and unchanged persistent storage (`vm/readback`); the core remained halted
until the retry.
The final SWD check (`final.json`, `storage-check.log`) verified the restored
firmware and found all 131072 storage bytes unchanged, preserving five existing
allocations. The power-management milestone below supersedes this deployment
reference.

## System OFF GPIO wake and timed restart

`power-nrf5340.toit` tests argument validation, System OFF wake at both GPIO
levels, and a 750 ms timed `power.deep-sleep` followed by software reset.
It also checks `supports-timed-deep-sleep`, invalid durations and wake pins,
and configuring/disabling a wake source without disturbing its live GPIO.
The wake pin remains configured during the timed phase, but is held inactive,
so the timer must end that sleep. Each shutdown
has a pending I2C read (fixture SCL held low), a child blocked on UART RX, and an
open ADC. The wake pin is still owned by a GPIO resource until teardown. The
fixture checks released UART/GPIO outputs at each sleep marker and changes the
wake input after 500 ms. The fourth boot checks UART, I2C, SPI, and ADC again.
ESP32 GPIO32/33 retain the phase, so UART uses nRF8/9 instead of nRF36/37.

Use the system-only `toit.envelope` from the normal build, the existing ESP32
fixture, and the persistent serial paths above (`ESP_SERIAL` and `NRF_SERIAL`):

```sh
mkdir -p build/nrf5340-poweroff
cp build/zephyr-nrf5340/toit.envelope build/nrf5340-poweroff/power.envelope
build/host/sdk/bin/toit tool firmware -e build/nrf5340-poweroff/power.envelope \
  extract -o build/nrf5340-poweroff/system-only.bin
build/host/sdk/bin/toit compile -s -o build/nrf5340-poweroff/power.snapshot \
  tests/hw/nrf5340/power-nrf5340.toit
build/host/sdk/bin/toit tool firmware -e build/nrf5340-poweroff/power.envelope \
  container install power build/nrf5340-poweroff/power.snapshot
build/host/sdk/bin/toit tool firmware -e build/nrf5340-poweroff/power.envelope \
  extract -o build/nrf5340-poweroff/power.bin
python3 tests/hw/nrf5340/check-gpio.py \
  --esp-serial "$ESP_SERIAL" --nrf-serial "$NRF_SERIAL" \
  --image build/nrf5340-poweroff/power.bin \
  --log-dir build/nrf5340-poweroff/vm --allow-reboots --release-pin 19 \
  --sleep-release-pin 19 --sleep-release-pin 18 --min-sleep-ms 600 \
  --wake-on '[toit] System OFF wake-pin=32 active=1' 'CONFIG 13 OUT 1' \
  --wake-on '[toit] System OFF wake-pin=32 active=0' 'CONFIG 13 OUT 0' \
  --expect 'NRF5340 POWER PASS' --seconds 30 \
  --require-marker 'POWER validation and duration bounds PASS' \
  --require-marker 'POWER pending I2C, UART child and ADC ready phase=2'
```

For the edge-case variant, compile `power-edge-nrf5340.toit`, install it under
the same `power` name in a separate envelope, and extract `edge.bin`. Run the
same paired command with that binary, a separate log directory, and
`--expect 'NRF5340 POWER EDGE PASS'`. Omit both `--wake-on` options: the pin is
already active before shutdown. Add
`--require-marker '[toit] System ON sleep for 5000 ms'`. The final restart must
report watchdog reset instead of software reset. Its two-second timer starts
before teardown, and the requested sleep is five seconds.

The independent `poweroff-native.c` probe also passed both wake levels with
14 fixture requests and three boots (`native`, `native-paired.log`). Build it
using `TOIT_ZEPHYR_BUILD_VM=OFF` and `TOIT_ZEPHYR_NATIVE_SOURCE` as for the fault
probe. Its paired-run options are `--native --allow-reboots`,
`--boot-marker 'NRF5340 NATIVE POWEROFF BOOT'`,
`--expect 'NRF5340 NATIVE POWEROFF PASS'`, `--release-pin 18`, and wake rules
`'NATIVE POWEROFF entering wake-high=1' 'CONFIG 13 OUT 1'` and
`'NATIVE POWEROFF entering wake-high=0' 'CONFIG 13 OUT 0'`.

These tests do not measure current: an attached debugger can emulate System
OFF. The nRF5340 has no RTC wake from System OFF; the timed API uses System ON.
Reset-only power-off and the maximum 24-hour duration were validated as API
arguments, not exercised end to end. See `docs/nrf5340.md` for the distinction.

Restore `build/nrf5340-poweroff/system-only.bin` after testing, using `flash.py`
as above. The restored image is the deployment reference for this milestone.
The final SWD verification (`final.json`, `storage-check.log`) confirmed that
all 131072 persistent-storage bytes and five allocations match the preceding
fault milestone. The system-only image remains 503808 bytes (492 KiB).

## Ordinary two-core firmware updates

BLE-enabled CMake builds now include their matching network controller in the
Toit envelope. Format 1004 exports a three-file tar bundle; application-only
format 1003 continues to export a binary. The board flasher validates bundle
addresses, sizes, vectors, and SHA-256 hashes before opening hardware, then
programs and verifies both cores without recovery or a full-device erase.
See [firmware envelopes](../../../docs/nrf5340.md#firmware-envelopes) for commands.

Run the input and programming-failure tests without a board:

```sh
python3 tests/hw/nrf5340/test-flash.py
```

The nine tests include an actual OpenOCD Tcl interpreter with simulated target
commands. Injected probe, write, and verification failures must stop execution
before subsequent programming or restart. That test is skipped when the pinned
OpenOCD executable is unavailable. `tools/zephyr/check-build.sh` also runs
`test-envelope.py` against real default, BLE, and secure envelopes, checking
container edits, controller retention, hashes, and incompatible format rejection.

Hardware evidence is under `build/nrf5340-dual-core/`. Separate-image programming,
a manually prepared tar, and the automatically built tar each passed all sixteen
BLE adapter reopen cycles and VM teardown. The automatic run is recorded in
`automatic-qualification/flash.log` and `automatic-run.log`. After restoring the
normal application, `verify-after.log` confirms byte-for-byte preservation of
settings, Toit storage, and all 256 KiB of network flash compared with the initial
backups. The controller bytes written during these tests matched the originally
installed controller. `fixture.log` confirms the unchanged ESP32 wired fixture
responds and is idle. These tests do not qualify atomic updates or OTA.

## Standalone deep sleep and current measurement

These probes need only the nRF5340 board. They do not need the ESP32 fixture.
Current qualification additionally needs an instrument that resolves microamps;
a functional wake test or debugger register inspection does not establish
sleep current. The following tests have been prepared, not run on hardware
for the current changes.

### Prepare matching firmware

Build each program in a separate output directory using the same board and
configuration. Set up the host SDK and Zephyr environment as described in
[Build and run](../../../docs/nrf5340.md#build-and-run). Use the normal RC/LDO
configuration first:

```sh
cmake -S toolchains/zephyr -B build/nrf-current-timed -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_HOST="$PWD/build/host/sdk/bin/toit" \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/deep-sleep-current.toit"
cmake --build build/nrf-current-timed --target toit_envelope -j4

cmake -S toolchains/zephyr -B build/nrf-current-off -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_HOST="$PWD/build/host/sdk/bin/toit" \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/poweroff-current.toit"
cmake --build build/nrf-current-off --target toit_envelope -j4
```

Each build produces `toit.envelope` and `zephyr/zephyr.bin`. These firmware
images each contain exactly one probe; do not install both probes concurrently.
Save the currently installed application/envelope before replacing it.

For the low-current comparison, repeat the configure/build pairs with new
output directories and these extra CMake configure arguments:

```sh
-DEXTRA_CONF_FILE="$PWD/toolchains/zephyr/low-power.conf" \
-DDTC_OVERLAY_FILE="$PWD/toolchains/zephyr/low-power.overlay"
```

First verify that the board has the 32.768 kHz crystal and VREGMAIN DC/DC
inductor/capacitors. Do not assume that another module with the same SoC has
these components. In each generated `zephyr/.config`, check
`CONFIG_TICKLESS_KERNEL=y`, `CONFIG_PM_DEVICE=y`, and
`CONFIG_CLOCK_CONTROL_NRF_K32SRC_XTAL=y` for the low-current variant.
Its RC calibration option should be absent or disabled. In
`zephyr/zephyr.dts`, `vregmain` must have `regulator-initial-mode = <1>`.
For these application-only probes, `CONFIG_SOC_NRF53_CPUNET_ENABLE` and
Bluetooth must be disabled. Keep those generated files with the results.

### Verify behavior without a precision meter

1. Disconnect the paired fixture and anything attached to P1.00. Each probe
   drives P1.00 high for two seconds, then deliberately leaves it open for
   VM teardown. A weak external pull-down (for example 100 kohms) lets a meter
   or logic analyzer distinguish the driven high level from a released pin.
2. Flash the timed image using the existing board flash procedure. Capture
   console timestamps through the board's persistent serial path.
   Expect `POWER CURRENT entering timed 60 s deep sleep`,
   `VM teardown complete`, and `System ON sleep for 60000 ms`.
   P1.00 must fall after teardown and remain low throughout the wait.
3. Expect a fresh boot after approximately 60 seconds plus boot time.
   Subsequent boot messages must include the software-reset bit (0x2) and
   exclude the watchdog bit (0x10). Run at least three cycles. A missing
   crystal can prevent the low-current image from booting, so establish
   normal operation before attempting a current measurement.
4. Flash the untimed image. Expect `POWER CURRENT entering untimed deep sleep`
   and `System OFF wake-pin=-1`. P1.00 must be released. It must remain asleep
   for at least two minutes and boot again when the physical reset input is
   asserted. Timed restart is not expected for this image.
5. If the ESP32 fixture becomes available, run `power-nrf5340.toit` using the
   paired procedure above. This adds pending I2C, UART-child and ADC cleanup,
   GPIO wake, and recovery checks. Run `power-edge-nrf5340.toit` to check that
   an armed watchdog still interrupts timed deep sleep.

An attached debugger can emulate System OFF. Repeat functional reset/wake
checks with the debugger detached and a pin reset or power cycle before
accepting the untimed behavior.

### Measure when suitable equipment is available

1. Measure the module/SoC supply, excluding the USB-to-UART bridge, power LEDs,
   and debugger supply. Use the same supply voltage and temperature for both
   images. Ensure UART, SWD, fixture, and GPIO connections cannot back-power
   the target; disconnect them for the measurement. After programming,
   disconnect the debugger and apply a pin reset or power cycle.
2. Capture the timed probe for at least three complete cycles. Average a
   window well inside each 60-second sleep interval (for example seconds
   10-50); also record periodic spikes and integrated whole-cycle charge.
   Do not report only the minimum sample or include boot current in the
   steady-sleep average. Repeat with the untimed probe over matching windows.
3. Repeat for both the normal RC/LDO and verified crystal/DC/DC variants.
   Record the firmware commit, generated configuration, board revision,
   instrument, supply voltage, temperature, steady currents, and their ratio.
   A target of a few microamps and approximately 2x the untimed current is
   not a pass result until both absolute current and ratio have been measured.
4. If current is too high, check debugger release and board loads first, then
   console suspension, application CPU clock (64 MHz), GPIO-event latency
   (LowPower), network core forced off, and unused peripheral clocks.
   Periodic RC calibration should disappear in the crystal configuration.
   Kernel RAM remains powered during timed sleep and is an outstanding
   optimization if it prevents meeting the target.
5. Restore the saved application when finished. Keep functional logs separate
   from current traces; a pass in one does not imply a pass in the other.

### Timed pin wake and multiple wake sources

Build `tests/hw/nrf5340/timed-wake-nrf5340.toit` as the bundled program using
the same CMake commands above. This is a standalone test; disconnect the
ESP32 fixture and external loads from P1.00, P1.01, and P1.02.

1. Leave both wake inputs inactive (the probe pulls P1.00 down and P1.01 up).
   Expect a reboot after the 60-second sleep plus boot time.
2. On a subsequent cycle, drive P1.00 high after sleep entry. Expect an early
   reboot with the software-reset bit. Repeat by driving P1.01 low.
3. Hold either input active before sleep entry. Expect an immediate restart
   rather than a lost wake; release the input to avoid repeating the restart.
4. Toggle P1.02 in either direction during sleep. It was configured, replaced,
   then disabled, so it must not end sleep early.
5. Repeat the paired tests above to verify resource cleanup with the new
   configuration API. Those tests still cover untimed wake at both levels
   and watchdog expiry during timed sleep.

This procedure checks the new behavior; it has not yet been run on hardware.
Neither an attached debugger nor these GPIO tests qualify current consumption.
