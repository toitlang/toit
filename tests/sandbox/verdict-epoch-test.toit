// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests the verification epoch of install-time verdicts
// (verified/verification-epoch.cmake, src/flash_allocation.h): the verdict
// of an untrusted image is recorded with the epoch of the VM that verified
// it, and a VM takes only a verdict of its own epoch.
//
// A firmware update that keeps the installed containers (same system uuid,
// same mapping address) is, on a host, a new VM on the same flash registry
// file. A VM of the same epoch runs the image on its recorded verdict. The
// header a firmware with another epoch writes is the same header with that
// epoch and the checksum over it: the test writes it into the flash file
// (the checksum is a CRC-32, so the new one follows from the old one and the
// changed bytes, without knowing the address the checksum also covers).
// Such an image is listed but refused, as an image without a verdict
// (VERIFICATION_FAILED, with the reason on stderr), at a start and at boot,
// where the other boot containers still run; with the original epoch back,
// it runs again. An edit of the epoch without the checksum makes the
// allocation invalid: an image cannot give itself another epoch.
//
// Runs the installers of install-verdict-test.toit and boot-refused-test.toit
// in child VMs whose flash registry is a file, without address-space
// randomization (setarch -R), as those tests do.

import crypto.crc show Crc
import expect show *
import host.file
import io show LITTLE-ENDIAN
import system
import uuid
import .sandbox-util show *

TARGET ::= "verdict-epoch-target-0123456789"

PROGRAM ::= """
main:
  print "$TARGET"
"""

PAGE-SIZE ::= 4096
// The allocation header (src/flash_allocation.h): marker, checksum, id,
// metadata, type, size in pages, system uuid. The epoch is the last four
// bytes of the uuid field, which ends the header.
HEADER-SIZE ::= 48
CHECKSUM-OFFSET ::= 4
ID-OFFSET ::= 8
SIZE-OFFSET ::= 30
EPOCH-OFFSET ::= 44

main args:
  run := args[0]
  compiler := args[1]
  sdk := compiler[..compiler.size - "/lib/toit/bin/toit.compile".size]
  toit := "$sdk/bin/toit"
  bits := system.BITS-PER-WORD

  with-tmp-directory: | dir |
    image := build-image toit compiler dir bits
    test-start run dir image
    test-boot run dir image
  print "verdict-epoch-test OK"

test-start run/string dir/string image/string -> none:
  flash := "$dir/start.registry"
  environment := {"TOIT_FLASH_REGISTRY_FILE": flash, "TOIT_VERIFY_TIME": "1"}
  installer := "tests/sandbox/install-verdict-installer.toit"
  result := run-process ["setarch", "-R", run, installer, "install", image] --environment=environment --timeout-ms=120_000
  print result.output
  expect (result.output.contains "verified: 1")
  expect (result.output.contains "exit: 0")
  id := (result.output.split "id: ")[1].trim[..36]
  epoch := read-epoch flash id
  other := epoch ^ 0x0100_0001

  start := : | expected-listed/bool |
    result = run-process ["setarch", "-R", run, installer, "start", id] --environment=environment --timeout-ms=60_000
    print result.output
    expect (result.output.contains "listed: $expected-listed")
    result.output

  // The same epoch (a new VM of the same build): runs on the recorded
  // verdict, without verifying again.
  output := start.call true
  expect-not (output.contains "verifier: ")
  expect (output.contains TARGET)
  expect (output.contains "exit: 0")

  // The header of a firmware with another epoch: listed, refused as an
  // image without a verdict, with the reason.
  write-epoch flash id other
  output = start.call true
  expect-not (output.contains TARGET)
  expect (output.contains "start failed: VERIFICATION_FAILED")
  expect (output.contains "verdict of verification epoch $(hex other), not $(hex epoch): reinstall it")
  expect-not (output.contains "verifier: ")

  // With this firmware's epoch it is a verdict again: the decision is the
  // epoch.
  write-epoch flash id epoch
  output = start.call true
  expect (output.contains TARGET)
  expect (output.contains "exit: 0")

  // The epoch edited without a new checksum: the allocation is invalid.
  bytes := file.read-contents flash
  offset := find-header bytes id
  bytes[offset + EPOCH-OFFSET] ^= 0x01
  file.write-contents bytes --path=flash
  output = start.call false
  expect-not (output.contains TARGET)

