# Native firmware provenance

An SDK version string does not identify the native bytes in these working-tree
experiments. The invalid-key schedule on2026-09-19 exposed this directly: both
reused native images returned numeric mbedTLS error0x4c80, although current
`src/resources/tls.cc` already maps that error to the text required by `sc-ecdh`.
The source fix and its earlier hardware validation were present; the reused
images predated it. See `build/ble-sm-invalid-schedule-native-001`.

For a new current-source hardware campaign:

1. Rebuild the selected native target using `build/ble-esp32-current-build.sh`
   or `build/ble-esp32s3-current-build.sh`. Preserve the actual build result and
   the relevant source, SDK configuration and compiler-command hashes.
2. Assemble from that build's `firmware.envelope`. Record the hashes of
   `$firmware.bin`, `$firmware.elf`, `system` and the test snapshot. Container IDs,
   directory names and SDK version labels are not byte-identity checks.
3. Compare the actual board's public partition table and unchanged boot metadata,
   then extract the complete image to enforce fit before an OTA0-only write.
   A binary-only extraction is insufficient for that fit check.
4. Run the relevant native behavior test. For invalid EC keys, checking the
   normalized error string exists in the binary catches this particular stale
   image, but it does not prove arbitrary source freshness or protocol behavior.

Controlled comparisons may deliberately reuse a frozen native image. Label its
scope and preserve its hashes; a newer Toit snapshot does not update that native
runtime. The original-board BlueZ resumption comparisons remain frozen experiments,
separate from current-source native validation. Their observed successes and
failures remain evidence for those exact images.

The corrected schedule campaign is `build/ble-sm-invalid-schedule-native-002`.
Its test snapshot is byte-identical to001, while native and system images are
rebuilt. Both new system images are172734 bytes (SHA256
`b7c17b8febdd83ffe288cef078ed0691c130fa18dd7230bc1dfcbfae3a81b32d`), compared
with172570 in the reused images. Both boards subsequently pass the unchanged
schedule with51 full and50 compacting GCs, successful recovery, deep sleep and
released ports. This proves the scoped native crypto/GC test, not broader radio
interoperability. Use the campaign's terminal result for its exact scope.
