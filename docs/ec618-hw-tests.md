# EC618 hardware tests — living plan

Goal: grow real hardware-in-the-loop coverage for the EC618, and implement the
missing peripheral functionality the tests exercise. This is a **living
document** — update it as tests/peripherals land or as the setup changes.

The pattern (after `tests/hw/esp32`): each dual-board test is two files,
`<name>-ec618.toit` (device under test, run via the mini-jag tester) and
`<name>-esp32.toit` (helper that drives/observes signals, run via Jaguar). They
coordinate by signal + generous timing windows (the two boards are driven by two
independent control planes, so there is no shared barrier).

See also: `tests/hw/ec618/README.md` (how to run), `tests/hw/esp-tester/`
(the mini-jag harness), `docs/ota-dual-slot-plan.md` (the OTA design),
`docs/ota-contract.md` (the frozen base/VM ABI).

## The two rigs

There are **two** physical setups on Florian's desk. The EC618 is moved between
them; only one is "live" at a time.

### 1. Test rig — `modest-affair` (dual-board peripheral tests)
- **ESP32**: classic ESP32 `modest-affair` (Jaguar over WiFi). Has **DACs**
  (IO25/IO26) — needed for the ADC test. USB serial = **CP2102N** (Silicon Labs).
- **EC618**: console/control on **UART0**. USB serial = **CH340** (QinHeng).
- **Identify the ports by CHIP, not by `/dev/ttyUSBN`** — the numbering swaps
  between sessions. As of 2026-06-08: EC618 (CH340) = `/dev/ttyUSB0`, ESP32
  (CP2102N) = `/dev/ttyUSB1`. Confirm with
  `udevadm info -q property -n <port> | grep ID_VENDOR` or
  `esptool.py --port <port> chip_id` (only the ESP32 answers). The EC618
  `toit tool firmware flash --port <x>` value is **unused** (ectool finds the
  boot-ROM COM itself) — only the CLI requires the flag.
- **Boot mode**: **manual** (no auto-boot); operator triggers the boot ROM by
  hand for a full flash.
- **Wiring**: full ESP32↔EC618 GPIO/ADC harness (see table below). This is the
  only rig that can run the dual-board peripheral tests.

### 2. Dev/flash rig — `quirky-plenty` (full-flash + OTA debugging)
- **ESP32**: ESP32-C6 `quirky-plenty` (`/dev/ttyACM0`). **No DAC**, and **no
  GPIO/ADC test wiring** — wired to the EC618 only for boot control and console.
  Cannot run the dual-board peripheral tests.
- **EC618**: console/control on **UART1** (CH340, e.g. `/dev/ttyUSB0` there).
- **Boot mode**: **automatic** — ESP32-C6 GPIO19 → EC618 USB_BOOT (active high),
  GPIO23 → 5 V relay (active high). So this rig can **full-flash a complete
  image** over the boot ROM (and is the safe place to iterate on the OTA path —
  a full flash always recovers it).
- Helpers in `dev/ec618-rig/` (`boot-high.toit`, `boot-run.toit`,
  `flash-full.sh`, …). `export ECTOOL_PATH=/home/flo/.pyenv/versions/3.8.18/bin/ectool`.

> **UART per rig:** the print/console UART differs (UART0 on the test rig, UART1
> on the dev rig). It is one build-time choice
> (`CONFIG_TOIT_EC618_PRINT_UART_ID` in `toolchains/ec618/ec618_config.h`); the
> mini-jag agent opens whatever `ec618.print-uart-id` reports, so a rig switch is
> a **single config line + rebuild + (re)flash** — the agent needs no edit.

## Control planes

- **EC618 (device under test)**: the resident **mini-jag agent**
  (`tests/hw/esp-tester/mini-jag.toit`) over the print UART. Driven from the
  host with `tester.toit run --chip ec618 --port-board1 <ec618-port> <test-ec618.toit>`.
  Verdict = the test container's exit code. Also does OTA firmware-update
  (`firmware-update` subcommand) over the same wire.
- **ESP32 (helper)**: **Jaguar** over WiFi (`jag run <test-esp32.toit> -d <name>`).
  Program `print` output is read from its serial console.

