// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that the system ends with an error when it runs out of memory
// starting a boot container: on a device that restarts it, and a firmware
// that isn't validated yet is rolled back (the previous one may boot).
//
// The system process fails the requests it serves for other processes when
// it runs out of memory, instead of restarting the device
// (system-oom-request-test.toit). For a boot container that made the start a
// refused one: the other boot containers started and the device kept
// running without it, so a new firmware whose boot container can't start
// was kept. Now, as before that change, the boot ends: the system exits
// with 1 (the host VM's exit code; a device restarts) before the next boot
// container (here the application) runs. The start is not tried again (as
// before; the request path tries again after 100 ms).
//
// The boot container: a trusted format-2 program installed with
// FLAG-RUN-BOOT; the VM that boots it fails the container start's first
// attempt sequence (-Xinject_system_oom=spawn:4) or the first two (spawn:8;
// before, refused after the retry, and the application ran). The children
// run without address-space randomization (setarch -R): a program
// allocation is valid only at the address it was written to.

import expect show *
import system
import .sandbox-util show *

PROGRAM ::= """
main:
  print "boot-oom-target ran"
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
    result := run-process [compiler, "-w", snapshot, source]
    expect-equals 0 result.exit-code
    image := "$dir/program.image"
    result = run-process [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", image, snapshot]
    expect-equals 0 result.exit-code

    environment := {"TOIT_FLASH_REGISTRY_FILE": flash}
    result = run-process ["setarch", "-R", run, installer, "install-trusted", image]
        --environment=environment
        --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    expect (result.output.contains "id: ")

    // Without a failure the boot container and the application run.
    result = boot run installer environment null
    expect (result.output.contains "boot-oom-target ran")
    expect (result.output.contains "boot-refused app ran")
    expect-equals 0 result.exit-code

    ["spawn:4", "spawn:8"].do: | injection/string |
      result = boot run installer environment injection
      expect (result.output.contains "[out of memory in system process: starting boot container ")
      expect-not (result.output.contains "boot-oom-target ran")
      expect-not (result.output.contains "boot-refused app ran")
      expect-equals 1 result.exit-code
  print "boot-oom-test OK"

boot run/string installer/string environment/Map injection/string? -> RunResult:
  flags := injection ? ["-Xinject_system_oom=$injection"] : []
  result := run-process ["setarch", "-R", run] + flags + [installer, "app"]
      --environment=environment
      --timeout-ms=60_000
  print result.output
  return result
