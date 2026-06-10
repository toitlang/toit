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
25 (DAC1) -> [~2:1 divider] -> ADC0 (pin 3)      ADC channel 0 (AIO3)    CONFIRMED (exact, ratio ~0.47)
26 (DAC2) -> [~2:1 divider] -> ADC1 (pin 4)      ADC channel 1 (AIO4)    CONFIRMED (exact, ratio ~0.46)
27        -> 05  (GPIO11, uart2_txd)             PAD26 (GPIO11 primary)  CONFIRMED (gpio-output)
14        -> 06  (GPIO10, uart2_rxd)             PAD25 (GPIO10 primary)  CONFIRMED (uart2 tests; gpio-map)
13        -> 09  (GPIO22, MAIN_DTR)              ?                       to verify
33        -> 10  (GPIO08, SPI0_CS, I2C1_SDA)     PAD23 (GPIO8)           CONFIRMED (gpio-map: 23 pulses at IO33)
32        -> 11  (GPIO10, UART2_RX, SPI0_MISO)   MIRRORS PAD25's net     CONFIRMED (gpio-map: GPIO10 hits IO14+IO32)
23        -> 12  (GPIO01, PWM10)                 PAD16 (TIMER0 PWM)      CONFIRMED (pwm test: 1 kHz measured at IO23)
22        -> 13  (GPIO09, I2C1_SCL, SPI0_MOSI)   PAD24 (GPIO9)           CONFIRMED (gpio-map: 24 pulses at IO22)
21        -> 14  (GPIO11, UART2_TX, SPI0_CLK)    MIRRORS PAD26's net     CONFIRMED (NOT PAD22: isolated PAD22 drive = quiet; bit-11 drive with PAD26 GPIO-muxed = IO21+IO27 toggle)
19        -> 18  (GPIO24, MAIN_RI, PWM01)        ?                       to verify
18        -> 22  (I2C0_SDA)                      UNREACHABLE             measured 2026-06-10: responds to NO driveable pad (full gpio-map) and no I2C controller (I2C0 27/28 + I2C1 23/24 SCL probes silent); always-high pull-ups
17        -> 23  (I2C0_SCL)                      UNREACHABLE             see pin 22
 2        -> 27  (GPIO27, NET_STATUS, PWM04)     ?                       to verify
 4        -> 30  (UART1_TXD)                     UART1 TX (PAD34)        CONFIRMED (gpio-map: GPIO19 -> IO4)
