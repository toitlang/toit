# RP2040 hardware bring-up

These tests are manual. First install the persistent updater as described in
[`tools/rp2040/README.md`](../../../tools/rp2040/README.md). BOOTSEL is not wired;
initial installation must be coordinated with the user.

Build the VM application with the matching host Toit compiler:

```sh
CCACHE_DISABLE=1 TOIT_PACKAGE_CACHE_PATHS="$PWD/tools/.packages-bootstrap" \
  cmake -S toolchains/rp2040 -B build/rp2040-vm -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DTOIT_RP2040_BUILD_VM=ON -DPICO_BOARD=pico_w_2023
CCACHE_DISABLE=1 TOIT_PACKAGE_CACHE_PATHS="$PWD/tools/.packages-bootstrap" \
  cmake --build build/rp2040-vm --target toit-rp2040 --parallel 6
```

The default application is `vm-smoke.toit`. Select another using
`-DTOIT_RP2040_PROGRAM="$PWD/tests/hw/rp2040/pio-smoke.toit"`, then rebuild.
Upload `build/rp2040-vm/toit-rp2040.bin` through `tools/rp2040/upload.py`, choosing
a version and the test's exact PASS line with `--expect`. When a probe or VM is
already running, add `--request-update`. This selects 1200 baud on USB CDC to
request recovery without taking bytes from application stdin. The request works
even after the independent application container exits. The boot task feeds the inherited
runtime watchdog; native hangs still reset into the updater. Starting an
application watchdog gives it exclusive ownership of the timer until it is
stopped. The boot task cannot extend an application's watchdog deadline.

`vm-smoke` checks the platform identity, collection of movable heap objects,
integer and floating-point arithmetic, and task timers. `pio-smoke` checks
pin-free PIO FIFO loopback using concurrent DMA transfers, copying and external
buffer consumption, with GC during transfers. Neither test drives the rig's
peripheral wires. Build/analysis success does not count as a hardware PASS.

## Memory pressure

`system-oom.py` compiles `system-oom.toit` as a dedicated **system snapshot**,
builds an envelope from `--native-base`, and requires USB recovery within
twelve seconds after the allocation-failure marker. The fixture first reports
readiness and waits for the runner's `oom\n` command, so the observer is attached
before failure injection. Pass `--toit`, `--output`,
`--port`, `--id` and `--restore-image` as well. The native base is the envelope
build's `toit-rp2040.bin`, not an ordinary application binary. It restores and
verifies normal firmware afterward. Do not install this fixture as an ordinary
application: that would exercise a different failure path.

`memory-pressure.toit` rejects oversized native allocations while retaining
heap data, then exhausts growing strings repeatedly and verifies PIO DMA and
RAM-storage RPC still work after collection. It checks that system free-memory
statistics describe the Pico SRAM and prints heap accounting before and after. It can use `pio-lifecycle.py`
with `--expect 'memory-pressure-rp2040: PASS'` and the usual image/restore args.

## PIO lifecycle

`pio-lifecycle.toit` and `pio-lifecycle.py` exercise PIO without configuring
or driving header pins. The fixture checks copies and buffer ownership during
GC, cancellation, waiter wakeups, concurrent reclamation, orphan cleanup and
IRQs. It repeatedly fills both PIO blocks and all twelve DMA channels, checks
allocation failures preserve caller-owned buffers, and verifies resources can
be reopened after teardown. Sixteen transfer/GC cycles also catch negative process
accounting when native buffers are returned as external byte arrays. Pass `--uploader`, `--port`, `--id`, `--image` and
`--restore-image`; the runner restores the ordinary smoke application.

## Standard input and recovery

Build `stdio-rp2040.toit`, save its binary, then rebuild the ordinary `vm-smoke`
image for restoration. Run `stdio.py --uploader build/rp2040-ota-upload/rp2040-ota-upload
--port OBSERVED_PICO_LINK --id OBSERVED_BOARD_ID --image STDIO.bin
--restore-image SMOKE.bin` (as one command). It checks all byte values across
32 blocks larger than the native input buffer, fragmented USB writes, concurrent
GC and timers, and literal `update`/`hello` input reaching the application. It
then uploads the restore image while the application is blocked reading stdin.
The native uploader requests recovery through USB control, with no input bytes
sent until the loader identifies itself. No header GPIOs are driven by this test.

