// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that a boot container the VM refuses to run does not end the boot
// before the other boot containers are started (system/boot.toit,
// ContainerManager.end-boot). Boot starts the images in the flash registry
// before the bundled ones; when the first one was refused, no other
// container was running yet, so the system considered itself done and
// exited: on a device it entered deep sleep without a wakeup time, before
// the firmware's own containers ran. Found on an ESP32-C6 after an OTA
// update to a format-2 firmware with a format-1 container installed
// (FORMAT_2_REQUIRED at every boot, so the device never came up).
//
// The refused image here: a format-1 program installed untrusted with
// FLAG-RUN-BOOT while TOIT_UNTRUSTED_FORMAT1=1 allows that (no verdict);
// the next VM, without the variable, refuses it with FORMAT_2_REQUIRED.
// The children run without address-space randomization (setarch -R): a
// program allocation is valid only at the address it was written to.

import expect show *
import host.file
import system
import .sandbox-util show *

PROGRAM ::= """
main:
  print "boot-refused-target ran"
"""

main args:
  run := args[0]
  compiler := args[1]
  sdk := compiler[..compiler.size - "/lib/toit/bin/toit.compile".size]
  toit := "$sdk/bin/toit"
  bits := system.BITS-PER-WORD

  with-tmp-directory: | dir |
    flash := "$dir/flash.registry"
    installer := "tests/sandbox/boot-refused-installer.toit"
    source := "$dir/program.toit"
    write-file source PROGRAM
    snapshot := "$dir/program.snapshot"
    result := run-process [compiler, "-Xbytecode_format=1", "-w", snapshot, source]
    expect-equals 0 result.exit-code
    image := "$dir/program.image"
    result = run-process [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", image, snapshot]
    expect-equals 0 result.exit-code

    allow := {"TOIT_FLASH_REGISTRY_FILE": flash, "TOIT_UNTRUSTED_FORMAT1": "1"}
    result = run-process ["setarch", "-R", run, installer, "install", image] --environment=allow --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    expect (result.output.contains "id: ")

    // A new VM boots: the installed image is refused, the application (a
    // boot container registered after it) still runs.
    plain := {"TOIT_FLASH_REGISTRY_FILE": flash}
    result = run-process ["setarch", "-R", run, installer, "app"] --environment=plain --timeout-ms=60_000
    print result.output
    expect (result.output.contains "FORMAT_2_REQUIRED")
    expect-not (result.output.contains "boot-refused-target ran")
    expect (result.output.contains "boot-refused app ran")
    expect-equals 0 result.exit-code
