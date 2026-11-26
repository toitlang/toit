// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A VM built without sandboxes (CMake TOIT_SANDBOX=OFF, as a firmware without
  Kconfig TOIT_SANDBOX; docs/sandbox-policy.md, "Firmware without sandboxes")
  refuses untrusted containers cleanly and runs trusted programs as before:
- an image installed as untrusted is not committed (SANDBOX_NOT_SUPPORTED)
  and leaves no image behind;
- a trusted image installs and runs; started untrusted (with or without
  quotas) it is refused (SANDBOX_NOT_SUPPORTED); quotas alone (trusted)
  still work;
- `toit.run --untrusted` refuses the program (exit 1, it never runs).

Usage: refused-test.toit TOIT-RUN TOIT-COMPILE
*/

import expect show *
import host.file
import system
import ..sandbox.sandbox-util show *

PROGRAM ::= """
main:
  print "refused-test program ran"
"""

MARKER ::= "refused-test program ran"

main args:
  run := args[0]
  compiler := args[1]
  // The SDK's toit executable (snapshot-to-image): sdk/bin/toit next to
  // sdk/lib/toit/bin/toit.compile.
  sdk := compiler[..compiler.size - "/lib/toit/bin/toit.compile".size]
  toit := "$sdk/bin/toit"
  bits := system.BITS-PER-WORD
  installer := "tests/sandbox-off/refused-installer.toit"

  with-tmp-directory: | dir |
    environment := {"TOIT_FLASH_REGISTRY_FILE": "$dir/flash.registry"}
    source := "$dir/program.toit"
    write-file source PROGRAM

    // Compiled for an untrusted container: such an SDK makes no certificate
    // (it has no verifier), the image is refused before any verification.
    untrusted-snapshot := "$dir/untrusted.snapshot"
    compile-snapshot compiler source untrusted-snapshot --untrusted
    untrusted-image := image toit untrusted-snapshot "$dir/untrusted.image" bits
    result := run-process ["setarch", "-R", run, installer, "install-untrusted", untrusted-image] --environment=environment --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    expect (result.output.contains "untrusted image refused: this firmware has no sandbox support")
    expect (result.output.contains "commit failed: SANDBOX_NOT_SUPPORTED")
    expect (result.output.contains "images added: 0")
    expect-not (result.output.contains MARKER)

    // A trusted image installs and runs; untrusted starts of it are refused.
    trusted-snapshot := "$dir/trusted.snapshot"
    compile-snapshot compiler source trusted-snapshot
    trusted-image := image toit trusted-snapshot "$dir/trusted.image" bits
    result = run-process ["setarch", "-R", run, installer, "install-trusted", trusted-image] --environment=environment --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    expect (result.output.contains "trusted exit: 0")
    expect (result.output.contains "untrusted start failed: SANDBOX_NOT_SUPPORTED")
    expect (result.output.contains "untrusted start with quotas failed: SANDBOX_NOT_SUPPORTED")
    expect (result.output.contains "trusted with quotas exit: 0")
    expect-equals 2 (count result.output MARKER)

    // toit.run --untrusted: the program never runs.
    result = run-process [run, "--untrusted", source] --timeout-ms=60_000
    print result.output
    expect-equals 1 result.exit-code
    expect (result.output.contains "SANDBOX_NOT_SUPPORTED")
    expect-not (result.output.contains MARKER)

    // The same program runs trusted.
    result = run-process [run, source] --timeout-ms=60_000
    expect-equals 0 result.exit-code
    expect (result.output.contains MARKER)

image toit/string snapshot/string out/string bits/int -> string:
  result := run-process [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", out, snapshot]
  if result.exit-code != 0: throw "snapshot-to-image failed: $result.output"
  return out

count haystack/string needle/string -> int:
  result := 0
  from := 0
  while true:
    index := haystack.index-of needle from
    if index < 0: return result
    result++
    from = index + needle.size
