// Copyright (C) 2021 Toitware ApS.
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

import binary show LITTLE_ENDIAN
import bytes
import crypto.sha256 as crypto
import host.file
import host.arguments show *
import uuid
import writer
import encoding.json
import encoding.ubjson

// These two are the current offsets of the config data in the system image.
// We could auto-detect them from the bin file, but they are only used files
// from the current SDK so there's no need.
IMAGE_DATA_SIZE ::= 1024
IMAGE_DATA_OFFSET ::= 296

IMAGE_DATA_MAGIC_1 ::= 0x7017da7a
IMAGE_DATA_MAGIC_2 ::= 0xc09f19
/**
  usage: inject_config <config-json file> <bin file> [--unique_id=<uuid>] [<output file>]
*/
main args/List:
  parser := ArgumentParser
  parser.describe_rest ["config-path", "bin-path", "[out-path]"]
  parser.add_option "unique_id"
  parsed := parser.parse args
  config_path/string := parsed.rest[0] as string
  bin_path/string := parsed.rest[1] as string
  out_path/string := parsed.rest.size > 2 ? parsed.rest[2] as string : bin_path

  // Get the unique image id from the --unique_id argument or generate a random one.
  unique_id/uuid.Uuid := parsed["unique_id"]
      ? uuid.parse parsed["unique_id"]
      : (uuid.uuid5 "$random" "$Time.now".to_byte_array)

  config_data := file.read_content config_path
  bin_data := file.read_content bin_path

  config := json.decode config_data

  result := inject_config config unique_id bin_data

  out_stream := file.Stream.for_write out_path
  out_writer := writer.Writer out_stream
  out_writer.write result
  out_stream.close

// The factory image contains an "empty" section of 1024 bytes where we encoded the config
// such that the image can run completely independently. This function updates the sha256
// and XOR checksums to ensure that the image stays valid.
inject_config config/Map unique_id/uuid.Uuid bin_data/ByteArray -> ByteArray:
  image_data_position := get_image_data_position bin_data
  image_data_offset := image_data_position[0]
  image_data_size := image_data_position[1]
  image_config_size := image_data_size - uuid.SIZE

  config_data := ubjson.encode config

  // We need to regenerate the checksums for the image. Checksum format is described here:
  // https://docs.espressif.com/projects/esp-idf/en/latest/api-reference/system/app_image_format.html

  // NOTE this will not work if we enable CONFIG_SECURE_SIGNED_APPS_NO_SECURE_BOOT or CONFIG_SECURE_BOOT_ENABLED

  hash_appended := bin_data[23] == 1

  xor_cs_offset := bin_data.size - 1
  if hash_appended:
    xor_cs_offset = bin_data.size - 1 - 32

  for i := image_data_offset; i < image_data_offset + image_data_size; i++:
    bin_data[xor_cs_offset] ^= bin_data[i]

  if config_data.size > image_data_size:
    throw "config too big to inline into binary"

  bin_data.replace image_data_offset (ByteArray image_data_size)  // Zero out area.
  bin_data.replace image_data_offset config_data
  bin_data.replace image_data_offset + image_config_size unique_id.to_byte_array

  for i := image_data_offset; i < image_data_offset + image_data_size; i++:
    bin_data[xor_cs_offset] ^= bin_data[i]

  if hash_appended:
    boundary := bin_data.size - 32
    bin_data.replace boundary (crypto.sha256 bin_data 0 boundary)

  return bin_data

// Searches for two magic numbers that surround the image data area.
// This is the area in the image that is replaced with the config data.
// The exact location of this area can depend on a future SDK version
// so we don't know it exactly.
get_image_data_position bytes/ByteArray -> List:
  WORD_SIZE ::= 4
  for i := 0; i < bytes.size; i += WORD_SIZE:
    word_1 := LITTLE_ENDIAN.uint32 bytes i
    if word_1 == IMAGE_DATA_MAGIC_1:
      // Search for the end at the (0.5k + word_size) position and at
      // subsequent positions up to a data area of 4k.  We only search at these
      // round numbers in order to reduce the chance of false positives.
      for j := 0x200 + WORD_SIZE; j <= 0x1000 + WORD_SIZE and i + j < bytes.size; j += 0x200:
        word_2 := LITTLE_ENDIAN.uint32 bytes i + j
        if word_2 == IMAGE_DATA_MAGIC_2:
          return [i + WORD_SIZE, j - WORD_SIZE]
  // No magic numbers were found so the image is from a legacy SDK that has the
  // image data at a fixed offset.
  throw "invalid bin file, magic markers not found"