A dual-board test launches the ESP32 helper first (it waits for activity), then
runs the EC618 half; the helper prints a `... PASS`/`... FAIL` verdict.

## Wiring (test rig: ESP32 GPIO ↔ EC618 board pin)

The EC618 module's silkscreen GPIO labels are **Air780 module names, not the
EC618 GPIO controller-bit numbers** the `ec618` library uses, so the physical
pad behind each board pin is confirmed **experimentally** (toggle it, see which
ESP32 pin moves). One controller bit can surface on two pads (e.g. GPIO11 =
PAD26 *and* PAD22), which is the hint for the duplicated "GPIO11"/"GPIO10" pins.

```
ESP32 pin   EC618 board pin (label)              EC618 pad / channel     status
---------   ----------------------------------   ----------------------  ----------
25 (DAC1) -> [~2:1 divider] -> ADC1 (pin 4)      ADC channel 1 (AIO4)    CONFIRMED (exact, ratio ~0.47)
26 (DAC2) -> [near-direct]  -> ADC0 (pin 3)      ADC channel 0 (AIO3)    CONFIRMED (exact, ratio ~0.91 — divider missing on this path)
27        -> 05  (GPIO11, uart2_txd)             PAD26 (GPIO11 primary)  CONFIRMED (gpio-output)
14        -> 06  (GPIO10, uart2_rxd)             PAD25 (GPIO10 primary)  to verify
13        -> 09  (GPIO22, MAIN_DTR)              ?                       to verify
33        -> 10  (GPIO08, SPI0_CS, I2C1_SDA)     ?                       to verify
32        -> 11  (GPIO10, UART2_RX, SPI0_MISO)   ?                       to verify
23        -> 12  (GPIO01, PWM10)                 ?                       to verify
22        -> 13  (GPIO09, I2C1_SCL, SPI0_MOSI)   ?                       to verify
21        -> 14  (GPIO11, UART2_TX, SPI0_CLK)    PAD22 (GPIO11 alt)      to verify
19        -> 18  (GPIO24, MAIN_RI, PWM01)        ?                       to verify
18        -> 22  (I2C0_SDA)                      I2C0 SDA                to verify
17        -> 23  (I2C0_SCL)                      I2C0 SCL                to verify
 2        -> 27  (GPIO27, NET_STATUS, PWM04)     ?                       to verify
 4        -> 30  (UART1_TXD)                     UART1 TX (PAD34)        (= console on dev rig)
16        -> 31  (GPIO18, UART1_RXD, PWM14)      UART1 RX (PAD33)        (= console on dev rig)
```

### Voltage domains (important)
- EC618 IO is ~1.8 V. The ESP32 (3.3 V) reads the EC618's 1.8 V high cleanly, so
  **EC618 → ESP32 is safe and works** (verified by gpio-output).
- **ESP32 → EC618 (3.3 V into 1.8 V) is risky** without a divider — only the ADC
  lines have one. Prefer EC618-as-driver tests; for EC618-as-receiver (UART RX,
  I2C, GPIO input) confirm 3.3 V tolerance or add a divider first.
- EC618 ADC: with the wide range it reads well past 1.8 V (the adc test saw
  2.894 V on ch1); the ESP32 DACs (0–3.3 V) still feed it through external
  dividers to stay in range.

## Peripheral status (EC618 firmware)

| Peripheral | Status | Notes |
|-----------|--------|-------|
| GPIO | ✅ implemented, HW-tested | `gpio_ec618.cc`. Pull-up **HW-validated**; pull-down via `GPIO_PullConfig` (matches the SDK) but **pad-limited** — PAD26/UART pads are pull-up-only (pull-down is mainly on the wakeup pads). Input-buffer now enabled for input pins. **Open-drain: TODO** (emulate via output↔input). |
| UART | ✅ implemented | `uart_ec618.cc` (UART0/1/2). |
| I2C | ✅ implemented | `i2c_ec618.cc`. |
| Cellular | ✅ implemented | `cellular_ec618.cc`. |
| **ADC** | ✅ implemented, **HW-tested exact-value (both channels)** | `adc_ec618.cc`; `gpio.adc` channel ctor (0→AIO3, 1→AIO4). Self-calibrating ±60 mV. |
| DAC | ❌ n/a | EC618 needs no DAC for these tests (the ESP32 provides DAC). |
| PWM | ❌ missing | Wired (PWM01/04/10/14); implement + test next. |
| SPI | ❌ missing | SPI0 wired; implement + test. |

