# EC618 port — open work list

Companion to [ec618-roadmap.md](ec618-roadmap.md). Ordered roughly by priority.
Checked items are done and kept for context; unchecked are open.

## Next up (technical)

- [x] **I2C nominal 400 kHz mode** (2026-07-18).
  - ESP32 RMT disproved the 305-tick batch model. The bounded linear region is
    `2*SCLx+20` functional-clock ticks. The calibrated path uses 26 MHz through
    ~206 kHz, 51.2 MHz for intermediate fast requests, and a dedicated
    LuatOS-style timing word for the standard 400 kHz setting.
  - LuatOS production does not use the open CMSIS branch; its closed `soc_i2c`
    blob uses the same automatic/control mode as us and programs the complete
    TPR word. Its nominal-400 word measures ~344 kHz. Toit retains its timing
    fields on 26 MHz and uses the fastest bounded SCLx=30 variant: 1.25 us high
    + 1.50 us low, or ~363 kHz. SCLx=28 can make NACK traffic free-run. Higher
    requests clamp to the safe setting; dedicated controller mode is not needed.
  - HW proof: RMT on ESP32 IO17, plus `i2c-torture-ec618` with 175
    shape-changing/value-checked BMP280 transfers at each of 100 and 400 kHz
    (`bad=0` at both speeds).

- [x] **Cellular HW exercise** (2026-07-18). The standalone module on
  `quirky-plenty` passed attach/PDP activation, three DNS lookups, TCP/HTTP,
  UDP/NTP, and certificate-validated TLS/HTTPS over lwIP. The TLS test ran as a
  slot-embedded container because its trusted roots exceed the 64 KiB flash
  registry; normal network tests compile at O2 and fit. The total cellular
  transfer was well under 1 MB. Note the **PSU caveat**: the
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

## Watch / on-recurrence (not scheduled work)

- [ ] **Quirky RX deafness** — dormant. If it (or modest) goes deaf again,
  follow the **ordered protocol in known-issues #14**: (1) watch the console
  passively for the ~65 s watchdog-FATAL+banner cadence (device alive, TX good →
  deafness is inbound-only), (2) golden-window ping, (3) relay power-cycle
  (module POR, dongle untouched), (4) **USB-replug the dongle LAST** — replugging
  first destroys the evidence. The UART2 rescue lane
  (`dual-bridge-esp32.toit` + socat) is HW-validated as the way back after any
  console flip.

## GPIO doesn't work on alts atm.
All functionality (we can test) should work.

## Done this session (kept for context)

- [x] I2C real speeds + slave-legality ceiling (`308ee13f`, `818097b3`).
- [x] Alt-pad GPIO guard for the I2C bus-clear/wire-peek (Florian's concern: a
  GPIO bit reachable from an alternate pad must not be commandeered; today's pad
  table is 1:1 so it's dormant, but the fence is in).
- [x] Quirky RX deafness exoneration + #14 protocol (`0c3840ff`, `ea760fda`).
- [x] `dual-bridge-esp32.toit` + `console-set-ec618.toit` rig tools.
- [x] Doctor failure messages name non-HW causes (`38f8f24d`).
