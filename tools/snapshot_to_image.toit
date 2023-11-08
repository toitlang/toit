// Copyright (C) 2019 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
This program reads a snapshot, converts it into an image
  and dumps the content as a binary file or a source file to
  be read by the GNU assembler. Binary image outputs are left
  relocatable.
*/

import .image
import .snapshot
import .firmware show pad

import binary show LITTLE-ENDIAN ByteOrder
import bytes
import encoding.ubjson
import system
import uuid

import host.file
import cli

BINARY-FLAG      ::= "binary"
M32-FLAG         ::= "machine-32-bit"
M64-FLAG         ::= "machine-64-bit"
OUTPUT-OPTION    ::= "output"
FORMAT-OPTION    ::= "format"
ASSETS-OPTION    ::= "assets"
SNAPSHOT-FILE    ::= "snapshot-file"

abstract class RelocatedOutput:
  static ENDIAN/ByteOrder ::= LITTLE-ENDIAN

  out ::= ?
  constructor .out:

  abstract write-start -> none
  abstract write-word word/int is-relocatable/bool -> none
  abstract write-end -> none

  write word-size/int relocatable/ByteArray -> none:
    if word-size != 4: unreachable
    chunk-size := (word-size * 8 + 1) * word-size
    write-start
    List.chunk-up 0 relocatable.size chunk-size: | from to |
      write-chunk relocatable[from..to]
    write-end

  write-chunk chunk/ByteArray -> none:
    mask := ENDIAN.uint32 chunk 0
    for pos := 4; pos < chunk.size; pos += 4:
      write-word
          ENDIAN.uint32 chunk pos
          (mask & 1) != 0
      mask = mask >> 1

class BinaryRelocatedOutput extends RelocatedOutput:
  relocation-base/int ::= ?
  buffer_/ByteArray := ByteArray 4

  constructor out .relocation-base:
    super out

  write-start -> none:
    // Nothing to add here.

  write-end -> none:
    // Nothing to add here.

  write-word word/int is-relocatable/bool -> none:
    if is-relocatable: word += relocation-base
    write-uint32 word

  write-uint16 halfword/int:
    RelocatedOutput.ENDIAN.put-uint16 buffer_ 0 halfword
    out.write buffer_[0..2]

  write-uint32 word/int:
    RelocatedOutput.ENDIAN.put-uint32 buffer_ 0 word
    out.write buffer_

print-usage parser/cli.Command --error/string?=null:
  if error: print-on-stderr_ "Error: $error\n"
  print-on-stderr_ parser.usage
  exit 1

main args:
  parsed := null
  parser := cli.Command "snapshot_to_image"
      --rest=[cli.OptionString SNAPSHOT-FILE]
      --options=[
          cli.Flag M32-FLAG --short-name="m32",
          cli.Flag M64-FLAG --short-name="m64",
          cli.Flag BINARY-FLAG,
          cli.OptionEnum FORMAT-OPTION ["binary", "ubjson"],
          cli.OptionString OUTPUT-OPTION --short-name="o",
          cli.OptionString ASSETS-OPTION,
        ]
      --run=:: parsed = it

  parser.run args

  output-path/string? := parsed[OUTPUT-OPTION]

  if not output-path:
    print-usage parser --error="-o flag is not optional"

  format := ?
  if parsed[BINARY-FLAG]:
    if parsed[FORMAT-OPTION] != null:
      print-usage parser --error="cannot use --binary with --format option"
    format = "binary"
  else:
    format = parsed[FORMAT-OPTION]

  if not format:
    print-usage parser --error="no output format specified"

  machine-word-sizes := []
  if parsed[M32-FLAG]:
    machine-word-sizes.add 4
  if parsed[M64-FLAG]:
    machine-word-sizes.add 8
  if machine-word-sizes.is-empty:
    machine-word-sizes.add system.BYTES-PER-WORD

  if format == "binary" and machine-word-sizes.size > 1:
    print-usage parser --error="more than one machine flag provided"

  snapshot-path/string := parsed[SNAPSHOT-FILE]
  snapshot-bundle := SnapshotBundle.from-file snapshot-path
  snapshot-uuid ::= snapshot-bundle.uuid
  program := snapshot-bundle.decode
  system-uuid ::= sdk-version-uuid --sdk-version=snapshot-bundle.sdk-version
  assets-path := parsed[ASSETS-OPTION]
  assets := assets-path ? file.read-content assets-path : null
  id := image-id --snapshot-uuid=snapshot-uuid --assets=assets

  output := { "id": id.stringify }
  machine-word-sizes.do: | word-size/int |
    image := build-image program word-size
        --system-uuid=system-uuid
        --snapshot-uuid=snapshot-uuid
        --id=id
    buffer := bytes.Buffer
    buffer.write image.build-relocatable
    if assets:
      // Send the assets prefixed with the size and make sure
      // to round up to full "flash" pages.
      assets-size := ByteArray 4
      LITTLE-ENDIAN.put-uint32 assets-size 0 assets.size
      assets = pad (assets-size + assets) 4096
      // Encode the assets with dummy relocation information for
      // every chunk. The assets do not need relocation, but it
      // is simpler to just use the same image format for the
      // asset pages.
      chunk-size := word-size * 8 * word-size
      no-relocation := ByteArray word-size
      List.chunk-up 0 assets.size chunk-size: | from to |
        buffer.write no-relocation
        buffer.write assets[from..to]
    images := output.get "images" --init=: []
    machine := "-m$(word-size * 8)"
    images.add { "flags": [machine], "bytes": buffer.bytes }

  out := file.Stream.for-write output-path
  if format == "binary":
    out.write output["images"].first["bytes"]
  else:
    out.write (ubjson.encode output)
  out.close

sdk-version-uuid --sdk-version/string -> uuid.Uuid:
  return sdk-version.is-empty
      ? uuid.uuid5 "$random" "$Time.now-$Time.monotonic-us"
      : uuid.uuid5 "toit:sdk-version" sdk-version