Design decision: bind the **PLAT driver/HAL directly**, do **not** use the
LuatOS `luat_*` interface layer. A `TODO(toit)` in
`third_party/.../project/toit/src/toit_main.c` tracks dropping the few `luat_*`
calls still in the glue.

## Done
- **Dual-board harness** validated end-to-end (ESP32 Jaguar + EC618 mini-jag).
- **`gpio-output`** (EC618 drives GPIO11/PAD26 square wave, ESP32 IO27 counts
  edges) — **passing, committed**.
- **`gpio-pull`** (2026-06-08): **pull-up HW-validated** on PAD26 — with no pull
  the floating line reads a noisy ~8-11/16, and enabling the internal pull-up pins
  it to 16/16. **Pull-down does NOT pull PAD26 low** (reads 16/16 high even from a
  floating start, and the no-pull "float" read is jittery, so it isn't an external
  pull-up): PAD26 (UART2_TXD) is **pull-up-only**. The firmware's
  `GPIO_PullConfig(pad, 1, 0)` matches the SDK's own pull-down usage, so this is a
  pad/HW limitation (pull-down on the EC618 is mainly on the dedicated wakeup pads,
  a separate `APmuWakeupPadSettings` path), not a firmware bug. A clean pull-down
  check needs a pad that supports it — **rig-mapping TODO**. `gpio-pull-{ec618,esp32}.toit`.