test-boot run/string dir/string image/string -> none:
  flash := "$dir/boot.registry"
  environment := {"TOIT_FLASH_REGISTRY_FILE": flash}
  installer := "tests/sandbox/boot-refused-installer.toit"
  result := run-process ["setarch", "-R", run, installer, "install", image] --environment=environment --timeout-ms=120_000
  print result.output
  expect-equals 0 result.exit-code
  id := (result.output.split "id: ")[1].trim[..36]
  epoch := read-epoch flash id

  // Boot with the same epoch: the image starts as a boot container.
  result = run-process ["setarch", "-R", run, installer, "app"] --environment=environment --timeout-ms=60_000
  print result.output
  expect (result.output.contains TARGET)
  expect (result.output.contains "boot-refused app ran")
  expect-equals 0 result.exit-code

  // Boot after an update to a firmware with another epoch: the image is
  // refused, the boot goes on.
  other := epoch ^ 0x8000_0000
  write-epoch flash id other
  result = run-process ["setarch", "-R", run, installer, "app"] --environment=environment --timeout-ms=60_000
  print result.output
  expect-not (result.output.contains TARGET)
  expect (result.output.contains "VERIFICATION_FAILED")
  expect (result.output.contains "verdict of verification epoch $(hex other), not $(hex epoch)")
  expect (result.output.contains "boot-refused app ran")
  expect-equals 0 result.exit-code

build-image toit/string compiler/string dir/string bits/int -> string:
  write-file "$dir/program.toit" PROGRAM
  snapshot := "$dir/program.snapshot"
  compile-snapshot compiler "$dir/program.toit" snapshot --untrusted
  image := "$dir/program.image"
  result := run-process [toit, "tool", "snapshot-to-image", "--format=binary", "-m$bits", "-o", image, snapshot]
  if result.exit-code != 0: throw "snapshot-to-image failed: $result.output"
  return image

hex value/int -> string:
  return "$(%08x value)"

/** The offset of the allocation header of the image $id in $bytes. */
find-header bytes/ByteArray id/string -> int:
  id-bytes := (uuid.Uuid.parse id).to-byte-array
  for offset := 0; offset + PAGE-SIZE <= bytes.size; offset += PAGE-SIZE:
    if (LITTLE-ENDIAN.uint32 bytes offset) != 0xdeadface: continue
    if bytes[offset + ID-OFFSET..offset + ID-OFFSET + 16] != id-bytes: continue
    return offset
  throw "no allocation for $id"

read-epoch path/string id/string -> int:
  bytes := file.read-contents path
  return LITTLE-ENDIAN.uint32 bytes (find-header bytes id) + EPOCH-OFFSET

/**
Writes $epoch into the header of the image $id in the flash file $path, with
  the checksum a VM of that epoch computes.

The checksum is a chain of CRC-32s (src/utils.cc, standard CRC-32) over the
  address, the header after the checksum field and, with the verdict bit,
  the program's bytes after the header. For two messages of the same length
  the CRC-32s differ by the CRC (no initial value, no final xor) of their
  xor, so the new checksum is the old one xor the CRC of the changed epoch
  bytes followed by as many zeros as bytes follow them.
*/
write-epoch path/string id/string epoch/int -> none:
  bytes := file.read-contents path
  offset := find-header bytes id
  old := LITTLE-ENDIAN.uint32 bytes offset + EPOCH-OFFSET
  diff := ByteArray 4
  LITTLE-ENDIAN.put-uint32 diff 0 (old ^ epoch)
  size := (LITTLE-ENDIAN.uint16 bytes offset + SIZE-OFFSET) * PAGE-SIZE
  crc := Crc.little-endian 32 --polynomial=0xEDB88320
  crc.add diff
  crc.add (ByteArray size - HEADER-SIZE)
  checksum := LITTLE-ENDIAN.uint32 bytes offset + CHECKSUM-OFFSET
  LITTLE-ENDIAN.put-uint32 bytes offset + CHECKSUM-OFFSET (checksum ^ crc.get-as-int)
  LITTLE-ENDIAN.put-uint32 bytes offset + EPOCH-OFFSET epoch
  file.write-contents bytes --path=path
