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

import binary show LITTLE_ENDIAN ByteOrder
import bytes
import encoding.ubjson
import uuid
import host.file
import cli

BINARY_FLAG      ::= "binary"
M32_FLAG         ::= "machine-32-bit"
M64_FLAG         ::= "machine-64-bit"
OUTPUT_OPTION    ::= "output"
FORMAT_OPTION    ::= "format"
ASSETS_OPTION    ::= "assets"
SNAPSHOT_FILE    ::= "snapshot-file"

abstract class RelocatedOutput:
  static ENDIAN/ByteOrder ::= LITTLE_ENDIAN

  out ::= ?
  constructor .out:

  abstract write_start -> none
  abstract write_word word/int is_relocatable/bool -> none
  abstract write_end -> none

  write word_size/int relocatable/ByteArray -> none:
    if word_size != 4: unreachable
    chunk_size := (word_size * 8 + 1) * word_size
    write_start
    List.chunk_up 0 relocatable.size chunk_size: | from to |
      write_chunk relocatable[from..to]
    write_end

  write_chunk chunk/ByteArray -> none:
    mask := ENDIAN.uint32 chunk 0
    for pos := 4; pos < chunk.size; pos += 4:
      write_word
          ENDIAN.uint32 chunk pos
          (mask & 1) != 0
      mask = mask >> 1

class BinaryRelocatedOutput extends RelocatedOutput:
  relocation_base/int ::= ?
  buffer_/ByteArray := ByteArray 4

  constructor out .relocation_base:
    super out

  write_start -> none:
    // Nothing to add here.

  write_end -> none:
    // Nothing to add here.

  write_word word/int is_relocatable/bool -> none:
    if is_relocatable: word += relocation_base
    write_uint32 word

  write_uint16 halfword/int:
    RelocatedOutput.ENDIAN.put_uint16 buffer_ 0 halfword
    out.write buffer_[0..2]

  write_uint32 word/int:
    RelocatedOutput.ENDIAN.put_uint32 buffer_ 0 word
    out.write buffer_

print_usage parser/cli.Command --error/string?=null:
  if error: print_on_stderr_ "Error: $error\n"
  print_on_stderr_ parser.usage
  exit 1

main args:
  parsed := null
  parser := cli.Command "snapshot_to_image"
      --rest=[cli.OptionString SNAPSHOT_FILE]
      --options=[
          cli.Flag M32_FLAG --short_name="m32",
          cli.Flag M64_FLAG --short_name="m64",
          cli.Flag BINARY_FLAG,
          cli.OptionEnum FORMAT_OPTION ["binary", "ubjson"],
          cli.OptionString OUTPUT_OPTION --short_name="o",
          cli.OptionString ASSETS_OPTION,
        ]
      --run=:: parsed = it

  parser.run args

  output_path/string? := parsed[OUTPUT_OPTION]

  if not output_path:
    print_usage parser --error="-o flag is not optional"

  format := ?
  if parsed[BINARY_FLAG]:
    if parsed[FORMAT_OPTION] != null:
      print_usage parser --error="cannot use --binary with --format option"
    format = "binary"
  else:
    format = parsed[FORMAT_OPTION]

  if not format:
    print_usage parser --error="no output format specified"

  machine_word_sizes := []
  if parsed[M32_FLAG]:
    machine_word_sizes.add 4
  if parsed[M64_FLAG]:
    machine_word_sizes.add 8
  if machine_word_sizes.is_empty:
    machine_word_sizes.add BYTES_PER_WORD

  if format == "binary" and machine_word_sizes.size > 1:
    print_usage parser --error="more than one machine flag provided"

  snapshot_path/string := parsed[SNAPSHOT_FILE]
  snapshot_bundle := SnapshotBundle.from_file snapshot_path
  snapshot_uuid ::= snapshot_bundle.uuid
  program := snapshot_bundle.decode
  system_uuid ::= sdk_version_uuid --sdk_version=snapshot_bundle.sdk_version
  assets_path := parsed[ASSETS_OPTION]
  assets := assets_path ? file.read_content assets_path : null
  id := image_id --snapshot_uuid=snapshot_uuid --assets=assets

  output := { "id": id.stringify }
  machine_word_sizes.do: | word_size/int |
    image := build_image program word_size
        --system_uuid=system_uuid
        --snapshot_uuid=snapshot_uuid
        --id=id
    buffer := bytes.Buffer
    buffer.write image.build_relocatable
    if assets:
      // Send the assets prefixed with the size and make sure
      // to round up to full "flash" pages.
      assets_size := ByteArray 4
      LITTLE_ENDIAN.put_uint32 assets_size 0 assets.size
      assets = pad (assets_size + assets) 4096
      // Encode the assets with dummy relocation information for
      // every chunk. The assets do not need relocation, but it
      // is simpler to just use the same image format for the
      // asset pages.
      chunk_size := word_size * 8 * word_size
      no_relocation := ByteArray word_size
      List.chunk_up 0 assets.size chunk_size: | from to |
        buffer.write no_relocation
        buffer.write assets[from..to]
    images := output.get "images" --init=: []
    machine := "-m$(word_size * 8)"
    images.add { "flags": [machine], "bytes": buffer.bytes }

  out := file.Stream.for_write output_path
  if format == "binary":
    out.write output["images"].first["bytes"]
  else:
    out.write (ubjson.encode output)
  out.close

sdk_version_uuid --sdk_version/string -> uuid.Uuid:
  return sdk_version.is_empty
      ? uuid.uuid5 "$random" "$Time.now-$Time.monotonic_us"
      : uuid.uuid5 "toit:sdk-version" sdk_version