- **mini-jag reconnect-after-OTA fixed** (2026-06-08): the host now drains the
  post-reset boot-ROM/bootloader banner before pinging, so the firmware-update
  reconnect/validate succeeds without `--debug-boot` (previously `read-ack` spent
  one ping attempt per backlog byte and never reached the agent's pong).
- **Reset-on-VM-exit safety net** (2026-06-08, `CONFIG_TOIT_EC618_RESET_ON_VM_EXIT`,
  default 1): on a full-VM `EXIT_DONE` the firmware now resets (reboots into the
  program) instead of deep-sleeping with no wakeup timer. This makes the rig
  self-recover from a crash that brings the whole VM down — see the incident
  below. *(Built but not yet HW-verified: the board was bricked when this landed.)*
- **ADC exact-value test passing** (2026-06-08, test rig): the ESP32 drives a
  known DAC staircase; the EC618 self-calibrates the per-channel board divider
  (2-point fit) and verifies every level within ±60 mV. Both channels pass
  (errors <16 mV). The two DAC→ADC paths have different dividers: one is a clean
  **~2:1** (ratio ~0.47), the other is **near-direct** (ratio ~0.91 — it reads
  ~2.89 V at a 3.0 V DAC step where a 2:1 divider would give ~1.5 V; the ~0.91 vs
  1.0 is just the ADC's uncalibrated gain/offset). **Swapping the two DAC→ADC
  wires moved the ratios with the DAC path, not the ADC channel** — so both EC618
  ADC channels are healthy and the missing divider is on the **IO26/DAC2** rig
  path. Current wiring: IO25(DAC1)→[~2:1]→ADC1, IO26(DAC2)→[near-direct]→ADC0. The
  test self-calibrates per channel, so it passes regardless; the divider asymmetry
  is a rig note, not a test concern. `adc-{ec618,esp32}.toit`.
- **OTA A≠B FIXED** (see below) — changed-firmware OTA now boots + validates, so
  real (non-smoke) dual-board tests can be delivered by OTA.
- **EC618 mini-jag tester** on a configurable print UART (`ec618.print-uart-id`).
- **`basics`** smoke test passing on the test rig (UART0).

## OTA A≠B — FIXED (2026-06-08)

**Root cause:** the VM's writable `.data` init (interpreter dispatch table,
per-module `*_primitives_` tables, mutable globals) lived in the **fixed base**
flash region (`.load_dram_shared` LMA), not in the slots, and the OTA never
updated it. So a slot booted with the *last full-flashed* firmware's `.data`; a
firmware whose `.data` differed (e.g. ADC: 141↔142 slot pointers) ran the new
slot code against the **old** `.data` → corrupt dispatch/primitive tables →
wedge → AON watchdog (~27 s) → rollback. (`A==B` coincidentally worked; full
flash always worked because it rewrites the base `.data`.)

**Fix (shipped, HW-verified):** each firmware carries its **own** VM `.data` init
image **inside its slot**, and the device copies the **active slot's** copy to
RAM at boot before relocating the `.data` slot pointers. Mechanism: a `data_size`
word in the SRL1 table; a `__vm_data_start/_end` linker bracket; `gen-slot-reloc`
extracts the image → `slot-data.bin` (`$ec618-data.bin`); `firmware.toit` places
it after the extension + appends it to the canonical image; `toit_ec618.cc`
`load_active_slot_vm_data()` copies it at boot. Full details + the frozen contract
in **`docs/ota-contract.md`**.

**Verified** on the dev rig: full-flash firmware-1 (ADC, 712 B `.data`) boots
slot A; OTA firmware-2 (no-ADC, 708 B `.data`) trial-boots slot B, reconnects,
and validates. (Previously the changed `.data` wedged + rolled back.)

## Known issues
1. **Per-rig UART** (UART0 test rig / UART1 dev rig) — one config line,
   `CONFIG_TOIT_EC618_PRINT_UART_ID`; the agent auto-follows.
2. **OTA'd VM `.data` must fit the base reservation.** The `__vm_data` bracket is
   sized to the base VM's `.data` (not padded), so a future OTA whose `.data` is
   *larger* than the base image's would overrun PLAT `.init_array`. Today's images
   fit; consider padding the reservation if VM `.data` grows. (`docs/ota-contract.md`.)
3. **ADC accuracy / calibration**: `trimAdcSetGolbalVar` is not in the jump table,
   so `HAL_ADC_CalibrateRawCode` uses its uncalibrated linear fallback (fine for
   ratiometric tracking; add it to the wrapped set for a calibrated reading —
   base-image change, needs a full flash).
4. **GPIO-service teardown crash → deep-sleep brick (2026-06-08).** Running
   `gpio-map` (which opened/closed ~6 GPIO pins in a container, re-using
   controller bit 11) crashed the device on container teardown: a `CLOSED`
   exception in the shared GPIO service (decoded with the *agent's* snapshot, not
   the test's) brought the whole VM down (`EXIT_DONE`), and the firmware deep-slept
   with **no wakeup timer** → bricked until a physical power-cycle (watchdogs are
   gated while asleep; the rig has no remote reset). Two follow-ups: **(a)**
   `CONFIG_TOIT_EC618_RESET_ON_VM_EXIT=1` (added, default on) turns that VM exit
   into a self-recovering reboot — the rig-level safety net; **(b)** the GPIO
   service should not crash on a normal multi-pin open/close/teardown — root-cause
   the `CLOSED` exception in the gpio resource/service path (suspects: re-opening a
   just-closed controller bit, or finalizer ordering). `gpio-map` is hardened to
   not re-drive bit 11 and must only be run on `RESET_ON_VM_EXIT=1` firmware.

## Exhaustive dual-board testing — design + status (2026-06-08)

Goal (Florian): tests should be **exhaustive** like `tests/hw/esp32` — exercise
every config (baud rates, RTS/CTS, RS485, modes; PWM freq/duty; ADC ranges; GPIO
modes), not just "does it work."

### Verdict capture (how results come back)
- **EC618 side**: the mini-jag tester reports the container's exit code — captured
  directly by `tester.toit run`.
- **ESP32 side**: `jag run` returns right after *deploy*; it does NOT stream the
  program's `print` back. The ESP32's verdict goes to its **serial console**
  (the CP2102N port) — read that port to get the "... PASS/FAIL" line. (This is
  how gpio-output / uart2 verdicts are obtained.)

### Control lane (Florian's suggestion) + the jag-args constraint
- `jag run` **cannot pass program arguments** to a networked device (only
  `-d host`). So the ESP32 half can't be parameterized per phase (baud, etc.)
  from the host. The fix is an **in-device control lane**: the EC618 tells the
  ESP32 each phase/param over a dedicated UART.
- Plan: **control lane = UART1 when testing UART2; UART2 for everything else.**
- The **safe** control direction is **EC618 → ESP32** (1.8 V → 3.3 V). A one-way
  control lane (EC618 commands; ESP32 reports via its console) needs no risky
  direction and is the place to start.

### Safe vs. risky directions (the board-damage rule)
- **EC618 drives → ESP32 reads = SAFE** (ESP32 high-Z input; 1.8 V→3.3 V is read
  cleanly). Covers: UART TX, PWM, GPIO output, DAC→ADC (ESP32 drives its own DAC,
  EC618 reads its own ADC). These can be made exhaustive now.
- **ESP32 drives → EC618 reads = RISKY** (3.3 V into a 1.8 V pad). Covers: EC618
  UART RX, CTS, GPIO input, I2C, SPI. Do **not** drive these directly. The safe
  way is ESP32 **open-drain** (only ever pulls low, never outputs 3.3 V) + an
  **EC618 input pull-up** (line idles at 1.8 V). That needs EC618 GPIO
  pull-up/down + open-drain, which is **UNIMPLEMENTED** — implement + verify on a
  gpio toggle first. Always gpio-toggle a wire (EC618 drives → ESP32 reads) to
  confirm connectivity before relying on it.

### Per-peripheral exhaustive plan
- **UART2**: baud sweep (TX side, safe — *baseline committed*); RTS/CTS flow
  control and RS485 (the EC618-output side is safe; the EC618-receive side is
  risky); EC618 UART RX (risky direction).
- **PWM** (not yet implemented): EC618 drives, ESP32 measures freq/duty over a
  range — safe direction.
- **ADC**: exact-value staircase (EC618 measures the ESP32 DAC, self-calibrating
  the board divider, ±60 mV per level) — *done, safe*.
- **GPIO**: output modes (safe); input + pull-up/down + open-drain (risky
  direction — needs the open-drain feature above).
- **I2C / SPI**: last; likely reflash the ESP32 with a C **slave** sketch.

### Status / blocker
- UART2 baseline test committed (115200, RX integrity). The automated baud sweep
  is blocked on the control lane (jag-args) — next step.
- **RESOLVED (2026-06-08):** the earlier "modest-affair EC618 went unresponsive,
  needs a physical power-cycle" blocker is fixed by the **general mini-jag
  watchdog** (commit 92dde5d8): the agent now arms the hardware watchdog for its
  whole life and feeds it on every host message, so an agent wedge / hung VM
  resets straight back into a fresh agent (~60 s) with no external reset. A
  device hang no longer stalls autonomous HW work. (A **short-circuit** can still
  damage the boards — that risk is unchanged; follow the safe-direction +
  gpio-toggle-first rule below.)

## TODO / roadmap
- [x] Make mini-jag open `ec618.print-uart-id`'s controller.
- [x] Full-flash + confirm firmware boots clean (isolates OTA from firmware).
- [x] Fix the OTA A≠B / per-slot `.data` bug.
- [x] Run the ADC functional test on the test rig (both channels track; no dead pin).
- [ ] Add `trimAdcSetGolbalVar` + `delay_us` to the jump-table wrapped set
      (`gen-plat-jt`) for a calibrated ADC + clean conversion wait (base-image
      change; needs a full flash).
- [ ] Add a periodic **state heartbeat** to the mini-jag agent (observability).
- [ ] Generalize `--debug-boot` into a `--verbose-uart` tester flag.
- [ ] Implement + test **PWM** (EC618 drives, ESP32 measures frequency/duty).
- [ ] **UART2** loopback (EC618 TX → ESP32 RX; safe 1.8 V→3.3 V direction).
- [ ] **SPI**, **I2C** (consider the 3.3 V→1.8 V direction / dividers first).
- [x] **GPIO pull-up/down** (`set_pull`, and `config` honours it) + input buffer
      for input pins.
- [ ] **GPIO open-drain**: emulate via output↔input (separate commit; see the
      `TODO(toit)` in `gpio_ec618.cc`).
- [ ] More **GPIO**: input (ESP32 drives — level-shift first), interrupts.
- [ ] Experimentally map the remaining `?` pads in the wiring table.
- [ ] Eventually wire the EC618 tests into CTest (needs a rig power-cycle story).
