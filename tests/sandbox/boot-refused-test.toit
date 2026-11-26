// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// FORMAT-1-ONLY (docs/format2-migration.md): delete with format 1; the boot
// case of verdict-epoch-test.toit also has a refused boot container.

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
// The refused image here is an untrusted format-1 program in flash, which
// no VM runs (untrusted programs run only on the verified core, in format
// 2), and which no VM installs: install refuses it with FORMAT_2_REQUIRED.
// Such an image can only be left by an older firmware, which allowed
// untrusted format 1. The test installs the program trusted, with
// FLAG-RUN-BOOT, and sets the untrusted flag in the flash file, with the
// checksum that older firmware would have computed (the checksum is a
// CRC-32, so the new one follows from the old one and the changed byte, as
// in verdict-epoch-test.toit). The next VM refuses the image with
// FORMAT_2_REQUIRED, also with the variable that allowed untrusted format 1
// before (TOIT_UNTRUSTED_FORMAT1=1, which no longer has an effect), and the
// boot goes on. The children run without address-space randomization
// (setarch -R): a program allocation is valid only at the address it was
// written to.

import crypto.crc show Crc
import expect show *
import host.file
import io show LITTLE-ENDIAN
import system
import uuid
import .sandbox-util show *

PROGRAM ::= """
main:
  print "boot-refused-target ran"
"""

PAGE-SIZE ::= 4096
// The allocation header (src/flash_allocation.h): marker, checksum, id,
// metadata, type, size in pages, system uuid (48 bytes). The checksum of an
// allocation without the verdict bit covers the address and the header
// after the checksum field.
HEADER-SIZE ::= 48
CHECKSUM-OFFSET ::= 4
ID-OFFSET ::= 8
FLAGS-OFFSET ::= 24
// FlashAllocation::Header::FLAGS_PROGRAM_UNTRUSTED_MASK and
// FLAGS_PROGRAM_VERIFIED_MASK.
FLAG-UNTRUSTED ::= 1 << 2
FLAG-VERIFIED ::= 1 << 6

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

    environment := {"TOIT_FLASH_REGISTRY_FILE": flash, "TOIT_UNTRUSTED_FORMAT1": "1"}

    // Installing it untrusted is refused, also with the old variable.
    result = run-process ["setarch", "-R", run, installer, "install", image] --environment=environment --timeout-ms=60_000
    print result.output
    expect (result.output.contains "FORMAT_2_REQUIRED")
    expect-not (result.output.contains "id: ")

    result = run-process ["setarch", "-R", run, installer, "install-trusted", image] --environment=environment --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    expect (result.output.contains "id: ")
    id := (result.output.split "id: ")[1].trim[..36]
    set-untrusted flash id

    // A new VM boots: the installed image is refused, the application (a
    // boot container registered after it) still runs.
    result = run-process ["setarch", "-R", run, installer, "app"] --environment=environment --timeout-ms=60_000
    print result.output
    expect (result.output.contains "FORMAT_2_REQUIRED")
    expect-not (result.output.contains "boot-refused-target ran")
    expect (result.output.contains "boot-refused app ran")
    expect-equals 0 result.exit-code
  print "boot-refused-test OK"

/** The offset of the allocation header of the image $id in $bytes. */
find-header bytes/ByteArray id/string -> int:
  id-bytes := (uuid.Uuid.parse id).to-byte-array
  for offset := 0; offset + PAGE-SIZE <= bytes.size; offset += PAGE-SIZE:
    if (LITTLE-ENDIAN.uint32 bytes offset) != 0xdeadface: continue
    if bytes[offset + ID-OFFSET..offset + ID-OFFSET + 16] != id-bytes: continue
    return offset
  throw "no allocation for $id"

/**
Sets the untrusted flag of the image $id in the flash file $path, with the
  checksum a VM computes for that header.

For two messages of the same length the CRC-32s differ by the CRC (no
  initial value, no final xor) of their xor, so the new checksum is the old
  one xor the CRC of the changed flags byte followed by as many zeros as
  header bytes follow it (verdict-epoch-test.toit, write-epoch).
*/
set-untrusted path/string id/string -> none:
  bytes := file.read-contents path
  offset := find-header bytes id
  flags := bytes[offset + FLAGS-OFFSET]
  expect-equals 0 (flags & (FLAG-UNTRUSTED | FLAG-VERIFIED))
  crc := Crc.little-endian 32 --polynomial=0xEDB88320
  crc.add #[FLAG-UNTRUSTED]
  crc.add (ByteArray HEADER-SIZE - FLAGS-OFFSET - 1)
  checksum := LITTLE-ENDIAN.uint32 bytes offset + CHECKSUM-OFFSET
  LITTLE-ENDIAN.put-uint32 bytes offset + CHECKSUM-OFFSET (checksum ^ crc.get-as-int)
  bytes[offset + FLAGS-OFFSET] = flags | FLAG-UNTRUSTED
  file.write-contents bytes --path=path
