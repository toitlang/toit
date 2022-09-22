// Copyright (C) 2022 Toitware ApS.
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
import writer

import host.file
import host.arguments show *

OUTPUT_OPTION ::= "output"

/**
  usage: inject_image <img file> <bin file> -o <output file>
*/
main args/List:
  parser := ArgumentParser
  parser.describe_rest ["img-path", "bin-path"]
  parser.add_option OUTPUT_OPTION --short="o"
  parsed := parser.parse args
  img_path/string := parsed.rest[0] as string
  bin_path/string := parsed.rest[1] as string
  out_path/string := parsed[OUTPUT_OPTION]

  // img_data := file.read_content img_path
  img_data := ByteArray 1024: it & 0xff
  bin_data := file.read_content bin_path

  binary := Binary bin_data
  binary.add_irom_segment img_data
  print "Segments = $binary.segments_.size"
  binary.segments_.size.repeat: | segment/int |
    print "Segment $(segment + 1): $binary.segments_[segment]"

  out_stream := file.Stream.for_write out_path
  out_writer := writer.Writer out_stream
  out_writer.write binary.bits
  out_stream.close

/*
typedef struct {
    uint8_t magic;              /*!< Magic word ESP_IMAGE_HEADER_MAGIC */
    uint8_t segment_count;      /*!< Count of memory segments */
    uint8_t spi_mode;           /*!< flash read mode (esp_image_spi_mode_t as uint8_t) */
    uint8_t spi_speed: 4;       /*!< flash frequency (esp_image_spi_freq_t as uint8_t) */
    uint8_t spi_size: 4;        /*!< flash chip size (esp_image_flash_size_t as uint8_t) */
    uint32_t entry_addr;        /*!< Entry address */
    uint8_t wp_pin;            /*!< WP pin when SPI pins set via efuse (read by ROM bootloader,
                                * the IDF bootloader uses software to configure the WP
                                * pin and sets this field to 0xEE=disabled) */
    uint8_t spi_pin_drv[3];     /*!< Drive settings for the SPI flash pins (read by ROM bootloader) */
    esp_chip_id_t chip_id;      /*!< Chip identification number */
    uint8_t min_chip_rev;       /*!< Minimum chip revision supported by image */
    uint8_t reserved[8];       /*!< Reserved bytes in additional header space, currently unused */
    uint8_t hash_appended;      /*!< If 1, a SHA256 digest "simple hash" (of the entire image) is appended after the checksum.
                                 * Included in image length. This digest
                                 * is separate to secure boot and only used for detecting corruption.
                                 * For secure boot signed images, the signature
                                 * is appended after this (and the simple hash is included in the signed data). */
} __attribute__((packed))  esp_image_header_t;
*/

// https://docs.espressif.com/projects/esp-idf/en/latest/api-reference/system/app_image_format.html
class Binary:
  static MAGIC_OFFSET_         ::= 0
  static SEGMENT_COUNT_OFFSET_ ::= 1
  static HASH_APPENDED_OFFSET_ ::= 23
  static HEADER_SIZE_          ::= 24

  static ESP_CHECKSUM_MAGIC_   ::= 0xef

  header_/ByteArray
  segments_/List

  constructor bits/ByteArray:
    header_ = bits[0..HEADER_SIZE_]
    // TODO(kasper): Validate magic.
    offset := HEADER_SIZE_
    segments_ = List header_[SEGMENT_COUNT_OFFSET_]:
      segment := read_segment_ bits offset
      offset = segment.end
      segment

  bits -> ByteArray:
    // The total size of the resulting byte array must be
    // padded so it has 16-byte alignment. We place the
    // the XOR-based checksum as the last byte before that
    // boundary.
    end := segments_.last.end
    xor_checksum_offset/int := (round_up end + 1 16) - 1
    size := xor_checksum_offset + 1
    sha_checksum_offset/int? := null
    if hash_appended:
      sha_checksum_offset = size
      size += 32
    // Construct the resulting byte array and write the segments
    // into it. While we do that, we also compute the XOR-based
    // checksum and store it at the end.
    result := ByteArray size
    result.replace 0 header_
    xor_checksum := ESP_CHECKSUM_MAGIC_
    segments_.do: | segment/Segment |
      xor_checksum ^= segment.xor_checksum
      write_segment_ result segment
    result[xor_checksum_offset] = xor_checksum
    // Update the SHA256 checksum if necessary.
    if sha_checksum_offset:
      sha_checksum := crypto.sha256 result 0 sha_checksum_offset
      result.replace sha_checksum_offset sha_checksum
    return result

  hash_appended -> bool:
    return header_[HASH_APPENDED_OFFSET_] == 1

  add_segment bits/ByteArray address/int -> Segment:
    offset := segments_.last.end
    segment := Segment bits --offset=offset --address=address
    header_[SEGMENT_COUNT_OFFSET_]++
    segments_.add segment
    return segment

  add_irom_segment bits/ByteArray -> Segment:
    return add_segment bits find_free_irom_address

  find_free_irom_address -> int:
    address := Segment.IROM_MAP_START_
    segments_.do: | segment/Segment |
      if not segment.is_irom: continue.do
      end := segment.address + segment.size
      address = max address (round_up end 4096)
    return address

  static read_segment_ bits/ByteArray offset/int -> Segment:
    address := LITTLE_ENDIAN.uint32 bits offset + Segment.LOAD_ADDRESS_OFFSET_
    size := LITTLE_ENDIAN.uint32 bits offset + Segment.DATA_LENGTH_OFFSET_
    start := offset + Segment.HEADER_SIZE_
    return Segment bits[start..start + size]
        --offset=offset
        --address=address

  static write_segment_ bits/ByteArray segment/Segment -> none:
    offset := segment.offset
    LITTLE_ENDIAN.put_uint32 bits (offset + Segment.LOAD_ADDRESS_OFFSET_) segment.address
    LITTLE_ENDIAN.put_uint32 bits (offset + Segment.DATA_LENGTH_OFFSET_) segment.size
    bits.replace (offset + Segment.HEADER_SIZE_) segment.bits

class Segment:
  static LOAD_ADDRESS_OFFSET_ ::= 0
  static DATA_LENGTH_OFFSET_  ::= 4
  static HEADER_SIZE_         ::= 8

  static IROM_MAP_START_ ::= 0x400d0000
  static IROM_MAP_END_   ::= 0x40400000

  bits/ByteArray
  offset/int
  address/int

  constructor .bits --.offset --.address:

  size -> int:
    return bits.size

  end -> int:
    return offset + HEADER_SIZE_ + size

  is_irom -> bool:
    return IROM_MAP_START_ <= address < IROM_MAP_END_

  xor_checksum -> int:
    result := 0
    bits.do: result ^= it
    return result

  stringify -> string:
    return "len 0x$(%05x size) load 0x$(%08x address)"
