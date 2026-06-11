---
name: toit-envelope
description: How to use a prebuilt firmware envelope from toitlang/envelopes for end-to-end testing of containers, services, and drivers. Use when integration-testing a service container, testing inter-container RPC, or running ESP32/host firmware locally.
---

# Toit Envelope Skill
A *firmware envelope* is a single artifact that bundles a Toit virtual machine
with zero or more Toit containers. Envelopes are the unit of distribution: you
install containers into one, then either flash it to a device (ESP32) or run
it as a normal process (host).

Prebuilt envelopes are published at
[`github.com/toitlang/envelopes`](https://github.com/toitlang/envelopes) — one
release per SDK version, with a separate `.envelope.gz` per target (e.g.
`firmware-x64-linux.envelope.gz`, `firmware-esp32.envelope.gz`).

For local end-to-end testing — without flashing real hardware — the **host**
envelopes are the most useful. They run as a normal Linux/macOS process,
so you can boot multiple containers and watch their output on stdout.

## When to use this skill
Use this when you need to:
- run a service container and a client container together to verify
  inter-container RPC (see `toit-services`),
- exercise a driver's *service-container* layer 3, including assets-based
  configuration (see `toit-driver`),
- reproduce a firmware-only bug locally without ESP32 hardware,
- prepare an ESP32 image for QEMU or Wokwi (see `toit tool firmware extract --help`).

For just running a single Toit program, use `toit run` (see `toit-exe`) —
envelopes are unnecessary unless you need the container/firmware machinery.

## Picking and unpacking an envelope
1. Find the SDK version: `toit version`.
2. Download the matching release asset from `toitlang/envelopes`:
   ```
   curl -L -o firmware-x64-linux.envelope.gz \
     https://github.com/toitlang/envelopes/releases/download/<sdk-version>/firmware-x64-linux.envelope.gz
   gunzip firmware-x64-linux.envelope.gz
   ```
   The envelope's SDK version must match the SDK you compile with — mismatched
   versions fail at install or boot. `toit tool firmware -e <env> show` prints
   the version of any envelope.
3. Pick the right kind:
   - `firmware-x64-linux` / `firmware-arm64-linux` / `firmware-x64-macos` /
     `firmware-arm64-macos` — host envelopes, run as a process.
   - `firmware-esp32`, `firmware-esp32s3`, `firmware-esp32-qemu`, … — ESP32
     variants. `esp32-qemu` is the right choice for QEMU (it includes an
     Ethernet driver compatible with QEMU's `open_eth`).

## Compiling a container image
A container image is a relocatable Toit image plus optional assets. Build it
in two steps:

```
# 1. Compile to a snapshot (keeps debug info — keep it for crash decoding!).
toit compile -s -o service.snapshot service/main.toit

# 2. Convert snapshot to a binary image. Word size must match the envelope:
#    -m64 for x64/arm64 host and esp32-* targets, -m32 for legacy 32-bit hosts.
toit tool snapshot-to-image -m64 --format=binary -o service.image service.snapshot
```

Keep the `.snapshot` file around — it's what `toit decode` needs to turn a
crash blob from the firmware back into a stack trace.

## Installing a container
```
toit tool firmware -e firmware-x64-linux.envelope \
    container install <name> service.image
```

`<name>` is how the container shows up in `firmware ... show` and in the
firmware's runtime logs. Useful flags:
- `--assets=<file>` — bundle an assets file with this container (see below).
- `--trigger=boot|none` — run on boot (default) vs. install-only.
- `--critical` — reboot the firmware if this container exits.
- `-o <path>` — write to a new envelope instead of mutating in place.

Mutating the envelope in place is the simplest workflow; copy the original
once into your build dir and treat it as a build artifact.

## Configuring with assets
The toit-driver layer 3 reads container *assets* to discover its
configuration. Build an assets file with `toit tool assets`:

```
# 1. Write the configuration as JSON.
echo '{"start": 100.0, "step": 5.0}' > cfg.json

# 2. Create an empty assets file and add the config under a known key.
#    Encoding 'tison' is a compact binary format; the container decodes it
#    with `(tison.decode bytes)`.
toit tool assets -e cfg.assets create
toit tool assets -e cfg.assets add --format=tison configuration cfg.json

# 3. Bundle when installing the container.
toit tool firmware -e firmware-x64-linux.envelope \
    container install my-service service.image --assets=cfg.assets
```

The asset *bytes* are tison-encoded; the container's `main` must call
`tison.decode` on the value `assets.decode.get "configuration"` returns. The
toit-driver skill's `main` template already does this — don't strip the
`tison.decode` call thinking the system did it for you.

## Multiple containers
Each `container install` adds another container that boots in parallel when
the firmware starts. This is the cleanest way to test inter-container RPC
locally: install the provider as `my-service` and a tiny client program as
`test-client`. On boot, the client opens the service and prints its
readings.

```
toit tool firmware -e env container install my-service  service.image --assets=cfg.assets
toit tool firmware -e env container install test-client client.image
toit tool firmware -e env show          # confirm both are present
```

The client must give the provider a moment to register before opening — the
default `ServiceClient.open` already waits up to 100 ms, which is plenty on
host. For more, pass `--timeout=` (see `toit-services`).

## Running on the host
For host envelopes, extract a runnable tarball:

```
toit tool firmware -e firmware-x64-linux.envelope extract --format=tar -o run.tar
mkdir run && tar -xf run.tar -C run
cd run && ./boot.sh
```

`boot.sh` runs the firmware until the firmware itself decides to stop (or
you Ctrl-C). For a one-shot test, gate it with `timeout`:

```
timeout 5 ./boot.sh
```

The directory layout (`ota0/`, `ota1/`, `current`, `flash-registry`) is
persistent state — the *same* layout an ESP32 has in flash. Containers can
write to `flash-registry` etc. and that state survives across reboots within
a single `run/` directory. Delete the directory between tests to start fresh.

## Running an ESP32 image in QEMU
For `firmware-esp32-qemu`:

```
toit tool firmware -e firmware-esp32-qemu.envelope extract --format=image -o image.bin
qemu-system-xtensa -M esp32 -nographic \
    -drive file=image.bin,format=raw,if=mtd \
    -nic user,model=open_eth,hostfwd=tcp::2222-:1234
```

The `firmware-esp32-qemu` envelope ships with an Ethernet driver compatible
with QEMU's `open_eth`. Other ESP32 envelopes won't have networking.

## Decoding crashes
A container crash on the firmware prints a base64 blob like:

```
Received a Toit system message. Executing the command below will
make it human readable:
jag decode WyNVBVVYU1UQdjI...
```

Decode it with the snapshot you saved earlier:

```
toit decode -s service.snapshot 'WyNVBVVYU1UQdjI...'
# As check failed: a ByteArraySlice_ is not a Map.
#   0: install-from-assets_      service/main.toit:15:22
#   ...
```

Without the snapshot the decode still works but prints addresses instead of
file:line. Always keep the snapshot you compiled from.

## What you cannot test on a host envelope
- Real GPIO/I2C/SPI/UART — there is no hardware. Use a fake driver class for
  the layer-1 tests; only ESP32 hardware (or QEMU with a model) can exercise
  the bus path end-to-end.
- ESP32-specific features (deep sleep, NVS, OTA flash partitions). Some are
  emulated on host, but behavior may differ.
- Power-management and timing — the host scheduler is not the FreeRTOS
  scheduler. Don't rely on host timing reproducing on-device timing.

For everything else — service registration, client/provider RPC, asset
parsing, container lifecycle, multi-container interactions — host envelopes
are the fastest way to test.

## Quick reference
```
toit version                                       # SDK version
gunzip firmware-x64-linux.envelope.gz              # 1. unpack envelope
toit compile -s -o foo.snapshot foo.toit           # 2. snapshot
toit tool snapshot-to-image -m64 --format=binary \
    -o foo.image foo.snapshot                      # 3. image
toit tool assets -e a.assets create                # 4a. assets (optional)
toit tool assets -e a.assets add \
    --format=tison configuration cfg.json
toit tool firmware -e env container install \
    foo foo.image --assets=a.assets                # 4b. install
toit tool firmware -e env show                     # 5. inspect
toit tool firmware -e env extract \
    --format=tar -o run.tar                        # 6. extract host
mkdir run && tar -xf run.tar -C run && \
    cd run && ./boot.sh                            # 7. run
toit decode -s foo.snapshot '<base64>'             # 8. crash trace
```
