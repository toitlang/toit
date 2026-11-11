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
// Shipped certificates (verified/spec/format/18-shipped-certificate.md): the
// image carries the program's certificate as a trailing block; the installer
// verifies with it and then erases the block's pages (they are not part of
// the allocation and become a hole). In the device configuration (no
// inference; on hosts TOIT_REQUIRE_CERTIFICATE=1) an image without a
// certificate is rejected; a certificate of another program is rejected in
// both configurations.
//
// Runs an installer program (install-verdict-installer.toit) in a child VM
// whose flash registry is a file (TOIT_FLASH_REGISTRY_FILE), so that the test
// can corrupt the installed image between two runs. The children run without
// address-space randomization (setarch -R): a program allocation is valid only
// at the address it was written to (its checksum covers the address), as on a
// device, whose flash is mapped at a fixed address.

import expect show *
import host.file
import io show LITTLE-ENDIAN
import system
import uuid
import .sandbox-util show *

TARGET ::= "install-verdict-corruption-target-0123456789"

PROGRAM ::= """
main:
  print "$TARGET"
  sum := 0
  10.repeat: sum += it
  print "sum: \$sum"
"""

// Another accepted program: its certificate does not fit PROGRAM.
OTHER-PROGRAM ::= """
class Point:
  x := 0
  y := 0
  constructor .x .y:
  operator + other/Point -> Point: return Point (x + other.x) (y + other.y)

main:
  p := Point 1 2
  5.repeat: p += Point it 1
  print "point: \$p.x \$p.y"
"""

DEEP-SLEEP-PROGRAM ::= """
import esp32
main:
  esp32.deep-sleep (Duration --ms=10)
"""

// The trailing block's marker ("TCB1", src/flash_allocation.h).
CERTIFICATE-MARKER ::= #[0x54, 0x43, 0x42, 0x31]
PAGE-SIZE ::= 4096

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
    // The device configuration: no inference.
    device := {"TOIT_FLASH_REGISTRY_FILE": "$dir/device.registry", "TOIT_VERIFY_TIME": "1",
               "TOIT_REQUIRE_CERTIFICATE": "1"}
    installer := "tests/sandbox/install-verdict-installer.toit"

    image := build-image toit compiler dir "program" PROGRAM bits
    image-bytes := file.read-contents image
    expect (contains image-bytes CERTIFICATE-MARKER)
    result := run-process ["setarch", "-R", run, installer, "install", image] --environment=environment --timeout-ms=120_000
    print result.output
    expect-equals 0 result.exit-code
    // Verified at install time with the shipped certificate, the verdict
    // recorded, and it runs.
    expect (result.output.contains "verified: 1")
    expect (result.output.contains "untrusted: 1")
    expect (result.output.contains "verifier: accepted (shipped certificate)")
    // The verification reported its progress to the scheduler once per
    // method (Process::note_progress), so a long one is not taken for a
    // dead-lock on devices.
    check-progress result.output
    expect (result.output.contains TARGET)
    expect (result.output.contains "sum: 45")
    expect (result.output.contains "exit: 0")
    id := (result.output.split "id: ")[1].trim[..36]

    // The certificate block is gone: its pages after the allocation are
    // erased (a hole) and no block is left anywhere in the flash.
    check-block-dropped flash id

    // It still starts from flash in a new VM (the verdict is in flash).
    result = run-process ["setarch", "-R", run, installer, "start", id] --environment=environment --timeout-ms=60_000
    print result.output
    expect (result.output.contains "listed: true")
    // The recorded verdict is used: the program is not verified again.
    expect-not (result.output.contains "verifier: ")
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

    // Without a certificate, a host infers one ...
    bare := build-image toit compiler dir "bare" PROGRAM bits --no-certificate
    expect-not (contains (file.read-contents bare) CERTIFICATE-MARKER)
    result = run-process ["setarch", "-R", run, installer, "install", bare] --environment=environment --timeout-ms=120_000
    print result.output
    expect (result.output.contains "verified: 1")
    expect (result.output.contains "verifier: accepted,")
    expect (result.output.contains "exit: 0")

    // ... a device rejects the image.
    result = run-process ["setarch", "-R", run, installer, "install", bare] --environment=device --timeout-ms=120_000
    print result.output
    expect (result.output.contains "no certificate")
    expect (result.output.contains "commit failed: VERIFICATION_FAILED")

    // With its certificate, the device accepts it and drops the block.
    result = run-process ["setarch", "-R", run, installer, "install", image] --environment=device --timeout-ms=120_000
    print result.output
    expect (result.output.contains "verifier: accepted (shipped certificate)")
    expect (result.output.contains "verified: 1")
    expect (result.output.contains "exit: 0")
    check-block-dropped "$dir/device.registry" (result.output.split "id: ")[1].trim[..36]

    // A certificate of another program: rejected on the host (no fallback to
    // the inference) and on the device.
    other := build-image toit compiler dir "other" OTHER-PROGRAM bits
    other-bare := build-image toit compiler dir "other-bare" OTHER-PROGRAM bits --no-certificate
    other-bytes := file.read-contents other
    other-bare-bytes := file.read-contents other-bare
    expect (other-bytes[..other-bare-bytes.size] == other-bare-bytes)
    // The image without a certificate followed by the block of the other
    // program (the block's chunks follow the program's).
    forged := "$dir/forged.image"
    file.write-contents --path=forged (file.read-contents bare) + other-bytes[other-bare-bytes.size..]
    [environment, device].do: | env/Map |
      result = run-process ["setarch", "-R", run, installer, "install", forged] --environment=env --timeout-ms=120_000
      print result.output
      expect (result.output.contains "verifier: rejected (shipped certificate)")
      expect (result.output.contains "commit failed: VERIFICATION_FAILED")
  print "install-verdict-test OK"