`usb-stress.toit` and `usb-stress.py` extend this coverage to sustained,
simultaneous input/output and CDC line-coding control transfers. Build the
fixture into an application envelope and pass `--image`, `--restore-image`,
`--uploader`, `--port`, `--id`, and a new `--output` directory. The default
16,384 blocks transfer 16,891,904 verified binary bytes while the Pico runs GC.
The host pipelines up to eight blocks and changes between 57,600 and 115,200
CDC baud every 32 blocks. Neither rate requests recovery or configures a
physical UART. After the workload, the runner closes USB for 30 seconds, then
uses the traced uploader to restore the smoke image and verifies its startup.
Use `--blocks`, `--window` (1..8), and `--idle-seconds` to vary these conditions.
At the observed rate the default workload takes about 15 minutes. The first
failure stops the test without another upload or GPIO reset, preserving the
device state and logs for investigation.
The first full run passed on October 6 (application 429 → smoke 430), with
512 control changes and 58,930 GC cycles over 850.5 seconds. Recovery after
the closed-port idle answered in 1.722 seconds. Evidence is under
`build/rp2040-recovery-idle/usb-stress/`. This did not reproduce or fix the
historical intermittent USB loss.

`recovery-idle.py` repeats recovery after normal application exit and after an
ordinary container exception. Build `recovery-exception.toit` as a noncritical
application container, then supply its binary with `--exception-image` and the
ordinary smoke binary with `--idle-image`. Other arguments are `--uploader`,
`--port`, `--id`, and a new `--output` directory. The default three cycles test
0/1/10/30-second idle periods with the host serial port closed or held open.
Use `--port-state closed` or `--port-state open` to isolate one host condition;
custom `--delays` may extend up to 600 seconds to investigate longer idle gaps.
The fixture waits for the observer before throwing; ordinary container failure
leaves the system running, so recovery still requires the USB control request.
The runner records the exception, each upload stage, and image hashes, then
stops at the first failure without GPIO resets or another restore attempt.
It enables the native uploader's `--verbose` trace, recording elapsed time,
recovery handshake progress, block offsets, acknowledgements, and reboot
verification without logging application output or firmware payload bytes.
Inspect that preserved device state before recovering it. A complete run ends
with the smoke image restored. The first hardware run passed all 13 uploads
with `--cycles 1 --delays 0 1 10`, including six application exceptions. Evidence
is in `build/rp2040-recovery-idle/run-20261006/`. This did not reproduce the earlier
intermittent USB recovery failure. Three-minute closed-port checks also passed,
including recovery after binary modem traffic and a deliberate receive timeout
(see `modem/recovery-timeout.toit` and the modem README). The cause remains open.
Do not run it while the modem bridge awaits a physical BOOT step.

`usb-backpressure.toit` floods USB stdout while `usb-observer-esp32.toit`
receives progress counters over the verified GP16 -> GPIO34 wire. Run
`usb-backpressure.py` with `--image`, `--restore-image`, `--uploader`, `--port`,
`--id`, `--jag`, `--helper-device`, `--helper-repo`, `--helper-log`, and a new
`--output` directory. The helper repo must supply the SDK expected by the
running Jaguar service. The runner leaves USB unread for `--seconds` (default
15), verifies independent VM progress, then requests recovery once while USB
is still unread. Success restores both ordinary applications. Failure leaves
the observer and Pico state intact. USB log loss is expected in this test.

