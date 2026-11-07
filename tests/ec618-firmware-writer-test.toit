// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import crypto.sha256 as crypto
import io show LITTLE-ENDIAN
import ..system.extensions.ec618.firmware-writer

HEADER-SIZE ::= 56

main:
  test-stream
  test-header-checkpoints
  test-resume
  test-invalid
  test-failures
  print "EC618 firmware writer: stream, checkpoints, resume, bounds and failures PASS"

image -> ByteArray:
  bytes := ByteArray (HEADER-SIZE + 9000 + 17): (it * 37 + 11) & 0xff
  LITTLE-ENDIAN.put-uint32 bytes 0 (HEADER-SIZE - 4)
  bytes.replace 4 #[83, 82, 76, 51] 0 4
  LITTLE-ENDIAN.put-uint32 bytes 16 9000
  LITTLE-ENDIAN.put-uint32 bytes 28 17
  return bytes

test-stream:
  expected := image
  [1, 7, 16, 4096, expected.size].do: |chunk|
    backend := MemorySlot
    writer := SlotFirmwareWriter backend 0 expected.size
    List.chunk-up 0 expected.size chunk: |start end|
      expect-equals (end - start) (writer.write expected[start..end])
    expect-equals ((expected.size - HEADER-SIZE) % 4096) writer.flush
    expect-equals 0 backend.stages
    writer.commit (crypto.sha256 expected)
    expect-equals 1 backend.stages
    expect-equals expected backend.canonical
    expect-equals [0, 4096, 8192] backend.erases
    expect-throw "INVALID_STATE": writer.write #[1]
    expect-throw "INVALID_STATE": writer.pad 0 0
    expect-throw "INVALID_STATE": writer.flush
    expect-throw "INVALID_STATE": writer.commit null
    writer.close
    writer.close

  backend := MemorySlot
  writer := SlotFirmwareWriter backend 0 expected.size
  writer.write expected[..HEADER-SIZE]
  expected.fill --from=HEADER-SIZE 0x71
  expect-equals (expected.size - HEADER-SIZE) (writer.pad (expected.size - HEADER-SIZE) 0x71)
  writer.commit (crypto.sha256 expected)
  expect-equals expected backend.canonical
  writer.close

test-header-checkpoints:
  expected := image
  backend := MemorySlot
  writer := SlotFirmwareWriter backend 0 expected.size
  HEADER-SIZE.repeat: |index|
    writer.write expected[index..index + 1]
    durable := index == HEADER-SIZE - 1
    expect-equals (durable ? 0 : index + 1) writer.flush
    expect-equals (durable ? 1 : 0) backend.begins
  writer.close
  resumed := SlotFirmwareWriter backend HEADER-SIZE expected.size
  resumed.write expected[HEADER-SIZE..]
  resumed.commit (crypto.sha256 expected)
  expect-equals expected backend.canonical
  resumed.close

  // A failed retry may erase or partially program the next sector, but must
  // leave the saved checkpoint usable for another retry (including a reset).
  ["erase", "torn-write"].do: |operation|
    backend = MemorySlot
    writer = SlotFirmwareWriter backend 0 expected.size
    writer.write expected[..HEADER-SIZE + 4096 + 87]
    checkpoint := HEADER-SIZE + 4096 + 87 - writer.flush
    writer.close
    retry := SlotFirmwareWriter backend checkpoint expected.size
    backend.fail = operation
    expect-throw "FLASH_FAILURE": retry.write expected[checkpoint..]
    retry.close
    expect-equals expected[..checkpoint] backend.canonical[..checkpoint]
    expect-equals 0 backend.stages
    backend.fail = null
    retry = SlotFirmwareWriter backend checkpoint expected.size
    retry.write expected[checkpoint..]
    retry.commit (crypto.sha256 expected)
    expect-equals expected backend.canonical
    retry.close

test-resume:
  expected := image
  // Cover durable sector boundaries and deliberately earlier checkpoints.
  [HEADER-SIZE, HEADER-SIZE + 4096, HEADER-SIZE + 8192].do: |checkpoint|
    backend := MemorySlot
    initial := SlotFirmwareWriter backend 0 expected.size
    received := HEADER-SIZE + 8192 + 87
    initial.write expected[..received]
    expect-equals 87 initial.flush
    expect (checkpoint <= received - initial.flush)
    initial.close
    expect-equals 0 backend.stages
    before := backend.erases.size
    resumed := SlotFirmwareWriter backend checkpoint expected.size
    expect-equals 1 backend.resumes
    expect-equals before backend.erases.size
    resumed.write expected[checkpoint..]
    resumed.commit (crypto.sha256 expected)
    expect-equals expected backend.canonical
    // Never erase any sector covered by the checkpoint.
    backend.erases[before..].do:
      expect (it >= (round-down (checkpoint - HEADER-SIZE) 4096))
    resumed.close

  // A checkpoint cannot carry an unchecked prefix into a staged image.
  backend := MemorySlot
  writer := SlotFirmwareWriter backend 0 expected.size
  writer.write expected
  checkpoint := expected.size - writer.flush
  writer.close
  backend.flash[7] = backend.flash[7] ^ 1
  resumed := SlotFirmwareWriter backend checkpoint expected.size
  resumed.write expected[checkpoint..]
  expect-throw "firmware: checksum mismatch": resumed.commit (crypto.sha256 expected)
  expect-equals 0 backend.stages
  resumed.close

