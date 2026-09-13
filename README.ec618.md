# EC618 (Air780E)

- [Rig guide](docs/ec618-rig-guide.md): build, full flash, OTA, wiring, and tests.
- [Open issues and TODOs](docs/ec618-todo.md).
- [Design notes](docs/ec618-design-notes.md): constraints behind the frozen
  base, relocation, console transaction, DMA, watchdog, and allocator choices.

The build entry points are `make ec618-base` and `make ec618`. Rebuild and
fully flash the base after base-side changes; use slot OTA for VM-only changes.
The slot must match the exact installed base fingerprint.