`recovery-transport.py` tests loader reply integrity and abandoned sessions.
Configure a native-tools build with `-DTOIT_RP2040_RECOVERY_TEST_APP=ON`, then
pass its `toit-rp2040-recovery-test.bin` with `--image`. This runs the real
recovery sources at the application address and leaves the installed loader
unchanged. Alternatively, use `--installed-loader` to test the installed loader
directly. Both modes require `--restore-image`, `--uploader`, `--port`, `--id`,
and a new `--output` directory. The test checks 64 individual replies, 512
queued replies with a 1.5-second read pause, disconnect after `begin`, and an
idle partial command. The host writes and reads concurrently after the pause
to accommodate the loader's backpressure. It finishes by uploading the restore
image through the tested protocol and verifying the smoke application.

## Identity, reset and watchdog

`platform-smoke` checks the flash-derived board identity, `device.hardware-id`,
fresh identity buffers after GC, and rejection of reserved supply pins. It then
resets with a PIO read DMA pending. It repeats after every boot until the host
requests recovery. `watchdog-smoke` checks invalid timeouts, runtime health,
application feeding/stopping, and expiration while the boot task is still alive.
Neither test drives header GPIOs.

Build three images, preserving the binaries between builds:

```sh
make rp2040 RP2040_BOARD=pico_w_2023
cp build/rp2040-pico_w_2023-vm/toit-rp2040.bin /tmp/rp2040-restore.bin
make rp2040 RP2040_BOARD=pico_w_2023 \
  RP2040_PROGRAM="$PWD/tests/hw/rp2040/platform-smoke.toit"
cp build/rp2040-pico_w_2023-vm/toit-rp2040.bin /tmp/rp2040-platform.bin
make rp2040 RP2040_BOARD=pico_w_2023 \
  RP2040_PROGRAM="$PWD/tests/hw/rp2040/watchdog-smoke.toit"
cp build/rp2040-pico_w_2023-vm/toit-rp2040.bin /tmp/rp2040-watchdog.bin
python3 tests/hw/rp2040/lifecycle.py \
  --port /dev/serial/by-id/OBSERVED_PICO_LINK --id OBSERVED_BOARD_ID \
  --version 100 --reset-image /tmp/rp2040-platform.bin \
  --watchdog-image /tmp/rp2040-watchdog.bin --restore-image /tmp/rp2040-restore.bin
```

The runner checks the observed USB identity, normal reboot with active DMA,
and recovery within six seconds of arming a one-second application watchdog.
It uses three consecutive image versions and restores the VM smoke image after
success. A failed run can leave a test image or recovery running; use the USB
uploader to restore a known-good application. The final success marker is
`RP2040 lifecycle hardware: PASS`.

## Native failure recovery

`native-failures.py` builds and installs test-only images for abort, process
exit, fatal error, interrupt-disabled panic, hard fault, fault with XIP disabled,
stack-overflow handling, and an interrupt-disabled infinite loop. Each test must
reach the identified USB recovery loader; a printed fault marker alone does
not count as success. The hang test uses the runtime health watchdog without
arming an application watchdog.

Starting from an ordinary VM build with fault injection disabled:

```sh
python3 tests/hw/rp2040/native-failures.py \
  --port /dev/serial/by-id/OBSERVED_PICO_LINK --id OBSERVED_BOARD_ID \
  --version 110 --build build/rp2040-pico_w_2023-vm \
  --restore-image /tmp/rp2040-restore.bin
```

Use `--fault NAME` to select individual cases. The runner preserves each tested
binary and writes `native-failure-results.json` in the build directory. It
restores the original build configuration even on failure, and reinstalls the
supplied known-good image after all hardware checks succeed. The injector is
absent from normal builds; `TOIT_RP2040_TEST_FAULT` is an explicit test option.
The final success marker is `RP2040 native failure hardware: PASS`.

## Storage and container isolation

`storage-write-rp2040` checks that the application is registered with the
container service and cannot invoke privileged system primitives. It checks
RAM buckets, flash bucket replacement/removal, an 8193-byte value, and region
writes crossing NOR page and sector boundaries. `storage-read-rp2040` only
reads those fixtures, so replacing the firmware with this reader verifies
persistence through the updater and reboot.

Build the writer, reader and ordinary VM smoke images separately and save
each binary before the next build. Then run:

