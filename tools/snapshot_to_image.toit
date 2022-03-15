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

// This program reads a snapshot, converts it into an image
// and dumps the content as a binary file or a source file to
// be read by the GNU assembler. Binary image outputs can be
// relocated to a specific address or left relocatable.

import .image
import .snapshot

import binary show LITTLE_ENDIAN ByteOrder
import uuid
import host.file
import services.arguments

BINARY_FLAG      ::= "binary"
M32_FLAG         ::= "machine-32-bit"
M64_FLAG         ::= "machine-64-bit"
RELOCATE_OPTION  ::= "relocate"
UNIQUE_ID_OPTION ::= "unique_id"

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
  static HEADER_SIZE ::= 48

  size/int ::= ?
  relocation_base/int ::= ?
  image_uuid/uuid.Uuid ::= ?

  buffer_/ByteArray := ByteArray 4
  skip_header_bytes_ := HEADER_SIZE

  constructor out .size .relocation_base .image_uuid:
    super out

  write_start -> none:
    write_uint32 0xDEADFACE                        // Marker.
    write_uint32 0                                 // Offset in partition.
    write_uuid (uuid.uuid5 "program" "$Time.now")  // Program id.
    out.write #[0xFF, 0xFF, 0xFF, 0xFF, 0xFF]      // Metadata.
    write_uint16 (size + 4095) / 4096              // Pages in flash.
    out.write #[0x02]                              // Type = program.
    write_uuid image_uuid                          // Image uuid.

  write_word word/int is_relocatable/bool -> none:
    // Skip the words that are part of the header. They are all written
    // using $write_start.
    if skip_header_bytes_ > 0:
      skip_header_bytes_ -= 4
      return
    if is_relocatable: word += relocation_base
    write_uint32 word

  write_end -> none:
    // Nothing to add here.

  write_uint16 halfword/int:
    RelocatedOutput.ENDIAN.put_uint16 buffer_ 0 halfword
    out.write buffer_[0..2]

  write_uint32 word/int:
    RelocatedOutput.ENDIAN.put_uint32 buffer_ 0 word
    out.write buffer_

  write_uuid uuid/uuid.Uuid:
    out.write uuid.to_byte_array

class SourceRelocatedOutput extends RelocatedOutput:
  constructor out:
    super out

  write_start -> none:
    writeln "        .globl toit_image"
    writeln "        .globl toit_image_size"
    writeln "        .section .rodata"
    writeln "        .align 4"
    writeln "toit_image:"

  write_word word/int is_relocatable/bool:
    if is_relocatable: writeln "        .long toit_image + 0x$(%x word)"
    else:              writeln "        .long 0x$(%x word)"

  write_end -> none:
    writeln "toit_image_size: .long toit_image_size - toit_image"

  writeln text/string:
    out.write text
    out.write "\n"

print_usage:
  print_ "Usage: snapshot_to_image [--$BINARY_FLAG] [--$RELOCATE_OPTION=0x...] [-m32|-m64] <snapshot> <output>"

main args:
  parser := arguments.ArgumentParser
  parser.add_flag M32_FLAG --short="m32"
  parser.add_flag M64_FLAG --short="m64"
  parser.add_flag BINARY_FLAG

  parser.add_option RELOCATE_OPTION
  parser.add_option UNIQUE_ID_OPTION --default="00000000-0000-0000-0000-000000000000"

  parsed := parser.parse args
  if parsed.rest.size != 2:
    print_usage
    return

  snapshot_path/string := parsed.rest[0]
  output_path/string := parsed.rest[1]

  default_word_size := BYTES_PER_WORD
  binary_output := false
  if parsed[BINARY_FLAG]:
    binary_output = true
  else:
    default_word_size = 4  // Use 32-bit non-binary output.

  relocation_base/int? := null
  relocate_option := parsed[RELOCATE_OPTION]
  if relocate_option:
    if not (relocate_option.starts_with "0x"):
      print_usage
      return
    relocation_base = int.parse relocate_option[2..] --radix=16

  word_size := null
  if parsed[M32_FLAG]:
    word_size = 4
  if parsed[M64_FLAG]:
    if word_size:
      print_usage  // Already set to -m32.
      return
    word_size = 8
  if not word_size:
    word_size = default_word_size

  if not binary_output and word_size != 4:
    print_ "Error: Cannot generate 64-bit non-binary output"
    return

  if not binary_output and relocation_base:
    print_ "Error: Relocation only works for 32-bit binary output"
    return

  out := file.Stream.for_write output_path
  snapshot_bundle := SnapshotBundle.from_file snapshot_path
  program := snapshot_bundle.decode
  image := build_image program word_size
  relocatable := image.build_relocatable
  if binary_output:
    if relocation_base:
      image_uuid := uuid.parse parsed[UNIQUE_ID_OPTION]
      output := BinaryRelocatedOutput out relocatable.size relocation_base image_uuid
      output.write word_size relocatable
    else:
      out.write relocatable
  else:
    output := SourceRelocatedOutput out
    output.write word_size relocatable
  out.close
