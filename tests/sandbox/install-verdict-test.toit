// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests install-time verification of untrusted images (Phase 5): an image
// installed with the untrusted flag is verified when it is committed to the
// flash registry, and the verdict is recorded in the allocation (flags bit
// 6, src/flash_allocation.h), so starting it does not verify it again. The
// allocation's checksum covers the verified bytes: after the image is
// corrupted in flash, it no longer starts. An image the verifier rejects is
// not installed.
//
// Runs an installer program (install-verdict-installer.toit) in a child VM
// whose flash registry is a file (TOIT_FLASH_REGISTRY_FILE), so that the test
// can corrupt the installed image between two runs. The children run without
// address-space randomization (setarch -R): a program allocation is valid only
// at the address it was written to (its checksum covers the address), as on a
// device, whose flash is mapped at a fixed address.

import expect show *
import host.file
import system
import .sandbox-util show *

// A string of the installed program; the test corrupts it in the flash file.
TARGET ::= "install-verdict-corruption-target-0123456789"

PROGRAM ::= """
main:
  print "$TARGET"
  sum := 0
  10.repeat: sum += it
  print "sum: \$sum"
"""

DEEP-SLEEP-PROGRAM ::= """
import esp32
main:
  esp32.deep-sleep (Duration --ms=10)
"""

main args:
  run := args[0]
  compiler := args[1]
  // The SDK's toit executable (snapshot-to-image): sdk/bin/toit next to
  // sdk/lib/toit/bin/toit.compile.
  sdk := compiler[..compiler.size - "/lib/toit/bin/toit.compile".size]
  toit := "$sdk/bin/toit"
  bits := system.BITS-PER-WORD

  with-tmp-directory: | dir |
    flash := "$dir/flash.registry"
    // TOIT_VERIFY_TIME=1: every verification prints a "verifier:" line.
    environment := {"TOIT_FLASH_REGISTRY_FILE": flash, "TOIT_VERIFY_TIME": "1"}
    installer := "tests/sandbox/install-verdict-installer.toit"

    image := build-image toit compiler dir "program" PROGRAM bits
    result := run-process ["setarch", "-R", run, installer, "install", image] --environment=environment --timeout-ms=120_000
    print result.output
    expect-equals 0 result.exit-code
    // Verified at install time, the verdict recorded, and it runs.
    expect (result.output.contains "verified: 1")
    expect (result.output.contains "untrusted: 1")
    expect (result.output.contains "verifier: accepted")
    expect (result.output.contains TARGET)
    expect (result.output.contains "sum: 45")
    expect (result.output.contains "exit: 0")
    id := (result.output.split "id: ")[1].trim[..36]

    // It still starts from flash in a new VM (the verdict is in flash).
    result = run-process ["setarch", "-R", run, installer, "start", id] --environment=environment --timeout-ms=60_000
    print result.output
    expect (result.output.contains "listed: true")
    // The recorded verdict is used: the program is not verified again.
    expect-not (result.output.contains "verifier: accepted")
    expect (result.output.contains "exit: 0")

    // Corrupt the program's bytes in flash: the verdict no longer holds and
    // the image does not start.
    corrupted := corrupt flash TARGET
    expect corrupted > 0
    result = run-process ["setarch", "-R", run, installer, "start", id] --environment=environment --timeout-ms=60_000
    print result.output
    expect-not (result.output.contains TARGET[1..])
    expect-not (result.output.contains "exit: 0")
    expect (result.output.contains "listed: false")

    // A program the verifier rejects (deep sleep) is not installed.
    rejected := build-image toit compiler dir "deep-sleep" DEEP-SLEEP-PROGRAM bits
    result = run-process ["setarch", "-R", run, installer, "install", rejected] --environment=environment --timeout-ms=120_000
    print result.output
    expect (result.output.contains "commit failed: VERIFICATION_FAILED")
  print "install-verdict-test OK"

build-image toit/string compiler/string dir/string name/string source/string bits/int -> string:
  write-file "$dir/$(name).toit" source
  snapshot := "$dir/$(name).snapshot"
  compile-snapshot compiler "$dir/$(name).toit" snapshot
  image := "$dir/$(name).image"
  result := run-process [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", image, snapshot]
  if result.exit-code != 0: throw "snapshot-to-image failed: $result.output"
  return image

/** Flips a byte of every occurrence of $needle in the file $path. */
corrupt path/string needle/string -> int:
  bytes := file.read-contents path
  pattern := needle.to-byte-array
  count := 0
  i := 0
  while i + pattern.size <= bytes.size:
    if bytes[i] == pattern[0] and bytes[i..i + pattern.size] == pattern:
      bytes[i + 1] ^= 0x20
      count++
      i += pattern.size
    else:
      i++
  file.write-contents bytes --path=path
  return count