```sh
python3 tests/hw/rp2040/storage.py \
  --port /dev/serial/by-id/OBSERVED_PICO_LINK --id OBSERVED_BOARD_ID \
  --version 130 --writer-image /tmp/rp2040-storage-writer.bin \
  --reader-image /tmp/rp2040-storage-reader.bin \
  --restore-image /tmp/rp2040-restore.bin
```

The runner uses three consecutive versions and restores the smoke image on
success. Test data remains under `toit-rp2040-test/` in the flash registry.
These tests do not establish power-loss atomicity of storage operations.

`storage-interruption.toit` and `storage-interruption.py` exercise six reset
points using a dedicated native fault-test image: partial data programming,
partial header programming, a committed replacement before cleanup, partial
cleanup erase, partial deletion erase, and partial header invalidation. Recovery
must expose the old value, new value, or deletion as appropriate, while the
unrelated storage fixtures remain intact. The test cleans up its own bucket and
control region. It programs deterministic partial states on real NOR; it does
not switch off board power or characterize arbitrary brownouts.

```sh
make rp2040 RP2040_BOARD=pico_w_2023 \
  RP2040_PROGRAM="$PWD/tests/hw/rp2040/storage-interruption.toit" \
  RP2040_CMAKE_FLAGS=-DTOIT_RP2040_TEST_STORAGE_INTERRUPTION=ON
cp build/rp2040-pico_w_2023-vm/toit-rp2040.bin /tmp/rp2040-storage-fault.bin
make rp2040 RP2040_BOARD=pico_w_2023
python3 tests/hw/rp2040/storage-interruption.py \
  --uploader build/host/sdk/lib/toit/bin/rp2040-ota-upload \
  --port /dev/serial/by-id/OBSERVED_PICO_LINK --id OBSERVED_BOARD_ID \
  --image /tmp/rp2040-storage-fault.bin \
  --restore-image build/rp2040-pico_w_2023-vm/toit-rp2040.bin
```

Ordinary `make rp2040` builds explicitly disable fault injection. CMake rejects
it in envelope bases. The matching host regression is `tests/storage-recovery`;
it also verifies both allocation orders, stale-copy reclamation, generation
wraparound, legacy migration and rejection of ambiguous metadata.

`storage-exhaustion.toit` reserves every remaining registry page through
uncommitted container writers. It checks that rejected bucket overwrites,
additions and removals leave open aliases and persisted values unchanged,
then closes the writers and verifies that their space can be reused. The
pre-existing storage fixtures must remain readable throughout.

## Installed containers

After creating the storage fixtures above, build a current system envelope
with `make rp2040-envelope RP2040_BOARD=pico_w_2023`, then run:

```sh
python3 tests/hw/rp2040/containers.py \
  --toit build/host/sdk/bin/toit \
  --envelope build/rp2040-pico_w_2023-envelope/firmware.envelope \
  --port /dev/serial/by-id/OBSERVED_PICO_LINK --id OBSERVED_BOARD_ID \
  --output build/rp2040-container-tests
```

The runner compiles a child with assets and streams its relocatable image in
257-byte writes through the container service. It verifies RPC start/wait,
arguments, GC, assets, auto-start after normal reset and firmware replacement,
metadata persistence, and uninstall. It then recreates the storage fixtures,
runs the exhaustion test, and restores an ordinary smoke application. Five
firmware versions are consumed. `--build-only` prepares the images without
touching hardware.

The registry has only 56 KiB. The installer therefore removes the named
`toit-rp2040-test/persistent` and `toit-rp2040-test/region` fixtures and the
`success` key in `toit-rp2040-test/envelope` to make room for its child; other
storage is preserved. An interrupted run may leave the test child installed
and those fixtures absent. Resume the generated persistence image to remove
the child, then run the generated storage writer and smoke images. Do not
erase the whole registry to make this test fit.

## Firmware service

