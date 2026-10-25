# nRF5340 hardware fixtures

The initial wiring fixture checks the connections between an Ebyte E83-2G4M03S-TB and an
ESP32 DevKitC V4 before the nRF5340 Toit port is available. The ESP32 runs Toit;
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

The latest qualification is recorded in `build/nrf5340-acceptance/summary.json`:
all eight suites passed, totaling 1,563 fixture requests. The initial run passed
the first five suites and exposed the SPI capture issue described below. After
correcting the ESP32 fixture and expanding the SPI test, SPI, ADC, and PWM passed
in the `remaining` run. Both runs restored the normal nRF image and preserved
settings and Toit storage byte-for-byte. The result records the exact sources,
firmware hashes, and individual logs rather than treating the initial run as a
pass. Both 32-bit and 64-bit host suites also passed all 1,010 non-flaky tests.

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

The combined peripheral run exposed an ESP32 DMA receive boundary issue: an
exactly 4096-byte receive buffer returned four zero bytes starting at offset
4092. This is fixed in the ESP32 driver by reserving internal DMA headroom
([ESP32 SPI fix](https://github.com/toitlang/toit/pull/3320)). Use firmware
containing that fix for the ESP32 peer. The fixture requests the exact receive
size and checks the returned length and every payload byte, so it detects a
regression without compensating for it. The fixed driver passed all 511 checks
with the unchanged nRF test image. Local evidence is in
`build/pr-stack/spi-run.log`; the original failure is recorded in
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

The suite passed 21 fixture requests. It checks both input channels with a
seven-level staircase, raw values, all eight gains, maximum-voltage rounding
and saturation, sample counts crossing the 64-sample native chunk boundary,
concurrent reads, deadlines and task-cancellation recovery, 64
close/reacquire cycles, borrowed-pin compatibility, and process cleanup.
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

This passed (`build/nrf5340-pwm/data-test.log`). Both the normal and BLE builds
pass with PWM enabled (`build.log` and `ble-build.log` in the same directory).
These checks do not establish hardware operation, pin routing or cleanup.

`pwm-nrf5340.toit` uses nRF pins 32, 36, 8 and 9, wired to ESP32 pins 13, 32,
18 and 23. Run it with those ESP32 pins configured as inputs, for example with
the BLE peer fixture. It does not use the wired fixture's acknowledgement
protocol. It checks all four controllers independently, four channels on one
controller, resource exhaustion, failed-open rollback, clamping, frequency
changes, sixteen close/remap cycles, legacy borrowed pins, child-process
cleanup, and active generators at VM teardown. The borrowed-pin deprecation
warnings during compilation are expected.

For slow waveforms it enables the digital input buffer on the PWM-driven pad
and measures sixteen periods using GPIO edge waits. This requires no new wire,
but the scheduler limits timing precision; it is not an external waveform or
high-frequency qualification. The final four live outputs must also be checked
externally after `VM teardown complete` to verify release.

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

The first run passed all four controllers' frequencies and the 25/50/75-percent
duty checks, then exposed the unarmed static-capture problem
(`paired-first.log`). The corrected fixture uses explicit `PWM_ARM`,
`PWM_TRAIN` and `PWM_STATIC` commands. These tests allow 3% frequency error
(or two counts) and eight percentage points of polled duty error; they do not
establish precision clock accuracy or high-frequency signal quality.

Both suites now pass on hardware. `build/nrf5340-pwm/lifecycle.log` records
sixteen remap cycles, resource limits and invalid inputs, clamping, borrowed
pins, 50/100 Hz pad read-back and child-process cleanup. `paired-final.log`
records 69 fixture requests, including all four independent controllers,
1/2/5/10 kHz frequency measurements, shared-frequency changes, duty ratios at
50 Hz and 4 Hz, channel reuse, and four endpoint/recovery cycles. Every
endpoint cycle checks a PWM train and both static levels with RMT. After each
suite's successful VM teardown, all four outputs pass the dual-bias release
check. External frequency checks above 10 kHz and scheduler latency during
lowest-frequency stops remain outstanding.

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

## BLE secure central connections

`ble-security-esp32` is an independent ESP-IDF Bluedroid peer. Its `fff0`
service exposes an encrypted-read-only `fff1` characteristic containing
`toit-secure-v1`. Build it with the repository's ESP-IDF environment and flash
the identified ESP32. Its UART accepts `STATUS`, `CLEAR`, `ACCEPT`, `REJECT`,
`NO_BOND`, `LEGACY`, `HOLD`, and `REBOOT`. `HOLD` leaves the security request
unanswered to exercise cancellation. The fixture does not print key material.

Use the Zephyr environment described above and the existing HCI network image:

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340-pairing -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  '-DEXTRA_CONF_FILE=bluetooth.conf;settings.conf;bluetooth-security.conf' \
  -DDTC_OVERLAY_FILE="$PWD/toolchains/zephyr/bluetooth.overlay" \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/ble-pairing-nrf5340.toit" \
  -DTOIT_ZEPHYR_STARTUP_TEST="$PWD/tests/hw/nrf5340/ble-pairing-clear-native.c"
cmake --build build/zephyr-nrf5340-pairing --target toit_envelope -j8
python3 tests/hw/nrf5340/check-pairing.py \
  --image build/zephyr-nrf5340-pairing/zephyr/zephyr.bin \
  --esp-serial "$ESP_SERIAL" --nrf-serial "$NRF_SERIAL" \
  --log-dir build/nrf5340-pairing/first --policy ACCEPT
```

The cleanup hook deletes only the nRF's `bt/keys` records. All policies except
`KEEP` also clear the ESP32's bonds. These are destructive **test** operations
on the devices' existing bonds; use the dedicated lab boards.
To verify persistence, rebuild with `-DTOIT_ZEPHYR_STARTUP_TEST=` and use
`--policy KEEP` with a fresh log directory. Require an initial nRF bond count
of one, an ESP32 boot bond count of one, and no new ESP32 key events. Opening
the console resets this ESP32 devkit; the runner waits for boot before issuing
commands. The nRF firmware replacement preserves both persistent partitions.

For rejection, build `ble-pairing-negative-nrf5340.toit` with the cleanup hook
and run each of `REJECT`, `NO_BOND`, and `LEGACY` in a separate log directory.
For cancellation, build `ble-pairing-cancel-nrf5340.toit` with the cleanup hook
and use `HOLD`. The runner verifies both the Toit result and peer connection
counts, and requires VM teardown. Always restore the normal nRF firmware and
the ESP32 wired fixture after qualification.

Secure connections require SC Just Works, a 16-byte key, and bonding. They do
not provide MITM authentication. Passkey, numeric comparison, OOB, and public
bond deletion APIs remain unavailable. Do not use the separate crypto
self-test configuration for pairing: its SMP debug logging can expose keys.

Hardware qualification is recorded in `build/nrf5340-pairing/summary.json`:
twelve encrypted connections (including four using persisted bonds after
firmware replacement and peer reboot), nine rejected connections across the
three policies, and four cancellations. Both consoles and VM teardown were
checked. The successful recovery run follows the failure/cancellation tests.
The positive image is 672 KiB with 135220 bytes of static RAM; default BLE
remains 580 KiB with pairing disabled. One flash timed out in FTDI transport
at 250 kHz and passed after resetting only the debug adapter and retrying.

## BLE secure peripheral connections

`ble-peripheral-security-esp32` reverses the roles: its independent Bluedroid
central connects to the nRF's `toit-nrf-sec` advertisement. Build and flash it
with the repository's ESP-IDF environment. It exposes UART commands `RUN`,
`RUN_REJECT`, `BOND`, `NO_BOND`, `CLEAR`, and `STATUS`.

Use the same Zephyr security configuration and bond cleanup hook as the central
test above, with `TOIT_ZEPHYR_PROGRAM` set to
`tests/hw/nrf5340/ble-peripheral-security-nrf5340.toit`. Then run:

```sh
python3 tests/hw/nrf5340/check-peripheral-security.py \
  --image build/zephyr-nrf5340-pairing/zephyr/zephyr.bin \
  --esp-serial "$ESP_SERIAL" --nrf-serial "$NRF_SERIAL" \
  --log-dir build/nrf5340-peripheral-security/bonded --policy BOND
```

The test checks encrypted-only characteristic and descriptor reads, writes,
and local value updates, followed by peripheral/adapter close and reopen.
Rebuild without the cleanup hook and use `KEEP` to check persisted bonds
after nRF firmware replacement and ESP32 reboot. For fresh non-bonded pairing,
use `ble-peripheral-security-unbonded-nrf5340.toit` with the cleanup hook and
`NO_BOND`. `ble-peripheral-security-bonding-nrf5340.toit` with `BOND` checks
that the bonding flag alone permits SC pairing. Legacy pairing remains disabled
by the shared Zephyr configuration.

Use `ble-peripheral-security-disabled-nrf5340.toit` with the cleanup hook and
`DISABLED` to verify refusal when neither peripheral flag is set. The ESP32
then reconnects without requesting security and writes a plaintext control
value, proving the peripheral remains usable after refusal. All runs require
four adapter cycles and VM teardown; `KEEP` additionally requires restored
bonds and no new ESP32 key events. Use a fresh log directory for every run.

The Bluedroid fixture explicitly removes its volatile peer record after each
non-bonded connection. This stack retains the SC PENC key in RAM even without
a bond; its `ESP_BLE_SEC_ENCRYPT` path otherwise tries that stale key on the
next link. The original reconnect failure is retained in
`build/nrf5340-peripheral-security/unbonded`. This is fixture-side cleanup,
not persistence of unbonded keys on the nRF. Key-event logs contain only type
tags, never key material. The cleanup completion can report a storage failure
because there were no NVS bond keys to delete; the RAM record has already been
removed. The test checks zero bonds and a fresh encryption-key event on every
connection rather than treating that storage status as proof of RAM cleanup.

`ble-pairing-mixed-nrf5340.toit` uses the earlier ESP32 security **peripheral**
fixture to check role isolation. It opens a security-disabled local peripheral
before or after a secure central connection, closes that peripheral, then
reads the remote encrypted value. Restore both normal board images afterward.

Hardware evidence is in `build/nrf5340-peripheral-security/summary.json`:
sixteen secure peripheral connections (bonded, persisted, unbonded, and
bonding-only), four pairing refusals with four plaintext recovery connections,
and four secure central connections checking local-peripheral isolation.
All completed adapter cleanup and VM teardown. The positive server image
uses 672 KiB of flash and 135220 bytes of static RAM without the cleanup hook.
The normal BLE build remains 580 KiB with security disabled. The permission
regression covers all four shared Toit guard fixes: characteristic `read` and
`write`, descriptor `read` and `set-value`, using encrypted-only permissions.

### Notification and indication encryption

`ble-notify-security-nrf5340.toit` gives two characteristics both notification
and indication properties, protecting notifications on one and indications on
the other. Both retain plaintext reads. Build it with the same security
configuration and bond-cleanup startup hook above, and flash the updated
`ble-peripheral-security-esp32` fixture. Run:

```sh
python3 tests/hw/nrf5340/check-peripheral-security.py \
  --image build/zephyr-nrf5340-bonds/zephyr/zephyr.bin \
  --esp-serial "$ESP_SERIAL" --nrf-serial "$NRF_SERIAL" \
  --log-dir build/nrf5340-notify-security/hardware \
  --policy NO_BOND --notifications
```

Before pairing, the peer reads both plaintext values and attempts to enable
protected CCC bits with Write Commands. Reading the CCC back must show zero.
Commands deliberately avoid Bluedroid's automatic pairing/retry on an ATT
error response. Each characteristic's unprotected mode must still deliver.
After explicit SC pairing, both modes on both characteristics must deliver
the expected bytes and notification/indication type. Every mode is disabled
after use. The test repeats through four adapter lifetimes, with fresh keys
and zero bonds, then requires VM teardown. It does not exercise restoration of
a bonded CCC on an unencrypted reconnect; the native tests separately check
the permission attribute used at send time, without requiring a CCC write.

The four-cycle run passed in `build/nrf5340-notify-security/verified`: sixteen
rejected CCC enables, eight plaintext deliveries, sixteen encrypted deliveries,
four fresh pairings and VM teardown. The client re-registers notifications
before each trigger because Bluedroid clears its local registrations on Service
Changed after pairing. The initial failure and diagnostic run are retained in
`hardware` and `diagnostic`; neither is counted as passing evidence.
The existing encrypted characteristic/descriptor read/write suite also passed
four connections using the updated firmware and peer, in `read-write-regression`.

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

Both variants passed on the E83 board, each completing 1552 garbage collections.
The full 131072-byte storage partition, including five existing allocations,
was byte-identical before and after the two flashes. The SWD deployment tool
verified both the old and new firmware while taking these storage backups.
Evidence is in `build/nrf5340-envelope`: `prepare.log`, `host.log`, `ctest.log`,
`flash-snapshot/console.log`, `flash-image/console.log`, `before.json`,
`after.json`, and `storage-check.log`. Re-extraction after selecting envelope
format 1003 produced the exact same flashed binaries (`flashed-sha256.txt`).
The CMake target was also checked with a source application plus an additional
precompiled image; its extraction preserved native bytes and all three containers.
The board was then restored to the system-only envelope extraction at
`build/nrf5340-envelope/final-base.bin`; that file was the SWD deployment
reference for the envelope milestone (the lifecycle milestone below supersedes it). `final.json` records the final firmware/storage check.

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

Both variants passed on hardware: 26 fixture requests and exactly two boots
each. `build/nrf5340-lifecycle/{exit,throw}/paired.log` records the checks, with
raw console and flash logs beside it. The unchanged original firmware was
also tested: `before/paired.log` shows successful teardown and released pins,
followed by failure to reboot. Four host regressions passed (`host-tests.log`).
The existing reset/watchdog suite also passed: 16 fixture requests across five
boots, recorded under `reset-regression`.
The final restore was verified through SWD. All 131072 storage bytes and five
allocations matched the preceding envelope milestone's backup (`final.json`
and `storage-check.log`). The lifecycle milestone used
`build/nrf5340-lifecycle/system-only.bin` as its firmware reference; the native
fault milestone below supersedes it.

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
levels, and a 750 ms System ON sleep followed by software reset. Each shutdown
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

Both variants passed with 40 fixture requests and four boots each. The normal
variant observed 759 ms for the requested 750 ms sleep. The edge variant
observed 1513 ms before watchdog reset, after roughly 500 ms of I2C cleanup.
Evidence is in `build/nrf5340-poweroff/{vm,edge}`, `vm-paired.log`, and
`edge-paired.log`. Three host container/firmware regressions passed
(`host-tests.log`).

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

## Shared Bluetooth and Toit crypto qualification

`ble-security-crypto.conf` enables Zephyr SMP with Toit's vendored Mbed TLS
as its custom PSA provider. It also enables the optional Toit SipHash and
Blake2s primitives so their `tests/crypto-test.toit` checks can run.
The normal and default BLE configurations leave these options disabled.
Asynchronous RSA generation remains unsupported on Zephyr.

Run `tools/zephyr/setup.sh` first and use the Zephyr environment described
above. The network core must already have the HCI IPC firmware from the next
section. No ESP32 peer is required for this test.

```sh
cmake -S toolchains/zephyr -B build/zephyr-nrf5340-security -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  '-DEXTRA_CONF_FILE=bluetooth.conf;../../tests/hw/nrf5340/ble-security-crypto.conf' \
  -DDTC_OVERLAY_FILE="$PWD/toolchains/zephyr/bluetooth.overlay" \
  -DTOIT_ZEPHYR_STARTUP_TEST="$PWD/tests/hw/nrf5340/ble-security-crypto.c" \
  -DTOIT_ZEPHYR_PROGRAM="$PWD/tests/hw/nrf5340/ble-security-crypto.toit"
cmake --build build/zephyr-nrf5340-security --target toit_envelope -j8
python3 tools/nrf5340/flash.py \
  build/zephyr-nrf5340-security/zephyr/zephyr.bin \
  --serial "$NRF_SERIAL" --log-dir build/nrf5340-security/final-hardware \
  --expect 'NRF5340 SHARED CRYPTO PASS' \
  --stop-after 'VM teardown complete' --seconds 600
```

The native startup probe checks AES/CMAC known answers, key permissions,
P-256 known answers, rejection of an invalid peer point, generated ECDH in
both directions, and exhaustion/reuse of all sixteen volatile key slots.
Then the Toit program runs the existing hash, ChaCha, SipHash, AEAD, Adler,
Blake2s, HMAC and random tests, sixteen Bluetooth
adapter open/close cycles with Zephyr's SMP self-tests, and those crypto tests
again while scanning and advertising remain active. Require both native PSA
and final shared-crypto PASS markers, all sixteen adapter cycles, and VM
teardown without an exception.

For the complete shared suite, set `TOIT_ZEPHYR_PROGRAM` to
`ble-security-crypto-exhaustive.toit` and increase the capture timeout. This
also runs the exhaustive pure-Toit Hamming and MD5 sweeps twice. The initial
full run was stopped after more than ten minutes in the MD5 sweep, confirmed
by mapping the live VM stack back to source; it is not recorded as a pass.
The focused qualification retains HMAC's MD5 known answers. The complete
suite has passed the earlier host regression runs.

This crypto qualification image does not enable Toit's secure-connect API.
The separate settings and Bluetooth security configuration provides that
integration; this crypto test does not exercise persistent bonds.
SMP debug logging is required for Zephyr's self-tests and must
not be used for actual pairing because it can log key material. The test
only scans and advertises without accepting connections. Restore the normal
system-only image after qualification.

## Network-core HCI IPC and BLE qualification

The originally locked network core was recovered with explicit user approval
on 2026-10-25. Application flash/UICR were restored and verified before the
controller was installed. The native probe and sixteen-cycle Toit adapter
test have now passed on hardware, and the ESP32 observed nRF advertisements.
Evidence is in `build/nrf5340-ble/{native-hardware,toit-hardware,esp-peer-console}.log`.
The four-cycle GATT discovery/descriptor-read suite also passes; see
`build/nrf5340-ble/gatt-uuid-fix-hardware.log`. Its UUID regression covers
16-, 32-, and 128-bit spellings of a Bluetooth-assigned service. Immediate
close/reconnect still fails (`connect-debug-peripheral-peer.log`), even with
ESP32 scanning disabled. Further GATT qualification is ongoing.
See `docs/nrf5340.md` for the full-device recovery requirement;
do not use a generic recover command assuming it preserves application flash.
The full application/UICR backup and hashes are in
`build/nrf5340-ble/before-recovery/manifest.json`. All persistent bytes matched
the preceding power-management checkpoint when that backup was taken.
Use the manifest's `application-uicr` entry for restoration, not its raw dump:
unselected KMU key reads return a masked value. The restorable image was
completed by selecting and reading all 128 slots, checking successful access,
and restoring slot selection to zero. All slots were readable and empty.

After `tools/zephyr/setup.sh`, use the same Zephyr environment as earlier:

```sh
cmake -S .cache/zephyr-workspace/zephyr/samples/bluetooth/hci_ipc \
  -B build/zephyr-nrf5340-hci -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpunet \
  -DBOARD_ROOT="$PWD/toolchains/zephyr" \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DEXTRA_CONF_FILE="$PWD/toolchains/zephyr/hci-ipc.conf"
cmake --build build/zephyr-nrf5340-hci -j8
cmake -S toolchains/zephyr -B build/zephyr-nrf5340-ble-native -G Ninja \
  -DBOARD=e83_2g4m03s_tb/nrf5340/cpuapp \
  -DPython3_EXECUTABLE="$PWD/.cache/zephyr-venv/bin/python" \
  -DTOIT_ZEPHYR_BUILD_VM=OFF \
  -DTOIT_ZEPHYR_NATIVE_SOURCE="$PWD/tests/hw/nrf5340/ble-native.c" \
  -DEXTRA_CONF_FILE="$PWD/toolchains/zephyr/bluetooth.conf" \
  -DDTC_OVERLAY_FILE="$PWD/toolchains/zephyr/bluetooth.overlay"
cmake --build build/zephyr-nrf5340-ble-native -j8
```

For the optional VM link check, use `build/zephyr-nrf5340-ble`, omit both native
options, set `-DTOIT_ZEPHYR_PROGRAM=`, and build target `toit_envelope`. The
network-core controller is built automatically and carried by the format 1004
envelope. Extract it with `--format=tar` and pass the tar to
`tools/nrf5340/flash.py`; see the [two-core deployment instructions](../../../docs/nrf5340.md#firmware-envelopes).
The backend implements scanning and nonconnectable
advertising, unencrypted central connections, GATT discovery, and attribute
reads/writes, subscriptions and peripheral connections. Secure Connections
Just Works pairing and persistent bonds are covered by the security tests below.

`ble-native.c` checks HCI initialization, identity, AES-128 LE/BE known answers,
48 random bytes, and four two-second advertising/scanning cycles. Scan reports
are diagnostic; they do not yet assert an ESP32 peer identity or prove outbound
RF operation. The separate paired Toit test supplies that evidence. Radio
tests temporarily replace the wired fixture; restore it afterward.

The first Toit-level test, `ble-nrf5340.toit`, compiles and is prepared as
`build/nrf5340-ble/toit-test.bin`; it passes on hardware. It checks exclusive adapter
ownership, zero/finite/infinite scans, deadline cancellation and reuse,
advertisement/scan-response encoding, repeated stop, sixteen adapter reopen
cycles, and automatic teardown with scanning and advertising still active.
Install its snapshot as `ble-test` into the optional BLE envelope and extract
with `--format=tar` to deploy both cores. After network recovery, this
passed hardware validation with the identified ESP32 observing advertisements.

The paired connection test, `ble-connect-nrf5340.toit`, passes all four adapter
cycles with the [independent Bluedroid peer](ble-connect-esp32/README.md) and with
`ble-peer-esp32.toit` after applying its documented NimBLE dependency correction.
The previous failure on the second connection was traced to an ESP32 callback
suppressed on early disconnect, leaving advertising stopped. The nRF image and
connection timing are unchanged. The affected unmodified NimBLE version still
fails this case. Use the
ESP32 firmware's matching SDK to install the peer, and restore the existing
`wiring-esp32.toit` fixture afterward. The peer advertises `toit-esp-peer`, exposes
read-only characteristics, a description descriptor, a notification
characteristic with a CCCD, and prints a five-second heartbeat. With the
`--observe-advertising` program argument it first scans for `toit-nrf-probe`
and prints `ESP32 BLE PEER observed nRF advertisement`. Use this mode for
outbound advertisement validation; connection/GATT tests use the peripheral
alone. The nRF test checks identifier validation,
16 cancelled attempts, 32 connect/close cycles, duplicate connections, ATT MTU,
a three-second connection timeout, adapter reopen, closing an adapter while
connecting, and final teardown with an active connection. It assumes its
synthetic random-static address `c2:47:73:19:aa:55` is absent from the test area.
The VM close currently waits synchronously for native connection cleanup, so
the Toit timeout cannot preempt that native wait.

Prepared snapshots and envelopes live under `build/nrf5340-ble/`:
`ble-connect.snapshot`, `ble-peer.snapshot`, `connect-test.envelope`, and
`connect-test.bin`. These are preparation artifacts, not hardware test results.
The connection backend and shared library compile, and the four existing host
regressions passed in `connections-host-tests.log`; none exercises HCI callback
ordering. The current hardware evidence is under
`build/nrf5340-ble/early-disconnect/`: `bluedroid-nrf.log` and
`bluedroid-console.log` record the independent peer run; `fixed-nrf.log` and
`fixed-console.log` record the corrected Toit peer. Each run checks the complete
nRF lifecycle suite. Bluedroid's HCI log records 37 remote disconnects, including
adapter close and VM teardown. The independent fixture README explains the
pinned dependency revision, diagnostic, patch, and restoration procedure.

`ble-gatt-nrf5340.toit` is prepared as `gatt.snapshot`, `gatt-test.envelope` and
`gatt-test.bin` in that directory. With the expanded ESP32 peer it checks
service/characteristic/descriptor discovery, properties and handles, filtered
descriptor boundaries, empty ranges, missing UUIDs, 32-bit UUID queries, and
four connection/adapter reopen cycles. The updated `gatt-uuid-fix` artifacts
pass on hardware, including equivalent 16-/32-/128-bit service UUID filters.
The native backend limits each discovery to 64 records and zero or one UUID
filter. Descriptor reads now check the description and CCCD values too.
Closing a resource or interrupting a GATT wait cancels the native request.
Zephyr's discovery API does not distinguish normal completion from all ATT
errors, so some peer-side errors can yield empty or partial results.

`ble-values-nrf5340.toit` is prepared as `values.snapshot`, `values-test.envelope`
and `values-test.bin`. It uses the peer's separate value service to check long
and empty reads, encrypted-read ATT errors, writes with and without responses,
empty and MTU-sized echoes, oversized-write rejection, and cancelling/reusing
delayed reads and writes across four adapter lifetimes. The shared UUIDs and
512-byte payload are in `ble-values-shared.toit`. The ESP32 delays selected
responses for 200 ms so a 30 ms client timeout can interrupt a pending request.
The test does not assume cancellation rolls back a write. All four cycles
pass on hardware (`values-uuid-fix-hardware.log`).

`ble-notify-nrf5340.toit` is prepared as `notify.snapshot`, `notify-test.envelope`
and `notify-test.bin`. Its UUIDs and deterministic payloads are shared with the
peer in `ble-notify-shared.toit`. Trigger writes select notifications or
indications and request a burst. The peer acknowledges the trigger before
sending, allowing NimBLE to process TX completions and indication ACKs. The
nRF polls a separate completion counter without consuming queued values.
During the intentional overflow burst, the old ESP32 SDK can lose a subscriber
between client enumeration and send; only that `INVALID_ARGUMENT` race after
the queue has overflowed is tolerated. Other send failures terminate the peer.
Overflow recovery requires a fresh marker after a bounded tail of already
queued old values, then checks that the queue is empty. Resubscribing cannot
retract packets already queued by the peer.
The current fixture uses ordinary `write` for every value, including empty
values. This requires the ESP32 backend fix that allocates an mbuf for empty
data; a null notification buffer instead asks NimBLE to send the stored value.
The earlier passing run used a store-before-send workaround with the old SDK.
The repeat run with the fixed native firmware passes all four adapter cycles
(`notify-qualified-hardware.log`, `esp-peer-qualified-console.log`), including
empty notifications after nonempty values without the old workaround.
The test covers FIFO order, empty and MTU-sized values, independent read
results, cancelled receiver waits, unsubscribe/resubscribe, overflow reporting,
duplicate subscription ownership, and disconnect with active subscriptions.
There are four adapter cycles. The first run exposed a fixture TX timeout
while sending inside the trigger callback; the corrected asynchronous version
passes all four cycles (`notify-empty-fix-hardware.log` and
`esp-peer-empty-fix-console.log`). It does not yet
exercise cancellation during a delayed CCC response or peer-initiated disconnect.

The optional BLE configuration now enables Zephyr's automatic ATT MTU
exchange. The normal `ble-peer-esp32.toit` fixture explicitly prefers MTU 247;
the value and notification test entry points require that negotiated value.
Both four-cycle suites pass with 244-byte writes, notifications and indications,
plus 512-byte reads, ATT errors, cancellation, overflow and reuse. Evidence is
under `build/nrf5340-ble/auto-mtu/`: `values-hardware.log`,
`notify-hardware.log`, and `peer247-console.log`.

For minimum-MTU compatibility, install `ble-peer-mtu23-esp32.toit` on the ESP32
and `ble-client-mtu23-nrf5340.toit` on the nRF. This combines both suites with
an explicit MTU-23 assertion, for eight adapter lifetimes. It passes in
`client23-hardware.log` with the peer console in `peer23-console.log`. The test
must end with `NRF5340 BLE CLIENT MTU23 PASS` and successful VM teardown.

The automatic-exchange build also passes `ble-connect-nrf5340.toit` against
the independent Bluedroid fixture (`auto-mtu/connect-hardware.log` and
`connect-peer-console.log`): 32 immediate connect/close cycles and all 37
expected remote disconnects, including adapter and VM teardown.
These are negotiation checks; runtime `Adapter.set-preferred-mtu` remains
unsupported on the nRF backend.

`ble-server-nrf5340.toit` and `ble-server-esp32.toit` reverse the roles. The nRF
serves stored values and receives queued writes; the ESP32 discovers and reads
the database, writes characteristic/descriptor echoes, and receives both
notifications and indications. Run the server image on the nRF and the separate
ESP32 central snapshot against a firmware built with the matching SDK. The
existing `ble-peer-esp32.toit` is for the opposite direction and is not this
test's partner. Restore the wired fixture after radio testing.

Build the ESP32 peer firmware from this worktree, using its matching host SDK.
The cached Jaguar alpha.199 firmware crashes on empty writes, uses prepared
writes for ordinary Write Requests, and ignores immediate read-start errors.
Those ESP32 backend defects are fixed here. For a fresh peer build, after
activating the ESP-IDF environment:

```sh
mkdir -p build/esp32-nrf-peer
cp toolchains/esp32/sdkconfig build/esp32-nrf-peer/sdkconfig
idf.py -C toolchains/esp32 -B "$PWD/build/esp32-nrf-peer" \
  -D SDKCONFIG="$PWD/build/esp32-nrf-peer/sdkconfig" build
build/host/sdk/bin/toit compile -s \
  -o build/nrf5340-ble/server-peer-native.snapshot \
  tests/hw/nrf5340/ble-server-esp32.toit
build/host/sdk/bin/toit tool firmware \
  -e build/esp32-nrf-peer/firmware.envelope container install server-peer \
  build/nrf5340-ble/server-peer-native.snapshot \
  -o build/nrf5340-ble/server-peer-native.envelope
```

Flash the resulting envelope on the identified ESP32. Start the nRF server
first and reset the client once it reports `NRF5340 BLE SERVER READY`. Holding
the ESP32 in reset during nRF startup avoids resetting an already established
link. Preserve console logs from both boards.

Prepared outputs are `server.snapshot`, `server-test.envelope`, `server-test.bin`
and `server-peer.snapshot` under `build/nrf5340-ble`. They cover four adapter
lifetimes, two peripheral lifetimes per adapter and two incoming connections
per peripheral lifetime. Logs from both boards are required: look for
`NRF5340 BLE SERVER PASS` and `ESP32 BLE SERVER PEER PASS`, then independently
check process cleanup. Before fragment compaction, the MTU-23 run stalled
after 242 bytes of a long read;
increasing the timeout does not help. With MTU 247, long/empty reads,
encrypted-read rejection and descriptor writes/read-back work. The old ESP32
firmware then panicked in `ble_gattc_write_long` on an empty Write Request
(`server-controlled-hardware.log`, `server-peer-controlled-console.log`).
Its backend passed a null mbuf for empty data. With the three ESP32 fixes above,
all sixteen connections and eight peripheral lifetimes pass across four
adapters (`server-read-hardware.log`, `server-peer-read-console.log`), including
final nRF VM teardown. That hardware run negotiated MTU 247.

The ESP32 read callback now compacts subsequent fragments into its existing
mbuf chain and reports allocation failures while discarding partial results.
The updated firmware builds (`esp-peer-compact-build.log`). A 32-bit ASan/UBSan
experiment using the actual NimBLE allocator exhausts a 12-buffer pool after
264 bytes with concatenation, but assembles 512 bytes using two buffers with
compaction (`mbuf-probe/run.log`). This validates the allocation explanation,
not the production callback or hardware behavior.

The regular server peer now explicitly requests and checks MTU 247. The
`ble-server-mtu23-esp32.toit` entry point runs the same sixteen-connection suite
with MTU 23; it must complete the 512-byte reads in small fragments. Prepared
peer envelopes are `server-peer-compact.envelope` and
`server-peer-mtu23.envelope` under `build/nrf5340-ble`. Both snapshots compile.
Repeat the nRF server run from cycle zero for each peer envelope and preserve
both console logs. After recovery of the PC USB controller, the MTU-23 suite
passes all sixteen connections, including thirty-two complete 512-byte reads,
eight peripheral lifetimes, four adapter lifetimes and final VM teardown
(`server-mtu23-sync-hardware.log`, `server-mtu23-sync-peer.log`). This also
qualifies the PWM-enabled BLE build. Both consoles must be attached before
starting the peer: attaching the ESP32 console during an earlier run reset it
and invalidated that attempt. The updated peer also passes the entire suite
at MTU 247 on the build without temporary diagnostics
(`server-mtu247-retry-hardware.log`, `server-mtu247-retry-peer.log`). The first
flash attempt timed out in the FTDI transport; closing and reopening it restored
access, and the retry flashed and verified successfully.
These tests do not qualify multiple simultaneous peers, slow/missing indication ACKs,
write-queue overflow, allocation failure or cancellation races. Deferred Toit
read/write callbacks and prepared writes remain explicitly unsupported.

With automatic MTU exchange enabled on the nRF, the MTU-23 suite passes again:
sixteen connections, eight peripheral lifetimes, four adapters and VM teardown
(`auto-mtu/server-order23-hardware.log`, `server-order23-console.log`). The ESP32
peer includes a connection-readiness fix: an MTU event arriving before CONNECT
must not wake Toit until the native connection handle is installed. It records
the early event, handles it once after CONNECT, and ignores duplicate events.
Without this fix the first service discovery can return ENOTCONN. These tests
use unencrypted links and do not qualify secure pairing.
The same updated ESP32 backend passes all sixteen MTU-247 connections against
the earlier `server-qualified.bin` nRF image, which has automatic exchange
disabled (`auto-mtu/server-order247-hardware.log`, `server-order247-console.log`).
This deliberately checks the ESP32-initiated exchange path; it is not a test
of incoming MTU-247 connections with nRF automatic exchange enabled.

The [native GATT tests](ble-native-tests/README.md) run the production server
callbacks and Zephyr's host database locally, without a radio or the Toit VM.
All seven cases passed with ASan/UBSan, including write-queue overflow/recovery,
per-mode encryption permissions, and contention between callback execution
and owner detachment. Their evidence
is in `build/nrf5340-ble/native-tests-run.log`; this does not qualify the paired
radio tests or replace their lifecycle checks.

Host checks for the new report queue and AD parser:

```sh
g++ -std=c++11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  tests/hw/nrf5340/ble-data-test.cc -o build/nrf5340-ble/ble-data-test
ASAN_OPTIONS=detect_leaks=0 build/nrf5340-ble/ble-data-test
```

These passed (`data-test.log`). LeakSanitizer is disabled because it cannot run
under this sandbox's tracing; address and undefined-behavior sanitizers remain
enabled. The expanded read-fragment/UUID/handle-range/capacity checks pass in
`values-data-test.log`. Four shared BLE/container/firmware regressions passed in
`values-host-tests.log`. These host checks do not test radio operation,
callback timing, transport reinitialization, or hardware power transitions.
Notification queue ownership/bounds/wraparound/empty/reset checks pass in
`notify-data-test.log`, and the same four host regressions pass in
`notify-host-tests.log`. All prepared BLE images and the ESP32 peer snapshot
are rebuilt against the SDK with the appended notification primitive.

The recovery bundle can be checked and staged without a board:

```sh
python3 tests/hw/nrf5340/test-prepare-recovery.py
python3 tools/nrf5340/prepare-recovery.py \
  build/nrf5340-ble/recovery-plan.json build/nrf5340-ble/recovery-bundle
```

Use a new destination for each bundle. The ten host tests cover corrupted or
truncated backups, unsafe UICR/key contents, wrong-core vectors, storage
overlap, existing-output preservation, publication failure, and a concurrent
source-file replacement. The utility never opens a debugger or erases flash;
live backup comparison and recovery approval remain separate prerequisites.

The separate recovery runner's twelve host tests use a memory-model debugger:

```sh
python3 tests/hw/nrf5340/test-recover.py
```

They check full application/storage preservation, empty-key validation,
device identity matching, and failure handling before and after the erase
boundary. No test accesses hardware. The runner's default check-only path has
also passed on the E83 board, with all flash and UICR matched and all 128 KMU
slots checked. See `build/nrf5340-recovery/23e7797a3a66458cae12d28b8af052e4`.
The application was resumed and confirmed running afterward. This check-only
milestone preceded the later authorized recovery recorded under
`build/nrf5340-ble/recovery-executed/`.

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
