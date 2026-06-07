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
(the mini-jag harness), `docs/ota-dual-slot-plan.md` (the OTA design).

## The two rigs

There are **two** physical setups on Florian's desk. The EC618 is moved between
them; only one is "live" at a time.

### 1. Test rig — `modest-affair` (dual-board peripheral tests)
- **ESP32**: classic ESP32 `modest-affair` (Jaguar over WiFi). Has **DACs**
  (IO25/IO26) — needed for the ADC test. Serial console = CP2102N on
  `/dev/ttyUSB0`.
- **EC618**: console/control on **UART0** → CH340 on `/dev/ttyUSB1`.
- **Boot mode**: **manual** (no auto-boot); operator triggers the boot ROM by
  hand for a full flash.
- **Wiring**: full ESP32↔EC618 GPIO/ADC harness (see table below). This is the
  only rig that can run the dual-board peripheral tests.

### 2. Dev/flash rig — `quirky-plenty` (full-flash + OTA debugging)
- **ESP32**: ESP32-C6 `quirky-plenty` (`/dev/ttyACM0`). **No DAC**, and **no
  GPIO/ADC test wiring** — it is wired to the EC618 only for boot control and
  console. Cannot run the dual-board peripheral tests.
- **EC618**: console/control on **UART1** → CH340 on `/dev/ttyUSB0`.
- **Boot mode**: **automatic** — ESP32-C6 GPIO19 → EC618 USB_BOOT (active high),
  GPIO23 → 5 V relay (active high). So this rig can **full-flash a complete
  image** over the boot ROM (and is the safe place to iterate on the OTA path —
  a full flash always recovers it).
- Helpers in `dev/ec618-rig/` (`boot-high.toit`, `boot-run.toit`,
  `flash-full.sh`, …). `export ECTOOL_PATH=/home/flo/.pyenv/versions/3.8.18/bin/ectool`.

> **UART gotcha:** the print/console UART differs per rig (UART0 on the test
> rig, UART1 on the dev rig). It is a build-time choice
> (`CONFIG_TOIT_EC618_PRINT_UART_ID`) **and** the mini-jag agent must open the
> same controller. To avoid the "two-places-must-agree" trap, the agent should
> open whatever `ec618.print-uart-id` reports, so a rig switch is a single
> config change. Switching rigs still requires a rebuild + (re)flash.

## Control planes

- **EC618 (device under test)**: the resident **mini-jag agent**
  (`tests/hw/esp-tester/mini-jag.toit`) over the print UART. Driven from the
  host with `tester.toit run --chip ec618 --port-board1 <port> <test-ec618.toit>`.
  Verdict = the test container's exit code. Also does OTA firmware-update
  (`firmware-update` subcommand) over the same wire.
- **ESP32 (helper)**: **Jaguar** over WiFi (`jag run <test-esp32.toit> --device
  <name>`). Program `print` output is read from its serial console
  (`jag monitor --port <port>`).

A dual-board test launches the ESP32 helper first (it waits for activity), then
runs the EC618 half; the helper prints a `... PASS`/`... FAIL` verdict to its
console.

## Wiring (test rig: ESP32 GPIO ↔ EC618 board pin)

The EC618 module's silkscreen GPIO labels are **Air780 module names, not the
EC618 GPIO controller-bit numbers** the `ec618` library uses, so the physical
pad behind each board pin is confirmed **experimentally** (toggle it, see which
ESP32 pin moves). One controller bit can surface on two pads (e.g. GPIO11 =
PAD26 *and* PAD22), which is the hint for the duplicated "GPIO11"/"GPIO10" pins.

