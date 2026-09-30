# BLE hardware fixtures

Board and adapter programs for the experimental host. They are not part of
CTest; see [docs/ble/hardware.md](../../docs/ble/hardware.md) for the rig,
permissions and flashing procedure.

- `fixtures/`: provider and application images installed on boards or run on
  Linux with an adapter index. Names starting with `vhci-` open the ESP32
  controller, `hci-` the Linux adapter, `service-` are applications talking to
  a provider over RPC.
- Top-level files are the drivers of the maintained checks: the `*.sh`
  scripts, `nightly.sh` which runs them all, `bench/` for measurements, and
  `campaigns/` and `pairing-retry/` for the documented campaigns. One-off
  campaign drivers that no check runs any more were removed on 2026-09-30;
  they are in the git history.
- `adapter-policy.toit` with `tools/ble-hci-supervisor` reserves a Linux
  adapter by MAC and restores its power state.
- `*-check.awk` scripts evaluate captured serial logs.

Select boards by full `/dev/serial/by-id/` path and adapters by MAC. Each
fixture prints `READY` and `COMPLETE` style markers on serial; a run passes
only when the checker script accepts the log.
