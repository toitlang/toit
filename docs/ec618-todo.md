# EC618 port — open work list

Companion to [ec618-roadmap.md](ec618-roadmap.md). Ordered roughly by priority.
Checked items are done and kept for context; unchecked are open.

## Next up (technical)

- [ ] **I2C 400 kHz via "dedicated" mode** (Florian: "look into automatic mode").
  - **Terminology is inverted** in the vendor SDK. `bsp_i2c.c`'s
    `I2C_TransferConfig` shows `AUTOMATIC_MODE1/2` **set** `MCR.CONTROL_MODE`,
    and our engine already sets `CONTROL_MODE` — so **we already run "automatic
    mode."** The unexplored path is **`DEDICATED_MODE` (CONTROL_MODE clear)**:
    per-byte SCR commands driven by `TX_ONE_DATA`/`RX_ONE_DATA` interrupts,
    instead of the byte-count state machine we use now. That per-cycle overhead
    is what caps us at ~117 kHz; dedicated mode is the candidate for real
    400 kHz.
  - **Investigation started, INCOMPLETE.** I built an RMT wire-analyzer on the
    ESP32 to measure real SCL phase widths (see the rig guide — reuse this
    technique!). First and only clean data point before we stopped: at **46000
    Hz requested the wire measured ~93 kHz** (high ≈ 5250 ns, low ≈ 5500 ns at
    50 ns RMT ticks). That is ~2× the nominal 46 kHz and **does not match the
    305-tick software-derived model** — it suggests the functional-clock source
    or the tick model in the absolute calibration is off (the source pinning may
    not be taking effect, or the clock is ~51 MHz where I assumed 26 MHz). The
    shipped behavior is safe regardless (the `i2c-speed` test checks pace
    **ordering**, not absolute Hz, and it passes), but **the absolute Hz labels
    on the driver are suspect** — resolve this with the RMT bench before trusting
    them or attempting dedicated mode.
  - Plan: (1) finish the RMT sweep at 46k/100k/117k to pin the real wire freq vs
    request and locate the true per-cycle overhead; (2) prototype dedicated mode
    by peek/poke of MCR/SCR from Toit, watching the RMT analyzer, before touching
    the C driver; (3) if it reaches 400 kHz cleanly against the BMP280 torture
    test, wire it into `src/resources/i2c_ec618.cc`.
  - Scratch files used (in the session scratchpad, not committed): an
    `i2c-scl-analyzer-esp32.toit` (RMT capture) and an `i2c-pace-hold-ec618.toit`
    (holds probe traffic at a requested pace). Rebuild from the rig-guide recipe.

- [ ] **Cellular HW exercise.** Code is complete (attach, appSetCFUN, PS events,
  TCP/UDP/TLS over lwIP) but HW coverage is thin. Note the **PSU caveat**: the
  modem POR-loop under RF draw was a **PSU brownout** — use a stiff supply; a
  UART-only agent keeps the modem off and is brownout-proof. Flashing uses
  `--burn_cp n` (Toit never flashes the CP); a stale/mismatched CP PORs the chip
  ~4.4 s after `appSetCFUN(1)` — full-flash a matched `cp-demo-flash.bin`.

## Florian's queue (owner: Florian, or needs a decision)

- [ ] **Base-image release dispatch.** The release workflow (`ec618-base-vN`)
  and the consumer path (`EC618_BASE_DIR`) exist; the **first release dispatch
  is still pending**. base-v2 now mints the universal `22cfaacd` fingerprint.
  Nothing this session changed the base (all I2C work was slot-side).
- [ ] **`os_esp32.cc` condvar review (upstream candidate).** We hardened the
  EC618 condvar to per-thread binary wake semaphores (`5b97ff3e`); `os_esp32.cc`
  still uses the older task-notification pattern. Worth an upstream review.
- [ ] **Retire `build-dual-image`.** `tools/ec618/provision.toit` supersedes it
  (retargets an image to another descriptor, round-trip byte-identical).
- [ ] **Toit language / skill friction list.** Recurring papercuts recorded in
  the `feedback_toit_language_friction` memory: multi-line named-arg
  continuations and multi-line ternaries fail to parse (must single-line —
  bit me again this session with the RMT constructor); `$x.y.size` interpolation
  greediness (use `$(...)`); `lib/uart.toit` flush fixes are upstream-worthy;
  no `file.read-link` in the host lib. We own Toit + the skills, so these are
  fixable at the source.

## Watch / on-recurrence (not scheduled work)

- [ ] **Quirky RX deafness** — dormant. If it (or modest) goes deaf again,
  follow the **ordered protocol in known-issues #14**: (1) watch the console
  passively for the ~65 s watchdog-FATAL+banner cadence (device alive, TX good →
  deafness is inbound-only), (2) golden-window ping, (3) relay power-cycle
  (module POR, dongle untouched), (4) **USB-replug the dongle LAST** — replugging
  first destroys the evidence. The UART2 rescue lane
  (`dual-bridge-esp32.toit` + socat) is HW-validated as the way back after any
  console flip.

## Done this session (kept for context)

- [x] I2C real speeds + slave-legality ceiling (`308ee13f`, `818097b3`).
- [x] Alt-pad GPIO guard for the I2C bus-clear/wire-peek (Florian's concern: a
  GPIO bit reachable from an alternate pad must not be commandeered; today's pad
  table is 1:1 so it's dormant, but the fence is in).
- [x] Quirky RX deafness exoneration + #14 protocol (`0c3840ff`, `ea760fda`).
- [x] `dual-bridge-esp32.toit` + `console-set-ec618.toit` rig tools.
- [x] Doctor failure messages name non-HW causes (`38f8f24d`).
