# Memory and throughput comparison: NimBLE host vs Toit host

Same board, same controller, same central. The peripheral advertises one
service with one notifying characteristic; the central (Linux dongle, Toit
host) connects, subscribes, counts notifications for a fixed window,
disconnects, and repeats. Each peripheral prints `BENCH` lines with
`system.process-stats` (system free, largest free block, process allocated
and reserved) at every phase and every two seconds.

- `provider.toit` + `app.toit`: controller-only firmware, Toit host provider container and application container.
- `nimble.toit`: default firmware (NimBLE), the `ble` package.
- `central.toit`: Linux, `toit.run central.snapshot <adapter index> <peer address hex> [cycles]`.

`run.sh toit|direct|nimble [cycles]` (outputs under `build/ble-bench-001/`) assembles and flashes both images on the original
ESP32 and runs the central against each.