`firmware-self-update` exercises the standard `system.firmware` API. It checks
mapping and configuration access, rejects invalid bounds, competing writers,
incomplete data, a bad checksum and invalid vectors. It terminates a client during
a multi-sector write and checks that a new writer can take ownership. It then copies the running
image through `FirmwareWriter` while GC and a timer task run, commits its SHA-256,
and upgrades. After reboot it verifies the running image's digest against a
flash bucket marker and removes that marker.

Build and save this fixture and an ordinary VM smoke image, then run:

```sh
python3 tests/hw/rp2040/firmware.py \
  --port /dev/serial/by-id/OBSERVED_PICO_LINK --id OBSERVED_BOARD_ID \
  --version 140 --test-image /tmp/rp2040-firmware-test.bin \
  --restore-image /tmp/rp2040-restore.bin
```

The runner requires the service-installed version, exact size/CRC and post-reboot
application verification, then restores the smoke image. It consumes three
consecutive versions. If interrupted after commit, the test marker may remain
in `toit-rp2040-test/firmware`; rerun the same fixture to finish its verification.
The test copies the current image. `firmware-stream.py` additionally streams a
different image over USB stdin into `FirmwareWriter`, rejects an incomplete
transfer and a complete corrupt image, and verifies the changed image's SHA-256
after upgrading. It mutates each caller buffer after writing and runs concurrent
GC. The runner checks the loader's exact version, size and CRC, then restores
the smoke application. This passed with a 602,116-byte target on Pico W-2023;
it isolates the firmware service from the unresolved ESP8285 download failure.

```sh
python3 tests/hw/rp2040/firmware-stream.py \
  --toit build/host/sdk/bin/toit \
  --envelope build/rp2040-pico_w_2023-envelope/firmware.envelope \
  --output build/rp2040-w2023-vm/firmware-stream \
  --port "$PICO_PORT" --id "$PICO_ID" --restore-image "$SMOKE_IMAGE"
```

Use the observed persistent USB path and board ID, and a saved smoke image.
`--build-only` prepares the images without accessing hardware. A successful run
consumes three versions; it leaves the recovery loader and helper untouched.

## Cryptography and TLS

Build `crypto-rp2040.toit` or `tls-rp2040.toit` as the application, saving a
separate ordinary `vm-smoke.toit` image first. Run the corresponding Python
runner with `--uploader SDK/lib/toit/bin/rp2040-ota-upload`, `--port` (persistent
USB path), `--id`, `--image` and `--restore-image`. Both runners restore and
verify the smoke application even after a test failure. They update only the
application; the recovery loader is preserved.

The crypto fixture checks random requests across the entropy and DRBG size
boundaries, fresh output after reset, asynchronous RSA with concurrent RNG,
GC and timers, abandoned/queued generation, ECDSA and ECDH. The runner requires
separate P-256, P-384 and P-521 results before accepting the final PASS. It uses 1024-bit
RSA keys only to shorten regression runs, not as an application recommendation.
Output inequality is a regression check, not an entropy-quality measurement.

The TLS fixture uses base64-framed records over USB against Python/OpenSSL.
It requires mutual certificate authentication, hostname validation, exact
encrypted echoes and explicit rejection of a wrong hostname and untrusted CA.
It also checks an unset clock, not-yet-valid and expired certificates, and a
successful connection after correcting the clock. The expired case sets the
clock to 2050, covering values beyond the 32-bit Unix time limit. It does not
use the modem or header pins.
The existing long-lived test certificates and test-only keys are reused from
`tests/tls-no-net-test.toit`.

The host CTest `tests/ctest/entropy-mixer-test.cc` uses linker-level fault
injection on Linux to check entropy seed/reseed failures and subsequent retries.
It uses the production mixer without a firmware fault-injection interface.

## UART and modem

`peripheral-lifecycle.toit` first requires its test pins GP18–21 and GP26–27 to follow
both weak-pull directions, without enabling output drivers. It then repeats
ADC ownership/mux/read/close, I2C allocation-failure cleanup and empty-bus NACK,
and SPI target cleanup plus controller transfers in all four modes. Run via
`pio-lifecycle.py --expect 'peripheral-lifecycle-rp2040: PASS'`. These checks do
not measure ADC accuracy or verify external SPI/I2C data.

