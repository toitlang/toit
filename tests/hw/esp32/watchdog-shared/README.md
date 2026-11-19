# Shared watchdog hardware fixture

This standalone ESP32 fixture tests `system.watchdog` and its interaction
with the legacy `esp32.watchdog-*` API. It intentionally resets the device.
It uses the console and no external signal pins.

Compile `fixture.toit` with the SDK matching the firmware and install the
snapshot as a boot container in a temporary envelope. Back up the application
before flashing and restore it afterward. The fixture has no package
dependencies; its local package files keep it independent of the peripheral
packages used by the surrounding hardware tests.

After `S3-WATCHDOG READY reason=N`, send one command per line over the console:

| Command | Required result |
| --- | --- |
| `contract` | Feed through both APIs for longer than the deadline; repeated stop/feed while stopped; legacy ownership and shared rearming; `PASS contract`. |
| `rearm-long` | Extend a one-second timeout to four seconds and survive the original deadline; `PASS rearm-long`. |
| `stopped-busy` | Stop a one-second watchdog, then remain CPU-busy for three seconds; `PASS stopped-busy`. |
| `cross-container` | A child feeds through both APIs and stops the parent's watchdog; `PASS cross-container`. |
| `idle-expire` | Arm for one second and sleep; watchdog diagnostic and a fresh ready banner with reset reason 6. |
| `busy-expire` | Arm for one second and remain CPU-busy; the same reset evidence. |
| `rearm-short` | Replace an eight-second deadline with one second; the same reset evidence within the shorter deadline. |

Success lines have the full prefix `S3-WATCHDOG PASS`. Expiry cases print
`S3-WATCHDOG ARMED` before waiting. They must produce the ESP-IDF diagnostic
`Task watchdog got triggered.` and then reboot with `esp32.RESET-TASK-WATCHDOG`
(6). A reset alone, an exception, or a success line from another phase is
not sufficient. `PING` returns the ready banner without changing the watchdog.

Run these phases with no other watchdog provider or host keep-alive routine
feeding the same system watchdog. Ordinary package host tests cannot qualify
this hardware behavior.
