# RP2350 host-side image tests

`run_envelope_tests.sh` exercises the complete RP2350 envelope path. It creates
an envelope from a hashed TBYB native base, installs a child container with
assets and boot-critical flags, applies configuration, and extracts the image
twice to check deterministic output. It also sends the result through a fake
native OTA uploader and checks malformed hashes, missing TBYB flags, slot
overflow, the native image parser, an independent SHA-256 calculation, and
picotool verification. The recovery-UF2 check reconstructs the slot-A payload,
checks that only the terminal TBYB bit was cleared to match a ROM-bought image,
independently verifies its ROM hash, checks that no block reaches slot B or the
registry, and compares the pure-Toit output byte for byte with picotool's
`uf2 convert` plus `uf2 combine` output.

Build the native envelope base and the full system snapshot first, then run:

```sh
tools/rp2350/tests/run_envelope_tests.sh \
  build/rp2350-envelope-base/toit-rp2350.bin \
  .cache/rp2350/system.snapshot \
  build/rp2350/partitions-experimental.uf2
```

The first two positional arguments default to the paths shown above. The third
is optional; when omitted, the test generates a temporary partition-table UF2
from the checked-in manifest using the resolved picotool. The equivalent manual
command is:

```sh
.cache/rp2350/install/bin/picotool partition create \
  toolchains/rp2350/partitions-experimental.json \
  build/rp2350/partitions-experimental.uf2
```

Set `TOIT` to
choose the host SDK executable and `PICOTOOL` to choose picotool. The script
defaults `TOIT_PACKAGE_CACHE_PATHS` to `tools/.packages-bootstrap`, so it uses
the repository's bootstrapped package cache without downloading packages.
`REQUIRE_PICOTOOL=1` is used for the derived-image check. A C++17 compiler is
required for the sanitizer-enabled native parser test.

`run_ota_image_parser_tests.sh IMAGE.bin...` can be used separately for native
images or other derived images. It runs the production parser under ASan and
UBSan, boundary mutations, the independent Toit hash checks, and picotool
when available. Set `REQUIRE_PICOTOOL=1` to make a missing picotool an error.

`check-persistent-data.sh TOIT-RP2350.ELF` verifies that the RAM bucket and
both retained clock fields are inside the SDK's persistent-data section in
SRAM bank 0. This catches accidentally placing a retained field in ordinary
BSS, even when the firmware still links. It requires Arm GNU `objdump` and
`nm`; override `OBJDUMP` and `NM` for another toolchain installation.

`run_flash_tests.sh BASE.bin SYSTEM.snapshot PARTITIONS.uf2` tests ROM flashing
without a USB device. A mock picotool captures the generated UF2 and checks it
against extraction from the current envelope with an installed container and
configuration. It checks USB serial selection, verification and absolute
partition addressing, error propagation, and that a failed load never reboots.
Invalid OTA/BOOT option combinations must fail before invoking a tool.
