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

import encoding.ubjson
import io
import io show LITTLE-ENDIAN ByteOrder
import system
import uuid show *

import host.file
import cli

M32-FLAG         ::= "machine-32-bit"
M64-FLAG         ::= "machine-64-bit"
OUTPUT-OPTION    ::= "output"
FORMAT-OPTION    ::= "format"
ASSETS-OPTION    ::= "assets"
SNAPSHOT-FILE    ::= "snapshot-file"

abstract class RelocatedOutput:
  static ENDIAN/ByteOrder ::= LITTLE-ENDIAN

  out-le/io.EndianWriter
  word-size/int

  constructor out/io.Writer --.word-size:
    out-le = out.little-endian

  abstract write-start -> none
  abstract write-word word/int is-relocatable/bool -> none
  abstract write-end -> none

  write relocatable/ByteArray -> none:
    chunk-size := (word-size * 8 + 1) * word-size
    write-start
    List.chunk-up 0 relocatable.size chunk-size: | from to |
      write-chunk relocatable[from..to]
    write-end

  write-chunk chunk/ByteArray -> none:
    if word-size == 4:
      mask := ENDIAN.uint32 chunk 0
      for pos := word-size; pos < chunk.size; pos += word-size:
        word := ENDIAN.uint32 chunk pos
        write-word word ((mask & 1) != 0)
        mask = mask >> 1
    else if word-size == 8:
      mask := ENDIAN.int64 chunk 0
      for pos := word-size; pos < chunk.size; pos += word-size:
        word := ENDIAN.int64 chunk pos
        write-word word ((mask & 1) != 0)
        mask = mask >> 1
    else:
      unreachable

class BinaryRelocatedOutput extends RelocatedOutput:
  relocation-base/int ::= ?

  constructor out/io.Writer .relocation-base --word-size/int:
    super out --word-size=word-size

  write-start -> none:
    // Nothing to add here.

  write-end -> none:
    // Nothing to add here.

  write-word word/int is-relocatable/bool -> none:
    if is-relocatable: word += relocation-base
    if word-size == 4:
      out-le.write-uint32 word
    else:
      out-le.write-int64 word

print-usage parser/cli.Command --error/string?=null:
  if error: print-on-stderr_ "Error: $error\n"
  print-on-stderr_ parser.usage
  exit 1

build-command -> cli.Command:
  cmd := cli.Command "snapshot-to-image"
      --help="""
        Converts a snapshot into an image.

        Images are word-size specific. If built with `-m32`, the image
        will be 32-bit, and if built with `-m64`, the image will be 64-bit.
        When compiling to a binary (--format=binary), exactly one of these flags
        must be provided. When compiling to UBJSON (--format=ubjson), both flags
        may be provided, in which case the image will be compiled to both
        word sizes.

        The binary format produces a single relocatable image.
        The UBJSON format produces a dictionary with the following entries:
          - 'id': The image ID.
          - 'images': A list of images, each with the following entries:
            - 'flags': A list of flags used to build the image. Either `-m32` or `-m64`.
            - 'bytes': The image bytes as a byte array.

        If an assets file is provided, it will be included in the image.
        """
      --rest=[cli.Option SNAPSHOT-FILE]
      --options=[
          cli.Flag M32-FLAG --short-name="m32" --help="Build a 32-bit image.",
          cli.Flag M64-FLAG --short-name="m64" --help="Build a 64-bit image.",
          cli.OptionEnum FORMAT-OPTION ["binary", "ubjson"] --required --help="Output format.",
          cli.Option OUTPUT-OPTION --short-name="o" --required --help="Output file.",
          cli.Option ASSETS-OPTION --help="Path to assets file.",
        ]
      --run=:: snapshot-to-image it
  return cmd

main args:
  cmd := build-command
  cmd.run args

snapshot-to-image parsed/cli.Parsed:
  output-path/string? := parsed[OUTPUT-OPTION]

  format := parsed[FORMAT-OPTION]

  machine-word-sizes := []
  if parsed[M32-FLAG]:
    machine-word-sizes.add 4
  if parsed[M64-FLAG]:
    machine-word-sizes.add 8
  if machine-word-sizes.is-empty:
    machine-word-sizes.add system.BYTES-PER-WORD

  if format == "binary" and machine-word-sizes.size > 1:
    print "More than one machine flag provided"
    exit 1

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
    buffer := io.Buffer
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
  writer := io.Writer.adapt out
  if format == "binary":
    writer.write output["images"].first["bytes"]
  else:
    writer.write (ubjson.encode output)
  out.close

sdk-version-uuid --sdk-version/string -> Uuid:
  return sdk-version.is-empty
      ? Uuid.uuid5 "$random" "$Time.now-$Time.monotonic-us"
      : Uuid.uuid5 "toit:sdk-version" sdk-version