16        -> 31  (GPIO18, UART1_RXD, PWM14)      UART1 RX (PAD33)        CONFIRMED (gpio-map: GPIO18 -> IO16)
```

**No hardware flow control is wireable as-is (measured 2026-06-10):** UART2 has
no flow control in the chip; UART1's RTS/CTS pads (PAD31/PAD32 = GPIO16/17,
mux ALT1 per RTE_Device.h — the only routing) reach **no** ESP32 pin, and
neither do the alt-pad candidates PAD21/PAD22 (isolated GPIO drives, ESP32
all-pin watch: silent). The two "duplicated GPIO" board pins are pad-net
MIRRORS (pin 11 = PAD25's net, pin 14 = PAD26's net), not alternate pads.
Testing RTS/CTS needs the board's MAIN_RTS/MAIN_CTS (GPIO16/17) pins — if the
dev board exposes them — wired to free ESP32 GPIOs. **Skipped for now**
(Florian, 2026-06-10): no board with exposed RTS/CTS pins is available;
revisit when one is.

### Voltage domains (important — corrected 2026-06-08)
- **The EC618 IO rail is configured to 3.3 V — a CHIP setting, not the module.**
  The EC618 has a software-configurable IO LDO (`slpManNormalIOVoltSet` /
  `slpManAONIOVoltSet`, `IOVOLT_*` ~1.65–3.40 V, grouped "1.8 / 2.8 / 3.3 V
  level"). It is a single shared IO rail, so **all** broken-out IO sits at the
  configured level — on this dev-board the 3.3 V group, so the pads are genuinely
  3.3 V-powered (NOT external level-shifters). **Measured**: EC618 GPIO10 high
  reads **3.16 V** (saturated 11 dB range) on the ESP32 ADC, vs 0.14 V idle
  (`gpio-vlevel-{ec618,esp32}.toit`). The Toit firmware doesn't touch the setting
  (uses the PLAT default), so it stays 3.3 V — but a firmware that set IOVOLT to
  the 1.8 V group would make every pad 1.8 V again (and ESP32→EC618 risky).
- So **EC618 ↔ ESP32 is 3.3 V ↔ 3.3 V both ways**: EC618 → ESP32 reads cleanly
  (no marginal-VIH worry), and **ESP32 → EC618 is no longer the risky "3.3 V into
  1.8 V" case** — receiver tests (UART RX, CTS, I2C, SPI, GPIO input) can be driven
  directly, no divider/open-drain needed.
- EC618 ADC inputs (AIO3/AIO4) are separate analog pins (not the level-shifted
  GPIO); the wide range reads to 3.8 V. The ESP32 DACs (0–3.3 V) feed them through
  the rig's ~2:1 dividers to stay mid-range.

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
- **I2C driver rewritten + BMP280 test ready — BLOCKED on rig wiring**
  (2026-06-10): i2c_ec618.cc had drifted from the current lib interface
  (bus-create takes a pull-up bool, probe takes a timeout, device-create
  carries frequency/timeout/ack-check — every call failed on argument
  types; this is also why `scan` "couldn't send an empty message"). Now:
  PAD addressing, per-device frequency switching, probe = SMBus
  receive-byte judged by GetDataCount (the blob's polling driver has no
  zero-length write), NACK detection on all transfers. Also fixed: taking
  &Driver_I2C0 faulted (see the jump-table data-symbol commit). A real
  BMP280 (chip-id 0x58, SDO->GND = 0x76) sits on the breadboard, verified
  end-to-end from the ESP32 (bme280-probe-esp32) with its power switched
  by IO13. BUT the sensor sits on the rig's "I2C0" board pins 22/23 —
  measured UNREACHABLE from the EC618 (see the wiring table): no GPIO pad
  and neither I2C controller reaches them. The EC618 test
  (bmp280-{ec618,esp32}: scan + chip-id + forced measurement with
  datasheet temperature compensation) is written and waits for the sensor
  wires to move to reachable nets. Open question: which mux (if any) puts
  I2C1 on pads 23/24 — ALT2 produces no SCL there; the blob is RTE-fixed
  to pads 19/20 (unwired). Candidate paths: move wires + find the mux, or
  bit-banged I2C over the (working) open-drain GPIO emulation.
- **GPIO open-drain emulation + `gpio-opendrain` test** (2026-06-10,
  passing): the EC618 GPIO has no open-drain bit, so the driver now
  emulates it — the pin DIRECTION tracks the value (0 = output-low,
  1 = input/high-Z; a pull-up supplies the high level). `config`, `set`
  and `set-open-drain` are direction-aware; open-drain pins always get the
  pad input buffer so `get` reads the WIRE. Tested as a real two-master
  bus on PAD33 <-> ESP32 IO16 (both open-drain, pull-ups both sides,
  commands over UART2): drive/release levels, `get` readback in both
  states, the wired-AND property (EC618 released + ESP32 pulling low →
  EC618 reads 0), 5× toggling, live `set-open-drain` flips to push-pull
  and back, and open-drain WITHOUT the internal pull-up (external pull-up
  only) including a high-Z proof — a released pin loses against the
  peer's weak pull-DOWN, which a push-pull high would win. All 26 checks
  pass. Notably the GPIO input register tracks the pad even in output
  direction (the readback checks prove it).
  `gpio-opendrain-{ec618,esp32}.toit`.
- **GPIO interrupts fixed + `gpio-interrupt` test** (2026-06-10, passing):
  `Pin.wait-for` NEVER worked on the EC618 — three driver bugs found by the
  new test (ESP32 drives pulse trains into PAD26, the EC618 counts them via
  wait-for): (1) `GpioResourceGroup` used the default `on_event`, which
  returns state 0, so the edge event never set the lib's
  GPIO-STATE-EDGE-TRIGGERED bit; (2) the `config_interrupt` /
  `last_edge_trigger_timestamp` primitives returned values from two
  unrelated counters (and a constant 0), while the gpio lib compares them
  as timestamps of ONE clock to decide whether an edge arrived after
  arming — they now share a global trigger sequence, captured before
  arming and advanced+recorded per GPIO bit in the ISR; (3) the ISR's
  event payload used a third counter (now the same sequence). Verified:
  exactly 50/50 pulses counted at 50 Hz and at 250 Hz (2 ms phases — the
  interrupt dispatch turnaround beats a phase), and a quiet line causes no
  wakeups. `gpio-interrupt-{ec618,esp32}.toit`.
- **PWM implemented + `pwm` dual-board test** (2026-06-10, passing): new
  `pwm_ec618.cc` behind the generic `gpio.pwm` API. PWM rides the AP TIMER
  instances (one output each; TIMER0/1/2/4 — 3 and 5 are platform-reserved),
  iomux ALT5, 26 MHz source; registers are programmed directly (the SDK's
  `TIMER_setupPwm` isn't jump-tabled and is integer-percent only), clocks +
  start/stop via the jump table — no base-image change. Test: EC618 commands
  the ESP32 over UART2; ESP32 measures with a pulse counter (frequency) and
  busy-polling (duty/level). Verified: 1/2 kHz frequency (~+1.2% measured —
  crystal tolerance, consistent everywhere), duty 0.25/0.5/0.75 (±1%),
  constant low/high extremes, live set-frequency, two simultaneous channels
  (TIMER4/PAD33 -> IO16, TIMER0/PAD16 -> IO23 — confirming that wire),
  closed channel goes silent while the other keeps running. TWO hardware
  quirks found (vs the SDK's own code): `TMR[0] == TMR[1]` ("100%" per the
  SDK) and `TMR[0] == 0` both give constant LOW — duty 1.0 is programmed as
  high with a 2-tick (77 ns) low notch; and the constant-low state is a
  one-way trap (compare writes latch on the match event, which never fires
  — the SDK's `TIMER_updatePwmDutyCycle` has the same bug), so leaving it
  restarts the timer via the TCCR enable bit. `pwm-{ec618,esp32}.toit`.
- **`uart2-flush` flush semantics** (2026-06-10, passing): `out.flush` /
  `write --flush` must return when the last bit leaves the wire — verified by
  pure timing (2 KiB cannot flush faster than its wire time, nor much slower)
  at 9600/115200/921600, no helper board needed. Found a real bug: the
  `wait_tx` primitive was a non-blocking TEMT check and the lib then waited
  for a TX event to retry — but the blob's TX_ALL_DONE is best-effort (same
  root cause as the RS485 DE bug), so **flush hung forever at 9600** (115200+
  only worked by event-timing luck). `wait_tx` now polls LSR.TEMT bounded by
  the cache+FIFO drain time. Also: `--break-length` now throws UNIMPLEMENTED
  instead of silently sending break-less data (no break API in the PLAT
  blob), and a fresh UART2 open is verified quiet (no garbage byte).
  `uart2-flush-ec618.toit`.
- **`uart2-rs485` RS485 half-duplex** (2026-06-10, passing 9600/115200/921600):
  UART2 in `MODE-RS485-HALF-DUPLEX` with the direction line on PAD33 (any
  GPIO-capable pad works; new `--rs485-de` pin on the `Ec618.uartN`
  constructors); the ESP32 verifies exactly one DE pulse per message at IO16,
  DE released right after the last bit, and DE low while it echoes. Found and
  fixed TWO driver bugs: (1) the DE pad was driven through the luatos
  core-driver `GPIO_Config`/`GPIO_Output` — a *different* GPIO stack than the
  OEM `GPIO_pin*` API the gpio driver uses (mixing is forbidden by its own
  header), and on hardware those calls never moved the pad; (2) the PLAT
  blob's `UART_CB_TX_ALL_DONE` is **best-effort** — it samples LSR.TEMT once
  at TX-DMA-done dispatch (disassembly of `prvUart_TxDone`,
  `libcore_airm2m.a`) and stays silent if the FIFO is still draining, so at
  ≤115200 DE stayed high forever. The write primitive now polls
  `Uart_IsTSREmpty` and releases DE synchronously (ISR drop kept as the
  zero-latency fast path at high baud). `uart2-rs485-{ec618,esp32}.toit`.
- **`uart2-config` configuration matrix** (2026-06-10, passing): all 49
  combinations — data bits 5..8 × parity none/even/odd × stop bits 1/2 (+ a
  1.5-stop probe) at 115200 and 921600, reopening both sides per config —
  round-trip correctly. A deliberate parity mismatch shows the error counter
  fires once per bad byte while the bytes are still delivered intact
  (detectable, not filtering). Gotcha: a fresh UART1 open can emit a glitch
  byte that garbles the first control-lane line; tests flush a newline after
  opening control. `uart2-config-{ec618,esp32}.toit`.
- **`Container.wait` spurious-CLOSED fix** (2026-06-10, HW-verified): a failing
  memory-churning test killed the agent (watchdog reset 60 s later) because a
  waited-on container is only weakly rooted while its waiter task is blocked —
  GC collected it and the proxy finalizer closed it mid-wait. SDK fix
  (`waited-on_` strong set in `lib/system/containers.toit`) + mini-jag catches
  wait errors + the host tester fails fast on `run: test wait failed`. Found
  with the new software watchdog. Details: `docs/ec618-known-issues.md` #3.
- **`uart2-echo` extended to 4 MBd** (2026-06-10): the small-token round-trip
  passes at 9600..4 MHz in both reopen and set-baud modes — the raw baud
  config is fine all the way up; high-baud problems are load problems.
- **`uart2-bigdata` throughput + leak test** (2026-06-10): 256 KiB per
  direction per baud, deterministic stream + CRC, no echo (each side only
  reads or only writes — per Florian: the ESP32 can't echo fast enough at high
  baud, and the EC618 lockup case was simultaneous TX+RX, which gets its own
  test). TX clean at all bauds; RX clean through 3 MBd; **4 MBd RX loses 8–21
  bytes per 256 KiB** (known-issues #4). Reports max-read (ring fill),
  first-bad offset, and the driver error counter per phase.
- **`uart2-ring` driver characterization** (2026-06-10, passing): locks in the
  measured PLAT RX-ring behavior — exactly 32 KiB capacity (independent of
  `RxCacheLen`), overflow silently discards the ENTIRE buffer, error callback
  never fires, and **one overflow kills RX on the port until reopen** (set-baud
  does not recover it). If an SDK change moves these, this test says so.
- **`uart2-duplex` full-duplex stress** (2026-06-10): EC618 sends AND receives
  256 KiB concurrently per baud — the historical lockup case, now split out of
  bigdata per Florian. Result: **no lockup** (agent survives, watchdog never
  fires), TX is flawless (ESP32 CRC-verifies all 256 KiB at every baud), but
  **RX delivers 0 bytes** — the receiver falls behind the 32 KiB ring once and
  the overflow-wedge (known-issues #4) kills RX for the rest of the run. The
  test stays red until the RX path is fixed.
- **Dual-board harness** validated end-to-end (ESP32 Jaguar + EC618 mini-jag).
- **`gpio-output`** (EC618 drives GPIO11/PAD26 square wave, ESP32 IO27 counts
  edges) — **passing, committed**.
- **`gpio-input`** (2026-06-08): the reverse — ESP32 drives, EC618 reads on
  PAD26. Validates the receive direction at 3.3 V (172 edges read). The runner
  sets the EC618 pad to input before the ESP32 drives, so two 3.3 V drivers never
  fight. `gpio-input-{ec618,esp32}.toit`.
- **`uart2-echo` exhaustive UART2 round-trip** (2026-06-08): the EC618 sweeps the
  baud rates in BOTH modes (re-open per baud, and one open + set-baud), telling
  the ESP32 the baud over a **control lane** (UART1 TX PAD34 → ESP32 IO4) so one
  deploy covers the sweep; the ESP32 echoes on UART2 so the EC618 verifies TX **and**
  RX. **Passes 9600..921600 in both modes.** This surfaced + fixed a real bug: the
  generic uart lib auto-sets the ESP32-only `high-priority` tx-flag for
  baud ≥ 460800, which the EC618 create primitive rejected → every ≥460800 open
  failed `INVALID_ARGUMENT` (set-baud worked, the tell). Fixed by ignoring that
  flag on EC618 (commit 96b9f86b). `uart2-echo-{ec618,esp32}.toit`,
  `uart-reopen-ec618.toit` (open 9600..3 MHz regression).
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
- **Resilience: reset-on-VM-exit + sleeper keep-alive** (2026-06-08): two layers
  against the deep-sleep brick (see the incident below). (1)
  `CONFIG_TOIT_EC618_RESET_ON_VM_EXIT` (default 1): on a full-VM `EXIT_DONE` the
  firmware resets (reboots into the program) instead of deep-sleeping with no
  wakeup timer — **HW-verified**: a `gpio-map` teardown crash rebooted and
  recovered the agent, no brick. (2) A separate **`sleeper`** keep-alive container
  in the EC618 envelope (installed alongside mini-jag) so the VM keeps a runnable
  process and never falls into the `EXIT_DONE` deep-sleep-without-wakeup that the
  watchdog can't escape (deep sleep ≈ power-off; the watchdogs are off there, which
  is fair). `sleeper.toit`; **HW-verified**: agent + sleeper coexist, basics pass,
  and the board survives a 90 s idle and stays responsive (an earlier "sleeper
  breaks idle" claim was a misdiagnosis).
  - **Watchdog model (clarified):** the EC618 has two watchdogs. The **main WDT**
    (`ec618.watchdog`, fed by the agent on host messages) counts **active (awake)
    time** — the SDK's `WDT_enterLowPowerStatePrepare` disables its clock before
    any chip low-power sleep — so it catches **busy hangs**, not an idle-stuck
    agent. The **AON watchdog** (`slpManAonWdt*`, fed by the scheduler tick) is the
    always-on one and guards **VM liveness**. A Toit `sleep` is just a FreeRTOS
    timer-wait (`xTaskNotifyWait`); the chip only low-power-sleeps when the *whole*
    VM is idle (FreeRTOS tickless idle → slpman) — that's correct, not a misrouted
    scheduler sleep. Gap: an agent stuck *while the VM idles* is covered by neither
    (main WDT paused in sleep; AON fed by the still-ticking scheduler) — rare, and
    a healthy idle agent is fine.
- **ADC exact-value test passing** (2026-06-08, test rig): the ESP32 drives a
  known DAC staircase; the EC618 self-calibrates the per-channel board divider
  (2-point fit) and verifies every level within ±60 mV. Both channels pass
  (errors ≤8 mV) with a clean **~2:1 divider on both** paths (ratios ~0.47 / ~0.46).
  Earlier one path read **near-direct** (ratio ~0.91); that was traced to a wrong
  resistor in its divider (**1 MΩ instead of 1 kΩ**) and fixed on the rig — the
  diagnosis "missing/ineffective divider" was right. Wiring restored to the
  original IO25(DAC1)→ADC0, IO26(DAC2)→ADC1. The test self-calibrates per channel,
  so it is robust to the actual ratio. `adc-{ec618,esp32}.toit`.
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

### Direction safety (UPDATED 2026-06-08 — both directions are 3.3 V)
The dev-board level-shifts the EC618 IO to **3.3 V** (see Voltage domains above),
so EC618 ↔ ESP32 is **3.3 V ↔ 3.3 V both ways** and the old "risky 3.3 V→1.8 V"
rule no longer applies:
- **EC618 drives → ESP32 reads = SAFE.** UART TX, PWM, GPIO output, DAC→ADC.
- **ESP32 drives → EC618 reads = SAFE too** (3.3 V → 3.3 V dev-board input).
  EC618 UART RX, CTS, GPIO input, I2C, SPI can be driven **directly** — no
  open-drain / pull-up / divider tricks needed. (The EC618 open-drain emulation is
  therefore no longer required for these tests; it stays a nice-to-have.)
- Still **gpio-toggle a new wire first** to confirm connectivity (and that nothing
  shorts) before relying on it — that habit is cheap and catches miswiring.

### Per-peripheral exhaustive plan
- **UART2**: baud sweep (TX side — *baseline committed*); RS485 *done*;
  RTS/CTS skipped (not wireable on this rig, no alternative board); EC618
  UART RX — all safe now (3.3 V both ways), drive directly.
- **PWM** — *done* (implemented + HW-tested; see Done).
- **ADC**: exact-value staircase (EC618 measures the ESP32 DAC, self-calibrating
  the board divider, ±60 mV per level) — *done*.
- **GPIO**: output modes (done) + pull-up (done); input driven by the ESP32 is now
  safe (drive directly). EC618 open-drain emulation is optional (no longer needed
  for the rig's risky direction).
- **I2C / SPI**: last; likely reflash the ESP32 with a C **slave** sketch.

### Status / blocker
- The control lane works; the full baud sweep (uart2-echo, 9600..4 MHz, both
  modes) and the bigdata throughput test ride on it. Current UART focus:
  4 MBd RX loss (known-issues #4 — flow control is the fix path), then
  RTS/CTS, RS485, parity/stop/data-bit configs, and a full-duplex stress test
  (the historical lockup case: EC618 sending AND receiving at high rate).
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
- [x] Add `trimAdcSetGolbalVar` + `delay_us` to the jump-table wrapped set
      (`gen-plat-jt`) for a calibrated ADC + clean conversion wait — DONE
      2026-06-10 (table renumbered: full flash required; rerun the ADC test
      after flashing to validate the calibrated path).
- [ ] Generalize `--debug-boot` into a `--verbose-uart` tester flag.
- [x] Implement + test **PWM** (EC618 drives, ESP32 measures frequency/duty;
      pwm_ec618.cc on TIMER0/1/2/4, generic `gpio.pwm` API).
- [x] **UART2** round-trip: echo sweep 9600..4 MHz (both modes) + bigdata
      256 KiB/direction + ring characterization.
- [ ] **UART RX overflow-wedge** (known-issues #4, the big one): try
      `Uart_RxBufferClear` as an unwedge; real fix = move RX onto the open
      CMSIS `bsp_usart.c` driver with our own ring; then RTS/CTS flow control.
- [ ] **UART2 4 MBd RX loss** (known-issues #4): investigate the IRQ-latency
      source. RTS/CTS testing is SKIPPED for now (see the wiring note above):
      UART1's PAD31/32 don't reach the ESP32 and no board with exposed
      MAIN_RTS/MAIN_CTS pins is available (Florian, 2026-06-10).
- [x] **UART full-duplex stress** test written + run (uart2-duplex): no
      lockup; TX clean; RX dead via the overflow-wedge — red until #4 is fixed.
- [x] **UART configs**: parity, stop bits, data bits + error counter on
      induced parity errors (uart2-config, all 49 configs pass).
- [x] **RS485 half-duplex** (uart2-rs485): DE timing verified at the ESP32;
      fixed the mixed-GPIO-stack DE drive and the best-effort TX_ALL_DONE
      reliance (synchronous TEMT drain in write).
- [ ] **SPI**, **I2C** (consider the 3.3 V→1.8 V direction / dividers first).
- [x] **GPIO pull-up/down** (`set_pull`, and `config` honours it) + input buffer
      for input pins.
- [x] **GPIO open-drain**: emulated via direction-tracks-value (output-low /
      high-Z); HW-tested as a real two-master wired-AND bus (gpio-opendrain).
- [x] **GPIO interrupts** (`Pin.wait-for`): was entirely broken — fixed
      (on_event state bit + shared trigger-sequence protocol) and HW-tested
      (gpio-interrupt, exact pulse counts at 50 and 250 Hz).
- [ ] Experimentally map the remaining `?` pads in the wiring table.
- [ ] Eventually wire the EC618 tests into CTest (needs a rig power-cycle story).