test-invalid:
  expected := image
  backend := MemorySlot
  [[-1, expected.size], [0, 0], [10, 9], [0, backend.slot-size + 1]].do: |bounds|
    expect-throw "INVALID_ARGUMENT": SlotFirmwareWriter backend bounds[0] bounds[1]
  expect-equals 0 backend.begins
  writer := SlotFirmwareWriter backend 0 expected.size
  expect-throw "OUT_OF_BOUNDS": writer.pad -1 0
  expect-throw "OUT_OF_BOUNDS": writer.write (ByteArray (expected.size + 1))
  expect-throw "INVALID_ARGUMENT": writer.pad 1 256
  expect-equals 0 backend.begins
  writer.write expected[..expected.size - 1]
  expect-throw "firmware: incomplete image": writer.commit null
  expect-equals 0 backend.stages
  writer.write expected[expected.size - 1..]
  expect-throw "OUT_OF_BOUNDS": writer.write #[0]
  writer.commit (crypto.sha256 expected)
  writer.close
  expect-throw "INVALID_STATE": writer.write #[]

  [0, 1, 51, 53, expected.size].do: |size|
    backend = MemorySlot
    writer = SlotFirmwareWriter backend 0 expected.size
    header := ByteArray 4
    LITTLE-ENDIAN.put-uint32 header 0 size
    expect-throw "firmware: invalid relocation table size": writer.write header
    expect-equals 0 backend.begins
    expect-throw "INVALID_STATE": writer.write expected
    writer.close

  backend = MemorySlot
  writer = SlotFirmwareWriter backend 0 (expected.size - 1)
  expect-throw "firmware: image size differs from relocation table":
    writer.write expected[..HEADER-SIZE]
  expect-equals 0 backend.begins
  writer.close

  backend = MemorySlot
  writer = SlotFirmwareWriter backend 0 expected.size
  writer.write expected[..HEADER-SIZE]
  writer.close
  expect-throw "INVALID_ARGUMENT": SlotFirmwareWriter backend 4 expected.size
  [1, 16, 4095, 4097].do: |offset|
    expect-throw "INVALID_ARGUMENT":
      SlotFirmwareWriter backend (HEADER-SIZE + offset) expected.size
  expect-equals 0 backend.resumes
  expect-throw "firmware: image size differs from relocation table":
    SlotFirmwareWriter backend HEADER-SIZE (expected.size - 1)
  expect-equals 0 backend.resumes

test-failures:
  expected := image
  ["begin", "erase", "write"].do: |operation|
    backend := MemorySlot
    writer := SlotFirmwareWriter backend 0 expected.size
    backend.fail = operation
    expect-throw "FLASH_FAILURE": writer.write expected
    expect-throw "INVALID_STATE": writer.commit null
    expect-throw "INVALID_STATE": writer.write #[]
    writer.close
    expect (not backend.armed)
    expect-equals 0 backend.stages
  ["write", "stage"].do: |operation|
    backend := MemorySlot
    writer := SlotFirmwareWriter backend 0 expected.size
    writer.write expected
    backend.fail = operation
    expect-throw "FLASH_FAILURE": writer.commit (crypto.sha256 expected)
    expect-throw "INVALID_STATE": writer.commit null
    writer.close
    expect (not backend.armed)
    expect-equals 0 backend.stages

  backend := MemorySlot
  writer := SlotFirmwareWriter backend 0 expected.size
  writer.write expected
  writes := backend.writes
  expect-throw "firmware: checksum mismatch": writer.commit (ByteArray 32)
  expect-equals writes backend.writes
  expect-equals 0 backend.stages
  writer.close
  backend.fail = "read"
  expect-throw "FLASH_FAILURE": SlotFirmwareWriter backend HEADER-SIZE expected.size
  expect (not backend.armed)

class MemorySlot implements SlotWriterBackend:
  flash := ByteArray 16384 --initial=0xa5
  table/ByteArray? := null
  begins := 0
  resumes := 0
  erases := []
  writes := 0
  stages := 0
  armed := false
  fail/string? := null

  slot-size -> int: return flash.size

  check operation/string -> none:
    if fail == operation: throw "FLASH_FAILURE"

  begin bytes/ByteArray --resume/bool -> none:
    check "begin"
    if resume:
      expect-equals table bytes
      resumes++
    else:
      table = bytes.copy
      begins++
    armed = true

  canonical -> ByteArray:
    bytes := ByteArray (4 + table.size + (LITTLE-ENDIAN.uint32 table 12) + (LITTLE-ENDIAN.uint32 table 24))
    LITTLE-ENDIAN.put-uint32 bytes 0 table.size
    bytes.replace 4 table 0 table.size
    bytes.replace (4 + table.size) flash 0 (bytes.size - 4 - table.size)
    return bytes

  read offset/int bytes/ByteArray -> none:
    check "read"
    source := canonical
    bytes.replace 0 source offset (offset + bytes.size)

  erase offset/int -> none:
    check "erase"
    expect armed
    expect-equals 0 (offset % 4096)
    flash.fill --from=offset --to=(offset + 4096) 0xff
    erases.add offset

  write offset/int bytes/ByteArray -> none:
    check "write"
    expect armed
    expect-equals 0 (offset % 16)
    expect-equals 0 (bytes.size % 16)
    bytes.size.repeat: expect-equals 0xff flash[offset + it]
    if fail == "torn-write":
      flash.replace offset bytes 0 16
      throw "FLASH_FAILURE"
    flash.replace offset bytes 0 bytes.size
    writes++

  end -> none:
    armed = false

  stage -> none:
    check "stage"
    expect (not armed)
    stages++
