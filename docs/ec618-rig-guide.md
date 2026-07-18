# EC618 rig guide — how to drive the two setups

Practical operator's guide for the two physical rigs on Florian's desk. Written
so the work continues on a different host machine wired to the **same rigs**.
Pairs with [ec618-roadmap.md](ec618-roadmap.md) and the wiring table in
[ec618-hw-tests.md](ec618-hw-tests.md).

## The two rigs at a glance

| | `modest-affair` (test rig) | `quirky-plenty` (dev/flash rig) |
|---|---|---|
| Helper MCU | classic **ESP32** (has DACs IO25/26) | **ESP32-C6** |
| Helper access | Jaguar over WiFi | Jaguar over WiFi |
| Helper USB serial | CP2102N | native USB (`ttyACM0`) |
| EC618 form | dev board (Air780E) | small EC618 module |
| EC618 console UART | **UART0** (`control uart=0`) | **UART1** (`control uart=1`) |
| EC618 USB serial | CH340 dongle | CH340/CP2102N dongle |
| EC618 boot | **manual** (2 s PWRKEY press, no auto-boot) | **remote** (C6 GPIO strap + relay) |
| Peripheral wiring | **full** GPIO/ADC/I2C/SPI harness | **none** (boot + console only) |
| Use for | all dual-board peripheral tests | full flash + OTA iteration (always recoverable) |

Both EC618s can be plugged in **at the same time** (modest on UART0, quirky on
UART1). Only one is usually the focus, but don't assume only one is present.

## Port identification — READ THIS FIRST (the #1 time-sink)

**Never trust `/dev/ttyUSBN`.** The kernel renumbers across sessions and even
mid-session. Worse: if both EC618 dongles are the serial-less CH340 type they
**share one `/dev/serial/by-id` name** (`usb-1a86_USB_Serial-if00-port0`), so
only one gets the symlink and it **flip-flops** between the two boards on every
re-enumeration. The host doctor warns when `ttyUSB` nodes outnumber their by-id
links (the collision signature).

Two reliable methods, in order of preference:

1. **Console output = ground truth.** Read the port and look for the mini-jag
   banner: `[mini-jag] starting; control uart=0` → **modest**;
   `control uart=1` → **quirky**. The boot line `booting VM slot X` and
   `running on EC618` confirm it's an EC618 console at all.
   ```
   stty -F <port> 115200 raw -echo
   timeout 90 cat <port>            # watch for the banner (see the watchdog cadence below)
   ```
2. **`/dev/serial/by-path`** — USB topology is stable across renumbering (unlike
   by-id for the colliding CH340s). Map it once per host and script against it.

Other identifiers: `udevadm info -q property -n <port> | grep ID_VENDOR`;
the helper ESP32s are on WiFi so `jag scan --list -o json` gives their IPs and
chips (quirky C6 shows `esp32c6`, modest shows `esp32`). If a port reads
`Device or resource busy`, a `jag`/`socat`/`cat` you left running holds it —
check with `lsof <port>` before theorizing about hardware.

> As observed on 2026-07-18 (VOLATILE, verify with method 1): modest EC618 =
> ttyUSB0, quirky EC618 = ttyUSB2, modest ESP32 (CP2102N) = ttyUSB1, quirky C6 =
> ttyACM0. Do not hardcode these.

## Control planes

- **EC618 (device under test):** the resident **mini-jag agent**
  (`tests/hw/esp-tester/mini-jag.toit`) over the console UART. Drive it from the
  host tester; the verdict is the test container's exit code.
- **ESP32 helper:** **Jaguar over WiFi** — `jag run <helper>.toit -d <name>`.
  `jag run` returns right after *deploy*; the helper's `print` output goes to its
  **serial console**, not to `jag run`'s stdout. For modest read the CP2102N
  port; for quirky read `ttyACM0`.

A dual-board test: launch the ESP32 helper first (it waits for a signal), then
run the EC618 half; the helper prints its own `... PASS`/`... FAIL` line.

## Running a device test (both rigs)