External checks reuse the original rig: GP4→ESP32 GPIO19, GP5→GPIO27,
GP6→GPIO18, GP7→GPIO23 and GP26→GPIO25. No additional jumpers are needed.
Preserve these connections and the UART/RUN wires. Before enabling
peripheral drivers, run `peripheral-wiring.toit` with
`peripheral-wiring-esp32.toit`: all five signal pairs remain inputs and must follow
independent weak pulls in both directions. This checks mapping and isolation.
GPIO25 is reserved for the subsequent ESP32 DAC stimulus; it stays an input
during the wiring check.

`external-peripherals.py` runs that input-only check first and installs
`external-peripherals.toit` only after it passes. Build and save both fixture
binaries, then rebuild `vm-smoke.toit` for restoration. Pass `--wiring-image`,
`--image`, `--restore-image`, `--uploader`, `--port`, `--id`, `--jag`,
`--helper-device` and `--helper-repo`. Omit `--image` to check wiring alone.
The runner restores the Pico smoke application and helper Wi-Fi service even
after failure. The input-only check must pass before the runner enables any peripheral outputs.

The external fixture synchronizes seven DAC levels (0–3 V) over the existing
UART, samples GP26 in 129-sample requests, checks raw/voltage consistency,
endpoint bounds and intermediate levels against a two-point fit. This tests
the combined DAC/ADC path; it is not calibrated absolute ADC metrology.
It then checks the wired I2C0 instance at 100 and 400 kHz in both roles: reads,
repeated starts, FIFO-boundary writes through 1025 bytes, missing-target NACK,
and close/reopen between target transactions. Every transferred byte is checked
by the receiving board. SPI exercises controller modes 0–3 against the ESP32
non-DMA target, then Pico target modes 1/3 with and without DMA, including
1025-byte DMA transfers. It reuses targets across short transactions with
different response patterns, checks deadline expiry and task cancellation
while waiting for clocks, and cancels/closes after three verified bytes while
the controller still holds CS active. Subsequent full transactions check for
stale transmit/receive data and successful resource reuse. The same data wires
change direction when the roles change; both sides close the previous
peripherals before configuring the next.
This complete fixture passed on Pico W-2023 using the existing wiring above,
including the bidirectional input-only gate and restoration of the ordinary
Pico smoke application and helper Wi-Fi fixture.
The extended SPI recovery cases also passed in modes 1/3 with and without DMA.
BufferTarget checks include autonomous short/overlength transactions, copied
response ownership, response updates, receive queue order, exact overflow
counts, recovery after draining the queue, GC and close with a blocked receiver.
The helper leaves 1 ms between these autonomous transactions; this does not
establish a minimum supported CS-inactive interval. A separate command-phase
test generates 1/7/9/11/15 clocks plus 8/16-clock controls. It verifies that
partial trailing bytes are discarded and a subsequent complete transaction
starts at bit zero on the same target. All these cases passed on Pico W-2023.
The I2C tests use internal pulls on this rig; passing at the configured 400 kHz
does not establish electrical rise-time or timing margins for other wiring.

`pwm-gpio.py` reuses the verified GP16 -> ESP32 GPIO34 and GP17 <- GPIO4 wires.
The Pico tests GPIO levels/open-drain behavior and pin reservations on GP16,
then uses GP16 for PWM and GP17 only for UART command input. The ESP32 measures
100/400/8000 Hz and 25/50/75% duty, plus static 0/100% duty. Twenty close/reopen
cycles check GPIO/PWM resource release. Use the same arguments as
`uart-stress.py`; this runner starts its peer after the Pico reports ready and
restores both devices afterward.

`uart-stress.toit` runs against `uart-stress-esp32.toit` on the verified
GP16/GP17 to ESP32 GPIO34/GPIO4 connection. It checks large binary transfers
with GC/timers at 115200 and 921600 baud, 9600-baud operation, deliberate
small-buffer overflow and recovery, reservations, invalid mux settings and
twenty close/reopen cycles that wake a blocked reader. Traffic stress uses
large buffers; the overflow test explicitly selects the small buffer.