build-image toit/string compiler/string dir/string name/string source/string bits/int
    --certificate/bool=true -> string:
  write-file "$dir/$(name).toit" source
  snapshot := "$dir/$(name).snapshot"
  // Images for untrusted containers: compiled with --untrusted, which ships
  // the certificate.
  compile-snapshot compiler "$dir/$(name).toit" snapshot --untrusted
  image := "$dir/$(name).image"
  command := [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", image, snapshot]
  if not certificate: command.add "--no-certificate"
  result := run-process command
  if result.exit-code != 0: throw "snapshot-to-image failed: $result.output"
  return image

/**
Checks that the accepting "verifier:" line of $output (TOIT_VERIFY_TIME=1)
  reports one progress report to the scheduler per method.
*/
check-progress output/string -> none:
  line := (output.split "\n").filter: it.starts-with "verifier: accepted (shipped certificate)"
  expect-equals 1 line.size
  // "..., 1234 methods, ...; progress 1234 (to the scheduler)".
  methods := int.parse ((line[0].split " methods")[0].split ", ").last
  progress := (line[0].split "; progress ")[1]
  expect-equals "$methods (to the scheduler)" progress.trim
  expect methods > 100

/**
Checks that the allocation of the image $id in the flash registry file $path
  is not followed by its certificate block: the page after it is erased, and
  no page of the registry starts with the block's marker.
*/
check-block-dropped path/string id/string -> none:
  bytes := file.read-contents path
  id-bytes := (uuid.Uuid.parse id).to-byte-array
  found := false
  for offset := 0; offset + PAGE-SIZE <= bytes.size; offset += PAGE-SIZE:
    expect-not (bytes[offset..offset + 4] == CERTIFICATE-MARKER)
    // The allocation header (src/flash_allocation.h): marker 0xdeadface, the
    // checksum, the id, the metadata, the type and the size in pages.
    if (LITTLE-ENDIAN.uint32 bytes offset) != 0xdeadface: continue
    if bytes[offset + 8..offset + 24] != id-bytes: continue
    found = true
    end := offset + (LITTLE-ENDIAN.uint16 bytes offset + 30) * PAGE-SIZE
    page := bytes[end..end + PAGE-SIZE]
    expect (page.every: it == 0xff)
  expect found

contains haystack/ByteArray needle/ByteArray -> bool:
  for i := 0; i + needle.size <= haystack.size; i++:
    if haystack[i] == needle[0] and haystack[i..i + needle.size] == needle: return true
  return false

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