```
stty -F <ec618-console> 115200 raw -echo
# wait for a fresh agent so you land in a clean cycle:
timeout 150 grep -am1 "mini-jag. starting" <ec618-console> >/dev/null && sleep 3

build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
    --chip ec618 --toit-exe build/host/sdk/bin/toit \
    --port-board1 <ec618-console> tests/hw/ec618/<name>-ec618.toit
```

Pass an argument to a test with `--arg <value>` (reaches the container's `args`).
Example — flip the console UART then let the watchdog reboot into it:
`... run --arg 1 tests/hw/ec618/console-set-ec618.toit`.

## OTA (both rigs, over the console UART)

```
build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit firmware-update \
    --toit-exe build/host/sdk/bin/toit --port <ec618-console> \
    --envelope build/ec618/firmware.envelope
```

Streams the image to the inactive slot, reboots on trial, smoke-tests, and
validates (permanent) unless `--no-validate`. This is the fast inner loop for
slot-side changes — no full flash needed.

### Running a test larger than the 64 KiB flash registry

The regular `tester run` path compiles EC618 tests at O2 with assertions and
installs an anonymous image in the 64 KiB flash registry. If the resulting
image is still too large (certificate-root TLS is one example), embed exactly
one named test in a temporary envelope and run it from the VM slot:

```
build/host/sdk/bin/toit compile --snapshot -O2 --enable-asserts \
    --project-root tests/hw/ec618 -o /tmp/ec618-test.snap \
    tests/hw/ec618/net-https.toit
build/host/sdk/bin/toit tool firmware --envelope=build/ec618/firmware.envelope \
    container add --trigger=none -o /tmp/ec618-test.envelope \
    test /tmp/ec618-test.snap
build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit firmware-update \
    --toit-exe build/host/sdk/bin/toit --port <ec618-console> \
    --envelope /tmp/ec618-test.envelope
build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run-embedded \
    --toit-exe build/host/sdk/bin/toit --port <ec618-console>
```

`run-embedded` selects a named slot container; ordinary `run` selects the
anonymous registry test, so the OTA smoke test remains independent. Restore
the standard agent-only envelope with the normal OTA command when finished.

## Full flash (quirky only — the safe recovery path)

Only `quirky-plenty` can full-flash over the boot ROM, so it's where you iterate
on anything that could brick (base image, OTA layout). `export
ECTOOL_PATH=/home/flo/.pyenv/versions/3.8.18/bin/ectool`. Boot control is remote:

- **C6 GPIO19** → EC618 USB_BOOT strap (active high)
- **C6 GPIO23** → 5 V relay (active high)

Helpers in `dev/ec618-rig/`: `boot-high.toit`, `boot-run.toit`,
`boot-run-hold.toit` (power-cycle into normal boot and hold power — used for a
**remote cold boot**; you hear the relay click). Cold-boot quirky's EC618:
`jag run dev/ec618-rig/boot-run-hold.toit -d quirky-plenty`. Flash window is
tight: boot mode first, then the flash command within ~15 s.

modest has **no remote boot** — it needs a physical **2 s PWRKEY press** and does
not auto-boot. If modest goes dark after any bench work (power blip), it is
almost always waiting for that press.

## Using the ESP32 to observe the EC618 (Florian's tip — high value)

The helper ESP32 can *measure* what the EC618 does, not just drive it. Use its
peripherals as instruments over the wired nets:

- **Pulse counter** (`import pulse-counter`) — count edges of an EC618 output
  over a window (e.g. `tests/hw/esp-tester/edge-counter-esp32.toit`, and the
  gpio-output edge tests). Good for "is it toggling / at roughly what rate."
- **RMT input capture** (`import rmt`) — capture exact pulse widths. This is how
  to get **real wire timing** (the I2C SCL-phase measurement for the 400 kHz
  arc). Recipe that worked:
  ```
  pin := gpio.Pin 17                                    # EC618 I2C0 SCL net (PAD13)
  ch  := rmt.Channel --input pin --memory-block-count=4 --clk-div=4 --idle-threshold=4000
  # clk-div=4 on 80 MHz => 20 MHz ticks = 50 ns/tick; idle-threshold=4000 => 200 us gap ends a capture
  sigs := ch.read                                      # returns Signals; iterate: sigs.do: | level period | ...
  ```
  **Toit gotcha:** the multi-line named-argument constructor call **fails to
  parse** — keep the `rmt.Channel ...` call on **one line**. (Same friction as
  multi-line ternaries; see the todo.)
- **GPIO as a logic probe** — the EC618 can toggle a spare pin at a known point
  in its code and the ESP32 counts/timestamps it, to trace execution or UART
  timing without a scope.

For the I2C bench specifically: ESP32 **IO17** taps the I2C0 **SCL** net (board
pin 23 / PAD13) and **IO18** taps **SDA** (board pin 22 / PAD14). Drive probe
traffic from the EC618 with a small "hold at requested Hz" test while the RMT
analyzer prints phase widths on the ESP32 console.

High-speed calibration result (2026-07-18): intermediate fast requests use the
gate-enabled 51.2 MHz source. The nominal 400 kHz path uses a complete
LuatOS-style timing word on 26 MHz and measures **~363 kHz** (1.25 us high +
1.50 us low) at the fastest bounded SCLH=SCLL=30 setting. SCLx=28 can make NACK
traffic free-run.

## Rig gotchas (each of these cost real time)

- **The bare envelope is agentless.** `make ec618` builds a BARE envelope (333
  ext pointers); the tester injects mini-jag + sleeper at run time (→856). A raw
  flash of the bare envelope has **no agent — silence is not death.** Use the
  tester flows, not a raw flash, when you expect an agent.
- **Sensor helpers quit on `Q`.** Every BMP280-family test ends by sending `Q`
  to the ESP32 power helper, which powers the sensor off **and exits**. A
  *chained* run then times out its `P 1` handshake at 10 s against a dead helper
  — a `DEADLINE_EXCEEDED` that looks exactly like an I2C stall. **Re-deploy
  `bmp280-esp32.toit` fresh before every sensor test.**
- **socat PTYs default to `VMIN=0`.** For the UART2 rescue lane
  (`dual-bridge-esp32.toit` + `socat pty,link=/tmp/...,raw,echo=0 tcp:...`), a
  blocking reader (`cat`, `grep`) on the PTY drains-and-EOFs instead of waiting —
  a "silent lane" that is really a lying observer (it manufactured a fake
  "5-minute watchdog wedge"). Run `stty -F /tmp/<pty> min 1 time 0` before
  reading, re-apply after any tester session on it, and never point two readers
  at one PTY.
- **mini-jag watchdog cadence.** An idle EC618 with no host contact prints
  `[toit] FATAL: watchdog timeout (60000 ms without feed) — resetting` and
  reboots about every **65 s** (60 s watchdog + ~5 s ROM/boot). Banners flowing =
  device alive and TX good. To land a command reliably, wait for a fresh
  `[mini-jag] starting` banner and act within the first few seconds
  ("golden window"). The tester's handshake also drains the boot backlog itself.
- **Don't idly poke the helper's serial port.** Opening/closing the ESP32's
  CP2102N console toggles DTR, which fires the dev board's standard auto-reset —
  it looks like the helper "died." That's by design; leave the port alone unless
  you mean to read it.
- **An unpowered board clamps shared nets.** A powered-off chip's protection
  diodes clamp any shared wire to its dead rail (this is why the dev board's NET
  LED lights when the wired ESP32 loses USB power, and why an unpowered BMP280
  read the I2C net low with a ~1 V parasitic rail). Keep helper boards powered
  during tests; a "held-low bus" is often just an unpowered peer.
- **Shared nets.** Some ESP32 pins serve double duty: IO13 powers the BMP280
  **and** drives the EC618 GPIO22 wake pad (same net). Check the wiring table
  before assuming a pin is free.

## Health check

When anything looks off, run the **host doctor** first, then the **device
doctor**:

```
build/host/sdk/bin/toit run --project-root tools tools/ec618/doctor.toit
# then, over the console:
... tester.toit run --chip ec618 ... --port-board1 <console> tests/hw/ec618/doctor-ec618.toit
```

The host doctor checks the partition descriptor, base artifacts (stamp + symbol
match), the flashable image's anchor record + console byte, the envelope agent
(BARE warning), the data-reloc freshness, and enumerates serial ports by chip
(with the CH340-collision warning). The device doctor self-reports base-id,
booted slot, slot size, console byte, and reset/wake cause.
