# PIO assembly for Toit

Build the assembler from the repository's pinned Pico SDK:

```sh
cmake -S third_party/pico-sdk/tools/pioasm -B build/pioasm -G Ninja \
  -DPIOASM_VERSION_STRING=pinned-sdk
cmake --build build/pioasm --parallel
python3 tools/pio/compile.py --pioasm build/pioasm/pioasm \
  tests/pio/programs.pio -o tests/pio/programs.toit
```

Each `.program name` exports `NAME-PROGRAM`, a `rp2350.pio.Program`.
Public constants and labels export `NAME-SYMBOL`; file-level constants export
`SYMBOL`. Underscores become hyphens. Collisions are rejected. Generated
modules can be checked into driver packages; users need no assembler.

The generator preserves wrap, origin, PIO version, absolute GPIO ranges,
side-set, shift direction/thresholds, pin counts, FIFO configuration, MOV
status, and clock divider. The state-machine constructor supplies physical
pins and optional overrides. Embedded C SDK helper code is not translated.
Programs must declare their own initialization sequence in Toit.

Host checks:

```sh
python3 tools/pio/test_compile.py
build/host/sdk/bin/toit run tests/pio/program-test.toit
```

See [the PIO API and hardware validation](../../docs/rp2350-pio.md).