`uart-stress.py` deploys both test programs and restores the Pico smoke image
and ESP32 Wi-Fi echo service afterward. Pass `--uploader`, `--port`, `--id`,
`--image`, `--restore-image`, `--jag`, `--helper-device` and `--helper-repo`.
The helper repository must match its installed Jaguar firmware.

`uart-smoke` sends 32 distinct 256-byte frames over GP16/GP17 while collecting
garbage and checks every echoed byte. First run `uart-peer-esp32.toit` on the
helper (TX=GPIO4, RX=GPIO34), after verifying the wiring with weak pulls.
This test uses UART0, so it must run separately from the onboard modem test.
`uart-bridge.py` tests the native probe's USB/UART bridge against the same
ESP32 helper: 16 distinct 4096-byte payloads, then idle timeout and console
recovery. Pass the Pico's persistent USB path with `--port`.

[`modem/wifi-smoke.toit`](modem/wifi-smoke.toit) checks Wi-Fi association and
binary TCP/UDP echo using the sibling cellular package's shared AT session.
See [its setup instructions](modem/README.md) for the modem firmware and helper.

On W-2023, GP0/GP1 belong to the ESP8285 modem. GPIO and other peripheral
drivers reject them; UART permits TX=GP0 and RX=GP1 for the modem. GP23, GP24
and GP29 are reserved for supply circuitry. On official Pico W, the restricted
radio/supply pads are GP23, GP24, GP25 and GP29 instead.

`modem-identify.toit` is for W-2023 only. It sends `AT` and `AT+GMR` over UART0
at 115200 baud and requires an `OK` response to each. Before running it, move
the helper's GPIO4 jumper from GP1 to GP17 and verify the connection using the
native input-only probe. The newly built W-2023 recovery loader samples GP17;
an older GP1 loader must be replaced separately before GPIO-triggered recovery
can use the new wire. USB updating and watchdog recovery remain available.

The VM's flash registry occupies the reserved 56 KiB at offsets
`0x12000..0x1ffff`. Application updates preserve it. The RP2040 application is
linked at `0x10020000`, and both loader and host uploader check its initial
vectors before installation.

## Envelope configuration and assets

Build an envelope with `make rp2040-envelope RP2040_BOARD=pico_w_2023`, then
run `python3 tools/rp2040/tests/envelope-test.py build/rp2040-pico_w_2023-envelope`.
The retained `envelope-tests/firmware.bin` contains `envelope-rp2040.toit`,
a payload asset and configuration. Upload it using `tools/rp2040/upload.py`
and require this exact startup line:

```
envelope-rp2040: PASS bundled container, assets, config, GC, storage RPC, and identity
```

The application verifies the attached asset, configuration through the firmware
service, GC with retained data, storage RPC and the flash-derived board identity.
The host tests check relocation, container flags, deterministic extraction,
asset round-trip, invalid vectors, unsupported formats and slot exhaustion.
Restore an ordinary VM smoke image after the hardware check.

`envelope-reset.py` uses the retained `envelope-tests/installed.envelope` to
verify configuration (including nested data and a 64-bit integer), assets,
container startup and the existing persistent fixtures before and after an
explicit runtime reset. It requires the storage fixtures created by `storage.py`.
Pass `--toit SDK/bin/toit`, `--envelope`, `--port`, `--id` and `--restore-image`.
The runner restores the smoke application and the reset fixture removes its
own temporary bucket value.

## Installed SDK uploader

`uploader.py` invokes `toit tool firmware ... flash` with an envelope fixture,
checks application startup, then restores a raw smoke image using the native
uploader installed beside that SDK. Pass `--toit SDK/bin/toit`, `--envelope`,
`--config`, `--port` and `--restore-image`. It automatically increments the
recovery descriptor's version twice. The host-native uploader's separate PTY
regressions are under `tools/rp2040/ota-upload` and run through CTest.
