# ESP32 partition size checks

The `esp32-envelope-sizes` CI job runs only on the nightly schedule. It builds
every ESP32 variant listed by `toitlang/envelopes` on `main`, using the SDK under
test, and checks each envelope both with only its bundled containers and with
Jaguar installed. Jaguar's snapshot is compiled from its default branch
(currently `main`) with that same SDK. Ordinary CI runs do not perform these
size checks.

The job uses the existing compiler cache, but always builds and checks every
variant. It keeps only one native build on disk at a time and reports all
synthesis, build, and size failures before failing the job. It is independent
of the regular ESP32 job, so failures there do not skip variant coverage.

After regenerating `sdkconfig.defaults`, check variant synthesis too: the
envelopes repository applies patches with these files as context. In particular,
keep the explicit `CONFIG_PERIPH_CTRL_FUNC_IN_IRAM=n` in the classic ESP32
defaults for the `esp32-spiram-rev3` patch, even though it matches the IDF default.

`check-partition-sizes.sh` extracts complete flash images using the firmware
tool. This checks the final app size, including relocated containers, assets,
configuration, and flash-page padding, against the envelope's partition table.
The native binary alone can fit even when the image with Jaguar does not.
Using the firmware tool directly also avoids Jaguar's temporary partition-table
overrides, which would hide undersized SDK defaults.

To run locally with a snapshot compiled by the same SDK as the envelopes:

```sh
bash tests/esp32/check-partition-sizes.sh path/to/jaguar.snapshot \
  build/esp32/firmware.envelope build/esp32c3/firmware.envelope
```

Set `TOIT` to override the default `build/host/sdk/bin/toit` executable.
The check uses temporary copies and reports all failures before exiting.

To build and check all variants locally, activate the SDK's ESP-IDF environment,
build the host SDK, compile the envelopes tool and Jaguar snapshot, then run:

```sh
bash tests/esp32/check-envelope-variants.sh path/to/envelopes \
  path/to/envelope-tool path/to/jaguar.snapshot
```

This checks each variant's own partition table. It does not certify arbitrary
user containers, assets, or standalone partition-table overrides.