```
ESP32 pin   EC618 board pin (label)              EC618 pad / channel     status
---------   ----------------------------------   ----------------------  ----------
25 (DAC1) -> [divider] -> ADC0 (pin 3)           ADC channel 0 (AIO3)    to verify
26 (DAC2) -> [divider] -> ADC1 (pin 4)           ADC channel 1 (AIO4)    to verify (one ADC pin may be dead)
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
- EC618 ADC tops out at ~1.8 V on the default-ish ranges (max range 3.8 V with an
  internal divider); the ESP32 DACs (0–3.3 V) therefore feed it through external
  dividers.

## Peripheral status (EC618 firmware)

| Peripheral | Status | Notes |
|-----------|--------|-------|
| GPIO | ✅ implemented | `gpio_ec618.cc`. `set_pull`/`set_open_drain` are UNIMPLEMENTED (pulls ignored). |
| UART | ✅ implemented | `uart_ec618.cc` (UART0/1/2). |
| I2C | ✅ implemented | `i2c_ec618.cc`. |
| Cellular | ✅ implemented | `cellular_ec618.cc`. |
| **ADC** | ✅ implemented, smoke-tested on HW | `adc_ec618.cc` + `lib/ec618/adc.toit` (channel-addressed). On-device probe opens ch0/AIO3 and reads (floating pin ≈ 0.005 V), exits clean. Full DAC→ADC tracking test pending the test rig. |
| DAC | ❌ missing | EC618 has no DAC need for these tests (the ESP32 provides DAC). |
| PWM | ❌ missing | Wired (PWM01/04/10/14); implement + test next. |
| SPI | ❌ missing | SPI0 wired; implement + test. |

Design decision: bind the **PLAT driver/HAL directly**, do **not** use the
LuatOS `luat_*` interface layer (it needs LuatOS infra we don't build). There's
a `TODO(toit)` in `third_party/.../project/toit/src/toit_main.c` to also drop the
few `luat_*` calls still in the glue.

## Done
- **Dual-board harness** validated end-to-end (ESP32 Jaguar + EC618 mini-jag).
- **`gpio-output` test** (EC618 drives GPIO11/PAD26 square wave, ESP32 IO27
  counts edges) — **passing, committed**. Confirmed EC618 GPIO output + the
  1.8 V→3.3 V level works + the GPIO11=PAD26=pin5→IO27 mapping.
- **EC618 mini-jag tester** moved to a configurable print UART; harness README.
- **ADC implemented**: `adc_ec618.cc` (channels 0→AIO3, 1→AIO4; range selection;
  `HAL_ADC_CalibrateRawCode`), Toit API `ec618.adc.Adc`. Firmware **builds clean,
  all dual-slot checks pass**. Regenerated `src/toit_data_reloc.c` (VM `.data`
  layout changed — the expected hook).

## In progress / blocked
- **ADC firmware**: full-flashed on the dev rig and **boots clean as slot A**;
  on-device smoke test passes (the ADC primitive runs and returns a sane
  voltage). The full **DAC→ADC tracking test** (`adc-{ec618,esp32}.toit`,
  written) still needs the **test rig** (the dev-rig ESP32-C6 has no DAC).

## OTA bug — ROOT CAUSE FOUND (2026-06-07)

**The VM's writable `.data` init lives in the fixed PLAT flash region, not in the
slots, and the OTA never updates it.** Linker
([ec618_0h00_flash.c:270-285](../third_party/luatos-soc-ec618/PLAT/core/ld/ec618_0h00_flash.c#L270))
puts `*(.data*)` (incl. the VM's) in `.load_dram_shared` `>MSMB_AREA AT>FLASH_AREA`
— so its flash init image is in the **fixed base**, copied once by PLAT to a
single shared RAM `.data`. The slots (`.vm_a`/`.vm_b`) hold the VM's
`.text`/`.rodata`/`.init_array`. The OTA rewrites a **slot**; it never touches
the base `.data` init. The shared `.data` holds pointers *into* the slot (the
interpreter dispatch table, per-module primitive tables) which
`relocate_data_slot_pointers` shifts to the booted slot at boot.

So an OTA only boots if the new firmware's `.data` is byte-identical to the
**last full-flashed** firmware's. A firmware whose `.data` differs (a new global,
an extra primitive-table entry — e.g. adding ADC: 141→142 slot pointers) runs the
new slot code against the **old** `.data` → corrupt dispatch/primitive tables →
`run_boot_program` wedges → AON watchdog (~27 s) → rollback.

Reproduced on the dev rig:

| Running fw | OTA'd fw | Target slot | Result |
|---|---|---|---|
| ADC | ADC | B | ✅ boots + validates |
| ADC | ADC | A | ✅ boots + validates |
| ADC | **no-ADC** | A | ❌ wedges in `run_boot_program` → rollback |

(`FAULT_ACTION` was ruled out; full flash always works because it rewrites the
base `.data`.)

**Fix (in progress):** give the VM `.data` a **per-slot LMA inside the slot** so
the OTA carries it, and **copy it from the booting slot at boot** (before
`relocate_data_slot_pointers`). `gen-slot-reloc` (`.rel.vm_a` only) and the boot
`.data`-pointer relocation stay as-is. Touch points: the linker (`.vm_data`
section — VMA in `MSMB_AREA`, LMA appended to the slot, excluded from PLAT's
`.data` copy and `.bss` zero), a boot copy from the booting slot's `.vm_data`
LMA, regenerate `toit_data_reloc.c`, and confirm the envelope extract + device
relocate-on-write include the appended bytes.

## Known issues
1. **OTA into slot B faults (suspected dual-slot relocate-on-write bug).** After
   an OTA, slot B's VM **starts** (`booting VM slot B`, `@ 204MHz`) then
   **silently resets ~300 ms later**, before the agent banner; the bootloader
   rolls back to slot A (which boots fine). `relocate_data_slot_pointers()` ran
   OK (prints after it work); the fault is while executing the **relocated
   slot-B body**, and `FAULT_ACTION=1` (set in `toit_ec618.cc` before the VM
   runs) makes it a *silent* reset (no hardfault dump). The ADC firmware passes
   every host-side relocation check and no ADC code runs at boot, so this looks
   like a bug in the **recent OTA/relocation path**, exposed by the new image —
   not the ADC. **Confirmed**: the same image **full-flashed boots clean as slot
   A** (firmware is good) — so the fault is purely in the **relocate-on-write /
   slot-B** path. **Working hypothesis (Florian)**: the OTA breaks because the VM
   **C code changed** — the relocate-on-write mishandles the new body layout.
   **Experiment to run** (de-prioritized; full-flash recovers either way): revert
   the ADC so the VM body matches the last-known-good, then OTA — if it works,
   the body change is the trigger. Tools: `firmware-update --debug-boot` dumps
   the trial-boot console; to get a fault PC, build a variant that delays
   `FAULT_ACTION=1` so the hardfault dumper fires.
2. **Per-rig UART** (UART0 test rig / UART1 dev rig) — see the UART gotcha above.
3. **ADC accuracy / dead pin**: `trimAdcSetGolbalVar` is not in the jump table,
   so `HAL_ADC_CalibrateRawCode` uses its uncalibrated linear fallback (fine for
   ratiometric tracking). One of the two ADC channels on the test-rig board may
   be physically dead — the test passes if ≥1 channel tracks and flags the other.

## TODO / roadmap
- [ ] Make mini-jag open `ec618.print-uart-id`'s controller; set UART1 for the dev rig.
- [ ] Full-flash the ADC image on the dev rig → confirm the firmware boots clean
      (isolates the OTA bug from the firmware itself).
- [ ] Add `trimAdcSetGolbalVar` + `delay_us` to the jump-table wrapped set
      (`gen-plat-jt`) for a calibrated ADC + clean conversion wait (base-image
      change; needs a full flash).
- [ ] Add a periodic **state heartbeat** to the mini-jag agent (observability).
- [ ] Generalize `--debug-boot` into a `--verbose-uart` tester flag.
- [ ] **Debug the OTA slot-B relocation bug** (dev rig, full-flash as recovery).
- [ ] Run the **ADC functional test** on the test rig; confirm the 1.8 V range
      and which ADC channel (if any) is dead.
- [ ] Implement + test **PWM** (EC618 drives, ESP32 measures frequency/duty).
- [ ] **UART2** loopback (EC618 TX → ESP32 RX; safe direction).
- [ ] **SPI**, **I2C** (consider the 3.3 V→1.8 V direction / dividers first).
- [ ] More **GPIO**: input (ESP32 drives — level-shift first), interrupts, the
      `set_pull`/`set_open_drain` gaps.
- [ ] Experimentally map the remaining `?` pads in the wiring table.
- [ ] Eventually wire the EC618 tests into CTest (needs a rig power-cycle story).
