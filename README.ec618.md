# EC618 (Air780E) Port

## Prerequisites

- **ARM toolchain**: `arm-none-eabi-gcc` (system version for libtoit_vm,
  GCC 10.3 downloaded by xmake for the PLAT SDK)
- **xmake**: Install from https://xmake.io/ (`curl -fsSL https://xmake.io/shget.text | bash`)
- **ectool**: `pip install ectool` (from https://pypi.org/project/ectool/)
- **CMake** and **Ninja**

## Building

```sh
make ec618
```

This builds everything:
1. The host SDK (compiler, tools)
2. The EC618 VM library (`build/ec618/src/libtoit_vm.a`)
3. The firmware binary via xmake (bootloader + AP + CP)
4. The system snapshot (`system/extensions/ec618/boot.toit`)
5. The firmware envelope (`build/ec618/firmware.envelope`)
6. The flashable binpkg (`build/ec618/toit.binpkg`)

If xmake prompts to install the ARM toolchain, accept it (it downloads
GCC 10.3 which is required for PLAT SDK compatibility).

### Adding containers

After `make ec618`, you can add Toit programs to the envelope:

```sh
toit tool firmware -e build/ec618/firmware.envelope container install \
    --trigger=boot myapp myapp.snapshot
toit tool firmware -e build/ec618/firmware.envelope extract \
    -o build/ec618/toit.binpkg --format image
```

## Flashing

### Requirements

- An Air780E module connected via USB
- `ectool` installed (`pip install ectool`)

### Steps

1. Put the device into **boot mode**: hold BOOT, press RESET, release BOOT.
   The device appears as `/dev/ttyACM0` for a short window (~30 seconds).

2. Flash immediately (AP only — faster, skips bootloader and CP):
   ```sh
   ectool burn --burn_bl n --burn_cp n -f build/ec618/toit.binpkg
   ```

   First flash (or to reflash everything including bootloader):
   ```sh
   ectool burn -f build/ec618/toit.binpkg
   ```

   If auto-detection fails, specify the port:
   ```sh
   ectool burn --port /dev/ttyACM0 --port_type usb --burn_bl n --burn_cp n -f build/ec618/toit.binpkg
   ```

3. The device reboots automatically after flashing.

**Troubleshooting**: Flashing is brittle. Connect the device directly to
the host — do not use a USB hub. The boot mode window is short (~30s);
if ectool can't connect, try again immediately after entering boot mode.

## Serial Console

The EC618 has two UARTs accessible for debug output:

- **UART-DBG**: Shows bootloader messages (`boot rom try normal boot start!`).
  This is read-only and controlled by the bootloader.
- **UART1**: Application-level debug output (`printf`, `[toit] INFO: ...`).
  Configured at **921600 baud, 8N1**.

Connect to UART1 with a USB-UART adapter:
```sh
picocom /dev/ttyUSB0 -b 921600
```

## Current Status

The port is functional. The firmware boots, runs Toit programs, and
has cellular connectivity (via the on-chip modem).

Completed:
- C++ VM port (sections 1-19, 21-22 of the porting guide)
- Toit system extensions: boot, cellular, firmware, storage (section 20)
- Firmware tooling: envelope creation, extraction, binpkg format (section 23)
- Build pipeline: `make ec618` produces a ready-to-flash binpkg
