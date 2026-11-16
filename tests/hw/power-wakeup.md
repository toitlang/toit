# Shared power wake-pin qualification

`power-wakeup.toit` uses only the common GPIO and power APIs. It is a manual
hardware probe, not evidence of measured current or a completed hardware run.
Compile and install it as a boot container using the board's usual workflow.
Set `WAKE-PIN` to a free, exposed wake GPIO: for example nRF P1.00 (32),
original ESP32 GPIO33 (33), or EC618 PAD42 (42). Check the board wiring first.

1. Leave `TIMED=true` and `DISABLE-WAKE=false`. Start with the input inactive.
   After the `sleeping` line, drive it to the active state. It should reboot
   before the 30-second timer. Release it during the five-second delay after
   boot so the next sleep does not wake immediately.
2. Repeat without a pin transition. The device should reboot after about
   30 seconds, plus teardown and startup time.
3. Set `DISABLE-WAKE=true`. Repeat the active transition: it must be ignored;
   the timer should end sleep. This checks that disabling removes the source.
4. Set `WAKE-HIGH=false` and repeat with a falling transition. Change the
   source's inactive level accordingly. EC618 needs an edge after sleep entry;
   ESP32/nRF wake on a level, including an already-active level.
5. Set `TIMED=false` and re-enable the pin. Only the pin or a hardware reset
   should wake the device. With `DISABLE-WAKE=true`, use hardware reset to
   recover.
6. Set `TRIGGER` to `power.WAKE-LEVEL` on ESP32/nRF or `power.WAKE-EDGE`
   on EC618 and repeat. The opposite explicit mode must throw `UNSUPPORTED`
   before sleeping and leave the existing wake configuration unchanged.
7. Configure another valid pin before sleep and verify either can wake.
   nRF supports mixed levels. Original ESP32 must reject adding a second
   low-level pin or mixing levels; ESP32-S2/S3 must reject mixed levels.
   A rejected configuration must leave the original source armed.
8. Check that wake works with the pin still held by `gpio.Pin` in this probe.
   This exercises applying the sleep pulls after the VM closes GPIO resources.

Use an external signal source appropriate to the board's input voltage.
EC618's wake-input pulls belong to an approximately 2 V domain; do not assume
the AON GPIO supply defines its wake-input voltage.

After wake, `power.reset-reason` reports shared flags. ESP32/EC618 sleep wakes
report `RESET-LOW-POWER-WAKE`. nRF timed sleep reports `RESET-SOFTWARE`;
untimed GPIO wake reports `RESET-LOW-POWER-WAKE`.

On EC618, also run `ec618/reset-deep-sleep-contract.toit` to check the original
enum API alongside the shared flags, and `ec618/wakeup-pad42-ec618.toit` with
its existing ESP32 fixture for automated enable/disable coverage.
The nRF paired and edge tests in `nrf5340/power-nrf5340.toit` now exercise the
shared wake API.

ESP32 targets without EXT1 wake support are currently unsupported by this
GPIO configuration API. Existing platform APIs remain available for additional
wake sources, original ESP32 all-low masks, and EC618 both-edge wake.

Functional wake tests do not qualify current consumption. For nRF current
measurement, use the debugger-disconnected procedure in `nrf5340/README.md`.
