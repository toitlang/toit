// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.file
import host.pipe
import io

import ...tools.snapshot-to-image
import ...tools.firmware as firmware
import ...tools.snapshot show SnapshotBundle

/**
Tests that the Toit implementation of the relocation works.
*/

main args:
  arg-index := 0
  ignored-snap := args[arg-index++]
  toitrun := args[arg-index++]
  snapshot-to-image := args[arg-index++]

  test-dir := directory.mkdtemp "/tmp/test-snapshot_to_image-"
  try:
    toit-file := "$test-dir/test.toit"
    snap-file := "$test-dir/test.snap"
    img32-file := "$test-dir/test32.img"
    img64-file := "$test-dir/test64.img"

    file.write-content --path=toit-file """
      main:
        print "hello world"
      """
    pipe.run-program toitrun "-w" snap-file toit-file

    pipe.run-program [toitrun, snapshot-to-image, "--format", "binary", "-m32", "-o", img32-file, snap-file]
    pipe.run-program [toitrun, snapshot-to-image, "--format", "binary", "-m64", "-o", img64-file, snap-file]

    snapshot := file.read-content snap-file
    snapshot-bundle := SnapshotBundle "snapshot" snapshot
    snapshot-uuid ::= snapshot-bundle.uuid

    word-size := 4
    buffer := io.Buffer
    relocatable := file.read-content img32-file
    relocated-output := BinaryRelocatedOutput buffer 0x00000000 --word-size=word-size
    relocated-output.write relocatable
    relocated := buffer.bytes
    chunk-size := (word-size * 8 + 1) * word-size
    chunks-count := (relocatable.size + chunk-size - 1) / chunk-size
    expected-size := relocatable.size - chunks-count * word-size
    expect-equals expected-size relocated.size
    header := firmware.ImageHeader relocated --word-size=word-size
    expect-equals snapshot-uuid header.snapshot-uuid

    word-size = 8
    buffer = io.Buffer
    relocatable = file.read-content img64-file
    relocated-output = BinaryRelocatedOutput buffer 0x00000000 --word-size=word-size
    relocated-output.write relocatable
    relocated = buffer.bytes
    chunk-size = (word-size * 8 + 1) * word-size
    chunks-count = (relocatable.size + chunk-size - 1) / chunk-size
    expected-size = relocatable.size - chunks-count * word-size
    expect-equals expected-size relocated.size
    header = firmware.ImageHeader relocated --word-size=word-size
    expect-equals snapshot-uuid header.snapshot-uuid

  finally:
    directory.rmdir --recursive test-dir
